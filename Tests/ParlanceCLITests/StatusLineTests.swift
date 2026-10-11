import Dispatch
import Foundation
import ParlanceCore
import Testing
import os

@testable import ParlanceCLI

private let eraseLine = "\r\u{1B}[2K"
private let privateInput = "private input sentinel"
private let privateReply = "private model output sentinel"

/// Bounded event observation, including cleanup when the expected event never arrives.
private final class StatusNotice<Value: Sendable>: Sendable {
  private struct Deadline: Error {}
  private struct State {
    var result: Result<Value, any Error>?
    var waiter: CheckedContinuation<Value, any Error>?
  }
  private let state = OSAllocatedUnfairLock(initialState: State())
  func send(_ value: Value) { resolve(.success(value)) }
  private func resolve(_ result: Result<Value, any Error>) {
    let waiter = state.withLock {
      guard $0.result == nil else { return CheckedContinuation<Value, any Error>?.none }
      $0.result = result
      let waiter = $0.waiter
      $0.waiter = nil
      return waiter
    }
    waiter?.resume(with: result)
  }
  func wait() async throws -> Value {
    let deadline = DispatchWorkItem { self.resolve(.failure(Deadline())) }
    // Generous for slow shared CI machines; a passing wait returns as soon as the event arrives.
    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: deadline)
    defer { deadline.cancel() }
    return try await withCheckedThrowingContinuation { continuation in
      let result: Result<Value, any Error>? = state.withLock {
        if let result = $0.result { return result }
        $0.waiter = continuation
        return Result<Value, any Error>?.none
      }
      if let result { continuation.resume(with: result) }
    }
  }
}

private final class StatusClock: Sendable {
  struct State {
    var now: Duration = .zero
    var tick: (@Sendable () -> Void)?
    var subscriptions = 0
  }
  let state = OSAllocatedUnfairLock(initialState: State())
  var clock: CLIRequestClock {
    CLIRequestClock(
      now: { self.state.withLock { $0.now } },
      subscribe: { tick in
        self.state.withLock {
          $0.tick = tick
          $0.subscriptions += 1
        }
        return { self.state.withLock { $0.tick = nil } }
      })
  }
  func advance(_ seconds: Int) {
    let tick = state.withLock {
      $0.now += .seconds(seconds)
      return $0.tick
    }
    tick?()
  }
}

private final class StatusProvider: LLMProvider, Sendable {
  let ready = StatusNotice<Bool>()
  let continuation = OSAllocatedUnfairLock<
    AsyncThrowingStream<LLMEvent, any Error>.Continuation?
  >(initialState: nil)
  func stream(_ request: LLMRequest, cancellation: LLMCancellation) -> AsyncThrowingStream<
    LLMEvent, any Error
  > {
    let (stream, continuation) = AsyncThrowingStream<LLMEvent, any Error>.makeStream()
    self.continuation.withLock { $0 = continuation }
    cancellation.onCancel { continuation.finish(throwing: LLMError.aborted) }
    ready.send(true)
    return stream
  }
  func send(_ event: LLMEvent) { continuation.withLock { $0 }?.yield(event) }
  func finish(_ error: LLMError? = nil) {
    continuation.withLock { $0 }?.finish(throwing: error)
  }
}

private final class StatusHarness: Sendable {
  struct State {
    var out = ""
    var writes: [String] = []
    var signal: (@Sendable (UInt) -> Void)?
    var exitErrors: [String] = []
  }
  let state = OSAllocatedUnfairLock(initialState: State())
  let clock = StatusClock()
  let cleared = StatusNotice<Bool>()
  let retrying = StatusNotice<Bool>()
  let completed = StatusNotice<Int32>()
  var error: String { state.withLock { $0.writes.joined() } }
  var output: String { state.withLock { $0.out } }

  func environment(_ provider: any LLMProvider, tty: Bool) -> CLIEnvironment {
    CLIEnvironment(
      variables: ["OPENAI_API_KEY": "fake-test-key"], stdinIsTTY: false,
      stdoutIsTTY: false, stderrIsTTY: tty, readStdin: { Data() },
      stdout: { text in self.state.withLock { $0.out += text } },
      stderr: { text in
        self.state.withLock { $0.writes.append(text) }
        if text == eraseLine { self.cleared.send(true) }
        if text.contains("retrying in") { self.retrying.send(true) }
      }, makeProvider: { _ in provider },
      interruptSource: CLIInterruptSource { signal in
        self.state.withLock { $0.signal = signal }
        return { self.state.withLock { $0.signal = nil } }
      },
      exitImmediately: { _ in
        self.state.withLock { $0.exitErrors.append($0.writes.joined()) }
      }, requestClock: clock.clock)
  }

  func run(_ args: [String], environment: CLIEnvironment) async -> Int32 {
    let code = await CLIEnvironment.$override.withValue(environment) {
      await PL.execute(arguments: args).rawValue
    }
    completed.send(code)
    return code
  }

  func signal(_ count: UInt = 1) { state.withLock { $0.signal }?(count) }
}

private func statusReply(_ command: String) -> String {
  command == "fix"
    ? "<best>\(privateReply)</best><gloss>gloss</gloss><alts><alt><text>alternate</text><note>note</note></alt></alts>"
    : "<translation>\(privateReply)</translation><plain>plain</plain><terms></terms>"
}

struct StatusLineTests {
  @Test(arguments: ["fix", "explain"], [false, true])
  func firstTokenClearsBeforeCompletion(command: String, json: Bool) async throws {
    let harness = StatusHarness()
    let provider = StatusProvider()
    let task = Task {
      await harness.run(
        [command, privateInput, "--verbose"] + (json ? ["--json"] : []),
        environment: harness.environment(provider, tty: true))
    }
    defer {
      provider.finish(.aborted)
      task.cancel()
    }
    _ = try await provider.ready.wait()
    #expect(harness.error == eraseLine + "pl: waiting for first token 0s")
    harness.clock.advance(3)
    #expect(harness.error.hasSuffix(eraseLine + "pl: waiting for first token 3s"))
    provider.send(.retrying(after: .seconds(2), cause: .rateLimit))
    _ = try await harness.retrying.wait()
    #expect(harness.error.hasSuffix(eraseLine + "pl: retrying in 2s (rate limited)"))
    harness.clock.advance(1)
    #expect(harness.error.hasSuffix(eraseLine + "pl: retrying in 1s (rate limited)"))
    harness.clock.advance(1)
    #expect(harness.error.hasSuffix(eraseLine + "pl: waiting for first token 0s"))
    // Hold the stream open: clearing only on completion must time out and fail this test.
    provider.send(.text(statusReply(command)))
    _ = try await harness.cleared.wait()
    #expect(harness.error.hasSuffix(eraseLine))
    let afterFirst = harness.error
    harness.clock.advance(2)
    #expect(harness.error == afterFirst)
    provider.send(.finished(.stop))
    provider.finish()
    #expect(try await harness.completed.wait() == 0)
    #expect(await task.value == 0)
    let metadata = harness.error.components(separatedBy: "pl: request=").last ?? ""
    #expect(
      metadata.contains(
        "preset=openai model=gpt-6-luna effort=none(default) thinking=off(default) first_text_timeout=30 http=2xx"
      ))
    #expect(metadata.contains("first_token_ms=5000 total_ms=7000 retries=1\n"))
    #expect(!harness.error.contains(privateInput))
    #expect(!harness.error.contains(privateReply))
    #expect(harness.clock.state.withLock { $0.tick == nil })
  }

  @Test(arguments: ["fix", "explain"])
  func nonTTYIsSilentWithoutVerbose(command: String) async {
    let harness = StatusHarness()
    let provider = MockProvider(scripts: [
      [
        .event(.retrying(after: .seconds(2), cause: .server)),
        .event(.text(statusReply(command))), .event(.finished(.stop)),
      ]
    ])
    #expect(
      await harness.run(
        [command, privateInput], environment: harness.environment(provider, tty: false)) == 0)
    #expect(harness.error.isEmpty)
    #expect(harness.clock.state.withLock { $0.subscriptions == 0 })
  }

  @Test(arguments: ["fix", "explain"], [UInt(1), UInt(2)])
  func interruptClearsBeforeDiagnosticAndExitsImmediately(command: String, count: UInt) async throws
  {
    let harness = StatusHarness()
    let provider = StatusProvider()
    let task = Task {
      await harness.run(
        [command, privateInput, "--json", "--verbose"],
        environment: harness.environment(provider, tty: true))
    }
    defer {
      provider.finish(.aborted)
      task.cancel()
    }
    _ = try await provider.ready.wait()
    harness.signal(count)
    #expect(try await harness.completed.wait() == 130)
    #expect(await task.value == 130)
    #expect(harness.error.contains(eraseLine + "pl: request="))
    #expect(harness.error.contains("http=none first_token_ms=null"))
    #expect(harness.error.contains("pl: the request was aborted."))
    #expect(harness.output.contains("\"aborted\""))
    if count == 2 {
      #expect(harness.state.withLock { $0.exitErrors.count == 1 })
      // The line is cleared before the process would exit, not by the later normal completion.
      #expect(harness.state.withLock { $0.exitErrors.first?.hasSuffix(eraseLine) == true })
    }
    let completed = harness.error
    harness.clock.advance(10)
    #expect(harness.error == completed)
  }

  @Test(arguments: ["fix", "explain"])
  func failureClearsAndReportsHTTP(command: String) async {
    let harness = StatusHarness()
    let provider = MockProvider(scripts: [[.error(.server(status: 503))]])
    #expect(
      await harness.run(
        [command, privateInput, "--verbose"],
        environment: harness.environment(provider, tty: true)) == 6)
    #expect(harness.error.contains(eraseLine + "pl: request="))
    #expect(harness.error.contains("http=503 first_token_ms=null total_ms=0 retries=0"))
    #expect(
      harness.error.hasSuffix("pl: the provider reported a server error. HTTP 503. Try again.\n"))
  }

  @Test func statusSerializesNoticesAndStopsOnCompletion() {
    let harness = StatusHarness()
    let environment = harness.environment(MockProvider(scripts: []), tty: true)
    let reporter = RequestReporter(
      environment: environment,
      provider: ResolvedProvider(
        preset: .openai, baseURL: ProviderPreset.openai.baseURL!,
        model: ProviderPreset.openai.defaultModel!), verbose: false)
    let stop = reporter.startTicker()
    defer { stop() }
    reporter.begin(.quick)
    reporter.write("pl: notice\n")
    #expect(harness.error.hasSuffix(eraseLine + "pl: notice\n"))
    harness.clock.advance(1)
    #expect(harness.error.hasSuffix(eraseLine + "pl: waiting for first token 1s"))
    reporter.retry(after: .milliseconds(2500), cause: .server)
    #expect(harness.error.hasSuffix("retrying in 3s (provider unavailable)"))
    harness.clock.advance(1)
    #expect(harness.error.hasSuffix("retrying in 2s (provider unavailable)"))
    reporter.finish()
    #expect(harness.error.hasSuffix(eraseLine))
    let finished = harness.error
    harness.clock.advance(1)
    #expect(harness.error == finished)
  }

  @Test(arguments: ["fix", "explain"], [false, true])
  func verbosePrivacyAndHelperFailure(command: String, helperFails: Bool) async {
    let harness = StatusHarness()
    let provider = MockProvider(scripts: [
      [
        .event(.text(statusReply(command))), .event(.finished(.stop)),
      ]
    ])
    var environment = harness.environment(provider, tty: false)
    environment.variables = [:]
    environment.readConfig = { _ in
      Data(
        """
        provider = "openai"
        [providers.openai]
        api_key_cmd = "fake-helper-command --private-argument"
        """.utf8)
    }
    environment.runKeyCommand = { _, _ in
      .init(
        termination: .exit(helperFails ? 9 : 0),
        stdout: Data("fake-helper-output-key".utf8))
    }
    #expect(
      await harness.run([command, privateInput, "--verbose"], environment: environment)
        == (helperFails ? 3 : 0))
    for secret in [
      "fake-helper-command", "private-argument", "fake-helper-output-key",
      privateInput, privateReply,
    ] {
      #expect(!harness.error.contains(secret))
    }
    #expect(harness.error.contains("pl: request=") == !helperFails)
    #expect(!harness.error.contains("\u{1B}"))
  }

  @Test(arguments: ["fix", "explain"])
  func verboseSanitizesModelAndNeverPrintsContext(command: String) async {
    let harness = StatusHarness()
    let provider = MockProvider(scripts: [
      [
        .event(.text(statusReply(command))), .event(.finished(.stop)),
      ]
    ])
    var environment = harness.environment(provider, tty: false)
    environment.readContextTail = { _ in Data("private context sentinel".utf8) }
    let model = "model api_key=fake-embedded-secret fake-test-key"
    #expect(
      await harness.run(
        [command, privateInput, "--verbose", "--model", model]
          + (command == "explain" ? ["--context", "unused"] : []), environment: environment) == 0)
    #expect(harness.error.contains("[REDACTED]"))
    for secret in [
      "fake-test-key", "fake-embedded-secret", privateInput, privateReply,
      "private context sentinel",
    ] {
      #expect(!harness.error.contains(secret))
    }
    let lines = harness.error.split(separator: "\n")
    #expect(lines.filter { $0.hasPrefix("pl: request=") }.count == 1)
    #expect(lines.allSatisfy { $0.hasPrefix("pl: ") })
  }

  @Test(arguments: [
    // Controls split, rebuild or reparse the key; such a field is never printed.
    ("fake-test-key", "model\u{1B}[31m\r\n\t\u{07} fake-\u{1B}[0mtest-key"),
    ("fake-test-key", "m \u{1B}[fake-test-key"),
    ("fake-test-key", "m \u{1B}[f\u{07}ake-test-key"),
    ("fake\tshort", "m-fake\tshort"),
  ])
  func verboseNeverPrintsAFieldWithControls(key: String, model: String) async {
    let harness = StatusHarness()
    let provider = MockProvider(scripts: [
      [.event(.text(statusReply("fix"))), .event(.finished(.stop))]
    ])
    var environment = harness.environment(provider, tty: false)
    environment.variables["OPENAI_API_KEY"] = key
    #expect(
      await harness.run(
        ["fix", privateInput, "--verbose", "--model", model], environment: environment) == 0)
    #expect(harness.error.contains("model=[invalid]"))
    for secret in ["test-key", "short", "\u{1B}", "\r", "\t", "\u{07}"] {
      #expect(!harness.error.contains(secret))
    }
  }

  @Test func explainMetadataIsPerRequestIncludingFailedDeep() async {
    let harness = StatusHarness()
    let provider = MockProvider(scripts: [
      [.event(.text(statusReply("explain"))), .event(.finished(.stop))],
      [.event(.text("<vocab>words</vocab>")), .event(.finished(.stop))],
      [
        .event(.retrying(after: .seconds(1), cause: .rateLimit)),
        .error(.rateLimit(retryAfter: nil)),
      ],
    ])
    #expect(
      await harness.run(
        ["explain", privateInput, "--verbose", "--deep", "vocab", "--deep", "domain"],
        environment: harness.environment(provider, tty: false)) == 6)
    let lines = harness.error.split(separator: "\n").filter { $0.hasPrefix("pl: request=") }
    #expect(lines.count == 3)
    #expect(lines.first?.contains("request=quick") == true)
    #expect(lines.dropFirst().first?.contains("request=vocab") == true)
    #expect(lines.last?.contains("request=domain") == true)
    #expect(lines.last?.contains("http=none first_token_ms=null total_ms=0 retries=1") == true)
    #expect(lines.first?.hasSuffix("retries=0") == true)
    #expect(harness.output.isEmpty)
  }

  @Test func strictAndTransportRetriesAreCountedTogether() async {
    let harness = StatusHarness()
    let provider = MockProvider(scripts: [
      [
        .event(.retrying(after: .seconds(1), cause: .server)),
        .event(
          .text(
            "<best>first ⟦0⟧</best><gloss>gloss</gloss><alts><alt><text>changed</text><note>note</note></alt></alts>"
          )),
        .event(.finished(.stop)),
      ],
      [
        .event(.retrying(after: .seconds(2), cause: .rateLimit)),
        .event(
          .text(
            "<best>second ⟦0⟧</best><gloss>gloss</gloss><alts><alt><text>alt ⟦0⟧</text><note>note</note></alt></alts>"
          )),
        .event(.finished(.stop)),
      ],
    ])
    #expect(
      await harness.run(
        ["fix", "fooBar", "--verbose"],
        environment: harness.environment(provider, tty: true)) == 0)
    #expect(provider.recordedRequests.count == 2)
    #expect(harness.output == "second fooBar\n")
    #expect(harness.error.hasSuffix("retries=3\n"))
    #expect(harness.error.components(separatedBy: "pl: request=").count == 2)
    #expect(!harness.error.contains("fooBar"))
  }

  @Test func newRequestResetsTimingAndRetryCount() {
    let harness = StatusHarness()
    let reporter = RequestReporter(
      environment: harness.environment(MockProvider(scripts: []), tty: false),
      provider: ResolvedProvider(
        preset: .openai, baseURL: ProviderPreset.openai.baseURL!,
        model: ProviderPreset.openai.defaultModel!), verbose: true)
    reporter.begin(.quick)
    reporter.retry(after: .seconds(1), cause: .server)
    harness.clock.advance(1)
    reporter.firstToken()
    harness.clock.advance(2)
    reporter.finish()
    reporter.begin(.domain)
    harness.clock.advance(4)
    reporter.finish(error: .transport)
    let lines = harness.error.split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines[0].contains("first_token_ms=1000 total_ms=3000 retries=1"))
    #expect(lines[1].contains("http=none first_token_ms=null total_ms=4000 retries=0"))
  }

  @Test(arguments: [
    "write", "finish", "metadata", "tick", "firstToken", "retry", "strictRetry", "interrupt",
  ])
  func blockedStderrDoesNotDelayCancellationOrExit(writer: String) async throws {
    let harness = StatusHarness()
    let blocked = StatusNotice<Bool>()
    let drained = StatusNotice<Bool>()
    let cancelled = StatusNotice<Bool>()
    let firstReturned = StatusNotice<Bool>()
    let exited = StatusNotice<Int32>()
    let signalsFinished = StatusNotice<Bool>()
    let release = DispatchSemaphore(value: 0)
    let armed = OSAllocatedUnfairLock(initialState: false)
    let released = OSAllocatedUnfairLock(initialState: false)
    var environment = harness.environment(MockProvider(scripts: []), tty: true)
    environment.stderr = { _ in
      let stall = armed.withLock {
        let value = $0
        $0 = false
        return value
      }
      if stall {
        blocked.send(true)
        #expect(release.wait(timeout: .now() + 120) == .success)
        released.withLock { $0 = true }
        drained.send(true)
      }
    }
    let reporter = RequestReporter(
      environment: environment,
      provider: ResolvedProvider(
        preset: .openai, baseURL: ProviderPreset.openai.baseURL!,
        model: ProviderPreset.openai.defaultModel!), verbose: true)
    let handler = CLIInterruptHandler(
      source: environment.interruptSource,
      exitImmediately: { code in
        #expect(!released.withLock { $0 })
        exited.send(code)
      }, onInterrupt: { reporter.interrupt() })
    let token = try handler.beginOperation()
    token.onCancel { cancelled.send(true) }
    let stop = reporter.startTicker()
    defer {
      release.signal()
      stop()
      handler.stop()
    }
    reporter.begin(.fix)
    if writer == "strictRetry" || writer == "metadata" { reporter.firstToken() }
    armed.withLock { $0 = true }
    DispatchQueue.global().async {
      switch writer {
      case "write": reporter.write("pl: diagnostic\n")
      case "finish", "metadata": reporter.finish(error: .server(status: 503))
      case "tick": harness.clock.advance(1)
      case "firstToken": reporter.firstToken()
      case "retry": reporter.retry(after: .seconds(2), cause: .server)
      case "strictRetry": reporter.strictRetry()
      default: reporter.interrupt()
      }
    }
    _ = try await blocked.wait()
    // Like a DispatchSource, these two callbacks are serial. Neither may be held up by stderr.
    DispatchQueue(label: "parlance.test.signals").async {
      harness.signal()
      firstReturned.send(true)
      harness.signal()
      signalsFinished.send(true)
    }
    _ = try await cancelled.wait()
    #expect(token.isCancelled)
    _ = try await firstReturned.wait()
    #expect(try await exited.wait() == 130)
    _ = try await signalsFinished.wait()
    #expect(!released.withLock { $0 })
    release.signal()
    _ = try await drained.wait()
  }

  @Test(arguments: [UInt(1), UInt(2)])
  func interruptActionsPrecedeCleanup(count: UInt) throws {
    let harness = StatusHarness()
    let events = OSAllocatedUnfairLock(initialState: [String]())
    let environment = harness.environment(MockProvider(scripts: []), tty: false)
    let handler = CLIInterruptHandler(
      source: environment.interruptSource,
      exitImmediately: { _ in events.withLock { $0.append("exit") } },
      onInterrupt: { events.withLock { $0.append("cleanup") } })
    defer { handler.stop() }
    let token = try handler.beginOperation()
    token.onCancel { events.withLock { $0.append("cancel") } }
    harness.signal(count)
    #expect(
      events.withLock { $0 }
        == (count == 1 ? ["cancel", "cleanup"] : ["exit", "cancel", "cleanup"]))
  }

  @Test(arguments: [false, true])
  func interruptAfterCommitDoesNotRewriteMetadata(failed: Bool) throws {
    let harness = StatusHarness()
    let environment = harness.environment(MockProvider(scripts: []), tty: false)
    let reporter = RequestReporter(
      environment: environment,
      provider: ResolvedProvider(
        preset: .openai, baseURL: ProviderPreset.openai.baseURL!,
        model: ProviderPreset.openai.defaultModel!), verbose: true)
    let handler = CLIInterruptHandler(
      source: environment.interruptSource,
      exitImmediately: { _ in }, onInterrupt: { reporter.interrupt() })
    defer { handler.stop() }
    _ = try handler.beginOperation()
    reporter.begin(.fix)
    #expect(!handler.complete())
    harness.signal()
    #expect(!handler.isInterrupted)
    reporter.finish(error: failed ? .server(status: 503) : nil)
    #expect(harness.error.contains(failed ? "http=503" : "http=2xx"))
    #expect(!harness.error.contains("http=none"))
  }

  @Test(arguments: ["fix", "explain"], [false, true])
  func dumbTerminalSuppressesStatusButKeepsMetadata(command: String, verbose: Bool) async {
    let harness = StatusHarness()
    let provider = MockProvider(scripts: [
      [
        .event(.retrying(after: .seconds(2), cause: .server)),
        .event(.text(statusReply(command))), .event(.finished(.stop)),
      ]
    ])
    var environment = harness.environment(provider, tty: true)
    environment.variables["TERM"] = "dumb"
    #expect(
      await harness.run(
        [command, privateInput] + (verbose ? ["--verbose"] : []),
        environment: environment) == 0)
    #expect(!harness.error.contains("\u{1B}"))
    #expect(!harness.error.contains("waiting for") && !harness.error.contains("retrying in"))
    #expect(harness.error.isEmpty == !verbose)
    #expect(harness.clock.state.withLock { $0.subscriptions == 0 })
  }

  @Test func injectedEnvironmentDefaultsToInactiveClock() {
    let called = OSAllocatedUnfairLock(initialState: false)
    let environment = CLIEnvironment(
      variables: [:], stdinIsTTY: false, stdoutIsTTY: false,
      stderrIsTTY: true, readStdin: { Data() }, stdout: { _ in }, stderr: { _ in },
      makeProvider: { _ in MockProvider(scripts: []) })
    #expect(environment.requestClock.now() == .zero)
    let stop = environment.requestClock.subscribe { called.withLock { $0 = true } }
    stop()
    #expect(!called.withLock { $0 })
  }

  @Test func httpMetadataUsesOnlyCarriedStatuses() {
    let cases: [(LLMError?, String)] = [
      (nil, "2xx"), (.auth(status: 401), "401"), (.auth(status: nil), "none"),
      (.quota(status: 402), "402"), (.invalidRequest(status: 404, providerCode: nil), "404"),
      (.rateLimit(retryAfter: .seconds(1)), "none"), (.server(status: 529), "529"),
      (.transport, "none"), (.timeout(.firstToken), "none"), (.aborted, "none"),
      (.emptyResponse, "none"), (.malformedResponse, "none"),
    ]
    for (error, expected) in cases {
      let harness = StatusHarness()
      let reporter = RequestReporter(
        environment: harness.environment(MockProvider(scripts: []), tty: false),
        provider: ResolvedProvider(
          preset: .openai, baseURL: ProviderPreset.openai.baseURL!,
          model: ProviderPreset.openai.defaultModel!), verbose: true)
      reporter.begin(.quick)
      reporter.finish(error: error)
      #expect(harness.error.contains("http=\(expected) "))
    }
  }

  @Test func preparedTextAndPEMNoticeStartOnClearedLine() async {
    let harness = StatusHarness()
    let provider = MockProvider(scripts: [[.error(.auth(status: 401))]])
    let input = "before -----BEGIN " + "PRIVATE KEY----- hidden"
    #expect(
      await harness.run(
        ["explain", input, "--verbose", "--show-sent"],
        environment: harness.environment(provider, tty: true)) == 3)
    let writes = harness.state.withLock { $0.writes }
    #expect(writes.count > 3)
    #expect(writes[1] == eraseLine)
    #expect(writes[2].contains("[REDACTED]"))
    #expect(harness.error.contains("pl: a PEM block was redacted"))
    #expect(harness.error.contains("http=401"))
    #expect(!harness.error.contains("hidden"))
  }
}
