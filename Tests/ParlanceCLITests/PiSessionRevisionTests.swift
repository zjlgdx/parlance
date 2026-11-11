import Foundation
import Testing

@testable import ParlanceCLI

struct PiSessionRevisionTests {
  @Test(arguments: ["u1", "u2", "u2+a2"])
  func deletedUsersKeepInvisibleBoundaries(_ removed: String) throws {
    var parser = PiSessionParser()
    var records = [
      SessionFixture.piMessage("user", "Question one", id: "u1", parent: nil),
      SessionFixture.piAssistant("Answer one", id: "a1", parent: "u1"),
      SessionFixture.piMessage("user", "Question two", id: "u2", parent: "a1"),
      SessionFixture.piAssistant("Answer two", id: "a2", parent: "u2"),
    ]
    var parent = "a2"
    for target in removed.split(separator: "+").map(String.init) {
      records.append(
        SessionFixture.piEdit(target, content: nil, id: "delete-" + target, parent: parent))
      parent = "delete-" + target
    }
    for record in records { parser.feed(try JSONSerialization.data(withJSONObject: record)) }
    var expected = [
      SessionTurn(
        index: 1, prompt: removed == "u1" ? nil : "Question one", reply: "Answer one",
        complete: true)
    ]
    if removed != "u2+a2" {
      expected.append(
        SessionTurn(
          index: 2, prompt: removed == "u2" ? nil : "Question two", reply: "Answer two",
          complete: true))
    }
    #expect(parser.turns == expected)
    #expect(parser.turns.map(\.identity) == (removed == "u2+a2" ? ["a1"] : ["a1", "a2"]))
  }

  @Test func settledIdentitiesIncludeAbandonedRepliesOnlyWhenCompleteAndVisible() throws {
    var parser = PiSessionParser()
    let records = [
      SessionFixture.piMessage("user", "Question", id: "u", parent: nil),
      SessionFixture.piAssistant("Old branch", id: "a", parent: "u"),
      SessionFixture.piAssistant("Partial", id: "partial", parent: "a", stop: "toolUse"),
      SessionFixture.piAssistant("\u{1B}[0m ", id: "empty", parent: "partial"),
      SessionFixture.piAssistant("Current branch", id: "b", parent: "u"),
      SessionFixture.piEdit("b", content: nil, id: "edit", parent: "b"),
      // An empty stop reply on an abandoned branch that an edit there made visible.
      SessionFixture.piAssistant("", id: "blank", parent: "u"),
      SessionFixture.piEdit("blank", content: "Edited answer", id: "fill", parent: "blank"),
      SessionFixture.piMessage("user", "Back on b", id: "u2", parent: "edit"),
    ]
    for record in records { parser.feed(try JSONSerialization.data(withJSONObject: record)) }
    #expect(parser.turns.allSatisfy { !$0.complete })
    #expect(parser.settledIdentities == ["a", "b", "blank"])
  }

  @Test func emptyAgentDirectoryUsesDefault() throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let file = try fixture.pi([])
    var environment = fixture.environment
    environment.variables["PI_CODING_AGENT_DIR"] = ""
    environment.variables["PI_CODING_AGENT_SESSION_DIR"] = ""
    #expect(
      try PiSessionSource(environment: environment).sessions(cwd: fixture.cwd).map(\.path) == [
        file.path
      ])
  }

  @Test(arguments: [false, true])
  func explicitSessionDirectoryIsFlatAndTakesPrecedence(_ tilde: Bool) throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let directory = fixture.home.appendingPathComponent("flat-sessions")
    let file = try fixture.pi([], flatDirectory: directory)
    try fixture.pi([], id: "other-cwd", cwd: "/other", flatDirectory: directory)
    try fixture.pi([], id: "nested", flatDirectory: directory.appendingPathComponent("nested"))
    try fixture.pi([], id: "default-layout")
    var environment = fixture.environment
    environment.variables["PI_CODING_AGENT_DIR"] =
      fixture.home.appendingPathComponent("unused").path
    environment.variables["PI_CODING_AGENT_SESSION_DIR"] =
      tilde ? "~/flat-sessions" : directory.path
    #expect(
      try PiSessionSource(environment: environment).sessions(cwd: fixture.cwd).map(\.path) == [
        file.path
      ])
  }

  @Test(arguments: ["null", "\"1\"", "0", "-1", "\"2\"", "2.5", "true", "{}", "\"future\""])
  func versionInterpretationIsShared(_ json: String) throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let value = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
    let linear = ["null", "\"1\"", "0", "-1"].contains(json)
    let records = [
      SessionFixture.piMessage("user", "Question", id: "u", parent: nil),
      SessionFixture.piAssistant("Answer", id: "a", parent: "u"),
    ].map { linear ? $0.filter { $0.key != "id" && $0.key != "parentId" } : $0 }
    try fixture.pi(records, version: value)
    let source = PiSessionSource(environment: fixture.environment)
    let session = try #require(source.sessions(cwd: fixture.cwd).first)
    let expected: String
    switch json {
    case "null", "\"1\"": expected = "1"
    case "0", "-1": expected = json
    case "\"2\"": expected = "2"
    default: expected = "unknown"
    }
    #expect(session.version == expected)
    let turns = try source.turns(in: session)
    #expect(turns.map(\.reply) == ["Answer"])
    #expect(turns.map(\.identity) == [linear ? "line-3" : "a"])
  }

  @Test(arguments: ["cycle", "missing"])
  func brokenParentChainsUseOnlyReachableEntries(_ kind: String) throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    try fixture.pi([
      SessionFixture.piMessage("user", "Unreachable question", id: "other-u", parent: nil),
      SessionFixture.piAssistant("Unreachable reply", id: "other-a", parent: "other-u"),
      SessionFixture.piMessage(
        "user", "Reachable question", id: "u", parent: kind == "cycle" ? "a" : "missing"),
      SessionFixture.piAssistant("Reachable reply", id: "a", parent: "u"),
    ])
    let source = PiSessionSource(environment: fixture.environment)
    let session = try #require(source.sessions(cwd: fixture.cwd).first)
    #expect(
      try source.turns(in: session) == [
        SessionTurn(
          index: 1, prompt: "Reachable question", reply: "Reachable reply", complete: true)
      ])
  }
}

@Suite(.timeLimit(.minutes(1)))
struct PiSessionWatchRevisionTests {
  @Test(arguments: [false, true])
  func queuedIdentitySurvivesRenumbering(_ backlog: Bool) async throws {
    let delay = WatchDelay()
    let fixture = try SessionWatchFixture(
      agent: "pi",
      scripts: [
        [.delay(.seconds(1))] + SessionWatchFixture.response, SessionWatchFixture.response,
      ], clock: delay)
    try fixture.append(fixture.records(1) + fixture.records(2))
    let task = Task { await fixture.run() }
    defer {
      delay.released.advance()
      fixture.stop(task)
    }
    try await delay.entered.wait()
    try fixture.append(fixture.records(3) + (backlog ? fixture.records(4) : []))
    try await fixture.tick()
    try fixture.append([
      SessionFixture.piEdit("u1", content: nil, id: "delete-u1", parent: backlog ? "a4" : "a3"),
      SessionFixture.piEdit("a1", content: nil, id: "delete-a1", parent: "delete-u1"),
    ])
    try await fixture.tick()
    delay.released.advance()
    try await fixture.handledCompletions.wait()
    #expect(fixture.scheduledRequests.count == 2)
    if fixture.scheduledRequests.count == 2 { try await fixture.requestsFinished.wait(2) }
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    let last = fixture.provider.recordedRequests.last?.messages.last?.content
    #expect(last?.hasPrefix("Input:\nprivate-reply-\(backlog ? 4 : 3)") == true)
    let header = fixture.output.split(separator: "\n").last { $0.hasPrefix("── pi ·") }
    #expect(header?.hasPrefix("── pi · 第 \(backlog ? 3 : 2) 轮") == true)
    if backlog {
      #expect(fixture.error.contains("pl: skipped turns 2;"))
    } else {
      #expect(!fixture.error.contains("skipped turns"))
    }
  }

  @Test func removedQueuedIdentityDoesNotResendReplyAtItsOldPosition() async throws {
    let delay = WatchDelay()
    let fixture = try SessionWatchFixture(
      agent: "pi",
      scripts: [
        [.delay(.seconds(1))] + SessionWatchFixture.response, SessionWatchFixture.response,
      ], clock: delay)
    try fixture.append(fixture.records(1) + fixture.records(2, reply: "") + fixture.records(3))
    let task = Task { await fixture.run() }
    defer {
      delay.released.advance()
      fixture.stop(task)
    }
    try await delay.entered.wait()
    try fixture.append([
      SessionFixture.piEdit("a2", content: "Queued reply", id: "complete", parent: "a3")
    ])
    try await fixture.tick()
    try fixture.append([
      SessionFixture.piEdit("u2", content: nil, id: "delete-u2", parent: "complete"),
      SessionFixture.piEdit("a2", content: nil, id: "delete-a2", parent: "delete-u2"),
    ])
    try await fixture.tick()
    delay.released.advance()
    try await fixture.handledCompletions.wait()
    #expect(fixture.scheduledRequests.count == 1)
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    #expect(fixture.provider.recordedRequests.count == 1)
  }

  @Test func startupBaselineIncludesInactiveBranches() async throws {
    let fixture = try SessionWatchFixture(agent: "pi")
    try fixture.append([
      SessionFixture.piMessage("user", "Old A question", id: "ua", parent: nil),
      SessionFixture.piAssistant("Old A reply", id: "aa", parent: "ua"),
      SessionFixture.piMessage("user", "Old B question", id: "ub", parent: nil),
      SessionFixture.piAssistant("Old B reply", id: "ab", parent: "ub"),
    ])
    let task = Task { await fixture.run() }
    defer { fixture.stop(task) }
    try await fixture.requestsFinished.wait()
    try await fixture.handledCompletions.wait()
    try fixture.append([SessionFixture.piMessage("user", "New question", id: "new-u", parent: "aa")]
    )
    try await fixture.tick()
    #expect(fixture.scheduledRequests.count == 1)
    try fixture.append([SessionFixture.piAssistant("New answer", id: "new-a", parent: "new-u")])
    try await fixture.tick()
    // Wait for every scheduled request so a regression cannot hide behind task scheduling.
    try await fixture.requestsFinished.wait(fixture.scheduledRequests.count)
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    #expect(
      fixture.provider.recordedRequests.map {
        $0.messages.last?.content.components(separatedBy: "\n\n").first
      } == ["Input:\nOld B reply", "Input:\nNew answer"])
  }
}
