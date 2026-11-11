import Foundation
import Testing

@testable import ParlanceCLI

struct SessionSourceTests {
  @Test func claudeFiltersBlocksAndGroupsOnlyTheFinalMessage() throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    var first = SessionFixture.assistant("Final ", id: "piece-1", stop: "")
    first["message"] = [
      "id": "final-message", "content": [["type": "text", "text": "Final "]],
      "stop_reason": NSNull(),
    ]
    var last = SessionFixture.assistant("answer.", id: "piece-2", stop: "stop_sequence")
    last["message"] = [
      "id": "final-message", "content": [["type": "text", "text": "answer."]],
      "stop_reason": "stop_sequence",
    ]
    var sidechain = SessionFixture.assistant("HIDDEN SIDECHAIN", id: "side")
    sidechain["isSidechain"] = true
    var sideUser = SessionFixture.user("HIDDEN SIDE PROMPT", id: "side-u")
    sideUser["isSidechain"] = true
    var meta = SessionFixture.user("HIDDEN META", id: "meta")
    meta["isMeta"] = true
    let records: [[String: Any]] = [
      [
        "type": "user", "uuid": "u1",
        "message": ["content": [["type": "text", "text": "Question one."]]],
      ],
      SessionFixture.assistant("HIDDEN EARLIER NARRATION", id: "tool-narration", stop: "tool_use"),
      [
        "type": "assistant", "uuid": "thinking",
        "message": [
          "id": "final-message", "content": [["type": "thinking", "thinking": "HIDDEN THINKING"]],
        ],
      ],
      [
        "type": "assistant", "uuid": "tool",
        "message": [
          "id": "tool-message",
          "content": [
            ["type": "tool_use", "name": "HIDDEN TOOL", "input": ["text": "HIDDEN INPUT"]]
          ], "stop_reason": "tool_use",
        ],
      ],
      [
        "type": "user", "uuid": "result",
        "message": [
          "content": [
            ["type": "text", "text": "HIDDEN RESULT PREFIX"],
            ["type": "tool_result", "content": "HIDDEN RESULT"],
          ]
        ],
      ],
      sideUser, sidechain, meta, first, first, last, last,
      SessionFixture.user("<task-notification>HIDDEN INJECTION", id: "notification"),
      SessionFixture.assistant("Visible next answer.", id: "second"),
      SessionFixture.user("Interrupted question.", id: "interrupted"),
      SessionFixture.assistant("HIDDEN PARTIAL", id: "partial", stop: ""),
      SessionFixture.user("Tool-only question.", id: "tool-only"),
      SessionFixture.assistant("HIDDEN TOOL ONLY", id: "tool-only-a", stop: "tool_use"),
      ["type": "attachment", "content": "HIDDEN ATTACHMENT"],
      ["type": "unknown", "text": "HIDDEN UNKNOWN"],
    ]
    try fixture.claude(records, tail: "not json\n{\"type\":\"assistant\"")
    let source = ClaudeSessionSource(environment: fixture.environment)
    let session = try #require(source.sessions(cwd: fixture.cwd).first)
    let turns = try source.turns(in: session)
    #expect(
      turns == [
        SessionTurn(index: 1, prompt: "Question one.", reply: "Final answer.", complete: true),
        SessionTurn(index: 2, prompt: nil, reply: "Visible next answer.", complete: true),
        SessionTurn(index: 3, prompt: "Interrupted question.", reply: nil, complete: false),
        SessionTurn(index: 4, prompt: "Tool-only question.", reply: nil, complete: false),
      ])
    #expect(!String(describing: turns).contains("HIDDEN"))
  }

  @Test(arguments: [
    "<command-message>", "<command-name>", "<local-command-stdout>", "<system-reminder>",
  ])
  func claudeInjectedPromptsStillStartTurns(_ prefix: String) throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    try fixture.claude([
      SessionFixture.user(prefix + "ignored", id: "u"),
      SessionFixture.assistant("Visible answer", id: "a"),
    ])
    let source = ClaudeSessionSource(environment: fixture.environment)
    let session = try #require(source.sessions(cwd: fixture.cwd).first)
    #expect(
      try source.turns(in: session) == [
        SessionTurn(index: 1, prompt: nil, reply: "Visible answer", complete: true)
      ])
  }

  @Test(arguments: ["paginated", "legacy"])
  func codexCompletionAuthorityFilteringAndDeduplication(_ mode: String) throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    var prompt =
      mode == "legacy"
      ? SessionFixture.codexRecord(
        "event_msg", ["type": "user_message", "message": "First question."])
      : SessionFixture.codexUser("First question.")
    prompt["ordinal"] = 10
    let complete = SessionFixture.complete("turn-one", "Authoritative answer.")
    let records: [[String: Any]] = [
      SessionFixture.codexUser("<environment_context>HIDDEN ENV"),
      SessionFixture.codexUser("<user_instructions>HIDDEN INSTRUCTIONS"),
      SessionFixture.codexUser("<permissions>HIDDEN PERMISSIONS"),
      SessionFixture.codexRecord("turn_context", ["turn_id": "turn-one"]),
      prompt, prompt,
      SessionFixture.codexRecord(
        "response_item",
        [
          "type": "message", "role": "assistant", "phase": "commentary",
          "content": [["type": "output_text", "text": "HIDDEN COMMENTARY"]],
        ]),
      SessionFixture.codexRecord(
        "response_item", ["type": "reasoning", "text": "HIDDEN THINKING"]),
      SessionFixture.codexRecord(
        "response_item", ["type": "function_call", "arguments": "HIDDEN CALL"]),
      SessionFixture.codexRecord(
        "response_item", ["type": "function_call_output", "output": "HIDDEN RESULT"]),
      SessionFixture.codexRecord("inter_agent_communication_metadata", ["message": "HIDDEN AGENT"]),
      SessionFixture.codexRecord(
        "response_item",
        [
          "type": "message", "role": "assistant", "phase": "final_answer",
          "content": [["type": "output_text", "text": "HIDDEN SUPERSEDED FINAL"]],
        ]),
      SessionFixture.codexRecord(
        "event_msg", ["type": "agent_message", "message": "HIDDEN LEGACY DRAFT"]),
      complete, complete,
      SessionFixture.codexRecord("turn_context", ["turn_id": "turn-two"]),
      SessionFixture.codexUser("Aborted question."),
      SessionFixture.codexRecord("event_msg", ["type": "turn_aborted", "turn_id": "turn-two"]),
      SessionFixture.complete("turn-two", "HIDDEN AFTER ABORT"),
      SessionFixture.codexUser("Null question."), SessionFixture.complete("turn-three", nil),
      SessionFixture.codexUser("Last question."),
      SessionFixture.complete("turn-four", "Last answer."),
      SessionFixture.codexUser("Pending question."),
    ]
    try fixture.codex(records, mode: mode, tail: "malformed\n{\"type\":")
    let source = CodexSessionSource(environment: fixture.environment)
    let session = try #require(source.sessions(cwd: fixture.cwd).first)
    let turns = try source.turns(in: session)
    #expect(
      turns == [
        SessionTurn(
          index: 1, prompt: "First question.", reply: "Authoritative answer.", complete: true),
        SessionTurn(index: 2, prompt: "Aborted question.", reply: nil, complete: false),
        SessionTurn(index: 3, prompt: "Null question.", reply: nil, complete: false),
        SessionTurn(index: 4, prompt: "Last question.", reply: "Last answer.", complete: true),
        SessionTurn(index: 5, prompt: "Pending question.", reply: nil, complete: false),
      ])
    #expect(!String(describing: turns).contains("HIDDEN"))
    #expect(session.version == "0.166.0")
  }

  @Test func discoveryChecksCwdAndUsesCodexHome() throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let file = try fixture.claude([SessionFixture.user("Synthetic", id: "u")])
    try fixture.claude([["cwd": "/fictional-project", "type": "system"]], id: "collision")
    let date = Date(timeIntervalSince1970: 1234)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    let claude = ClaudeSessionSource(environment: fixture.environment)
    let sessions = try claude.sessions(cwd: fixture.cwd)
    #expect(sessions.count == 1)
    #expect(sessions.first?.id == "aaaaaaaa-1111")
    #expect(sessions.first?.path == file.path)
    #expect(sessions.first?.modified == date)
    #expect(sessions.first?.started == SessionLines.date("2026-11-05T14:02:00Z"))
    #expect(sessions.first?.version == "2.1.318")
    let root = fixture.home.appendingPathComponent("custom-codex")
    try fixture.codex([], root: root)
    try fixture.codex([], id: "other", cwd: "/elsewhere", root: root)
    var environment = fixture.environment
    environment.variables["CODEX_HOME"] = root.path
    #expect(
      try CodexSessionSource(environment: environment).sessions(cwd: fixture.cwd).map(\.id) == [
        "bbbbbbbb-2222"
      ])
    #expect(
      try CodexSessionSource(environment: fixture.environment).sessions(cwd: fixture.cwd).isEmpty)
  }

  @Test func codexDiscoveryStopsAtFirstMetadata() throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    try fixture.codex([])
    var environment = fixture.environment
    environment.readSessionLines = { _, visit in
      let data = try JSONSerialization.data(
        withJSONObject: SessionFixture.codexRecord(
          "session_meta",
          [
            "id": "synthetic", "cwd": "/elsewhere",
          ]))
      #expect(!visit(data))
    }
    #expect(try CodexSessionSource(environment: environment).sessions(cwd: fixture.cwd).isEmpty)
  }

  @Test func lineReaderCrossesChunksAndIgnoresUnterminatedRecord() throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let long = String(repeating: "synthetic ", count: 20_000)
    let file = fixture.home.appendingPathComponent("lines.jsonl")
    try Data((long + "\n{}\r\n{\"unfinished\":true}").utf8).write(to: file)
    var lines: [Data] = []
    try SessionLines.read(file.path) {
      lines.append($0)
      return true
    }
    #expect(lines == [Data(long.utf8), Data("{}\r".utf8)])
    var count = 0
    try SessionLines.read(file.path) { _ in
      count += 1
      return false
    }
    #expect(count == 1)
  }

  @Test func dialogueBudgetsKeepUTF8AndWholeTurns() {
    let first = SessionTurn(index: 1, prompt: "older", reply: "old answer", complete: true)
    let latest = SessionTurn(
      index: 2, prompt: "newer", reply: String(repeating: "界", count: 5500), complete: true)
    let context = SessionInput.context([first, latest])
    #expect(context.hasPrefix("界") && context.hasSuffix("界"))
    #expect(!context.contains("older"))
    #expect(context.utf8.count > CommandInput.contextBytes - 64)
    #expect(context.utf8.count <= CommandInput.contextBytes)
    let huge = SessionTurn(
      index: 3, prompt: "boundary", reply: String(repeating: "界", count: 349_520), complete: true)
    let attached = SessionInput.attachment([first, huge, latest])
    #expect(attached == SessionInput.dialogue(latest))
    #expect(!attached.contains("boundary"))
    #expect(SessionInput.attachment([huge]).isEmpty)
    let exact = SessionTurn(
      index: 5, prompt: nil,
      reply: String(repeating: "x", count: SessionInput.attachmentBytes - "Assistant: ".utf8.count),
      complete: true)
    #expect(SessionInput.attachment([first, exact]).utf8.count == SessionInput.attachmentBytes)
    let incomplete = SessionTurn(
      index: 4, prompt: "pending", reply: "HIDDEN PARTIAL", complete: false)
    #expect(SessionInput.dialogue(incomplete) == "User: pending")
  }
}

extension SessionSourceTests {
  @Test func claudeFinalReplyUsesEveryTextBlockWithItsMessageID() throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let first = SessionFixture.assistant("First part. ", id: "shared-message", stop: "tool_use")
    var last = SessionFixture.assistant("Last part.", id: "shared-message")
    last["uuid"] = "last-event"
    try fixture.claude([
      SessionFixture.user("Question.", id: "u"), first,
      SessionFixture.assistant("HIDDEN OTHER MESSAGE", id: "other-message", stop: "tool_use"), last,
    ])
    let source = ClaudeSessionSource(environment: fixture.environment)
    let session = try #require(source.sessions(cwd: fixture.cwd).first)
    #expect(
      try source.turns(in: session) == [
        SessionTurn(index: 1, prompt: "Question.", reply: "First part. Last part.", complete: true)
      ])
  }

  @Test func codexNewPromptBeforeTurnContextKeepsItsQuestion() throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    try fixture.codex([
      SessionFixture.codexRecord("turn_context", ["turn_id": "old"]),
      SessionFixture.codexUser("Interrupted question."),
      SessionFixture.codexUser("New question."),
      SessionFixture.codexRecord("turn_context", ["turn_id": "new"]),
      SessionFixture.complete("new", "New answer."),
    ])
    let source = CodexSessionSource(environment: fixture.environment)
    let session = try #require(source.sessions(cwd: fixture.cwd).first)
    #expect(
      try source.turns(in: session) == [
        SessionTurn(index: 1, prompt: "Interrupted question.", reply: nil, complete: false),
        SessionTurn(index: 2, prompt: "New question.", reply: "New answer.", complete: true),
      ])
  }
}
