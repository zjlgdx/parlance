import Foundation
import ParlanceCore
import Testing

@testable import ParlanceCLI

@Suite(.timeLimit(.minutes(1)))
struct SessionWatchRevisionTests {
  @Test(arguments: [false, true])
  func counterCancellationResumesAndRemovesWaiter(_ beforeRegistration: Bool) async throws {
    let counter = WatchCounter()
    let registered = WatchCounter()
    let task = Task {
      if beforeRegistration { withUnsafeCurrentTask { $0?.cancel() } }
      do {
        try await counter.wait(registered: { registered.advance() })
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }
    defer {
      task.cancel()
      counter.advance()
    }
    try await registered.wait()
    task.cancel()
    counter.advance()
    #expect(await task.value)
    // A cancelled waiter must not consume a later observation or be resumed twice.
    counter.advance()
    try await counter.wait()
  }

  @Test(arguments: ["deleted", "replaced", "truncated"])
  func deferredProviderCancellationHasOnlyFileDiagnostic(_ change: String) async throws {
    let fixture = try SessionWatchFixture(scripts: [[.hang]], delaysCancellation: true)
    try fixture.append(fixture.records(1))
    let task = Task { await fixture.run(verbose: false) }
    defer { fixture.stop(task) }
    try await fixture.calls.wait()
    let before = fixture.error
    fixture.state.withLock {
      switch change {
      case "deleted": $0.files.removeValue(forKey: fixture.path)
      case "replaced": $0.files[fixture.path]?.inode += 1
      default: $0.files[fixture.path]?.data = Data()
      }
    }
    try await fixture.tick()
    #expect(await fixture.result(task) == 66)
    #expect(
      String(fixture.error.dropFirst(before.count))
        == "pl: the bound session file disappeared, was replaced, or became unreadable.\n")
    #expect(fixture.state.withLock { $0.tokens.allSatisfy(\.isCancelled) })
  }

  @Test(arguments: ["retracted", "appended", "recompleted"])
  func queuedClaudeTurnUsesCurrentParserState(_ change: String) async throws {
    let delay = WatchDelay()
    let fixture = try SessionWatchFixture(
      agent: "claude",
      scripts: [
        [.delay(.seconds(1))] + SessionWatchFixture.response,
        SessionWatchFixture.response,
      ], clock: delay)
    try fixture.append(fixture.records(1))
    let task = Task { await fixture.run() }
    defer {
      delay.released.advance()
      fixture.stop(task)
    }
    try await delay.entered.wait()
    try fixture.append(fixture.records(2))
    try await fixture.tick()
    if change == "appended" {
      var more = SessionFixture.assistant(" appended text", id: "a2", stop: "")
      more["uuid"] = "additional-text"
      try fixture.append([more])
    } else {
      try fixture.append([SessionFixture.assistant("tool narration", id: "tool", stop: "tool_use")])
      if change == "recompleted" {
        try fixture.append([SessionFixture.assistant("new final reply", id: "new-end")])
      }
    }
    try await fixture.tick()
    delay.released.advance()
    try await fixture.handledCompletions.wait()
    if change == "retracted" {
      #expect(fixture.scheduledRequests.count == 1)
      #expect(fixture.provider.recordedRequests.count == 1)
    } else {
      try await fixture.requestsFinished.wait(2)
      let input = change == "appended" ? "private-reply-2 appended text" : "new final reply"
      #expect(
        fixture.provider.recordedRequests.last?.messages.last?.content.hasPrefix("Input:\n" + input)
          == true)
    }
    #expect(!fixture.error.contains("skipped"))
    fixture.signal()
    #expect(await fixture.result(task) == 130)
  }

  @Test func tickWaitsForHandlingAndRequestScheduling() async throws {
    let fixture = try SessionWatchFixture(scripts: [[.hang]])
    let task = Task { await fixture.run() }
    defer { fixture.stop(task) }
    try await fixture.subscribed.wait()
    try fixture.append(fixture.records(1))
    try await fixture.tick()
    #expect(fixture.handledTicks.count == 1)
    #expect(fixture.state.withLock { $0.tickSchedules.last } == 1)
    #expect(fixture.scheduledRequests.count == 1)
    try await fixture.calls.wait()
    try fixture.append(fixture.records(2))
    try await fixture.tick()
    #expect(fixture.handledTicks.count == 2)
    #expect(fixture.scheduledRequests.count == 1)
    fixture.signal()
    #expect(await fixture.result(task) == 130)
  }

  @Test(arguments: ["claude", "codex", "pi"], [false, true])
  func newerNoticeExcludesStartupBaseline(_ agent: String, _ explicit: Bool) async throws {
    let fixture = try SessionWatchFixture(agent: agent)
    let existingPath = SessionWatchFixture.path(agent, id: "already-present")
    let existing = try SessionWatchFixture.metadata(agent, id: "already-present", newer: true)
    fixture.state.withLock {
      $0.files[existingPath] = SessionWatchFixture.File(data: existing)
      $0.files[fixture.path]?.modified = Date(timeIntervalSince1970: 20)
    }
    let task = Task {
      await fixture.run(selection: explicit ? agent + ":aaaaaaaa-1111" : agent)
    }
    defer { fixture.stop(task) }
    try await fixture.subscribed.wait()
    for _ in 0..<10 { try await fixture.tick() }
    #expect(fixture.newerNotices.count == 0)
    // Appearance, rather than a later start timestamp, is the notification boundary.
    let newPath = SessionWatchFixture.path(agent, id: "newly-created")
    let newData = try SessionWatchFixture.metadata(agent, id: "newly-created")
    fixture.state.withLock { $0.files[newPath] = SessionWatchFixture.File(data: newData) }
    for _ in 0..<20 { try await fixture.tick() }
    #expect(fixture.newerNotices.count == 1)
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    #expect(fixture.error.contains("session aaaaaaaa"))
  }

  @Test(arguments: ["bogus", "claude:", "codex:a:b", ":id", ""])
  func selectionSyntaxPrecedesConfigurationAndKeys(_ selection: String) async throws {
    let fixture = try SessionWatchFixture()
    var environment = fixture.environment(config: "invalid = [")
    let reads = WatchCounter()
    let originalRead = environment.readConfig
    environment.readConfig = { path in
      reads.advance()
      return try originalRead(path)
    }
    #expect(await fixture.run(environment, selection: selection) == 64)
    #expect(fixture.error == "pl: choose claude, codex or pi, optionally followed by :ID.\n")
    #expect(reads.count == 0)
    #expect(fixture.state.withLock { $0.keyLookups == 0 && $0.listings == 0 })
  }

  @Test(arguments: [false, true])
  func parentCancellationAbortsAndCleansUp(_ inFlight: Bool) async throws {
    let fixture = try SessionWatchFixture(scripts: [[.hang]], delaysCancellation: true)
    if inFlight { try fixture.append(fixture.records(1)) }
    let task = Task { await fixture.run(verbose: false) }
    defer { fixture.stop(task) }
    try await fixture.subscribed.wait()
    if inFlight { try await fixture.calls.wait() }
    let before = fixture.error
    task.cancel()
    #expect(await fixture.result(task) == 130)
    #expect(fixture.state.withLock { $0.tokens.allSatisfy(\.isCancelled) })
    #expect(fixture.state.withLock { $0.tick == nil && $0.signal == nil })
    #expect(
      String(fixture.error.dropFirst(before.count)) == RewriteDiagnostic.forError(.aborted).line)
  }

  @Test func longPartialLineAcrossManyChunks() throws {
    let fixture = try SessionWatchFixture()
    let environment = fixture.environment()
    let binding = try SessionInput.select("codex", environment: environment)
    var file = try SessionWatchFile(binding: binding, environment: environment)
    let long = try SessionWatchFixture.lines([
      ["type": "ignored", "padding": String(repeating: "x", count: 3 * 1024 * 1024)]
    ])
    fixture.append(Data(long.dropLast()))
    try file.read(environment: environment)
    #expect(file.parser.turns.isEmpty)
    fixture.append(Data([10]))
    try fixture.append(fixture.records(1))
    try file.read(environment: environment)
    #expect(file.parser.turns.last?.reply == "private-reply-1")
    #expect(file.offset == fixture.state.withLock { UInt64($0.files[fixture.path]!.data.count) })
  }
}

extension SessionWatchRevisionTests {
  @Test func tickDoesNotReturnOnAFileStatusObservation() async throws {
    let fixture = try SessionWatchFixture()
    let registered = WatchCounter()
    fixture.state.withLock { $0.tick = { fixture.statuses.advance() } }
    let task = Task {
      do {
        try await fixture.tick(registered: { registered.advance() })
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }
    defer {
      task.cancel()
      fixture.handledTicks.advance()
    }
    try await registered.wait()
    task.cancel()
    fixture.handledTicks.advance()
    #expect(await task.value)
  }

  @Test func explainRetainsOptionSyntaxDiagnostic() throws {
    let fixture = try SessionWatchFixture()
    #expect(throws: (any Error).self) {
      try SessionInput.select("bogus", environment: fixture.environment())
    }
    #expect(
      fixture.error == "pl: choose --session claude, codex or pi, optionally followed by :ID.\n")
  }

  @Test func skippedHintSanitizesTheBoundID() async throws {
    let delay = WatchDelay()
    let fixture = try SessionWatchFixture(
      scripts: [
        [.delay(.seconds(1))] + SessionWatchFixture.response, SessionWatchFixture.response,
      ],
      clock: delay)
    let id = "bound\n\tid"
    let metadata = try SessionWatchFixture.metadata("codex", id: id)
    fixture.state.withLock { $0.files[fixture.path]?.data = metadata }
    try fixture.append(fixture.records(1))
    let task = Task { await fixture.run(selection: "codex:" + id) }
    defer {
      delay.released.advance()
      fixture.stop(task)
    }
    try await delay.entered.wait()
    try fixture.append(fixture.records(2) + fixture.records(3))
    try await fixture.tick()
    delay.released.advance()
    try await fixture.requestsFinished.wait(2)
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    let line = try #require(
      fixture.error.split(separator: "\n").first { $0.hasPrefix("pl: skipped") })
    #expect(
      line
        == "pl: skipped turns 2; look up a phrase from them with pl explain --session codex:boundid \"<phrase>\"."
    )
    #expect(!line.contains("private-"))
  }
}

/// The default file status and offset reader, on a disposable directory instead of in-memory fakes.
struct SessionWatchFileSystemTests {
  @Test func defaultReadersFollowAppendsAndDetectReplacement() throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let url = try fixture.codex([
      SessionFixture.codexRecord("event_msg", ["type": "task_started", "turn_id": "t1"]),
      SessionFixture.codexUser("Fictional question one."),
      SessionFixture.complete("t1", "Fictional reply one."),
    ])
    let environment = fixture.environment
    let binding = try SessionInput.select("codex", environment: environment)
    var file = try SessionWatchFile(binding: binding, environment: environment)
    try file.read(environment: environment)
    #expect(file.parser.turns.map(\.reply) == ["Fictional reply one."])
    let firstOffset = file.offset
    #expect(firstOffset == UInt64(try Data(contentsOf: url).count))

    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    let more = [
      SessionFixture.codexRecord("event_msg", ["type": "task_started", "turn_id": "t2"]),
      SessionFixture.codexUser("Fictional question two."),
      SessionFixture.complete("t2", "Fictional reply two."),
    ].map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
    try handle.write(contentsOf: Data((more.joined(separator: "\n") + "\n{\"half\":").utf8))
    try handle.close()
    try file.read(environment: environment)
    #expect(file.parser.turns.map(\.reply) == ["Fictional reply one.", "Fictional reply two."])
    #expect(file.parser.turns.map(\.identity) == ["t1", "t2"])
    let size = UInt64(try Data(contentsOf: url).count)
    #expect(file.offset > firstOffset && file.offset == size - UInt64("{\"half\":".utf8.count))

    // Atomic replacement gives the path a new inode; deletion removes it.
    let original = try Data(contentsOf: url)
    try original.write(to: url, options: .atomic)
    #expect(throws: (any Error).self) { try file.read(environment: environment) }
    try FileManager.default.removeItem(at: url)
    #expect(throws: (any Error).self) { try file.read(environment: environment) }
  }
}

extension SessionWatchRevisionTests {
  @Test(arguments: ["branch", "replace", "delete"])
  func queuedPiTurnUsesActivePathAndEdits(_ change: String) async throws {
    let delay = WatchDelay()
    let fixture = try SessionWatchFixture(
      agent: "pi",
      scripts: [
        [.delay(.seconds(1))] + SessionWatchFixture.response,
        SessionWatchFixture.response,
      ], clock: delay)
    try fixture.append(fixture.records(1))
    let task = Task { await fixture.run() }
    defer {
      delay.released.advance()
      fixture.stop(task)
    }
    try await delay.entered.wait()
    try fixture.append(fixture.records(2))
    try await fixture.tick()
    if change == "branch" {
      try fixture.append([
        SessionFixture.piMessage("user", "New branch question", id: "branch-u", parent: "a1"),
        SessionFixture.piAssistant("Replacement reply", id: "branch-a", parent: "branch-u"),
      ])
    } else {
      try fixture.append([
        SessionFixture.piEdit(
          "a2", content: change == "replace" ? "Replacement reply" : nil, id: "edit", parent: "a2")
      ])
    }
    try await fixture.tick()
    delay.released.advance()
    try await fixture.handledCompletions.wait()
    if change == "delete" {
      #expect(fixture.scheduledRequests.count == 1)
      #expect(fixture.provider.recordedRequests.count == 1)
    } else {
      try await fixture.requestsFinished.wait(2)
      let sent = try #require(fixture.provider.recordedRequests.last?.messages.last?.content)
      #expect(sent.hasPrefix("Input:\nReplacement reply"))
      if change == "branch" {
        #expect(sent.contains("New branch question"))
        #expect(!sent.contains("private-question-2"))
      }
    }
    fixture.signal()
    #expect(await fixture.result(task) == 130)
  }

  @Test func piDedupeUsesEntryIdentityRatherThanReplyText() async throws {
    let fixture = try SessionWatchFixture(agent: "pi")
    try fixture.append(fixture.records(1, reply: "Same reply"))
    let task = Task { await fixture.run() }
    defer { fixture.stop(task) }
    try await fixture.requestsFinished.wait()
    try fixture.append([
      SessionFixture.piEdit("a1", content: "Edited reply", id: "edit", parent: "a1")
    ])
    try await fixture.tick()
    #expect(fixture.scheduledRequests.count == 1)
    try fixture.append([
      SessionFixture.piAssistant("Same reply", id: "new-completion", parent: "edit")
    ])
    try await fixture.tick()
    try await fixture.requestsFinished.wait(2)
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    #expect(fixture.provider.recordedRequests.count == 2)
    #expect(
      fixture.provider.recordedRequests.allSatisfy {
        $0.messages.last?.content.hasPrefix("Input:\nSame reply") == true
      })
    #expect(fixture.output.components(separatedBy: "第 1 轮").count == 3)
  }
}
