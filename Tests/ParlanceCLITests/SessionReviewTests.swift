import Foundation
import ParlanceCore
import Testing

@testable import ParlanceCLI

struct SessionReviewTests {
  @Test(arguments: ["claude", "codex"])
  func injectedBlocksAreFilteredBeforeJoining(_ agent: String) throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let blocks = [
      "<bash-input>HIDDEN COMMAND</bash-input>", "<bash-stdout>HIDDEN OUTPUT</bash-stdout>",
      agent == "claude"
        ? "[Request interrupted by user] HIDDEN"
        : "# AGENTS.md instructions for /fictional/project\nHIDDEN RULES",
      "<system-reminder>HIDDEN PREFIX\ncontinued</system-reminder>  Real first question.  ",
      " Real second question. <system-reminder>HIDDEN SUFFIX</system-reminder> ",
      "<system-reminder>HIDDEN ONE</system-reminder>Third.<system-reminder>HIDDEN TWO</system-reminder>",
      "<div> HIDDEN accepted limitation", "   ",
    ]
    let turns: [SessionTurn]
    if agent == "claude" {
      try fixture.claude([
        [
          "type": "user", "uuid": "u",
          "message": ["content": blocks.map { ["type": "text", "text": $0] }],
        ],
        SessionFixture.assistant("Visible answer.", id: "a"),
      ])
      let source = ClaudeSessionSource(environment: fixture.environment)
      turns = try source.turns(in: #require(source.sessions(cwd: fixture.cwd).first))
    } else {
      try fixture.codex([
        SessionFixture.codexRecord("event_msg", ["type": "task_started", "turn_id": "t"]),
        SessionFixture.codexUser(
          "# AGENTS.md instructions for /fictional/project\nHIDDEN INITIAL RULES"),
        SessionFixture.codexRecord(
          "response_item",
          [
            "type": "message", "role": "user",
            "content": blocks.map { ["type": "input_text", "text": $0] },
          ]),
        SessionFixture.complete("t", "Visible answer."),
      ])
      let source = CodexSessionSource(environment: fixture.environment)
      turns = try source.turns(in: #require(source.sessions(cwd: fixture.cwd).first))
    }
    #expect(
      turns == [
        SessionTurn(
          index: 1, prompt: "Real first question.\nReal second question.\nThird.",
          reply: "Visible answer.", complete: true)
      ])
    #expect(!String(describing: turns).contains("HIDDEN"))
  }

  @Test(arguments: [
    "<bash-input>HIDDEN", "<bash-stdout>HIDDEN", "[Request interrupted by user] HIDDEN",
    "<system-reminder>HIDDEN</system-reminder>",
  ])
  func claudeInjectedStringStartsANilPromptTurn(_ text: String) throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    try fixture.claude([
      SessionFixture.user("Earlier question.", id: "u1"),
      SessionFixture.assistant("Earlier answer.", id: "a1"),
      SessionFixture.user(text, id: "u2"), SessionFixture.assistant("Next answer.", id: "a2"),
    ])
    let source = ClaudeSessionSource(environment: fixture.environment)
    let turns = try source.turns(in: #require(source.sessions(cwd: fixture.cwd).first))
    #expect(turns.count == 2)
    #expect(turns.last == SessionTurn(index: 2, prompt: nil, reply: "Next answer.", complete: true))
    #expect(!String(describing: turns).contains("HIDDEN"))
  }

  @Test func claudeSummaryAndTranscriptOnlyRecordsDoNotStartTurns() throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    var summary = SessionFixture.user("HIDDEN COMPACT SUMMARY", id: "summary")
    summary["isCompactSummary"] = true
    var transcript = SessionFixture.user("HIDDEN TRANSCRIPT ONLY", id: "transcript")
    transcript["isVisibleInTranscriptOnly"] = true
    try fixture.claude([
      SessionFixture.user("Real question.", id: "u"), summary, transcript,
      SessionFixture.assistant("Real answer.", id: "a"),
    ])
    let source = ClaudeSessionSource(environment: fixture.environment)
    #expect(
      try source.turns(in: #require(source.sessions(cwd: fixture.cwd).first)) == [
        SessionTurn(index: 1, prompt: "Real question.", reply: "Real answer.", complete: true)
      ])
  }

  @Test func claudeEndMarkersUpdateTheSameTurnUntilNextUser() throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let thinking: [String: Any] = [
      "type": "assistant", "uuid": "thinking",
      "message": [
        "id": "final", "content": [["type": "thinking", "thinking": "HIDDEN THINKING"]],
        "stop_reason": "end_turn",
      ],
    ]
    var text = SessionFixture.assistant("First part. ", id: "final")
    text["uuid"] = "text-first"
    var continuation = SessionFixture.assistant("Second part.", id: "final", stop: "")
    continuation["uuid"] = "text-second"
    try fixture.claude([
      SessionFixture.user("Question.", id: "u"), thinking, text, continuation,
      SessionFixture.user("Next question.", id: "u2"),
      SessionFixture.assistant("Superseded final.", id: "old-final"),
      SessionFixture.assistant("Latest final.", id: "new-final", stop: "stop_sequence"),
    ])
    let source = ClaudeSessionSource(environment: fixture.environment)
    #expect(
      try source.turns(in: #require(source.sessions(cwd: fixture.cwd).first)) == [
        SessionTurn(
          index: 1, prompt: "Question.", reply: "First part. Second part.", complete: true),
        SessionTurn(index: 2, prompt: "Next question.", reply: "Latest final.", complete: true),
      ])
  }

  @Test func claudeSyntheticAndAPIErrorRepliesAreIgnored() throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    var synthetic = SessionFixture.assistant(
      "HIDDEN SYNTHETIC", id: "synthetic", stop: "stop_sequence")
    var message = try #require(synthetic["message"] as? [String: Any])
    message["model"] = "<synthetic>"
    synthetic["message"] = message
    var apiError = SessionFixture.assistant("HIDDEN API ERROR", id: "error")
    apiError["isApiErrorMessage"] = true
    try fixture.claude([
      SessionFixture.user("Real question.", id: "u"),
      SessionFixture.assistant("Real reply.", id: "a"), synthetic, apiError,
    ])
    let source = ClaudeSessionSource(environment: fixture.environment)
    #expect(
      try source.turns(in: #require(source.sessions(cwd: fixture.cwd).first)) == [
        SessionTurn(index: 1, prompt: "Real question.", reply: "Real reply.", complete: true)
      ])
    let prepared = try SessionInput.prepare("claude", text: [], environment: fixture.environment)
    #expect(prepared.input == "Real reply.")
  }

  @Test(arguments: ["task_complete", "turn_aborted"])
  func codexMismatchedCompletionDoesNotReserveItsID(_ event: String) throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    try fixture.codex([
      SessionFixture.codexRecord("turn_context", ["turn_id": "first"]),
      SessionFixture.codexUser("First question."),
      SessionFixture.codexRecord(
        "event_msg", ["type": event, "turn_id": "later", "last_agent_message": "HIDDEN MISMATCH"]),
      SessionFixture.complete("first", "First answer."),
      SessionFixture.codexRecord("turn_context", ["turn_id": "later"]),
      SessionFixture.codexUser("Later question."),
      SessionFixture.complete("later", "Later answer."),
    ])
    let source = CodexSessionSource(environment: fixture.environment)
    #expect(
      try source.turns(in: #require(source.sessions(cwd: fixture.cwd).first)) == [
        SessionTurn(index: 1, prompt: "First question.", reply: "First answer.", complete: true),
        SessionTurn(index: 2, prompt: "Later question.", reply: "Later answer.", complete: true),
      ])
  }

  @Test func codexInjectedItemInsideATurnKeepsTheTurnWhole() throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    try fixture.codex([
      SessionFixture.codexRecord("turn_context", ["turn_id": "only"]),
      SessionFixture.codexUser("# AGENTS.md instructions for /fictional/project\nHIDDEN rules"),
      SessionFixture.codexUser("Real question."),
      SessionFixture.codexUser("<subagent_notification>HIDDEN</subagent_notification>"),
      SessionFixture.complete("only", "Real answer."),
    ])
    let source = CodexSessionSource(environment: fixture.environment)
    #expect(
      try source.turns(in: #require(source.sessions(cwd: fixture.cwd).first)) == [
        SessionTurn(index: 1, prompt: "Real question.", reply: "Real answer.", complete: true)
      ])
  }

  @Test func claudeLaterMessageWithoutEndMarkerReopensTheTurn() throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    var hook = SessionFixture.user("HIDDEN stop hook reason", id: "hook")
    hook["isMeta"] = true
    let records = [
      SessionFixture.user("Question.", id: "u"),
      SessionFixture.assistant("Early final.", id: "m1"), hook,
      SessionFixture.assistant("Checking again.", id: "m2", stop: "tool_use"),
    ]
    let source = ClaudeSessionSource(environment: fixture.environment)
    try fixture.claude(records)
    #expect(
      try source.turns(in: #require(source.sessions(cwd: fixture.cwd).first)) == [
        SessionTurn(index: 1, prompt: "Question.", reply: nil, complete: false)
      ])
    try fixture.claude(records + [SessionFixture.assistant("Real final.", id: "m3")])
    #expect(
      try source.turns(in: #require(source.sessions(cwd: fixture.cwd).first)) == [
        SessionTurn(index: 1, prompt: "Question.", reply: "Real final.", complete: true)
      ])
  }

  @Test func codexSubagentRolloutsAreNotSessions() throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    try fixture.codex([], id: "parent-1111")
    try fixture.codex(
      [], id: "child-2222",
      source: ["subagent": ["thread_spawn": ["agent_nickname": "Fictional"]]])
    let source = CodexSessionSource(environment: fixture.environment)
    #expect(try source.sessions(cwd: fixture.cwd).map(\.id) == ["parent-1111"])
  }

  @Test func sessionContextStripsEscapesBeforeClippingToTheFullMargin() {
    let escaped = String(repeating: "\u{1B}[31m\u{1B}[0m", count: 100)
    let turn = SessionTurn(
      index: 1, prompt: nil,
      reply:
        String(repeating: "x", count: 18_000) + " CUT LINE\n" + escaped
        + String(repeating: "safe line\n", count: 1600), complete: true)
    let context = SessionInput.context([turn])
    // A full margin is what makes the core leave the cut first line out of its search.
    #expect(!context.contains("\u{1B}"))
    #expect(context.utf8.count == CommandInput.contextBytes)
    #expect(context.hasSuffix(String(repeating: "safe line\n", count: 1600)))
    let crowded = SessionTurn(
      index: 2, prompt: nil,
      reply:
        String(repeating: "\u{1B}[31m", count: 220_000) + "Visible.", complete: true)
    #expect(SessionInput.attachment([crowded]) == "Assistant: Visible.")
    let nearLimit = SessionTurn(
      index: 3, prompt: nil,
      reply:
        String(repeating: "\u{1B}[31m", count: 4000) + "Short line.", complete: true)
    #expect(SessionInput.context([nearLimit]) == "Assistant: Short line.")
  }

  @Test func fileContextKeepsAFullMarginAndDropsOnlyAShortCutLine() throws {
    let fixture = try SessionFixture()
    defer { fixture.remove() }
    let file = fixture.home.appendingPathComponent("context.txt")
    let read = { try CommandInput.context(file.path, environment: fixture.environment) }
    // Escapes before the cut are removed first, so the kept text fills the margin.
    let escaped = String(repeating: "\u{1B}[31m\u{1B}[0m", count: 100)
    let safe = String(repeating: "safe line\n", count: 1500)
    try Data((String(repeating: "x", count: 20_000) + " CUT LINE\n" + escaped + safe).utf8)
      .write(to: file)
    let full = try #require(try read())
    #expect(!full.contains("\u{1B}"))
    #expect(full.utf8.count == CommandInput.contextBytes)
    #expect(full.hasSuffix(safe))
    // One long line keeps its tail instead of becoming empty.
    for size in [
      CommandInput.contextBytes - 1, CommandInput.contextBytes + 1, CommandInput.contextReadBytes,
    ] {
      try Data(String(repeating: "x", count: size).utf8).write(to: file)
      #expect(try read() == String(repeating: "x", count: min(size, CommandInput.contextBytes)))
    }
    // Cut inside a run of escapes: the escape-free remainder is short, so the core would not
    // skip its partial first line; it is dropped here.
    let short = String(repeating: "safe line\n", count: 100)
    try Data(
      ("HEAD " + String(repeating: "\u{1B}[0m", count: 20_000) + " CUT LINE\n" + short).utf8
    ).write(to: file)
    #expect(try read() == short)
    try Data(String(repeating: "\u{1B}[0m", count: 20_000).utf8).write(to: file)
    #expect(try read() == nil)
  }
}
