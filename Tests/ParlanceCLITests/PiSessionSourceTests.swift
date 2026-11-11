import Foundation
import Testing

@testable import ParlanceCLI

struct PiSessionSourceTests {
  @Test(arguments: ["default", "absolute", "tilde"])
  func discoveryChecksHeaderCwdAndAgentDirectory(_ location: String) throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    var environment = fixture.environment
    let root = location == "default" ? nil : fixture.home.appendingPathComponent("custom-pi")
    if location != "default" {
      environment.variables["PI_CODING_AGENT_DIR"] =
        location == "tilde" ? "~/custom-pi" : root!.path
    }
    let file = try fixture.pi([], root: root)
    try fixture.pi([], id: "collision", cwd: "/fictional-project", root: root)
    let modified = Date(timeIntervalSince1970: 1234)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    let sessions = try PiSessionSource(environment: environment).sessions(cwd: fixture.cwd)
    #expect(sessions.count == 1)
    let session = try #require(sessions.first)
    #expect(session.id == "cccccccc-3333")
    #expect(session.path == file.path)
    #expect(session.started == SessionLines.date("2026-11-05T14:02:00Z"))
    #expect(session.modified == modified)
    #expect(session.version == "3")
    #expect(try SessionInput.select("pi:cccc", environment: environment).session == session)
    #expect(try SessionInput.select("pi:cccccccc-3333", environment: environment).name == "pi")
  }

  @Test(arguments: ["\\fictional\\project", "C:\\fictional:project"])
  func directoryEncodingRemovesOnlyOneLeadingSeparator(_ cwd: String) throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    var environment = fixture.environment
    let encoded: String
    switch cwd {
    case "\\fictional\\project": encoded = "fictional-project"
    default: encoded = "C--fictional-project"
    }
    environment.listSessionDirectory = { path in
      #expect(path == fixture.home.path + "/.pi/agent/sessions/--" + encoded + "--")
      return []
    }
    #expect(try PiSessionSource(environment: environment).sessions(cwd: cwd).isEmpty)
  }

  @Test func activeLeafAndBranchRelativeEdits() throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    try fixture.pi([
      SessionFixture.piMessage("user", "Original question", id: "u", parent: nil),
      SessionFixture.piMessage("user", "HIDDEN abandoned question", id: "abandoned-u", parent: "u"),
      SessionFixture.piAssistant("HIDDEN abandoned reply", id: "abandoned", parent: "abandoned-u"),
      SessionFixture.piEdit(
        "u", content: "HIDDEN off-path edit", id: "off-edit", parent: "abandoned"),
      SessionFixture.piEntry(
        "branch_summary", id: "branch", parent: "u", fields: ["summary": "HIDDEN branch summary"]),
      SessionFixture.piAssistant("Active reply", id: "a", parent: "branch"),
      SessionFixture.piEdit("a", content: "Edited reply", id: "edit", parent: "a"),
      SessionFixture.piEntry(
        "label", id: "leaf", parent: "edit", fields: ["label": "HIDDEN label"]),
    ])
    let source = PiSessionSource(environment: fixture.environment)
    let session = try #require(source.sessions(cwd: fixture.cwd).first)
    let turns = try source.turns(in: session)
    #expect(
      turns == [
        SessionTurn(index: 1, prompt: "Original question", reply: "Edited reply", complete: true)
      ])
    #expect(turns.first?.identity == "a")
    #expect(!String(describing: turns).contains("HIDDEN"))
  }

  @Test func editsReplaceDeleteAndLatestWinsForBothRoles() throws {
    var parser = PiSessionParser()
    let records = [
      SessionFixture.piMessage("user", "HIDDEN original question", id: "u", parent: nil),
      SessionFixture.piAssistant("HIDDEN original reply", id: "a", parent: "u"),
      SessionFixture.piEdit("u", content: nil, id: "eu1", parent: "a"),
      SessionFixture.piEdit("a", content: nil, id: "ea1", parent: "eu1"),
      SessionFixture.piEdit("u", content: "HIDDEN superseded question", id: "eu2", parent: "ea1"),
      SessionFixture.piEdit("a", content: "HIDDEN superseded reply", id: "ea2", parent: "eu2"),
      SessionFixture.piEdit(
        "u", content: [["type": "text", "text": "Final question"]], id: "eu3", parent: "ea2"),
      SessionFixture.piEdit("a", content: "Final reply", id: "ea3", parent: "eu3"),
      SessionFixture.piMessage("user", "HIDDEN deleted question", id: "deleted-u", parent: "ea3"),
      SessionFixture.piAssistant(
        "HIDDEN deleted reply", id: "deleted-a", parent: "deleted-u", stop: "error"),
      SessionFixture.piEdit("deleted-u", content: nil, id: "du", parent: "deleted-a"),
      SessionFixture.piEdit("deleted-a", content: nil, id: "da", parent: "du"),
    ]
    for record in records { parser.feed(try JSONSerialization.data(withJSONObject: record)) }
    #expect(
      parser.turns == [
        SessionTurn(index: 1, prompt: "Final question", reply: "Final reply", complete: true)
      ])
    #expect(parser.turns.first?.identity == "a")
    #expect(!String(describing: parser.turns).contains("HIDDEN"))
    // A copy can retain its cached projection while the original receives another edit.
    let copy = parser
    parser.feed(
      try JSONSerialization.data(
        withJSONObject:
          SessionFixture.piEdit("a", content: nil, id: "remove", parent: "da")))
    #expect(parser.turns.last?.complete == false)
    #expect(parser.turns.last?.reply == nil)
    #expect(copy.turns.last?.reply == "Final reply")
  }

  @Test func compactionAndNonDialogueNeverEnterTurns() throws {
    var parser = PiSessionParser()
    var records = [
      SessionFixture.piMessage("user", "Before compaction", id: "u1", parent: nil),
      SessionFixture.piAssistant("Earlier answer", id: "a1", parent: "u1"),
      SessionFixture.piEntry(
        "compaction", id: "compact", parent: "a1",
        fields: ["summary": "HIDDEN summary", "firstKeptEntryId": "compact", "tokensBefore": 50000]),
      SessionFixture.piMessage(
        "user",
        [
          [
            "type": "text",
            "text": " <system-reminder>HIDDEN injection</system-reminder>Visible prompt ",
          ],
          ["type": "text", "text": "<notice>HIDDEN block</notice>"],
          ["type": "image", "data": "HIDDEN image", "mimeType": "image/png"],
          ["type": "text", "text": "# AGENTS.md instructions are visible for pi"],
          ["type": "text", "text": "[Request interrupted is visible for pi"],
        ], id: "u2", parent: "compact"),
      SessionFixture.piAssistant("HIDDEN between tools", id: "tool", parent: "u2", stop: "toolUse"),
    ]
    var parent = "tool"
    for role in [
      "toolResult", "system", "bashExecution", "custom", "branchSummary", "compactionSummary",
      "futureRole",
    ] {
      records.append(
        SessionFixture.piMessage(role, "HIDDEN role", id: "role-" + role, parent: parent))
      parent = "role-" + role
    }
    for type in [
      "custom", "custom_message", "usage", "model_change", "thinking_level_change", "session_info",
      "futureEntry",
    ] {
      records.append(
        SessionFixture.piEntry(type, id: type, parent: parent, fields: ["content": "HIDDEN entry"]))
      parent = type
    }
    records.append(
      SessionFixture.piMessage(
        "assistant",
        [
          ["type": "thinking", "thinking": "HIDDEN thinking", "text": "HIDDEN thinking text"],
          [
            "type": "toolCall", "id": "call", "name": "fictional",
            "arguments": ["text": "HIDDEN arguments"], "text": "HIDDEN call text",
          ],
          ["type": "text", "text": "Final "], ["type": "text", "text": "answer"],
        ], id: "a2", parent: parent))
    for record in records { parser.feed(try JSONSerialization.data(withJSONObject: record)) }
    #expect(
      parser.turns == [
        SessionTurn(index: 1, prompt: "Before compaction", reply: "Earlier answer", complete: true),
        SessionTurn(
          index: 2,
          prompt:
            "Visible prompt\n# AGENTS.md instructions are visible for pi\n[Request interrupted is visible for pi",
          reply: "Final answer", complete: true),
      ])
    #expect(!String(describing: parser.turns).contains("HIDDEN"))
  }

  @Test(arguments: ["stop", "toolUse", "error", "aborted", "length", "deferred", "unknown"])
  func lastAssistantAloneDecidesCompletion(_ stop: String) throws {
    var parser = PiSessionParser()
    for record in [
      SessionFixture.piMessage("user", "Question", id: "u", parent: nil),
      SessionFixture.piAssistant("Earlier stopped reply", id: "earlier", parent: "u"),
      SessionFixture.piAssistant("Last reply", id: "last", parent: "earlier", stop: stop),
    ] { parser.feed(try JSONSerialization.data(withJSONObject: record)) }
    #expect(parser.turns.last?.complete == (stop == "stop"))
    #expect(parser.turns.last?.reply == (stop == "stop" ? "Last reply" : nil))
    #expect(parser.turns.last?.identity == (stop == "stop" ? "last" : nil))
  }

  @Test(arguments: ["", "  \n", "\u{1B}[0m  "])
  func stopWithoutVisibleTextIsIncomplete(_ reply: String) throws {
    var parser = PiSessionParser()
    for record in [
      SessionFixture.piMessage("user", "<notice>injected</notice>", id: "u", parent: nil),
      SessionFixture.piAssistant(reply, id: "a", parent: "u"),
    ] { parser.feed(try JSONSerialization.data(withJSONObject: record)) }
    #expect(parser.turns == [SessionTurn(index: 1, prompt: nil, reply: nil, complete: false)])
    #expect(parser.turns.last?.identity == nil)
  }

  // A header without `version` is version 1, as pi itself reads it.
  @Test(arguments: [nil, 1, 2, 3] as [Int?])
  func versionsAndWholeFileMatchIncrementalFeeding(_ version: Int?) throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let records = [
      SessionFixture.piMessage("user", "First question", id: "u1", parent: nil),
      SessionFixture.piAssistant("First answer", id: "a1", parent: "u1"),
      SessionFixture.piMessage("user", "Next question", id: "u2", parent: "a1"),
      SessionFixture.piAssistant("Next answer", id: "a2", parent: "u2"),
    ].map { record in
      (version ?? 1) == 1 ? record.filter { $0.key != "id" && $0.key != "parentId" } : record
    }
    try fixture.pi(records, version: version, tail: "malformed\n{\"unfinished\":true}")
    let source = PiSessionSource(environment: fixture.environment)
    let session = try #require(source.sessions(cwd: fixture.cwd).first)
    var parser = source.makeParser()
    try SessionLines.read(session.path) { data in
      parser.feed(data)
      _ = parser.turns
      return true
    }
    let turns = try source.turns(in: session)
    #expect(turns == parser.turns)
    #expect(turns.map(\.reply) == ["First answer", "Next answer"])
    #expect(turns.map(\.identity) == ((version ?? 1) == 1 ? ["line-3", "line-5"] : ["a1", "a2"]))
    #expect(session.version == String(version ?? 1))
  }
}
