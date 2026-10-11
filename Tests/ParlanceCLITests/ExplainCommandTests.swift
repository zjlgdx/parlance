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
    DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: deadline)
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
    interruptOnTranslation: Bool = false
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
          return stdin.suffix(CommandInput.contextBytes)
        }
        self.state.withLock {
          $0.contextReads.append(path)
          $0.subscribedDuringRead = $0.signal != nil
        }
        if readError { throw CocoaError(.fileReadUnknown) }
        if let context { return context.suffix(CommandInput.contextBytes) }
        return try CommandInput.readFileTail(path)
      })
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
    for args in [["--tone", "agent"], ["--deep", "other"], ["--deep"], ["--unknown\u{1B}[31m"]] {
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
    #expect(prompt.contains("Target language: de"))
    #expect(prompt.contains("Native language: fr"))
    let defaults = ExplainHarness()
    #expect(await defaults.run() == 0)
    let defaultPrompt = try #require(
      defaults.provider.recordedRequests.first?.messages.first?.content)
    #expect(defaultPrompt.contains("Target language: en"))
    #expect(defaultPrompt.contains("Native language: zh-Hans"))
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
    // Invalid bytes outside the 16 KiB read margin do not invalidate a UTF-8 tail.
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
    #expect(tail == body.suffix(CommandInput.contextBytes))
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
      #expect(Set(result.keys) == ["translation", "plain", "terms", "vocab", "domain"])
      #expect(result["translation"] as? String == "Translation.")
      #expect(result["plain"] as? String == "Simple explanation.")
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
