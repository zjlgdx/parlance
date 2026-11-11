import Foundation
import ParlanceCore
import os

@testable import ParlanceCLI

/// Continuation-based observations: tests advance clocks and await events, without polling.
final class WatchCounter: Sendable {
  private struct Waiter {
    let target: Int
    var continuation: CheckedContinuation<Void, any Error>?
    var cancelled = false
  }
  private struct State {
    var count = 0
    var waiters: [UUID: Waiter] = [:]
  }
  private let state = OSAllocatedUnfairLock(initialState: State())
  var count: Int { state.withLock { $0.count } }

  func advance() {
    let ready = state.withLock { state in
      state.count += 1
      var ready: [CheckedContinuation<Void, any Error>] = []
      for (id, waiter) in state.waiters where waiter.target <= state.count {
        if let continuation = waiter.continuation {
          ready.append(continuation)
          state.waiters[id]?.continuation = nil
        }
      }
      return ready
    }
    for continuation in ready { continuation.resume() }
  }

  func wait(_ count: Int = 1, registered: (@Sendable () -> Void)? = nil) async throws {
    let id = UUID()
    state.withLock { $0.waiters[id] = Waiter(target: count) }
    defer { state.withLock { $0.waiters.removeValue(forKey: id) } }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let result: Result<Void, any Error>? = state.withLock {
          if Task.isCancelled || $0.waiters[id]?.cancelled == true {
            return .failure(CancellationError())
          }
          if $0.count >= count { return .success(()) }
          $0.waiters[id]?.continuation = continuation
          return nil
        }
        registered?()
        if let result { continuation.resume(with: result) }
      }
    } onCancel: {
      let continuation = self.state.withLock {
        $0.waiters[id]?.cancelled = true
        let continuation = $0.waiters[id]?.continuation
        $0.waiters[id]?.continuation = nil
        return continuation
      }
      continuation?.resume(throwing: CancellationError())
    }
  }
}

/// Holds MockProvider at a scripted delay until the test releases the request.
struct WatchDelay: Clock {
  typealias Instant = ContinuousClock.Instant
  let now = ContinuousClock.now
  var minimumResolution: Duration { .nanoseconds(1) }
  let entered = WatchCounter()
  let released = WatchCounter()

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    entered.advance()
    try await released.wait()
    try Task.checkCancellation()
  }
}

final class SessionWatchFixture: LLMProvider, Sendable {
  struct File: Sendable {
    var data: Data
    var inode: UInt64 = 1
    var modified = Date(timeIntervalSince1970: 1)
  }
  struct State {
    var files: [String: File] = [:]
    var out = ""
    var err = ""
    var tick: (@Sendable () -> Void)?
    var signal: (@Sendable (UInt) -> Void)?
    var reads: [(String, UInt64)] = []
    var listings = 0
    var keyLookups = 0
    var tokens: [LLMCancellation] = []
    var providerTokens: [LLMCancellation] = []
    var now: Duration = .zero
    var tickSchedules: [Int] = []
  }
  let state = OSAllocatedUnfairLock(initialState: State())
  let subscribed = WatchCounter()
  let statuses = WatchCounter()
  let handledTicks = WatchCounter()
  let handledCompletions = WatchCounter()
  let scheduledRequests = WatchCounter()
  let calls = WatchCounter()
  let requestsFinished = WatchCounter()
  let newerNotices = WatchCounter()
  let diagnostics = WatchCounter()
  let delaysCancellation: Bool
  let provider: MockProvider
  let agent: String
  let path: String
  let date = Date(timeIntervalSince1970: 1_000_000)

  static let response = [
    MockProvider.Step.event(
      .text(
        "<translation>Translated.</translation><plain>Explanation.</plain><terms></terms>")),
    .event(.finished(.stop)),
  ]

  init(
    agent: String = "codex", scripts: [[MockProvider.Step]] = [SessionWatchFixture.response],
    clock: any Clock<Duration> = ContinuousClock(), delaysCancellation: Bool = false
  ) throws {
    self.delaysCancellation = delaysCancellation
    self.agent = agent
    provider = MockProvider(scripts: scripts, clock: clock)
    path = Self.path(agent, id: "aaaaaaaa-1111")
    let data = try Self.metadata(agent, id: "aaaaaaaa-1111")
    state.withLock { $0.files[path] = File(data: data) }
  }

  static func path(_ agent: String, id: String) -> String {
    if agent == "pi" {
      return "/fake-home/.pi/agent/sessions/--fictional-project--/timestamp_\(id).jsonl"
    }
    return agent == "claude"
      ? "/fake-home/.claude/projects/-fictional-project/\(id).jsonl"
      : "/fake-home/.codex/sessions/2026/11/05/rollout-\(id).jsonl"
  }

  static func lines(_ records: [[String: Any]]) throws -> Data {
    var data = Data()
    for record in records {
      data.append(try JSONSerialization.data(withJSONObject: record, options: .sortedKeys))
      data.append(10)
    }
    return data
  }

  static func metadata(_ agent: String, id: String, newer: Bool = false) throws -> Data {
    let timestamp = newer ? "2026-11-05T15:00:00Z" : "2026-11-05T14:00:00Z"
    if agent == "claude" {
      return try lines([
        [
          "type": "system", "cwd": "/fictional/project", "version": "2.1.318",
          "timestamp": timestamp,
        ]
      ])
    }
    if agent == "pi" {
      return try lines([
        [
          "type": "session", "version": 3, "id": id, "cwd": "/fictional/project",
          "timestamp": timestamp,
        ]
      ])
    }
    return try lines([
      SessionFixture.codexRecord(
        "session_meta",
        [
          "id": id, "cwd": "/fictional/project", "timestamp": timestamp,
          "cli_version": "0.166.0", "history_mode": "paginated", "source": "cli",
        ])
    ])
  }

  func records(_ turn: Int, reply: String? = nil) -> [[String: Any]] {
    let prompt = "private-question-\(turn)"
    let reply = reply ?? "private-reply-\(turn)"
    if agent == "claude" {
      return [
        SessionFixture.user(prompt, id: "u\(turn)"),
        SessionFixture.assistant(reply, id: "a\(turn)"),
      ]
    }
    if agent == "pi" {
      return [
        SessionFixture.piMessage(
          "user", prompt, id: "u\(turn)", parent: turn == 1 ? nil : "a\(turn - 1)"),
        SessionFixture.piAssistant(reply, id: "a\(turn)", parent: "u\(turn)"),
      ]
    }
    return [
      SessionFixture.codexRecord("event_msg", ["type": "task_started", "turn_id": "t\(turn)"]),
      SessionFixture.codexUser(prompt), SessionFixture.complete("t\(turn)", reply),
    ]
  }

  func append(_ records: [[String: Any]]) throws { append(try Self.lines(records)) }
  func append(_ data: Data) { state.withLock { $0.files[path]?.data.append(data) } }
  var output: String { state.withLock { $0.out } }
  var error: String { state.withLock { $0.err } }
  func signal() { state.withLock { $0.signal }?(1) }

  func tick(registered: (@Sendable () -> Void)? = nil) async throws {
    let next = handledTicks.count + 1
    let callback = state.withLock {
      $0.now += .seconds(1)
      return $0.tick
    }
    callback?()
    try await handledTicks.wait(next, registered: registered)
  }

  func stop(_ task: Task<Int32, Never>) {
    signal()
    for token in state.withLock({ $0.tokens }) { token.cancel() }
    task.cancel()
    releaseProvider()
  }

  /// Awaits the watcher's exit code; a test that times out cancels the watcher instead of hanging.
  func result(_ task: Task<Int32, Never>) async -> Int32 {
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  func releaseProvider() {
    for token in state.withLock({ $0.providerTokens }) { token.cancel() }
  }

  func stream(_ request: LLMRequest, cancellation: LLMCancellation) -> AsyncThrowingStream<
    LLMEvent, any Error
  > {
    state.withLock { $0.tokens.append(cancellation) }
    // A separate MockProvider token lets a test defer transport shutdown after command cancellation.
    let providerToken = delaysCancellation ? LLMCancellation() : cancellation
    state.withLock { $0.providerTokens.append(providerToken) }
    let stream = provider.stream(request, cancellation: providerToken)
    calls.advance()
    return stream
  }

  func environment(tty: Bool = true, config: String? = nil) -> CLIEnvironment {
    CLIEnvironment(
      variables: ["OPENAI_API_KEY": "fake-watch-key"], stdinIsTTY: true,
      stdoutIsTTY: tty, stderrIsTTY: false,
      readStdin: { preconditionFailure("watch must not read stdin") },
      stdout: { text in self.state.withLock { $0.out += text } },
      stderr: { text in
        self.state.withLock { $0.err += text }
        if text.hasPrefix("pl: request=") { self.requestsFinished.advance() }
        if text.hasPrefix("pl: a newer") { self.newerNotices.advance() }
        if text.contains("interrupted the request") || text.contains("exceeds 20,000") {
          self.diagnostics.advance()
        }
      },
      makeProvider: { _ in self },
      interruptSource: CLIInterruptSource { receive in
        self.state.withLock { $0.signal = receive }
        return { self.state.withLock { $0.signal = nil } }
      }, homeDirectory: "/fake-home",
      readConfig: { _ in config.map { Data($0.utf8) } },
      makeKeychain: { _ in
        self.state.withLock { $0.keyLookups += 1 }
        return MemoryKeychain()
      }, currentDirectory: "/fictional/project",
      listSessionDirectory: { directory in
        self.state.withLock { state in
          state.listings += 1
          let prefix = directory + "/"
          return Array(
            Set(
              state.files.keys.compactMap { path in
                guard path.hasPrefix(prefix) else { return String?.none }
                return prefix + path.dropFirst(prefix.count).split(separator: "/")[0]
              })
          ).sorted()
        }
      },
      sessionModificationDate: { path in
        try self.state.withLock {
          guard let file = $0.files[path] else { throw CocoaError(.fileNoSuchFile) }
          return file.modified
        }
      },
      readSessionLines: { path, visit in
        let data = try self.state.withLock {
          guard let file = $0.files[path] else { throw CocoaError(.fileNoSuchFile) }
          return file.data
        }
        var start = data.startIndex
        for end in data.indices where data[end] == 10 {
          if !visit(Data(data[start..<end])) { break }
          start = end + 1
        }
      },
      requestClock: CLIRequestClock(
        now: { self.state.withLock { $0.now } },
        subscribe: { callback in
          self.state.withLock { $0.tick = callback }
          self.subscribed.advance()
          return { self.state.withLock { $0.tick = nil } }
        }),
      sessionFileStatus: { path in
        defer { self.statuses.advance() }
        return try self.state.withLock {
          guard let file = $0.files[path] else { throw CocoaError(.fileNoSuchFile) }
          return SessionFileStatus(device: 1, inode: file.inode, size: UInt64(file.data.count))
        }
      },
      readSessionBytes: { path, offset, count in
        try self.state.withLock {
          guard let file = $0.files[path] else { throw CocoaError(.fileNoSuchFile) }
          $0.reads.append((path, offset))
          return Data(file.data.dropFirst(Int(offset)).prefix(count))
        }
      }, wallDate: { self.date })
  }

  func run(
    _ environment: CLIEnvironment? = nil, options: [String] = [], selection: String? = nil,
    verbose: Bool = true
  ) async -> Int32 {
    let observe: @Sendable (SessionWatcher.Observation) -> Void = { event in
      switch event {
      case .handledTick:
        self.state.withLock { $0.tickSchedules.append(self.scheduledRequests.count) }
        self.handledTicks.advance()
      case .handledCompletion: self.handledCompletions.advance()
      case .scheduledRequest: self.scheduledRequests.advance()
      }
    }
    return await SessionWatcher.$observe.withValue(observe) {
      await CLIEnvironment.$override.withValue(environment ?? self.environment()) {
        await PL.execute(
          arguments: ["session", "watch", selection ?? agent, "--no-color"]
            + (verbose ? ["--verbose"] : []) + options
        ).rawValue
      }
    }
  }
}
