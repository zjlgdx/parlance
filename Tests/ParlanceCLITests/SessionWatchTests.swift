import Foundation
import ParlanceCore
import Testing

@testable import ParlanceCLI

@Suite(.timeLimit(.minutes(1)))
struct SessionWatchTests {
  @Test(arguments: ["claude", "codex", "pi"])
  func nonTTYDoesNotReadSessionOrCallProvider(_ agent: String) async throws {
    let fixture = try SessionWatchFixture(agent: agent)
    #expect(await fixture.run(fixture.environment(tty: false)) == 64)
    #expect(fixture.provider.recordedRequests.isEmpty)
    #expect(fixture.state.withLock { $0.listings } == 0)
    #expect(fixture.statuses.count == 0)
    #expect(fixture.error == "pl: session watch requires a terminal on stdout.\n")
  }

  @Test(arguments: ["claude", "codex", "pi"])
  func startupLatestHeaderAndSharedReplyMode(_ agent: String) async throws {
    let fixture = try SessionWatchFixture(agent: agent)
    try fixture.append(fixture.records(1) + fixture.records(2))
    let task = Task {
      await fixture.run(options: [
        "--target", "fr", "--native", "de", "--provider", "openai", "--model", "gpt-6.1-sol",
        "--effort", "high", "--thinking", "on", "--first-text-timeout", "20",
      ])
    }
    defer { fixture.stop(task) }
    try await fixture.requestsFinished.wait()
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    let name = agent == "claude" ? "Claude Code" : agent == "pi" ? "pi" : "Codex"
    #expect(fixture.error.contains("pl: using \(name) session aaaaaaaa (started "))
    #expect(fixture.error.contains("prompts: 2)"))
    #expect(
      fixture.error.contains(
        "the latest completed reply at start and each new reply are sent to openai (gpt-6.1-sol)"))
    #expect(
      fixture.error.contains("with up to 3,000 characters of earlier conversation, redacted."))
    #expect(fixture.error.contains("While an explanation runs, only the newest new reply is kept."))
    #expect(!fixture.error.contains("skipped"))
    #expect(fixture.error.contains("effort=high thinking=on first_text_timeout=20"))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    #expect(
      fixture.output.hasPrefix("── \(name) · turn 2 · \(formatter.string(from: fixture.date)) ──\n")
    )
    #expect(fixture.output.contains("Translated.\nPlain: Explanation.\nTerms:\n"))
    let requests = fixture.provider.recordedRequests
    #expect(requests.count == 1)
    let sent = try #require(requests.first?.messages.last?.content)
    #expect(
      sent
        == "Input:\nprivate-reply-2\n\nBackground context:\nUser: private-question-1\n\nAssistant: private-reply-1\n\nUser: private-question-2"
    )
    #expect(requests.first?.messages.first?.content.contains("fr") == true)
    #expect(requests.first?.messages.first?.content.contains("de") == true)
    #expect(!fixture.error.contains("private-question"))
    #expect(!fixture.error.contains("private-reply"))
    #expect(!fixture.output.contains("private-reply"))
  }

  @Test(arguments: ["claude", "codex", "pi"])
  func partialLineAndIdentityDedupe(_ agent: String) async throws {
    let fixture = try SessionWatchFixture(agent: agent)
    let task = Task { await fixture.run() }
    defer { fixture.stop(task) }
    try await fixture.subscribed.wait()
    let records = fixture.records(1, reply: "private-reply-1 漢字")
    try fixture.append(Array(records.dropLast()))
    let completion = try SessionWatchFixture.lines([try #require(records.last)])
    let cut = completion.count / 2
    fixture.append(Data(completion.prefix(cut)))
    try await fixture.tick()
    try await fixture.tick()
    #expect(fixture.provider.recordedRequests.isEmpty)
    #expect(fixture.scheduledRequests.count == 0)
    fixture.append(Data(completion.dropFirst(cut)))
    try await fixture.tick()
    try await fixture.requestsFinished.wait()
    fixture.append(completion)
    try await fixture.tick()
    #expect(fixture.scheduledRequests.count == 1)
    try fixture.append(fixture.records(2))
    try await fixture.tick()
    try await fixture.requestsFinished.wait(2)
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    #expect(fixture.provider.recordedRequests.count == 2)
    #expect(fixture.output.components(separatedBy: "turn 1").count == 2)
    let reads = fixture.state.withLock { $0.reads }
    #expect(reads.first?.1 == 0)
    #expect(reads.dropFirst().allSatisfy { $0.1 > 0 })
    #expect(!fixture.error.contains("private-"))
  }

  @Test(arguments: ["claude", "codex", "pi"])
  func backlogSkipsAllButLatest(_ agent: String) async throws {
    let delay = WatchDelay()
    let fixture = try SessionWatchFixture(
      agent: agent,
      scripts: [
        [.delay(.seconds(1))] + SessionWatchFixture.response,
        SessionWatchFixture.response,
      ], clock: delay)
    try fixture.append(fixture.records(1))
    let task = Task { await fixture.run() }
    defer { fixture.stop(task) }
    try await delay.entered.wait()
    try fixture.append(fixture.records(2))
    try await fixture.tick()
    try fixture.append(fixture.records(3) + fixture.records(4))
    try await fixture.tick()
    try await fixture.tick()
    #expect(fixture.provider.recordedRequests.count == 1)
    delay.released.advance()
    try await fixture.requestsFinished.wait(2)
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    #expect(fixture.provider.recordedRequests.count == 2)
    #expect(
      fixture.provider.recordedRequests.last?.messages.last?.content.hasPrefix(
        "Input:\nprivate-reply-4") == true)
    #expect(
      fixture.error.contains(
        "pl: skipped turns 2, 3; look up a phrase from them with pl explain --session \(agent):aaaaaaaa-1111 \"<phrase>\".\n"
      ))
    #expect(!fixture.output.contains("turn 2"))
    #expect(!fixture.output.contains("turn 3"))
    #expect(!fixture.error.contains("private-"))
  }

  @Test(arguments: ["claude", "codex", "pi"])
  func singleQueuedReplyIsNotSkipped(_ agent: String) async throws {
    let delay = WatchDelay()
    let fixture = try SessionWatchFixture(
      agent: agent,
      scripts: [
        [.delay(.seconds(1))] + SessionWatchFixture.response,
        SessionWatchFixture.response,
      ], clock: delay)
    try fixture.append(fixture.records(1))
    let task = Task { await fixture.run() }
    defer { fixture.stop(task) }
    try await delay.entered.wait()
    try fixture.append(fixture.records(2))
    try await fixture.tick()
    try await fixture.tick()
    delay.released.advance()
    try await fixture.requestsFinished.wait(2)
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    #expect(fixture.provider.recordedRequests.count == 2)
    #expect(fixture.state.withLock { $0.keyLookups } == 1)
    #expect(!fixture.error.contains("skipped"))
  }

  @Test(arguments: ["claude", "codex", "pi"])
  func replyFailureContinuesWithOneDiagnostic(_ agent: String) async throws {
    let fixture = try SessionWatchFixture(
      agent: agent,
      scripts: [
        [.event(.text("<translation>partial")), .error(.transport)],
        SessionWatchFixture.response,
      ])
    try fixture.append(fixture.records(1))
    let task = Task { await fixture.run() }
    defer { fixture.stop(task) }
    try await fixture.diagnostics.wait()
    try fixture.append(fixture.records(2))
    try await fixture.tick()
    try await fixture.requestsFinished.wait(2)
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    #expect(fixture.provider.recordedRequests.count == 2)
    let diagnostic = RewriteDiagnostic.forError(.transport).line
    #expect(fixture.error.components(separatedBy: diagnostic).count == 2)
    #expect(!fixture.error.contains("private-"))
  }

  @Test(
    arguments: ["claude", "codex", "pi"], [LLMError.auth(status: 401), LLMError.quota(status: 402)])
  func fatalProviderErrors(_ agent: String, _ error: LLMError) async throws {
    let fixture = try SessionWatchFixture(agent: agent, scripts: [[.error(error)]])
    try fixture.append(fixture.records(1))
    #expect(await fixture.run() == RewriteDiagnostic.forError(error).exitCode)
    #expect(
      fixture.error.components(separatedBy: RewriteDiagnostic.forError(error).line).count == 2)
    #expect(fixture.provider.recordedRequests.count == 1)
    #expect(fixture.state.withLock { $0.tick == nil && $0.signal == nil })
  }

  @Test func configurationAndStartupAuthenticationFailBeforeReading() async throws {
    let fixture = try SessionWatchFixture()
    #expect(await fixture.run(fixture.environment(config: "invalid = [")) == 78)
    var environment = fixture.environment()
    environment.variables = [:]
    #expect(await fixture.run(environment, options: ["--provider", "openai"]) == 3)
    #expect(fixture.state.withLock { $0.listings } == 0)
    #expect(fixture.provider.recordedRequests.isEmpty)
  }

  @Test(arguments: ["claude", "codex", "pi"])
  func oversizedReplyIsLocalFailureAndContinues(_ agent: String) async throws {
    let fixture = try SessionWatchFixture(agent: agent)
    try fixture.append(fixture.records(1, reply: String(repeating: "x", count: 20_001)))
    let task = Task { await fixture.run() }
    defer { fixture.stop(task) }
    try await fixture.diagnostics.wait()
    #expect(fixture.provider.recordedRequests.isEmpty)
    try fixture.append(fixture.records(2))
    try await fixture.tick()
    try await fixture.requestsFinished.wait()
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    #expect(fixture.provider.recordedRequests.count == 1)
    #expect(fixture.error.components(separatedBy: "input exceeds 20,000 characters.").count == 2)
    #expect(fixture.error.contains("input exceeds 20,000 characters. Use shorter input."))
    #expect(!fixture.error.contains("Use --doc"))
  }

  @Test(arguments: ["deleted", "replaced", "truncated"])
  func boundFileChangeEndsWatch(_ change: String) async throws {
    let fixture = try SessionWatchFixture()
    let task = Task { await fixture.run() }
    defer { fixture.stop(task) }
    try await fixture.subscribed.wait()
    fixture.state.withLock {
      switch change {
      case "deleted": $0.files.removeValue(forKey: fixture.path)
      case "replaced": $0.files[fixture.path]?.inode += 1
      default: $0.files[fixture.path]?.data = Data()
      }
    }
    try await fixture.tick()
    #expect(await fixture.result(task) == 66)
    #expect(fixture.error.components(separatedBy: "bound session file").count == 2)
    #expect(fixture.provider.recordedRequests.isEmpty)
  }

  @Test(arguments: ["claude", "codex", "pi"])
  func newerSessionOnlyAnnouncedOnceAndNeverRebound(_ agent: String) async throws {
    let fixture = try SessionWatchFixture(agent: agent)
    let task = Task { await fixture.run() }
    defer { fixture.stop(task) }
    try await fixture.subscribed.wait()
    let path = SessionWatchFixture.path(agent, id: "newer")
    let data =
      try SessionWatchFixture.metadata(agent, id: "newer", newer: true)
      + SessionWatchFixture.lines(fixture.records(99))
    fixture.state.withLock {
      $0.files[path] = SessionWatchFixture.File(
        data: data, modified: Date(timeIntervalSince1970: 2))
    }
    for _ in 0..<20 { try await fixture.tick() }
    try await fixture.newerNotices.wait()
    try fixture.append(fixture.records(1))
    try await fixture.tick()
    try await fixture.requestsFinished.wait()
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    #expect(fixture.newerNotices.count == 1)
    #expect(fixture.provider.recordedRequests.count == 1)
    #expect(
      fixture.provider.recordedRequests.first?.messages.last?.content.hasPrefix(
        "Input:\nprivate-reply-1") == true)
    #expect(fixture.state.withLock { $0.reads.allSatisfy { $0.0 == fixture.path } })
  }

  @Test func interruptCancelsInFlightRequest() async throws {
    let fixture = try SessionWatchFixture(scripts: [[.hang]])
    try fixture.append(fixture.records(1))
    let task = Task { await fixture.run() }
    defer { fixture.stop(task) }
    try await fixture.calls.wait()
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    #expect(fixture.state.withLock { $0.tokens.allSatisfy(\.isCancelled) })
    #expect(
      fixture.error.components(separatedBy: RewriteDiagnostic.forError(.aborted).line).count == 2)
    #expect(fixture.state.withLock { $0.signal == nil && $0.tick == nil })
  }

  @Test func claudeStopHookContinuationHasNewCompletionIdentity() async throws {
    let fixture = try SessionWatchFixture(agent: "claude")
    try fixture.append(fixture.records(1))
    let task = Task { await fixture.run() }
    defer { fixture.stop(task) }
    try await fixture.requestsFinished.wait()
    try fixture.append([SessionFixture.assistant("ignored narrative", id: "tool", stop: "tool_use")]
    )
    try await fixture.tick()
    try await fixture.tick()
    #expect(fixture.provider.recordedRequests.count == 1)
    #expect(fixture.scheduledRequests.count == 1)
    try fixture.append([SessionFixture.assistant("private-final-reply", id: "new-end")])
    try await fixture.tick()
    try await fixture.requestsFinished.wait(2)
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    #expect(fixture.provider.recordedRequests.count == 2)
    #expect(fixture.output.components(separatedBy: "turn 1").count == 3)
    #expect(
      fixture.provider.recordedRequests.last?.messages.last?.content.hasPrefix(
        "Input:\nprivate-final-reply") == true)
  }
}

extension SessionWatchTests {
  @Test(arguments: ["deleted", "replaced", "truncated"])
  func boundFileChangeCancelsInFlightWithOneDiagnostic(_ change: String) async throws {
    let fixture = try SessionWatchFixture(scripts: [[.hang]])
    try fixture.append(fixture.records(1))
    let task = Task { await fixture.run() }
    defer { fixture.stop(task) }
    try await fixture.calls.wait()
    fixture.state.withLock {
      switch change {
      case "deleted": $0.files.removeValue(forKey: fixture.path)
      case "replaced": $0.files[fixture.path]?.inode += 1
      default: $0.files[fixture.path]?.data = Data()
      }
    }
    try await fixture.tick()
    #expect(await fixture.result(task) == 66)
    #expect(fixture.error.components(separatedBy: "bound session file").count == 2)
    #expect(!fixture.error.contains("the request was aborted"))
    #expect(fixture.state.withLock { $0.tokens.allSatisfy(\.isCancelled) })
  }

  @Test(arguments: ["claude", "codex", "pi"])
  func completeJSONWithoutNewlineWaitsAndIdleTicksDoNotRead(_ agent: String) async throws {
    let fixture = try SessionWatchFixture(agent: agent)
    let task = Task { await fixture.run() }
    defer { fixture.stop(task) }
    try await fixture.subscribed.wait()
    let bytes = try SessionWatchFixture.lines(fixture.records(1))
    fixture.append(Data(bytes.dropLast()))
    try await fixture.tick()
    try await fixture.tick()
    let reads = fixture.state.withLock { $0.reads.count }
    try await fixture.tick()
    try await fixture.tick()
    #expect(fixture.state.withLock { $0.reads.count } == reads)
    #expect(fixture.provider.recordedRequests.isEmpty)
    #expect(fixture.scheduledRequests.count == 0)
    fixture.append(Data([10]))
    try await fixture.tick()
    try await fixture.requestsFinished.wait()
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    #expect(fixture.provider.recordedRequests.count == 1)
  }

  @Test func incrementalParserIdentityAndChunkBoundaries() throws {
    for agent in ["claude", "codex", "pi"] {
      let fixture = try SessionWatchFixture(agent: agent)
      // An ignored record crosses the reader's byte chunks, followed by a complete reply.
      try fixture.append([["type": "ignored", "padding": String(repeating: "x", count: 70_000)]])
      try fixture.append(fixture.records(1))
      let environment = fixture.environment()
      let binding = try SessionInput.select(agent, environment: environment)
      var file = try SessionWatchFile(binding: binding, environment: environment)
      try file.read(environment: environment)
      let first = try #require(file.parser.turns.last)
      #expect(first.identity == (agent == "codex" ? "t1" : "a1"))
      #expect(file.offset == fixture.state.withLock { UInt64($0.files[fixture.path]!.data.count) })
      try fixture.append(fixture.records(2))
      try file.read(environment: environment)
      #expect(file.parser.turns == (try binding.source.turns(in: binding.session)))
      #expect(file.parser.turns.last?.identity == (agent == "codex" ? "t2" : "a2"))
    }
    var parser = ClaudeSessionParser()
    var end = SessionFixture.assistant("answer", id: "message-id")
    end["uuid"] = "end-record-uuid"
    parser.feed(try JSONSerialization.data(withJSONObject: end))
    #expect(parser.turns.last?.identity == "end-record-uuid")
    var text = SessionFixture.assistant(" continued", id: "message-id", stop: "")
    text["uuid"] = "text-record-uuid"
    parser.feed(try JSONSerialization.data(withJSONObject: text))
    #expect(parser.turns.last?.identity == "end-record-uuid")
    #expect(parser.turns.last?.reply == "answer continued")
  }

  @Test func fileReplacementDuringReadDoesNotSendReplacementText() async throws {
    let fixture = try SessionWatchFixture()
    try fixture.append(fixture.records(1))
    var environment = fixture.environment()
    let read = environment.readSessionBytes
    environment.readSessionBytes = { path, offset, count in
      let data = try read(path, offset, count)
      fixture.state.withLock { $0.files[path]?.inode += 1 }
      return data
    }
    #expect(await fixture.run(environment) == 66)
    #expect(fixture.provider.recordedRequests.isEmpty)
    #expect(!fixture.error.contains("private-"))
  }

  @Test(arguments: ["claude", "codex", "pi"])
  func showSentUsesSharedRedactionAndExcludesTools(_ agent: String) async throws {
    let fixture = try SessionWatchFixture(agent: agent)
    let fakeKey = "sk-" + String(repeating: "a", count: 32)
    try fixture.append(fixture.records(1, reply: "private-reply \(fakeKey)"))
    try fixture.append([["type": "tool_result", "content": "hidden-tool-result"]])
    let task = Task { await fixture.run(options: ["--show-sent"]) }
    defer { fixture.stop(task) }
    try await fixture.requestsFinished.wait()
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    let sent = try #require(fixture.provider.recordedRequests.first?.messages.last?.content)
    #expect(sent.contains("[REDACTED]"))
    #expect(fixture.error.contains("Input:\nprivate-reply [REDACTED]"))
    #expect(!sent.contains(fakeKey))
    #expect(!sent.contains("hidden-tool-result"))
    #expect(!fixture.error.contains(fakeKey))
  }
}

extension SessionWatchTests {
  @Test func claudeInitialEndMarkerWithoutTextRemainsEligible() async throws {
    let fixture = try SessionWatchFixture(agent: "claude")
    let thinking: [String: Any] = [
      "type": "assistant", "uuid": "ending-thinking",
      "message": [
        "id": "final-message", "stop_reason": "end_turn",
        "content": [["type": "thinking", "thinking": "hidden-thought"]],
      ],
    ]
    try fixture.append([SessionFixture.user("private-question", id: "u1"), thinking])
    let task = Task { await fixture.run() }
    defer { fixture.stop(task) }
    try await fixture.subscribed.wait()
    var text = SessionFixture.assistant("private-final", id: "final-message", stop: "")
    text["uuid"] = "text-after-end"
    try fixture.append([text])
    try await fixture.tick()
    try await fixture.requestsFinished.wait()
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    #expect(fixture.provider.recordedRequests.count == 1)
    #expect(fixture.output.contains("turn 1"))
    #expect(!fixture.error.contains("hidden-thought"))
  }
}
