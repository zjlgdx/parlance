import ArgumentParser
import Foundation
import ParlanceCore

enum SessionInput {
  static let noInput = ExitCode(66)
  static let attachmentBytes = 1 << 20

  static func prepare(
    _ selection: String, text: [String], environment: CLIEnvironment,
    replyLimit: CommandInput.Limit = .standard
  ) throws -> PreparedSubject {
    let binding = try select(selection, environment: environment)
    let (source, selected, name) = (binding.source, binding.session, binding.name)
    let turns: [SessionTurn]
    do { turns = try source.turns(in: selected) } catch {
      environment.stderr(
        "pl: could not read the \(name) session. Check that the session file is readable.\n")
      throw noInput
    }
    let query = !text.isEmpty
    let last = turns.lastIndex { $0.complete && !visible($0.reply).isEmpty }
    let reply = last.flatMap { turns[$0].reply }
    guard query ? !turns.isEmpty : reply != nil else {
      let missing = query ? "turn" : "completed reply"
      let version =
        binding.agent == "pi"
        ? "session format v\(diagnostic(selected.version))" : "cli \(diagnostic(selected.version))"
      environment.stderr(
        "pl: no \(missing) found in the \(name) session (\(version)). The session format may have changed; update pl.\n"
      )
      throw noInput
    }
    announce(selected, name: name, turns: turns, environment: environment)
    if !query, let last {
      return try Self.reply(turns: turns, at: last, environment: environment, limit: replyLimit)
    }

    let input = try CommandInput.read(text, command: "explain", environment: environment)
    // Queries include questions whose replies are pending, but omit a reply repeated as input.
    var preceding = turns
    if let last, let reply,
      input.trimmingCharacters(in: .whitespacesAndNewlines) == visible(reply)
    {
      preceding[last].reply = nil
    }
    let background = context(preceding)
    let prepared = PreparedSubject(
      subject: ExplainSubject(
        input: input, context: background.isEmpty ? nil : .tail(background),
        inputRedaction: .redact))
    let session = attachment(turns)
    return session.isEmpty
      ? prepared : prepared.attaching(ExplainAttachment(name: name + " session", text: session))
  }

  struct Binding: Sendable {
    let agent: String
    let name: String
    let source: any SessionSource
    let session: SessionRef
    let initialSessionIDs: Set<String>
  }

  struct Selection {
    let agent: String
    let id: String?
  }

  static func syntax(
    _ selection: String, positional: Bool = false, environment: CLIEnvironment
  ) throws -> Selection {
    let parts = selection.split(separator: ":", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count), parts.count == 1 || !parts[1].isEmpty,
      parts[0] == "claude" || parts[0] == "codex" || parts[0] == "pi"
    else {
      try CommandInput.fail(
        "choose \(positional ? "" : "--session ")claude, codex or pi, optionally followed by :ID.",
        environment)
    }
    return Selection(agent: String(parts[0]), id: parts.count == 2 ? String(parts[1]) : nil)
  }

  static func select(_ selection: String, environment: CLIEnvironment) throws -> Binding {
    try select(syntax(selection, environment: environment), environment: environment)
  }

  static func select(_ selection: Selection, environment: CLIEnvironment) throws -> Binding {
    let agent = selection.agent
    let name: String
    let source: any SessionSource
    switch agent {
    case "claude":
      name = "Claude Code"
      source = ClaudeSessionSource(environment: environment)
    case "pi":
      name = "pi"
      source = PiSessionSource(environment: environment)
    default:
      name = "Codex"
      source = CodexSessionSource(environment: environment)
    }
    let sessions = ((try? source.sessions(cwd: environment.currentDirectory)) ?? []).sorted {
      $0.modified == $1.modified ? $0.id < $1.id : $0.modified > $1.modified
    }
    let selected: SessionRef
    if let id = selection.id {
      let exact = sessions.filter { $0.id == id }
      let matches = exact.isEmpty ? sessions.filter { $0.id.hasPrefix(id) } : exact
      guard matches.count == 1, let match = matches.first else {
        let choices = sessions.map { diagnostic($0.id, limit: 64) }.joined(separator: ", ")
        try CommandInput.fail(
          "session ID was not found or is ambiguous. Available IDs: \(choices.isEmpty ? "none" : choices).",
          environment)
      }
      selected = match
    } else {
      guard let session = sessions.first else {
        environment.stderr(
          "pl: no \(name) session found for this directory. Run pl in the directory where the session started.\n"
        )
        throw noInput
      }
      selected = session
    }
    return Binding(
      agent: agent, name: name, source: source, session: selected,
      initialSessionIDs: Set(sessions.map(\.id)))
  }

  static func announce(
    _ selected: SessionRef, name: String, turns: [SessionTurn], environment: CLIEnvironment
  ) {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    let started = selected.started.map { formatter.string(from: $0) } ?? "unknown"
    environment.stderr(
      "pl: using \(name) session \(diagnostic(selected.id, limit: 8)) (started \(started), prompts: \(turns.filter { $0.prompt != nil }.count))\n"
    )
  }

  static func reply(
    turns: [SessionTurn], at index: Int, environment: CLIEnvironment,
    limit: CommandInput.Limit = .standard
  ) throws -> PreparedSubject {
    let input = try CommandInput.validate(
      turns[index].reply ?? "", command: "explain", environment: environment, limit: limit)
    var preceding = Array(turns.prefix(index + 1))
    preceding[index].reply = nil
    let background = context(preceding)
    return PreparedSubject(
      subject: ExplainSubject(
        input: input, context: background.isEmpty ? nil : .tail(background),
        inputRedaction: .redact))
  }

  static func visible(_ text: String?) -> String {
    TerminalText.stripEscapes(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func dialogue(_ turn: SessionTurn) -> String {
    var parts: [String] = []
    if let prompt = turn.prompt { parts.append("User: " + prompt) }
    if turn.complete, let reply = turn.reply { parts.append("Assistant: " + reply) }
    return parts.joined(separator: "\n\n")
  }

  static func context(_ turns: [SessionTurn]) -> String {
    var parts: [String] = []
    var bytes = 0
    for turn in turns.reversed() where bytes <= CommandInput.contextBytes {
      let part = TerminalText.stripEscapes(dialogue(turn))
      guard !part.isEmpty else { continue }
      bytes += part.utf8.count + 2
      parts.append(part)
    }
    // Clipping escape-free text to the full margin lets the core skip the cut line itself.
    return CommandInput.clip(parts.reversed().joined(separator: "\n\n"), cut: false)
  }

  static func attachment(_ turns: [SessionTurn]) -> String {
    var parts: [String] = []
    var bytes = 0
    for turn in turns.reversed() {
      let part = TerminalText.stripEscapes(dialogue(turn))
      guard !part.isEmpty else { continue }
      let size = part.utf8.count + (parts.isEmpty ? 0 : 2)
      guard bytes + size <= attachmentBytes else { break }
      bytes += size
      parts.append(part)
    }
    return parts.reversed().joined(separator: "\n\n")
  }

  static func diagnostic(_ value: String, limit: Int = 80) -> String {
    String(TerminalText.display(value).filter { !$0.isNewline && $0 != "\t" }.prefix(limit))
  }
}
