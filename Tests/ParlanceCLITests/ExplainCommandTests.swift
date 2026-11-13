import Dispatch
import Foundation
import ParlanceCore
import Testing
import os

@testable import ParlanceCLI

private let quickReply = """
  <translation>Translation.</translation><plain>Simple explanation.</plain><terms><term><word>pool</word><ipa>puːl</ipa><meaning>shared resources</meaning><here>connections</here></term><term><word>empty</word><meaning>none</meaning><here>no connections</here></term></terms>
  """
private let pemNotice =
  "pl: a PEM block was redacted from the text sent; a stray marker takes the text around it too. Use --show-sent to inspect.\n"
private func reply(_ text: String = quickReply, finish: LLMFinishReason = .stop) -> [MockProvider
  .Step]
{
  [
    .event(.text(text)), .event(.usage(LLMUsage(promptTokens: 2, completionTokens: 3))),
    .event(.finished(finish)),
  ]
}
private func fakePEM(_ body: String = "obviously fake body") -> String {
  "-----BEGIN " + "PRIVATE KEY-----\n" + body + "\n-----END " + "PRIVATE KEY-----"
}

/// One-shot observation with a deadline, used instead of polling or synchronization sleeps.
private final class ExplainNotice<Value: Sendable>: Sendable {
  private struct Deadline: Error {}
  private struct State {
    var result: Result<Value, any Error>?
    var waiter: CheckedContinuation<Value, any Error>?
  }
  private let state = OSAllocatedUnfairLock(initialState: State())
  func send(_ value: Value) { resolve(.success(value)) }
  private func resolve(_ result: Result<Value, any Error>) {
    let waiter = state.withLock { state in
      guard state.result == nil else { return CheckedContinuation<Value, any Error>?.none }
      state.result = result
      let waiter = state.waiter
      state.waiter = nil
      return waiter
    }
    waiter?.resume(with: result)
  }
  func wait() async throws -> Value {
    let deadline = DispatchWorkItem { self.resolve(.failure(Deadline())) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: deadline)
    defer { deadline.cancel() }
    return try await withCheckedThrowingContinuation { continuation in
      let result: Result<Value, any Error>? = state.withLock { state in
        if let result = state.result { return result }
        state.waiter = continuation
        return Result<Value, any Error>?.none
      }
      if let result { continuation.resume(with: result) }
    }
  }
}

/// MockProvider's delay advances only when the test releases it; the observation is bounded.
private struct ExplainClock: Clock {
  typealias Instant = ContinuousClock.Instant
  let now = ContinuousClock.now
  var minimumResolution: Duration { .nanoseconds(1) }
  let sleeping = ExplainNotice<Bool>()
  let release = ExplainNotice<Bool>()
  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    sleeping.send(true)
    _ = try await release.wait()
    try Task.checkCancellation()
  }
  func advance() { release.send(true) }
}

private final class ExplainHarness: LLMProvider, Sendable {
  struct State {
    var out = ""
    var err = ""
    var reads = 0
    var contextReads: [String] = []
    var tokens: [LLMCancellation] = []
    var signal: (@Sendable (UInt) -> Void)?
    var subscribedDuringRead = false
    var subscribedDuringKey = false
    var stopped = false
    var resolved: ResolvedProvider?
  }
  let state = OSAllocatedUnfairLock(initialState: State())
  let provider: MockProvider
  let prepared = ExplainNotice<Bool>()
  let called = ExplainNotice<Bool>()
  let finished = ExplainNotice<Int32>()
  let displayed = ExplainNotice<Bool>()
  init(scripts: [[MockProvider.Step]] = [reply()], clock: any Clock<Duration> = ContinuousClock()) {
    provider = MockProvider(scripts: scripts, clock: clock)
  }
  var output: String { state.withLock { $0.out } }
  var error: String { state.withLock { $0.err } }
  func signal() { state.withLock { $0.signal }?(1) }
  func cancel() {
    signal()
    for token in state.withLock({ $0.tokens }) { token.cancel() }
  }
  func stream(_ request: LLMRequest, cancellation: LLMCancellation) -> AsyncThrowingStream<
    LLMEvent, any Error
  > {
    state.withLock { $0.tokens.append(cancellation) }
    let stream = provider.stream(request, cancellation: cancellation)
    called.send(true)
    return stream
  }
  func run(
    _ args: [String] = ["explain", "input"], stdin: Data = Data(), inputTTY: Bool = false,
    outputTTY: Bool = false, errorTTY: Bool = false,
    variables: [String: String] = ["OPENAI_API_KEY": "fake-test-key"], config: String? = nil,
    context: Data? = nil, readError: Bool = false, beforeStart: Bool = false,
    interruptOnTranslation: Bool = false, homeDirectory: String = "/test-home",
    currentDirectory: String = "/fictional/project"
  ) async -> Int32 {
    let environment = CLIEnvironment(
      variables: variables, stdinIsTTY: inputTTY, stdoutIsTTY: outputTTY, stderrIsTTY: errorTTY,
      readStdin: {
        self.state.withLock {
          $0.reads += 1
          $0.subscribedDuringRead = $0.signal != nil
        }
        if readError { throw CocoaError(.fileReadUnknown) }
        return stdin
      },
      stdout: { text in
        self.state.withLock { $0.out += text }
        if text.contains("Translation.") {
          self.displayed.send(true)
          if interruptOnTranslation { self.signal() }
        }
      },
      stderr: { text in
        let ready = self.state.withLock {
          $0.err += text
          return $0.err.contains("Input:\n[REDACTED]") && $0.err.contains(pemNotice)
        }
        if ready { self.prepared.send(true) }
      },
      makeProvider: { resolved in
        self.state.withLock { $0.resolved = resolved }
        return self
      },
      interruptSource: CLIInterruptSource { receive in
        self.state.withLock { $0.signal = receive }
        if beforeStart { receive(1) }
        return {
          self.state.withLock {
            $0.signal = nil
            $0.stopped = true
          }
        }
      },
      homeDirectory: homeDirectory,
      readConfig: { _ in config.map { Data($0.utf8) } },
      runKeyCommand: { _, _ in
        self.state.withLock { $0.subscribedDuringKey = $0.signal != nil }
        return APIKeyCommandResult(termination: .exit(0), stdout: Data("fake-helper-key".utf8))
      },
      readContextTail: { path in
        if path == "-" {
          self.state.withLock {
            $0.reads += 1
            $0.subscribedDuringRead = $0.signal != nil
          }
          if readError { throw CocoaError(.fileReadUnknown) }
          return stdin.suffix(CommandInput.contextReadBytes)
        }
        self.state.withLock {
          $0.contextReads.append(path)
          $0.subscribedDuringRead = $0.signal != nil
        }
        if readError { throw CocoaError(.fileReadUnknown) }
        if let context { return context.suffix(CommandInput.contextReadBytes) }
        return try CommandInput.readFileTail(path)
      }, currentDirectory: currentDirectory)
    let code = await CLIEnvironment.$override.withValue(environment) {
      await PL.execute(arguments: args).rawValue
    }
    finished.send(code)
    return code
  }
  func object() throws -> [String: Any] {
    #expect(output.split(separator: "\n").count == 1)
    return try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  }
}

struct ExplainCommandTests {
  private let commandReply = """
    <translation>Cleanup.</translation><plain>Deletes files.</plain><command>
    <part><code>sudo</code><does>Raise privileges.</does><effects>privilege</effects></part>
    <part><code>rm -rf</code><does>Delete files.</does><effects>deletes, writes, deletes, UNKNOWN</effects></part>
    <part><code>/tmp/build</code><does>The target.</does></part></command><terms></terms>
    """

  @Test(arguments: [false, true])
  func commandPartsRenderInPlainAndTTY(_ tty: Bool) async {
    let harness = ExplainHarness(scripts: [reply(commandReply)])
    #expect(
      await harness.run(["explain", "sudo rm -rf /tmp/build", "--no-color"], outputTTY: tty) == 0)
    #expect(
      harness.output
        == "Cleanup.\nPlain: Deletes files.\nCommand:\n- sudo: Raise privileges. [privilege]\n- rm -rf: Delete files. [writes, deletes]\n- /tmp/build: The target.\nTerms:\n"
    )
  }

  /// #307: entity-written codes reach every CLI output as the input's own text.
  @Test(arguments: [false, true])
  func entityCodesAreDecodedInEveryOutput(_ tty: Bool) async throws {
    let entities = commandReply.replacingOccurrences(
      of: "<code>/tmp/build</code>", with: "<code>/tmp/build 2&gt;&amp;1</code>")
    let input = "sudo rm -rf /tmp/build 2>&1"
    let harness = ExplainHarness(scripts: [reply(entities)])
    #expect(await harness.run(["explain", input, "--no-color"], outputTTY: tty) == 0)
    #expect(harness.output.contains("- /tmp/build 2>&1: The target.\n"))
    let json = ExplainHarness(scripts: [reply(entities)])
    #expect(await json.run(["explain", input, "--json"], outputTTY: tty) == 0)
    let result = try #require(try json.object()["result"] as? [String: Any])
    let command = try #require(result["command"] as? [[String: Any]])
    #expect(command[2]["code"] as? String == "/tmp/build 2>&1")
  }

  @Test func commandPartsJSONAndSanitization() async throws {
    let hostile = commandReply.replacingOccurrences(of: "sudo", with: "\u{1B}[31msudo\u{0}")
      .replacingOccurrences(of: "Raise privileges.", with: "Raise\u{7} privileges.")
    for tty in [false, true] {
      let harness = ExplainHarness(scripts: [reply(hostile)])
      #expect(
        await harness.run(["explain", "sudo rm -rf /tmp/build", "--json"], outputTTY: tty) == 0)
      let object = try harness.object()
      #expect(object["schema"] as? Int == 1)
      let result = try #require(object["result"] as? [String: Any])
      let command = try #require(result["command"] as? [[String: Any]])
      #expect(command.count == 3)
      #expect(Set(command[0].keys) == ["code", "does", "effects"])
      #expect(command[0]["code"] as? String == "sudo")
      #expect(command[0]["does"] as? String == "Raise privileges.")
      #expect(command[0]["effects"] as? [String] == ["privilege"])
      #expect(command[1]["effects"] as? [String] == ["writes", "deletes"])
      #expect(command[2]["effects"] as? [String] == [])
      let plain = ExplainHarness(scripts: [reply(hostile)])
      #expect(
        await plain.run(["explain", "sudo rm -rf /tmp/build", "--no-color"], outputTTY: tty) == 0)
      #expect(plain.output.contains("- sudo: Raise privileges. [privilege]"))
      #expect(!plain.output.contains("\u{1B}"))
      #expect(!plain.output.contains("\u{7}"))
      #expect(!plain.output.contains("\u{0}"))
    }
  }

  @Test func commandPartsRequireClosedSectionAndPlainCompletion() async {
    let open = String(commandReply[..<commandReply.range(of: "</part>")!.upperBound])
    for tty in [false, true] {
      let harness = ExplainHarness(scripts: [reply(open, finish: .length)])
      #expect(await harness.run(["explain", "sudo rm -rf /tmp/build"], outputTTY: tty) == 8)
      #expect(!harness.output.contains("Command:"))
      if !tty { #expect(harness.output.isEmpty) }
    }
    let missing = ExplainHarness()
    #expect(await missing.run(["explain", "git status --short"]) == 8)
    #expect(missing.output.isEmpty)
  }

  @Test func showSentIncludesElsewhereFromContextFile() async throws {
    let definition = "| rollout gate | fictional release check |"
    let context =
      "Fictional heading.\n" + definition + "\n"
      + String(repeating: "Fictional filler.\n", count: 250)
    let harness = ExplainHarness()
    #expect(
      await harness.run(
        ["explain", "rollout gate", "--context", "fictional.md", "--show-sent"],
        context: Data(context.utf8)) == 0)
    let section = "\n\nBackground elsewhere in the same text:\n" + definition
    #expect(harness.error.contains(section))
    #expect(
      harness.provider.recordedRequests.first?.messages.last?.content.contains(section) == true)
    #expect(harness.state.withLock { $0.contextReads } == ["fictional.md"])
  }

  @Test func inputRules() async {
    let cases: [([String], Data, Bool, Int32, String?, Int)] = [
      (["hello", "world"], Data("unused".utf8), true, 0, "hello world", 0),
      (["-", "word"], Data(), false, 0, "- word", 0),
      (["-"], Data("from stdin".utf8), true, 0, "from stdin", 1),
      ([], Data("piped".utf8), false, 0, "piped", 1),
      ([], Data(), true, 64, nil, 0),
      ([" \n"], Data(), false, 64, nil, 0),
      ([], Data(" \t\n".utf8), false, 64, nil, 1),
      (["-"], Data([0xFF]), false, 64, nil, 1),
      ([String(repeating: "界", count: 20_001)], Data(), false, 64, nil, 0),
      ([], Data(String(repeating: "界", count: 20_001).utf8), false, 64, nil, 1),
      (
        ["\u{1B}[31m" + String(repeating: "界", count: 20_000) + "\u{1B}[0m"], Data(), false, 0,
        String(repeating: "界", count: 20_000), 0
      ),
      ([], Data("\u{1B}[31mhello\u{1B}[0m".utf8), false, 0, "hello", 1),
      (
        [], Data(("\u{1B}[31m" + String(repeating: "界", count: 20_000) + "\u{1B}[0m").utf8), false,
        0, String(repeating: "界", count: 20_000), 1
      ),
      (["\u{1B}[31m\u{1B}[0m"], Data(), false, 64, nil, 0),
    ]
    for (args, stdin, tty, code, sent, reads) in cases {
      let harness = ExplainHarness()
      #expect(await harness.run(["explain"] + args, stdin: stdin, inputTTY: tty) == code)
      #expect(harness.state.withLock { $0.reads } == reads)
      if let sent {
        #expect(
          harness.provider.recordedRequests.first?.messages.last?.content == "Input:\n" + sent)
      } else {
        #expect(harness.provider.recordedRequests.isEmpty)
        #expect(harness.output.isEmpty)
      }
    }
    let unreadable = ExplainHarness()
    #expect(await unreadable.run(["explain", "-"], readError: true) == 64)
    #expect(unreadable.provider.recordedRequests.isEmpty)
  }

  @Test func optionsAndConfiguration() async throws {
    for args in [
      ["--tone", "agent"], ["--mode", "correct"], ["--formality", "formal"], ["--deep", "other"],
      ["--deep"],
      ["--unknown\u{1B}[31m"],
    ] {
      let harness = ExplainHarness()
      #expect(await harness.run(["explain", "input", "--json"] + args) == 64)
      #expect(harness.provider.recordedRequests.isEmpty)
      #expect(harness.output.isEmpty)
      #expect(!harness.error.contains("\u{1B}"))
    }
    let help = ExplainHarness()
    #expect(await help.run(["explain", "--help"]) == 0)
    #expect(help.output.contains("--context"))
    #expect(help.output.contains("--deep"))
    let configured = ExplainHarness()
    #expect(
      await configured.run(
        ["explain", "x", "--target", "de", "--native", "fr", "--model", "custom"],
        config: "provider = 'openai'\ntarget_language = 'ja'\nnative_language = 'ko'") == 0)
    #expect(configured.state.withLock { $0.resolved?.model } == "custom")
    let prompt = try #require(configured.provider.recordedRequests.first?.messages.first?.content)
    #expect(prompt.contains("Target language: German (de)"))
    #expect(prompt.contains("Native language: French (fr)"))
    let defaults = ExplainHarness()
    #expect(await defaults.run() == 0)
    let defaultPrompt = try #require(
      defaults.provider.recordedRequests.first?.messages.first?.content)
    #expect(defaultPrompt.contains("Target language: English (en)"))
    #expect(defaultPrompt.contains("Native language: Chinese, Simplified (zh-Hans)"))
    let invalid = ExplainHarness()
    #expect(await invalid.run(["explain", "x", "--json"], config: "api_key = 'fake'") == 78)
    #expect(invalid.output.isEmpty)
    #expect(invalid.provider.recordedRequests.isEmpty)
  }

  @Test func missingKeyProducesAuthJSONWithoutSubscribing() async throws {
    let harness = ExplainHarness()
    #expect(
      await harness.run(["explain", "x", "--provider", "openai", "--json"], variables: [:]) == 3)
    #expect(harness.provider.recordedRequests.isEmpty)
    #expect(!harness.state.withLock { $0.stopped })
    let object = try harness.object()
    #expect(object["result"] is NSNull)
    let error = try #require(object["error"] as? [String: Any])
    #expect(error["code"] as? String == "auth")
    #expect(error["http_status"] is NSNull)
  }

  @Test func contextInputAndUTF8Tail() async throws {
    for args in [["explain", "--context", "-"], ["explain", "-", "--context", "-"]] {
      let harness = ExplainHarness()
      #expect(await harness.run(args, stdin: Data("unused".utf8)) == 64)
      #expect(harness.state.withLock { $0.reads } == 0)
      #expect(harness.provider.recordedRequests.isEmpty)
    }
    for source in ["-", "file"] {
      let harness = ExplainHarness()
      let data = Data((String(repeating: "古", count: 20_001) + "\u{1B}[31mtail\u{1B}[0m").utf8)
      #expect(
        await harness.run(["explain", "input", "--context", source], stdin: data, context: data)
          == 0)
      let sent = try #require(harness.provider.recordedRequests.first?.messages.last?.content)
      #expect(
        sent == "Input:\ninput\n\nBackground context:\n" + String(repeating: "古", count: 2996)
          + "tail")
      #expect(harness.state.withLock { $0.reads } == (source == "-" ? 1 : 0))
    }
    for prefix in [Data([0x80]), Data([0x80, 0x80]), Data([0x80, 0x80, 0x80])] {
      let harness = ExplainHarness()
      #expect(
        await harness.run(
          ["explain", "x", "--context", "file"], context: prefix + Data("tail".utf8)) == 0)
      #expect(
        harness.provider.recordedRequests.first?.messages.last?.content.hasSuffix("tail") == true)
    }
    for invalid in [
      Data([0x80, 0x80, 0x80, 0x80]), Data([0xFF]), Data([0x61, 0x80]), Data([0xE7, 0x95]),
    ] {
      let harness = ExplainHarness()
      #expect(
        await harness.run(["explain", "x", "--context", "file", "--json"], context: invalid) == 64)
      #expect(harness.output.isEmpty)
      #expect(harness.provider.recordedRequests.isEmpty)
    }
    let terminal = ExplainHarness()
    #expect(await terminal.run(["explain", "x", "--context", "-"], inputTTY: true) == 64)
    #expect(terminal.state.withLock { $0.reads } == 0)
    #expect(terminal.provider.recordedRequests.isEmpty)
    let empty = ExplainHarness()
    #expect(await empty.run(["explain", "x", "--context", "file"], context: Data()) == 0)
    let badPath = ExplainHarness()
    #expect(
      await badPath.run(["explain", "x", "--context", "bad\u{1B}[31mpath"], readError: true) == 64)
    #expect(!badPath.error.contains("\u{1B}"))
    // Invalid bytes outside the 16 KiB margin do not invalidate a UTF-8 tail.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try (Data([0xFF]) + Data(String(repeating: "界", count: 6000).utf8)).write(to: url)
    let actualFile = ExplainHarness()
    #expect(
      await actualFile.run(["explain", "-", "--context", url.path], stdin: Data("input".utf8)) == 0)
    #expect(
      actualFile.provider.recordedRequests.first?.messages.last?.content
        == "Input:\ninput\n\nBackground context:\n" + String(repeating: "界", count: 3000))
  }

  @Test func stdinReadingStopsPastTheLimit() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(count: 3 * CommandInput.stdinLimit).write(to: url)
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let head = try CommandInput.readHead(file, limit: CommandInput.stdinLimit)
    #expect(head.count > CommandInput.stdinLimit)
    #expect(head.count <= CommandInput.stdinLimit + 64 * 1024)
    let harness = ExplainHarness()
    #expect(await harness.run(["explain"], stdin: head) == 64)
    #expect(harness.error.contains("exceeds 20,000 characters"))
    #expect(harness.provider.recordedRequests.isEmpty)
  }

  @Test func contextTailFromAPipe() throws {
    // Process substitution and /dev/stdin cannot seek; the tail is kept while reading to EOF.
    let pipe = Pipe()
    let body = Data(String(repeating: "a", count: 40_000).utf8) + Data("tail".utf8)
    let writer = pipe.fileHandleForWriting
    DispatchQueue.global().async {
      writer.write(body)
      try? writer.close()
    }
    let tail = try CommandInput.readFileTail(
      "/dev/fd/\(pipe.fileHandleForReading.fileDescriptor)")
    #expect(tail == body.suffix(CommandInput.contextReadBytes))
  }

  @Test func plainTextAndOrderedDeepRequests() async throws {
    let harness = ExplainHarness(scripts: [
      reply(), reply("<domain>Background.</domain>"), reply("<vocab>Words.</vocab>"),
      reply("<domain>More.</domain>"),
    ])
    #expect(
      await harness.run([
        "explain", "input", "--deep", "domain", "--deep", "vocab", "--deep", "domain",
      ]) == 0)
    #expect(
      harness.output
        == "Translation.\nPlain: Simple explanation.\nTerms:\n- pool (puːl): shared resources; connections\n- empty: none; no connections\nDomain: Background.\nVocab: Words.\nDomain: More.\n"
    )
    let requests = harness.provider.recordedRequests
    #expect(requests.count == 4)
    for (index, section) in ["domain", "vocab", "domain"].enumerated() {
      #expect(requests[index + 1].messages.first?.content.contains("<\(section)>") == true)
      #expect(requests[index + 1].messages.last == requests[0].messages.last)
    }
    let noTerms = ExplainHarness(scripts: [
      reply("<translation>T</translation><plain>P</plain><terms></terms>")
    ])
    #expect(await noTerms.run() == 0)
    #expect(noTerms.output == "T\nPlain: P\nTerms:\n")
  }

  @Test func quickFailureNeverStartsDeep() async throws {
    for steps in [
      [MockProvider.Step.error(.auth(status: 401))], reply(finish: .length), reply("raw malformed"),
    ] {
      let harness = ExplainHarness(scripts: [steps, reply("<domain>must not run</domain>")])
      let expected: Int32 = steps.count == 1 ? 3 : 8
      #expect(
        await harness.run(["explain", "x", "--deep", "domain", "--deep", "vocab"]) == expected)
      #expect(harness.provider.recordedRequests.count == 1)
      #expect(harness.output.isEmpty)
    }
  }

  @Test func firstDeepFailureSuppressesAllPlainTextAndLaterCalls() async throws {
    for json in [false, true] {
      for tty in [false, true] {
        let harness = ExplainHarness(scripts: [
          reply(), [.event(.text("<domain>partial")), .error(.quota(status: 402))],
          reply("<vocab>unused</vocab>"),
        ])
        #expect(
          await harness.run(
            ["explain", "x", "--deep", "domain", "--deep", "vocab"] + (json ? ["--json"] : []),
            outputTTY: tty) == 5)
        #expect(harness.provider.recordedRequests.count == 2)
        if json {
          let object = try harness.object()
          #expect(object["status"] as? String == "error")
          #expect(object["result"] is NSNull)
          let error = try #require(object["error"] as? [String: Any])
          #expect(error["section"] as? String == "domain")
          #expect(error["code"] as? String == "quota")
          #expect(error["http_status"] as? Int == 402)
          #expect(!harness.output.contains("Translation."))
          #expect(!harness.output.contains("partial"))
        } else if tty {
          #expect(harness.output.contains("Translation."))
          #expect(harness.output.contains("partial"))
          #expect(harness.output.contains("domain: the provider quota was exhausted."))
        } else {
          #expect(harness.output.isEmpty)
        }
      }
    }
    let laterFailure = ExplainHarness(scripts: [
      reply(), reply("<vocab>Words.</vocab>"), [.error(.transport)],
    ])
    #expect(await laterFailure.run(["explain", "x", "--deep", "vocab", "--deep", "domain"]) == 4)
    #expect(laterFailure.output.isEmpty)
    #expect(laterFailure.provider.recordedRequests.count == 3)
  }

  @Test func jsonShapeAndUsage() async throws {
    for withDeep in [false, true] {
      let harness = ExplainHarness(scripts: [
        reply(), reply("<vocab>Words.</vocab>"), reply("<vocab>Latest.</vocab>"),
        reply("<domain>Background.</domain>"),
      ])
      #expect(
        await harness.run(
          ["explain", "x", "--json"]
            + (withDeep ? ["--deep", "vocab", "--deep", "vocab", "--deep", "domain"] : []),
          outputTTY: true) == 0)
      let object = try harness.object()
      #expect(object["schema"] as? Int == 1)
      #expect(object["command"] as? String == "explain")
      #expect(object["status"] as? String == "ok")
      #expect(object["provider"] as? String == "openai")
      #expect(object["model"] as? String == ProviderPreset.openai.defaultModel)
      #expect(object["error"] is NSNull)
      #expect(object["fallback"] is NSNull)
      let result = try #require(object["result"] as? [String: Any])
      #expect(
        Set(result.keys) == [
          "translation", "plain", "command", "terms", "glossary", "vocab", "domain",
        ])
      #expect(result["translation"] as? String == "Translation.")
      #expect(result["plain"] as? String == "Simple explanation.")
      #expect(result["command"] is NSNull)
      let terms = try #require(result["terms"] as? [[String: Any]])
      #expect(terms.count == 2)
      #expect(Set(terms[0].keys) == ["word", "ipa", "meaning", "here"])
      #expect(terms[0]["ipa"] as? String == "puːl")
      #expect(terms[1]["ipa"] is NSNull)
      if withDeep {
        #expect(result["domain"] as? String == "Background.")
        #expect(result["vocab"] as? String == "Latest.")
      } else {
        #expect(result["vocab"] is NSNull)
        #expect(result["domain"] is NSNull)
      }
      #expect((object["usage"] as? [String: Int])?["prompt_tokens"] == (withDeep ? 8 : 2))
      #expect((object["usage"] as? [String: Int])?["completion_tokens"] == (withDeep ? 12 : 3))
      let timing = try #require(object["timing"] as? [String: Any])
      #expect(timing["first_token_ms"] is Double)
      #expect(timing["total_ms"] is Double)
      #expect(timing["retried"] as? Bool == false)
      #expect(timing["strict_retry"] as? Bool == false)
    }
  }

  @Test func failuresAndExitCodes() async throws {
    let failures: [(LLMError, Int32)] = [
      (.auth(status: 401), 3), (.transport, 4), (.timeout(.firstToken), 4), (.timeout(.idle), 4),
      (.timeout(.total), 4),
      (.quota(status: 402), 5), (.rateLimit(retryAfter: nil), 6), (.server(status: 503), 6),
      (.invalidRequest(status: 404, providerCode: .modelNotFound), 7), (.emptyResponse, 8),
      (.malformedResponse, 8), (.aborted, 130),
    ]
    for (failure, code) in failures {
      for json in [false, true] {
        let harness = ExplainHarness(scripts: [[.error(failure)]])
        #expect(await harness.run(["explain", "x"] + (json ? ["--json"] : [])) == code)
        if json {
          let object = try harness.object()
          let error = try #require(object["error"] as? [String: Any])
          #expect(error["code"] as? String == failure.code.rawValue)
          #expect(error["section"] == nil)
          #expect(object["result"] is NSNull)
          if failure.code == .invalidRequest {
            #expect(error["provider_code"] as? String == "model_not_found")
          } else {
            #expect(error["provider_code"] is NSNull)
          }
        } else {
          #expect(harness.output.isEmpty)
        }
        if failure == .timeout(.firstToken) {
          #expect(harness.error.contains("Try a faster model"))
        }
      }
    }
    for (steps, code) in [
      (reply(finish: .length), "truncated"), (reply(finish: .contentFilter), "content_filtered"),
      (reply(finish: .other), "finish_other"), (reply("raw malformed"), "malformed_sections"),
      (
        reply(quickReply.replacingOccurrences(of: "Translation.", with: " ")),
        "malformed_sections"
      ),
    ] {
      for json in [false, true] {
        let harness = ExplainHarness(scripts: [steps])
        #expect(await harness.run(["explain", "x"] + (json ? ["--json"] : [])) == 8)
        if json {
          let object = try harness.object()
          #expect((object["error"] as? [String: Any])?["code"] as? String == code)
          #expect(object["result"] is NSNull)
          #expect(!harness.output.contains("Translation."))
          #expect(!harness.output.contains("raw malformed"))
        } else {
          #expect(harness.output.isEmpty)
        }
      }
    }
    let malformedTTY = ExplainHarness(scripts: [reply("raw <T>text")])
    #expect(await malformedTTY.run(outputTTY: true) == 8)
    #expect(malformedTTY.output == "raw <T>text\n")
  }

  @Test func showSentRedactsInputAndContextBeforeFailure() async throws {
    let secret = "sk-" + String(repeating: "FakeDemo123", count: 4)
    // Splitting the fake key with ANSI proves escape removal precedes redaction.
    let decorated = "sk-\u{1B}[31m" + String(secret.dropFirst(3)) + "\u{1B}[0m"
    for failure in [LLMError.auth(status: 401), .emptyResponse] {
      for stdin in [false, true] {
        let harness = ExplainHarness(scripts: [[.error(failure)]])
        #expect(
          await harness.run(
            ["explain", stdin ? "-" : decorated, "--context", "file", "--show-sent"],
            stdin: Data(decorated.utf8), context: Data(decorated.utf8))
            == (failure.code == .auth ? 3 : 8))
        #expect(harness.error.contains("Input:\n[REDACTED]\n\nBackground context:\n[REDACTED]\n"))
        #expect(!harness.error.contains(secret))
        #expect(!harness.output.contains(secret))
        #expect(!harness.error.contains("\u{1B}"))
        #expect(!harness.error.contains(pemNotice))
        #expect(
          harness.provider.recordedRequests.first?.messages.last?.content
            == "Input:\n[REDACTED]\n\nBackground context:\n[REDACTED]")
      }
    }
  }

  @Test func pemNoticeMatchesSentWindowAndIsNotRepeated() async {
    let begin = "-----BEGIN " + "PRIVATE KEY-----"
    let end = "-----END " + "PRIVATE KEY-----"
    let cases: [(String, String?, Bool)] = [
      (fakePEM(), nil, true), (begin + "\nobviously fake", nil, true),
      ("obviously fake\n" + end, nil, true), ("input", fakePEM(), true),
      ("input", begin + String(repeating: "ordinary words\n", count: 350), true),
      ("input", fakePEM() + String(repeating: "ordinary words\n", count: 350), false),
      ("input", end + String(repeating: "ordinary words\n", count: 350), false),
      ("input", "ordinary context", false), ("input", nil, false),
    ]
    for (input, context, notice) in cases {
      for failure in [LLMError.auth(status: 401), .emptyResponse] {
        let harness = ExplainHarness(scripts: [
          [.event(.retrying(after: .seconds(1), cause: .server)), .error(failure)]
        ])
        #expect(
          await harness.run(
            ["explain", "--show-sent"] + (context == nil ? [] : ["--context", "file"]) + [
              "--", input,
            ],
            errorTTY: true, context: context.map { Data($0.utf8) })
            == (failure.code == .auth ? 3 : 8))
        #expect(harness.error.components(separatedBy: pemNotice).count == (notice ? 2 : 1))
        #expect(harness.error.contains("Input:\n"))
        if notice { #expect(harness.error.contains("[REDACTED]")) }
      }
    }
    let noShow = ExplainHarness()
    #expect(await noShow.run(["explain", "--", fakePEM()]) == 0)
    #expect(noShow.error == pemNotice)
  }

  @Test func preparedIsVisibleWhileProviderHangsThenInterruptWritesOneObject() async throws {
    for json in [false, true] {
      let harness = ExplainHarness(scripts: [[.hang], reply("<domain>unused</domain>")])
      let task = Task {
        await harness.run(
          ["explain", "--show-sent", "--deep", "domain"] + (json ? ["--json"] : []) + [
            "--", fakePEM(),
          ])
      }
      defer {
        harness.cancel()
        task.cancel()
      }
      #expect(try await harness.prepared.wait())
      #expect(try await harness.called.wait())
      #expect(harness.output.isEmpty)
      harness.signal()
      #expect(try await harness.finished.wait() == 130)
      #expect(harness.provider.recordedRequests.count == 1)
      #expect(harness.state.withLock { $0.tokens.allSatisfy(\.isCancelled) })
      #expect(harness.state.withLock { $0.stopped })
      if json {
        let object = try harness.object()
        #expect(object["status"] as? String == "error")
        #expect(object["result"] is NSNull)
        #expect((object["error"] as? [String: Any])?["code"] as? String == "aborted")
      } else {
        #expect(harness.output.isEmpty)
      }
      #expect(harness.error.components(separatedBy: pemNotice).count == 2)
      _ = await task.value
    }
  }

  @Test func preparedIsVisibleBeforeInjectedFirstTokenTimeout() async throws {
    let clock = ExplainClock()
    let harness = ExplainHarness(
      scripts: [[.delay(.seconds(10)), .error(.timeout(.firstToken))]], clock: clock)
    let task = Task { await harness.run(["explain", "--show-sent", "--json", "--", fakePEM()]) }
    defer {
      clock.advance()
      harness.cancel()
      task.cancel()
    }
    #expect(try await harness.prepared.wait())
    #expect(try await clock.sleeping.wait())
    #expect(harness.output.isEmpty)
    clock.advance()
    #expect(try await harness.finished.wait() == 4)
    #expect(harness.error.contains("Try a faster model"))
    #expect(harness.error.components(separatedBy: pemNotice).count == 2)
    #expect((try harness.object()["error"] as? [String: Any])?["code"] as? String == "timeout")
    _ = await task.value
  }

  @Test func deepIsSerialAndInterruptCancelsOnlyRunningOperation() async throws {
    for json in [false, true] {
      let clock = ExplainClock()
      let harness = ExplainHarness(
        scripts: [
          reply(), [.delay(.seconds(10))] + reply("<domain>Background.</domain>"),
          reply("<vocab>unused</vocab>"),
        ], clock: clock)
      let task = Task {
        await harness.run(
          ["explain", "x", "--deep", "domain", "--deep", "vocab"] + (json ? ["--json"] : []),
          outputTTY: true)
      }
      defer {
        clock.advance()
        harness.cancel()
        task.cancel()
      }
      #expect(try await clock.sleeping.wait())
      #expect(harness.provider.recordedRequests.count == 2)
      if json {
        #expect(harness.output.isEmpty)
      } else {
        #expect(harness.output.contains("Translation."))
      }
      harness.signal()
      #expect(try await harness.finished.wait() == 130)
      let tokens = harness.state.withLock { $0.tokens }
      #expect(tokens.count == 2)
      #expect(!tokens[0].isCancelled)
      #expect(tokens[1].isCancelled)
      #expect(harness.provider.recordedRequests.count == 2)
      if json {
        let object = try harness.object()
        #expect(object["result"] is NSNull)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "aborted")
        #expect(error["section"] as? String == "domain")
      }
      _ = await task.value
    }
    // With successful delayed quick, no deep operation may begin before it finishes.
    let clock = ExplainClock()
    let harness = ExplainHarness(
      scripts: [[.delay(.seconds(10))] + reply(), reply("<domain>Background.</domain>")],
      clock: clock)
    let task = Task { await harness.run(["explain", "x", "--deep", "domain"]) }
    defer {
      clock.advance()
      harness.cancel()
      task.cancel()
    }
    #expect(try await clock.sleeping.wait())
    #expect(harness.provider.recordedRequests.count == 1)
    clock.advance()
    #expect(try await harness.finished.wait() == 0)
    #expect(harness.provider.recordedRequests.count == 2)
    _ = await task.value
  }

  @Test func subscriptionAndCancellationBoundaries() async throws {
    let before = ExplainHarness()
    #expect(await before.run(["explain", "x", "--json"], beforeStart: true) == 130)
    #expect(before.provider.recordedRequests.isEmpty)
    #expect((try before.object()["error"] as? [String: Any])?["code"] as? String == "aborted")
    let harness = ExplainHarness()
    #expect(
      await harness.run(
        ["explain", "-", "--provider", "openai", "--context", "file"],
        stdin: Data("input".utf8), variables: [:],
        config: "[providers.openai]\napi_key_cmd = 'fake-helper'", context: Data("context".utf8))
        == 0)
    #expect(!harness.state.withLock { $0.subscribedDuringRead })
    #expect(!harness.state.withLock { $0.subscribedDuringKey })
    #expect(harness.state.withLock { $0.stopped })
    #expect(harness.state.withLock { $0.resolved?.apiKey } == "fake-helper-key")
    let boundary = ExplainHarness(scripts: [reply(), reply("<domain>unused</domain>")])
    #expect(
      await boundary.run(
        ["explain", "x", "--deep", "domain"], outputTTY: true, interruptOnTranslation: true) == 130)
    #expect(boundary.provider.recordedRequests.count == 1)
    #expect(boundary.output.contains("Translation."))
  }

  @Test func terminalSafetyAndColor() async throws {
    let hostile = "\u{1B}[31mTranslation.\u{1B}]52;c;fake\u{1B}\\\u{0}\u{7}\u{85}"
    for (json, tty) in [(false, false), (true, false), (false, true)] {
      let harness = ExplainHarness(scripts: [
        reply(quickReply.replacingOccurrences(of: "Translation.", with: hostile))
      ])
      #expect(
        await harness.run(
          ["explain", " x\u{7}\t\n", "--show-sent", "--no-color"] + (json ? ["--json"] : []),
          outputTTY: tty) == 0)
      #expect(!harness.output.contains("\u{1B}"))
      #expect(!harness.output.contains("\u{0}"))
      #expect(!harness.output.contains("\u{7}"))
      #expect(!harness.output.contains("\u{85}"))
      #expect(!harness.error.contains("\u{7}"))
      // Display-only C0 removal must not silently change the request.
      #expect(
        harness.provider.recordedRequests.first?.messages.last?.content == "Input:\n x\u{7}\t\n")
      if json {
        #expect(
          (try harness.object()["result"] as? [String: Any])?["translation"] as? String
            == "Translation.")
      }
    }
    for (flags, variables, colored) in [
      ([], ["NO_COLOR": ""], true), ([], ["NO_COLOR": "1"], false),
      ([], ["TERM": "dumb"], false), (["--no-color"], [:], false),
    ] {
      let harness = ExplainHarness()
      #expect(
        await harness.run(
          ["explain", "x"] + flags, outputTTY: true,
          variables: variables.merging(["OPENAI_API_KEY": "fake-test-key"]) { a, _ in a }) == 0)
      #expect(harness.output.contains("\u{1B}[1m") == colored)
    }
    let retry = ExplainHarness(scripts: [
      [.event(.retrying(after: .seconds(1), cause: .rateLimit))] + reply()
    ])
    #expect(await retry.run(["explain", "x", "--json"], errorTTY: true) == 0)
    #expect(retry.error.contains("retrying in 1s (rate limited)"))
    #expect((try retry.object()["timing"] as? [String: Any])?["retried"] as? Bool == true)
    let streamed = ExplainHarness(scripts: [
      [.event(.text("<translation>Translation.</translation>")), .hang]
    ])
    let task = Task { await streamed.run(outputTTY: true) }
    defer {
      streamed.cancel()
      task.cancel()
    }
    #expect(try await streamed.displayed.wait())
    streamed.signal()
    #expect(try await streamed.finished.wait() == 130)
    #expect(streamed.output.components(separatedBy: "Translation.").count == 2)
    _ = await task.value
  }
}

struct SessionCommandTests {
  @Test func session264DefinitionBeyondTailAndNoMatch() async throws {
    for hasDefinition in [true, false] {
      let fixture = try SessionFixture()
      defer { fixture.remove() }
      let definition = "We call this a one-sided skip: only the fictional left queue is skipped."
      var records: [[String: Any]] = []
      for turn in 1...6 {
        records.append(SessionFixture.user("Fictional question \(turn).", id: "u\(turn)"))
        let answer: String
        if turn == 1 {
          answer = hasDefinition ? definition : "An unrelated opening answer."
        } else if turn == 6 {
          answer = hasDefinition ? "Apply the one-sided skip." : "Apply the ordinary check."
        } else {
          answer = String(repeating: "Fictional padding without the query.\n", count: 160)
        }
        records.append(SessionFixture.assistant(answer, id: "a\(turn)"))
      }
      try fixture.claude(records)
      let harness = ExplainHarness()
      #expect(
        await harness.run(
          ["explain", "--session", "claude", "one-sided skip", "--show-sent"],
          homeDirectory: fixture.home.path) == 0)
      if hasDefinition {
        #expect(
          harness.error.contains(
            "Attached Claude Code session (lines that mention the input):\nAssistant: " + definition
          ))
      } else {
        #expect(
          harness.error.contains(
            "Attached Claude Code session: no exact match for the input was found; it may still be described in other words."
          ))
      }
    }
  }
}

extension SessionCommandTests {
  @Test func sessionReplyModeSkipsIncompleteAndNeverReadsStdin() async throws {
    for answer in ["Last visible reply.", "-"] {
      let fixture = try SessionFixture()
      defer { fixture.remove() }
      try fixture.claude([
        SessionFixture.user("Earlier question.", id: "u1"),
        SessionFixture.assistant("Earlier answer.", id: "a1"),
        SessionFixture.user("Current question.", id: "u2"),
        SessionFixture.assistant(answer, id: "a2"),
        SessionFixture.user("Pending question.", id: "u3"),
        SessionFixture.assistant("HIDDEN unfinished", id: "a3", stop: "tool_use"),
      ])
      let harness = ExplainHarness()
      #expect(
        await harness.run(
          ["explain", "--session", "claude", "--show-sent"],
          readError: true, homeDirectory: fixture.home.path) == 0)
      #expect(harness.state.withLock { $0.reads } == 0)
      let sent = try #require(harness.provider.recordedRequests.first?.messages.last?.content)
      #expect(
        sent
          == "Input:\n\(answer)\n\nBackground context:\nUser: Earlier question.\n\nAssistant: Earlier answer.\n\nUser: Current question."
      )
      #expect(!sent.contains("Pending"))
      #expect(!sent.contains("HIDDEN"))
      #expect(!sent.contains(fixture.home.path))
      #expect(!sent.contains("aaaaaaaa-1111"))
      let line = try #require(harness.error.split(separator: "\n").first)
      #expect(line.hasPrefix("pl: using Claude Code session aaaaaaaa (started "))
      #expect(line.hasSuffix(", prompts: 3)"))
      #expect(line.range(of: #"started \d{2}:\d{2}"#, options: .regularExpression) != nil)
      #expect(!line.contains("question"))
      #expect(!line.contains("reply"))
    }
  }

  @Test func sessionReplyModeWithoutEarlierDialogueSendsNoBackground() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    try fixture.claude([
      SessionFixture.user("<task-notification>fictional</task-notification>", id: "u1"),
      SessionFixture.assistant("Only reply.", id: "a1"),
    ])
    let harness = ExplainHarness()
    #expect(
      await harness.run(
        ["explain", "--session", "claude", "--show-sent"], homeDirectory: fixture.home.path) == 0)
    let sent = try #require(harness.provider.recordedRequests.first?.messages.last?.content)
    #expect(sent == "Input:\nOnly reply.")
  }

  @Test func sessionQueryStdinAndSameReplyContext() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    try fixture.codex([
      SessionFixture.codexUser("Previous question."),
      SessionFixture.complete("t1", "Previous answer."),
      SessionFixture.codexUser("Current question."),
      SessionFixture.complete("t2", " Current answer. "),
      SessionFixture.codexUser("Pending question."),
    ])
    for stdin in [false, true] {
      let harness = ExplainHarness()
      #expect(
        await harness.run(
          ["explain", "--session", "codex:bbbb", stdin ? "-" : "Current answer.", "--show-sent"],
          stdin: Data("Current answer.".utf8), homeDirectory: fixture.home.path) == 0)
      #expect(harness.state.withLock { $0.reads } == (stdin ? 1 : 0))
      let sent = try #require(harness.provider.recordedRequests.first?.messages.last?.content)
      #expect(
        sent.contains(
          "Background context:\nUser: Previous question.\n\nAssistant: Previous answer.\n\nUser: Current question.\n\nUser: Pending question.\n\nAttached Codex session:"
        ))
      #expect(sent.contains("Assistant:  Current answer. "))
      #expect(sent.contains("User: Pending question."))
    }
    let query = ExplainHarness()
    #expect(
      await query.run(
        ["explain", "--session", "codex", "different query"], homeDirectory: fixture.home.path) == 0
    )
    #expect(
      query.provider.recordedRequests.first?.messages.last?.content.contains(
        "User: Current question.\n\nAssistant:  Current answer. \n\nUser: Pending question.\n\nAttached"
      ) == true)
  }

  @Test func sessionRedactionAndTerminalSanitization() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let fake = "sk-test-FAKE0000000000000000000000"
    let decorated = "sk-\u{1B}[31m" + fake.dropFirst(3) + "\u{1B}[0m"
    try fixture.claude([
      SessionFixture.user("Question " + fake, id: "u1"),
      SessionFixture.assistant("Earlier " + decorated, id: "a1"),
      SessionFixture.user("Next", id: "u2"),
      SessionFixture.assistant("Reply " + decorated + "\u{7}", id: "a2"),
    ])
    for query in [false, true] {
      let harness = ExplainHarness()
      #expect(
        await harness.run(
          ["explain", "--session", "claude", "--show-sent"] + (query ? [fake] : []),
          homeDirectory: fixture.home.path) == 0)
      let sent = try #require(harness.provider.recordedRequests.first?.messages.last?.content)
      #expect(sent.contains("Input:\n" + (query ? "[REDACTED]" : "Reply [REDACTED]")))
      #expect(sent.contains("Question [REDACTED]"))
      #expect(sent.contains("Earlier [REDACTED]"))
      if query { #expect(sent.contains("Attached Claude Code session:")) }
      #expect(!sent.contains(fake))
      #expect(!harness.error.contains(fake))
      #expect(!harness.error.contains("\u{1B}"))
      #expect(!harness.error.contains("\u{7}"))
    }
  }

  @Test func sessionUsageAndMissingInputErrors() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let cases: [([String], Int32, String)] = [
      (["--session", "claude", "--context", "file"], 64, "--session and --context"),
      (["--session", "dsh"], 64, "choose --session"),
      (["--session", "claude:"], 64, "choose --session"),
      (["--session", "codex:a:b"], 64, "choose --session"),
      (
        ["--session", "claude"], 66,
        "no Claude Code session found for this directory. Run pl in the directory where the session started."
      ),
      (
        ["--session", "codex"], 66,
        "no Codex session found for this directory. Run pl in the directory where the session started."
      ),
      (["--session", "claude:missing"], 64, "Available IDs: none"),
    ]
    for (args, code, message) in cases {
      let harness = ExplainHarness()
      #expect(
        await harness.run(["explain", "--json"] + args, homeDirectory: fixture.home.path) == code)
      #expect(harness.error.contains(message))
      #expect(harness.output.isEmpty)
      #expect(harness.provider.recordedRequests.isEmpty)
      #expect(harness.state.withLock { $0.reads } == 0)
    }
    try fixture.claude([["type": "system", "text": "Unrecognized record"]])
    try fixture.codex([SessionFixture.codexRecord("unknown_kind", ["type": "unknown"])])
    for (agent, version) in [("claude", "2.1.318"), ("codex", "0.166.0")] {
      let harness = ExplainHarness()
      #expect(
        await harness.run(
          ["explain", "--session", agent, "query", "--json"], homeDirectory: fixture.home.path)
          == 66)
      #expect(harness.error.contains("no turn found"))
      #expect(
        harness.error.contains("(cli \(version)). The session format may have changed; update pl."))
      #expect(!harness.error.contains("Unfinished question"))
      #expect(harness.output.isEmpty)
      #expect(harness.provider.recordedRequests.isEmpty)
    }
    try fixture.claude([["cwd": fixture.cwd, "type": "unknown", "version": NSNull()]])
    let unknown = ExplainHarness()
    #expect(
      await unknown.run(["explain", "--session", "claude"], homeDirectory: fixture.home.path) == 66)
    #expect(unknown.error.contains("(cli unknown)"))
  }

  @Test func sessionSelectionUsesModificationAndExactOrUniquePrefix() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    for (id, date, answer) in [("abcdef00-one", 10.0, "Older."), ("abcdef00-two", 20.0, "Newer.")] {
      let file = try fixture.claude([SessionFixture.assistant(answer, id: "a")], id: id)
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: date)], ofItemAtPath: file.path)
    }
    for selector in ["claude:abcdef", "claude:missing"] {
      let harness = ExplainHarness()
      #expect(
        await harness.run(["explain", "--session", selector], homeDirectory: fixture.home.path)
          == 64)
      #expect(harness.error.contains("Available IDs: abcdef00-two, abcdef00-one"))
      #expect(harness.error.contains("abcdef00-one"))
      #expect(harness.provider.recordedRequests.isEmpty)
    }
    for (selector, answer) in [
      ("claude", "Newer."), ("claude:abcdef00-o", "Older."), ("claude:abcdef00-one", "Older."),
    ] {
      let harness = ExplainHarness()
      #expect(
        await harness.run(["explain", "--session", selector], homeDirectory: fixture.home.path) == 0
      )
      #expect(
        harness.provider.recordedRequests.first?.messages.last?.content.hasPrefix(
          "Input:\n" + answer) == true)
    }
    // A complete ID wins even if it is also a prefix of another ID.
    try fixture.claude([SessionFixture.assistant("Exact.", id: "a")], id: "abcdef00")
    let exact = ExplainHarness()
    #expect(
      await exact.run(
        ["explain", "--session", "claude:abcdef00"], homeDirectory: fixture.home.path) == 0)
    #expect(
      exact.provider.recordedRequests.first?.messages.last?.content.hasPrefix("Input:\nExact.")
        == true)
    let elsewhere = ExplainHarness()
    #expect(
      await elsewhere.run(
        ["explain", "--session", "claude"], homeDirectory: fixture.home.path,
        currentDirectory: "/elsewhere") == 66)
  }

  @Test func sessionPreservesLengthJSONDeepAndEligibilityContracts() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    try fixture.claude([SessionFixture.assistant(String(repeating: "界", count: 20_001), id: "a")])
    let long = ExplainHarness()
    #expect(
      await long.run(["explain", "--session", "claude"], homeDirectory: fixture.home.path) == 64)
    #expect(long.error.contains("input exceeds 20,000 characters"))
    #expect(long.provider.recordedRequests.isEmpty)
    try fixture.claude([SessionFixture.assistant("Short answer.", id: "a")])
    let harness = ExplainHarness(scripts: [reply(), reply("<domain>Background.</domain>")])
    #expect(
      await harness.run(
        ["explain", "--session", "claude", "term", "--json", "--deep", "domain", "--show-sent"],
        homeDirectory: fixture.home.path) == 0)
    #expect(try harness.object()["status"] as? String == "ok")
    #expect(harness.provider.recordedRequests.count == 2)
    #expect(
      harness.provider.recordedRequests[0].messages.last
        == harness.provider.recordedRequests[1].messages.last)
    #expect(harness.error.components(separatedBy: "Input:\n").count == 2)
    for json in [false, true] {
      for (steps, expected) in [
        (reply(finish: .length), Int32(8)),
        ([MockProvider.Step.error(.quota(status: 402))], Int32(5)),
      ] {
        let failed = ExplainHarness(scripts: [steps])
        #expect(
          await failed.run(
            ["explain", "--session", "claude", "--deep", "domain"] + (json ? ["--json"] : []),
            homeDirectory: fixture.home.path) == expected)
        #expect(failed.provider.recordedRequests.count == 1)
        if json {
          let object = try failed.object()
          #expect(object["status"] as? String == "error")
          #expect(object["result"] is NSNull)
        } else {
          #expect(failed.output.isEmpty)
        }
      }
    }
  }
}

extension SessionCommandTests {
  @Test func queryAcceptsPendingFirstAndSecondReplies() async throws {
    for agent in ["claude", "codex"] {
      for earlierReply in [false, true] {
        for stdin in [false, true] {
          let fixture = try SessionFixture()
          defer { fixture.remove() }
          if agent == "claude" {
            var records: [[String: Any]] = []
            if earlierReply {
              records = [
                SessionFixture.user("Earlier question.", id: "u1"),
                SessionFixture.assistant("Earlier answer.", id: "a1"),
              ]
            }
            records.append(SessionFixture.user("Pending real question.", id: "pending"))
            try fixture.claude(records)
          } else {
            var records: [[String: Any]] = []
            if earlierReply {
              records = [
                SessionFixture.codexUser("Earlier question."),
                SessionFixture.complete("t1", "Earlier answer."),
              ]
            }
            records.append(SessionFixture.codexUser("Pending real question."))
            try fixture.codex(records)
          }
          let harness = ExplainHarness()
          #expect(
            await harness.run(
              [
                "explain", "--session", agent, "--show-sent", "--json", "--",
                stdin ? "-" : "Answer not yet recorded.",
              ], stdin: Data("Answer not yet recorded.".utf8), homeDirectory: fixture.home.path)
              == 0)
          let sent = try #require(harness.provider.recordedRequests.first?.messages.last?.content)
          let background = try #require(sent.components(separatedBy: "\n\nAttached ").first)
          #expect(background.contains("User: Pending real question."))
          #expect(try harness.object()["status"] as? String == "ok")
          if !earlierReply {
            let replyMode = ExplainHarness()
            #expect(
              await replyMode.run(
                ["explain", "--session", agent], homeDirectory: fixture.home.path) == 66)
          }
        }
      }
    }
  }

  @Test(arguments: ["claude", "codex"])
  func injectedSystemTextNeverReachesRequests(_ agent: String) async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    if agent == "claude" {
      var summary = SessionFixture.user("HIDDEN SUMMARY", id: "summary")
      summary["isCompactSummary"] = true
      try fixture.claude([
        SessionFixture.user(
          "<system-reminder>HIDDEN PREFIX</system-reminder>Real question.<system-reminder>HIDDEN SUFFIX</system-reminder>",
          id: "u"),
        summary, SessionFixture.assistant("Real answer.", id: "a"),
      ])
    } else {
      try fixture.codex([
        SessionFixture.codexRecord("event_msg", ["type": "task_started", "turn_id": "t"]),
        SessionFixture.codexUser("# AGENTS.md instructions for /fictional/project\nHIDDEN RULES"),
        SessionFixture.codexUser(
          "<system-reminder>HIDDEN PREFIX</system-reminder>Real question.<system-reminder>HIDDEN SUFFIX</system-reminder>"
        ),
        SessionFixture.complete("t", "Real answer."),
      ])
    }
    let harness = ExplainHarness()
    #expect(
      await harness.run(
        ["explain", "--session", agent, "query", "--show-sent"], homeDirectory: fixture.home.path)
        == 0)
    let sent = try #require(harness.provider.recordedRequests.first?.messages.last?.content)
    #expect(!sent.contains("HIDDEN"))
    #expect(!sent.contains("# AGENTS.md"))
    #expect(sent.contains("User: Real question."))
    #expect(harness.error.contains(", prompts: 1)"))
  }

  @Test func queryWithOnlyADiscardedPromptSendsNoEmptySections() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    try fixture.claude([SessionFixture.user("<div> overflows", id: "u")])
    let harness = ExplainHarness()
    #expect(
      await harness.run(
        ["explain", "--session", "claude", "short term"], homeDirectory: fixture.home.path) == 0)
    let sent = try #require(harness.provider.recordedRequests.first?.messages.last?.content)
    #expect(sent == "Input:\nshort term")
    #expect(harness.error.contains(", prompts: 0)"))
  }

  @Test func escapeOnlyReplyIsNotTheLatestReply() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    try fixture.claude([
      SessionFixture.user("First question.", id: "u1"),
      SessionFixture.assistant("Real reply.", id: "a1"),
      SessionFixture.user("Second question.", id: "u2"),
      SessionFixture.assistant("\u{1B}[0m  ", id: "a2"),
    ])
    let harness = ExplainHarness()
    #expect(
      await harness.run(["explain", "--session", "claude"], homeDirectory: fixture.home.path) == 0)
    let sent = try #require(harness.provider.recordedRequests.first?.messages.last?.content)
    #expect(sent.hasPrefix("Input:\nReal reply.\n"))
  }

  @Test func cutContextLinesNeverReachRequestsAfterEscapeRemoval() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let context =
      String(repeating: "prefix ", count: 3000) + "fictional-cut-term CUT LINE\n"
      + String(repeating: "\u{1B}[31m\u{1B}[0m", count: 100)
      + String(repeating: "safe line\n", count: 1500)
    try fixture.claude([
      SessionFixture.user(context, id: "u"),
      SessionFixture.assistant("fictional-cut-term", id: "a"),
    ])
    let file = fixture.home.appendingPathComponent("context.txt")
    try Data(context.utf8).write(to: file)
    for args in [["--session", "claude"], ["fictional-cut-term", "--context", file.path]] {
      let harness = ExplainHarness()
      #expect(
        await harness.run(["explain", "--show-sent"] + args, homeDirectory: fixture.home.path) == 0)
      let sent = try #require(harness.provider.recordedRequests.first?.messages.last?.content)
      #expect(!sent.contains("CUT LINE"))
      #expect(!harness.error.contains("CUT LINE"))
      #expect(sent.contains("safe line"))
    }
  }
}

extension SessionCommandTests {
  @Test func availableIDsAreSanitizedAndLimitedTo64Characters() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let id = "abcdefgh\u{1B}[31m" + String(repeating: "x", count: 70)
    try fixture.claude([SessionFixture.assistant("Reply.", id: "a")], id: id)
    let harness = ExplainHarness()
    #expect(
      await harness.run(
        ["explain", "--session", "claude:missing"], homeDirectory: fixture.home.path) == 64)
    #expect(
      harness.error.contains("Available IDs: abcdefgh" + String(repeating: "x", count: 56) + "."))
    #expect(!harness.error.contains("\u{1B}"))
    #expect(!harness.error.contains(String(repeating: "x", count: 57)))
  }
}

extension SessionCommandTests {
  @Test(arguments: ["pi", "pi:cccc"])
  func piReplyModeUsesLatestCompleteReply(_ selection: String) async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    try fixture.pi([
      SessionFixture.piMessage("user", "Earlier question", id: "u1", parent: nil),
      SessionFixture.piAssistant("Earlier answer", id: "a1", parent: "u1"),
      SessionFixture.piMessage("user", "Current question", id: "u2", parent: "a1"),
      SessionFixture.piAssistant("Current answer", id: "a2", parent: "u2"),
      SessionFixture.piMessage("user", "Pending question", id: "u3", parent: "a2"),
      SessionFixture.piAssistant("HIDDEN unfinished", id: "a3", parent: "u3", stop: "toolUse"),
    ])
    let harness = ExplainHarness()
    #expect(
      await harness.run(
        ["explain", "--session", selection, "--show-sent"], readError: true,
        homeDirectory: fixture.home.path) == 0)
    #expect(harness.state.withLock { $0.reads } == 0)
    let sent = try #require(harness.provider.recordedRequests.first?.messages.last?.content)
    #expect(
      sent
        == "Input:\nCurrent answer\n\nBackground context:\nUser: Earlier question\n\nAssistant: Earlier answer\n\nUser: Current question"
    )
    #expect(harness.error.hasPrefix("pl: using pi session cccccccc (started "))
    #expect(harness.error.contains("prompts: 3)"))
    #expect(!sent.contains(fixture.home.path))
    #expect(!sent.contains("cccccccc-3333"))
  }

  @Test(arguments: [true, false])
  func piQueryFindsDefinitionBeyondContextTail(_ hasDefinition: Bool) async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let definition = "We call this a one-sided skip: only the fictional left queue is skipped."
    var records: [[String: Any]] = []
    for turn in 1...6 {
      records.append(
        SessionFixture.piMessage(
          "user", "Fictional question \(turn)", id: "u\(turn)",
          parent: turn == 1 ? nil : "a\(turn - 1)"))
      let answer: String
      if turn == 1 {
        answer = hasDefinition ? definition : "An unrelated opening answer."
      } else if turn == 6 {
        answer = "Apply the ordinary check."
      } else {
        answer = String(repeating: "Fictional padding without the query.\n", count: 160)
      }
      records.append(SessionFixture.piAssistant(answer, id: "a\(turn)", parent: "u\(turn)"))
    }
    try fixture.pi(records)
    let harness = ExplainHarness()
    #expect(
      await harness.run(
        ["explain", "--session", "pi", "one-sided skip", "--show-sent"],
        homeDirectory: fixture.home.path) == 0)
    let sent = try #require(harness.provider.recordedRequests.first?.messages.last?.content)
    if hasDefinition {
      #expect(
        sent.contains(
          "Attached pi session (lines that mention the input):\nAssistant: " + definition))
      #expect(harness.error.contains(definition))
      #expect(!sent.components(separatedBy: "Attached pi session")[0].contains(definition))
    } else {
      #expect(
        sent.contains(
          "Attached pi session: no exact match for the input was found; it may still be described in other words."
        ))
    }
  }

  @Test(arguments: [false, true], [2, 3, 99])
  func piUnrecognisedSessionNamesFormatVersion(_ query: Bool, _ version: Int) async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    try fixture.pi(
      [
        SessionFixture.piEntry("future_format", id: "future", parent: nil)
      ], version: version)
    let harness = ExplainHarness()
    #expect(
      await harness.run(
        ["explain", "--session", "pi"] + (query ? ["query"] : []),
        homeDirectory: fixture.home.path) == 66)
    let missing = query ? "turn" : "completed reply"
    #expect(
      harness.error
        == "pl: no \(missing) found in the pi session (session format v\(version)). The session format may have changed; update pl.\n"
    )
    #expect(harness.provider.recordedRequests.isEmpty)
  }

  @Test func piPendingTurnCanBeQueriedButHasNoCompletedReply() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    try fixture.pi(
      [
        SessionFixture.piMessage("user", "Pending question", id: "u", parent: nil),
        SessionFixture.piAssistant("HIDDEN partial", id: "a", parent: "u", stop: "length"),
      ], version: 2)
    let reply = ExplainHarness()
    #expect(
      await reply.run(["explain", "--session", "pi"], homeDirectory: fixture.home.path) == 66)
    #expect(
      reply.error
        == "pl: no completed reply found in the pi session (session format v2). The session format may have changed; update pl.\n"
    )
    #expect(reply.provider.recordedRequests.isEmpty)
    let query = ExplainHarness()
    #expect(
      await query.run(
        ["explain", "--session", "pi", "-"], stdin: Data("question".utf8),
        homeDirectory: fixture.home.path) == 0)
    let sent = try #require(query.provider.recordedRequests.first?.messages.last?.content)
    #expect(sent.contains("User: Pending question"))
    #expect(sent.contains("Attached pi session"))
    #expect(!sent.contains("HIDDEN"))
  }

  @Test func sessionHelpListsPiInBothCommands() {
    for help in [Explain.helpMessage(), Session.Watch.helpMessage()] {
      #expect(
        help.split(whereSeparator: \.isWhitespace).joined(separator: " ").contains(
          "Local session: claude, codex or pi, optionally followed by :ID."))
    }
  }
}

private let documentReply = """
  <gist>Document overview.</gist><decisions><decision>Approve plan.</decision></decisions><parts><part><heading>First</heading><plain>First explanation.</plain></part><part><heading>Second</heading><plain>Second explanation.</plain></part></parts><terms><term><word>pool</word><ipa>puːl</ipa><meaning>resources</meaning><here>connections</here></term></terms>
  """

struct ExplainDocumentCommandTests {
  @Test(arguments: [false, true], [false, true])
  func limitsAndDiagnostics(_ document: Bool, _ stdin: Bool) async throws {
    let limit = document ? ExplainDocument.maximumCharacters : 20_000
    let diagnostic =
      document
      ? "pl: input exceeds 60,000 characters. Explain one part of the document at a time.\n"
      : "pl: input exceeds 20,000 characters. Use --doc to explain a whole document.\n"
    for count in [limit, limit + 1] {
      let input = "\u{1B}[31m" + String(repeating: "界", count: count) + "\u{1B}[0m"
      let harness = ExplainHarness(scripts: [reply(document ? documentReply : quickReply)])
      let code = await harness.run(
        ["explain", "--json"] + (document ? ["--doc"] : []) + [stdin ? "-" : input],
        stdin: Data(input.utf8))
      #expect(code == (count == limit ? 0 : 64))
      if count == limit {
        #expect(try harness.object()["mode"] as? String == (document ? "document" : "quick"))
        #expect(harness.provider.recordedRequests.count == 1)
      } else {
        #expect(harness.error == diagnostic)
        #expect(harness.output.isEmpty)
        #expect(harness.provider.recordedRequests.isEmpty)
      }
    }
    // The byte guard applies before escape removal, even to short visible input.
    let bytes = Data(
      (String(repeating: "\u{1B}[0m", count: CommandInput.stdinLimit / 4) + "x").utf8)
    let oversized = ExplainHarness()
    #expect(
      await oversized.run(
        ["explain", "--json"] + (document ? ["--doc"] : []), stdin: bytes) == 64)
    #expect(oversized.error == diagnostic)
    #expect(oversized.output.isEmpty)
    #expect(oversized.provider.recordedRequests.isEmpty)
  }

  @Test func incompatibleOptionsFailBeforeReading() async {
    for options in [
      ["--deep", "vocab"], ["--deep", "domain"],
      ["--session", "claude", "query"], ["--session", "codex", "-"],
      ["--session", "pi", "query"], ["--session", "claude", "--context", "file"],
      ["--context", "-"],
    ] {
      let harness = ExplainHarness()
      #expect(await harness.run(["explain", "--doc", "--json"] + options) == 64)
      #expect(!harness.error.contains("Unknown option"))
      #expect(harness.output.isEmpty)
      #expect(harness.state.withLock { $0.reads } == 0)
      #expect(harness.provider.recordedRequests.isEmpty)
    }
  }

  @Test func sessionReplyLimitsAndQueryDiagnosticScope() async throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    for count in [20_001, 60_000, 60_001] {
      try fixture.claude([SessionFixture.assistant(String(repeating: "界", count: count), id: "a")])
      let harness = ExplainHarness(scripts: [reply(documentReply)])
      #expect(
        await harness.run(
          ["explain", "--doc", "--session", "claude", "--json"], readError: true,
          homeDirectory: fixture.home.path) == (count <= 60_000 ? 0 : 64))
      #expect(harness.state.withLock { $0.reads } == 0)
      if count <= 60_000 {
        #expect(try harness.object()["mode"] as? String == "document")
        #expect(
          harness.provider.recordedRequests.first?.messages.last?.content
            == "Input:\n" + String(repeating: "界", count: count))
      } else {
        #expect(
          harness.error.contains(
            "input exceeds 60,000 characters. Explain one part of the document at a time."))
        #expect(harness.provider.recordedRequests.isEmpty)
      }
      let quick = ExplainHarness()
      #expect(
        await quick.run(["explain", "--session", "claude"], homeDirectory: fixture.home.path) == 64)
      #expect(
        quick.error.contains(
          "input exceeds 20,000 characters. Use --doc to explain a whole document."))
    }
    let long = String(repeating: "界", count: 20_001)
    for args in [
      ["fix", long], ["explain", "--session", "claude", long],
      ["explain", "--session", "claude", "-"],
    ] {
      let harness = ExplainHarness()
      #expect(
        await harness.run(args, stdin: Data(long.utf8), homeDirectory: fixture.home.path) == 64)
      #expect(harness.error.hasSuffix("pl: input exceeds 20,000 characters. Use shorter input.\n"))
      #expect(harness.provider.recordedRequests.isEmpty)
    }
  }

  @Test(arguments: [false, true])
  func documentTextAndJSON(_ tty: Bool) async throws {
    for decisions in [true, false] {
      let response =
        decisions
        ? documentReply
        : documentReply.replacingOccurrences(
          of: "<decision>Approve plan.</decision>", with: "")
      let harness = ExplainHarness(scripts: [reply(response)])
      #expect(await harness.run(["explain", "--doc", "input", "--no-color"], outputTTY: tty) == 0)
      #expect(
        harness.output == "Gist: Document overview.\n"
          + (decisions ? "Decisions:\n- Approve plan.\n" : "")
          + "## First\nFirst explanation.\n## Second\nSecond explanation.\nTerms:\n- pool (puːl): resources; connections\n"
      )
      let json = ExplainHarness(scripts: [reply(response)])
      #expect(await json.run(["explain", "--doc", "input", "--json"], outputTTY: tty) == 0)
      let object = try json.object()
      #expect(object["mode"] as? String == "document")
      #expect(object["schema"] as? Int == 1)
      let result = try #require(object["result"] as? [String: Any])
      #expect(Set(result.keys) == ["gist", "decisions", "parts", "terms", "glossary"])
      #expect(result["gist"] as? String == "Document overview.")
      #expect(result["decisions"] as? [String] == (decisions ? ["Approve plan."] : []))
      #expect(
        result["parts"] as? [[String: String]] == [
          ["heading": "First", "plain": "First explanation."],
          ["heading": "Second", "plain": "Second explanation."],
        ])
      let terms = try #require(result["terms"] as? [[String: String]])
      #expect(
        terms == [["word": "pool", "ipa": "puːl", "meaning": "resources", "here": "connections"]])
      #expect((object["usage"] as? [String: Int]) == ["prompt_tokens": 2, "completion_tokens": 3])
    }
  }

  @Test(arguments: [false, true])
  func documentEntitiesAgreeAcrossOutputs(_ literalEntity: Bool) async throws {
    let input =
      "# Q & A\n# Already &amp; written\nR & D\n" + (literalEntity ? "literal &amp;" : "plain text")
    // Keep the no-entity document free of entities, including the second heading.
    let sent = literalEntity ? input : "# Q & A\n# Already & written\nR & D"
    let prose = "A &amp; B &lt; C &gt; D &quot;E&quot; &apos;F&apos;"
    let decoded = "A & B < C > D \"E\" 'F'"
    let text = literalEntity ? prose : decoded
    let secondHeading = literalEntity ? "Already &amp; written" : "Already & written"
    let response = """
      <gist>\(prose)</gist><decisions><decision>\(prose)</decision></decisions><parts><part><heading>Q &amp; A</heading><plain>\(prose)</plain></part><part><heading>Already &amp; written</heading><plain>\(prose)</plain></part><part><heading>Absent &amp; heading</heading><plain>\(prose)</plain></part></parts><terms><term><word>R &amp; D</word><ipa>\(prose)</ipa><meaning>\(prose)</meaning><here>\(prose)</here></term></terms>
      """
    let absentHeading = literalEntity ? "Absent &amp; heading" : "Absent & heading"
    let json = ExplainHarness(scripts: [reply(response)])
    #expect(await json.run(["explain", "--doc", sent, "--json"]) == 0)
    let result = try #require(try json.object()["result"] as? [String: Any])
    #expect(result["gist"] as? String == text)
    #expect(result["decisions"] as? [String] == [text])
    let parts = try #require(result["parts"] as? [[String: String]])
    #expect(
      parts == [
        ["heading": "Q & A", "plain": text],
        ["heading": secondHeading, "plain": text],
        ["heading": absentHeading, "plain": text],
      ])
    let terms = try #require(result["terms"] as? [[String: String]])
    #expect(terms == [["word": "R & D", "ipa": text, "meaning": text, "here": text]])
    let expected =
      "Gist: \(text)\nDecisions:\n- \(text)\n## Q & A\n\(text)\n"
      + "## \(secondHeading)\n\(text)\n## \(absentHeading)\n\(text)\n"
      + "Terms:\n- R & D (\(text)): \(text); \(text)\n"
    for tty in [false, true] {
      let harness = ExplainHarness(scripts: [reply(response)])
      #expect(await harness.run(["explain", "--doc", sent, "--no-color"], outputTTY: tty) == 0)
      #expect(harness.output == expected)
    }
    // A closed child must already use the sent input's decoding rule while <parts> stays open.
    let captured = OSAllocatedUnfairLock(initialState: "")
    var environment = CLIEnvironment.current
    environment.stdoutIsTTY = true
    environment.stdout = { value in captured.withLock { $0 += value } }
    var output = ExplainOutput(
      environment: environment, json: false, noColor: true, mode: .document)
    output.input = sent
    var parser = SectionStreamParser(schema: .explainDocument)
    let end = try #require(response.range(of: "</part>"))
    parser.feed(String(response[..<end.upperBound]))
    output.render(parser.snapshot)
    #expect(captured.withLock { $0 } == "Gist: \(text)\nDecisions:\n- \(text)\n## Q & A\n\(text)\n")
  }

  @Test func closedChildrenStreamBeforeTheirContainerCloses() {
    let captured = OSAllocatedUnfairLock(initialState: "")
    var environment = CLIEnvironment.current
    environment.stdoutIsTTY = true
    environment.stdout = { text in captured.withLock { $0 += text } }
    var output = ExplainOutput(
      environment: environment, json: false, noColor: true, mode: .document)
    var parser = SectionStreamParser(schema: .explainDocument)
    parser.feed("<gist>Overview")
    output.render(parser.snapshot)
    #expect(captured.withLock { $0.isEmpty })
    parser.feed(".</gist><decisions><decision>Approve.</decision>")
    output.render(parser.snapshot)
    #expect(captured.withLock { $0 } == "Gist: Overview.\n")
    parser.feed("</decisions><parts><part><heading>First</heading><plain>One.</plain>")
    output.render(parser.snapshot)
    #expect(captured.withLock { $0 } == "Gist: Overview.\nDecisions:\n- Approve.\n")
    parser.feed("</part><part><heading>Second</heading><plain>Two.")
    output.render(parser.snapshot)
    output.render(parser.snapshot)
    #expect(captured.withLock { $0 } == "Gist: Overview.\nDecisions:\n- Approve.\n## First\nOne.\n")
    parser.feed("</plain></part></parts><terms></terms>")
    output.render(parser.finish())
    #expect(
      captured.withLock { $0 }
        == "Gist: Overview.\nDecisions:\n- Approve.\n## First\nOne.\n## Second\nTwo.\nTerms:\n")
  }

  @Test func repeatedSectionsShowOnlyTheFirstWhileStreaming() {
    let captured = OSAllocatedUnfairLock(initialState: "")
    var environment = CLIEnvironment.current
    environment.stdoutIsTTY = true
    environment.stdout = { text in captured.withLock { $0 += text } }
    var output = ExplainOutput(
      environment: environment, json: false, noColor: true, mode: .document)
    var parser = SectionStreamParser(schema: .explainDocument)
    parser.feed(
      "<gist>A.</gist><gist>B.</gist><parts><part><heading>H1</heading><plain>P1.</plain></part>"
        + "</parts><parts><part><heading>H2</heading><plain>P2.</plain></part></parts>")
    output.render(parser.snapshot)
    output.render(parser.snapshot)
    #expect(captured.withLock { $0 } == "Gist: A.\n## H1\nP1.\n")
  }

  @Test func truncatedDocumentKeepsWhatTheTerminalShowed() async throws {
    let end = try #require(documentReply.range(of: "</part>"))
    let harness = ExplainHarness(scripts: [
      reply(String(documentReply[..<end.upperBound]), finish: .length)
    ])
    #expect(await harness.run(["explain", "input", "--doc", "--no-color"], outputTTY: true) == 8)
    // What was shown stays first; the raw reply follows, as for any malformed TTY reply.
    #expect(
      harness.output.hasPrefix(
        "Gist: Document overview.\nDecisions:\n- Approve plan.\n## First\nFirst explanation.\n<gist>"
      ))
  }

  @Test(arguments: [false, true])
  func failuresKeepModeAndNeverExportPartialResults(_ document: Bool) async throws {
    let response = document ? documentReply : quickReply
    let cases: [([MockProvider.Step], Int32, String)] = [
      (reply(response, finish: .length), 8, "truncated"),
      (reply(response, finish: .contentFilter), 8, "content_filtered"),
      (reply("<gist>Only gist.</gist>"), 8, "malformed_sections"),
      ([.event(.text(response)), .error(.transport)], 4, "transport"),
      ([.error(.auth(status: 401))], 3, "auth"),
      ([.error(.quota(status: 402))], 5, "quota"),
    ]
    for (steps, code, errorCode) in cases {
      for json in [false, true] {
        let harness = ExplainHarness(scripts: [steps])
        #expect(
          await harness.run(
            ["explain", "input"] + (document ? ["--doc"] : [])
              + (json ? ["--json"] : [])) == code)
        if json {
          let object = try harness.object()
          #expect(object["mode"] as? String == (document ? "document" : "quick"))
          #expect(object["result"] is NSNull)
          let error = try #require(object["error"] as? [String: Any])
          #expect(error["code"] as? String == errorCode)
          #expect(error["section"] == nil)
        } else {
          #expect(harness.output.isEmpty)
        }
      }
    }
    for beforeStart in [false, true] {
      let harness = ExplainHarness()
      #expect(
        await harness.run(
          ["explain", "input", "--json", "--provider", "openai"] + (document ? ["--doc"] : []),
          variables: beforeStart ? ["OPENAI_API_KEY": "fake-test-key"] : [:],
          beforeStart: beforeStart)
          == (beforeStart ? 130 : 3))
      let object = try harness.object()
      #expect(object["mode"] as? String == (document ? "document" : "quick"))
      #expect(object["result"] is NSNull)
    }
  }

  @Test func quickJSONOnlyGainsMode() async throws {
    let harness = ExplainHarness()
    #expect(await harness.run(["explain", "input", "--json"]) == 0)
    let object = try harness.object()
    #expect(
      Set(object.keys) == [
        "schema", "command", "mode", "status", "provider", "model", "result", "fallback", "usage",
        "timing", "error",
      ])
    #expect(object["mode"] as? String == "quick")
    let result = try #require(object["result"] as? [String: Any])
    #expect(
      Set(result.keys) == [
        "translation", "plain", "command", "terms", "glossary", "vocab", "domain",
      ])
    #expect(result["translation"] as? String == "Translation.")
    #expect(result["plain"] as? String == "Simple explanation.")
    #expect(result["command"] is NSNull)
    #expect(result["vocab"] is NSNull)
    #expect(result["domain"] is NSNull)
  }

  @Test func documentUsesPreparedSubjectAndFiltersEveryOutput() async throws {
    let hostile = documentReply.replacingOccurrences(of: ".", with: "\u{1B}[31m.\u{7}\u{0}")
    for options in [["--no-color"], ["--json"]] {
      for tty in [false, true] {
        let harness = ExplainHarness(scripts: [reply(hostile)])
        #expect(
          await harness.run(
            ["explain", "--doc", "--context", "-", "--show-sent", "--verbose"] + options + [
              "--", fakePEM(),
            ],
            stdin: Data("Context.".utf8), outputTTY: tty) == 0)
        #expect(!harness.output.contains("\u{1B}"))
        #expect(!harness.output.contains("\u{7}"))
        #expect(!harness.output.contains("\u{0}"))
        let request = try #require(harness.provider.recordedRequests.first)
        #expect(request.maxOutputTokens == 8192)
        #expect(
          request.messages.last?.content == "Input:\n[REDACTED]\n\nBackground context:\nContext.")
        #expect(harness.error.contains("Input:\n[REDACTED]\n\nBackground context:\nContext.\n"))
        #expect(harness.error.contains(pemNotice))
        #expect(harness.error.contains("request=document"))
      }
    }
  }
}
