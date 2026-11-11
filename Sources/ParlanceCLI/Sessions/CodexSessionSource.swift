import Foundation

struct CodexSessionSource: SessionSource {
  let environment: CLIEnvironment

  func sessions(cwd: String) throws -> [SessionRef] {
    let home = environment.variables["CODEX_HOME"] ?? environment.homeDirectory + "/.codex"
    var directories = [home + "/sessions"]
    // The store has year/month/day directories; do not recurse into unrelated home files.
    for _ in 0..<3 {
      directories = directories.flatMap { (try? environment.listSessionDirectory($0)) ?? [] }
    }
    let files = directories.flatMap { (try? environment.listSessionDirectory($0)) ?? [] }
    return files.compactMap { path in
      guard URL(fileURLWithPath: path).lastPathComponent.hasPrefix("rollout-"),
        path.hasSuffix(".jsonl")
      else { return nil }
      var metadata: [String: Any]?
      do {
        try environment.readSessionLines(path) { data in
          guard let record = SessionLines.object(data), record["type"] as? String == "session_meta"
          else { return true }
          metadata = record["payload"] as? [String: Any]
          return false
        }
        // Subagent threads write their own rollouts with the parent's cwd.
        guard let metadata, metadata["cwd"] as? String == cwd,
          (metadata["source"] as? [String: Any])?["subagent"] == nil,
          let id = metadata["id"] as? String
        else { return nil }
        return SessionRef(
          id: id, started: SessionLines.date(metadata["timestamp"]),
          modified: try environment.sessionModificationDate(path), path: path,
          version: metadata["cli_version"] as? String ?? "unknown")
      } catch { return nil }
    }
  }

  func turns(in session: SessionRef) throws -> [SessionTurn] {
    var parser = CodexSessionParser()
    try environment.readSessionLines(session.path) { data in
      parser.feed(data)
      return true
    }
    return parser.turns
  }

  func makeParser() -> any SessionParsing { CodexSessionParser() }
}

struct CodexSessionParser: SessionParsing {
  var completed: [SessionTurn] = []
  var pending: SessionTurn?
  var activeID: String?
  var finished: Set<String> = []
  var legacy = false

  var turns: [SessionTurn] { completed + (pending.map { [$0] } ?? []) }

  mutating func feed(_ data: Data) {
    guard let record = SessionLines.object(data), let type = record["type"] as? String,
      let payload = record["payload"] as? [String: Any]
    else { return }
    if type == "session_meta" {
      legacy = payload["history_mode"] as? String == "legacy"
      return
    }
    let event = payload["type"] as? String
    if type == "turn_context" || (type == "event_msg" && event == "task_started") {
      if let id = payload["turn_id"] as? String, id != activeID, !finished.contains(id) {
        if activeID != nil, let pending { completed.append(pending) }
        if activeID != nil { pending = nil }
        activeID = id
      }
    }
    var blocks: [String]?
    if type == "response_item", event == "message", payload["role"] as? String == "user",
      let content = payload["content"] as? [[String: Any]]
    {
      blocks = content.filter { $0["type"] as? String == "input_text" }
        .compactMap { $0["text"] as? String }
    } else if legacy, type == "event_msg", event == "user_message" {
      blocks = (payload["message"] as? String).map { [$0] }
    }
    // Turn boundaries come from turn ids, so an item that is entirely injected text changes
    // nothing; treating it as a prompt would close the turn it was injected into.
    if let blocks,
      let prompt = SessionPrompt.text(blocks, excluding: "# AGENTS.md instructions")
    {
      if pending?.prompt != prompt {
        if let pending, pending.prompt != nil {
          completed.append(pending)
          activeID = nil
        }
        pending = SessionTurn(
          index: completed.count + 1, prompt: prompt, reply: nil, complete: false)
      }
    }
    if type == "event_msg", event == "task_complete" || event == "turn_aborted",
      let id = payload["turn_id"] as? String
    {
      if let activeID, activeID != id { return }
      guard finished.insert(id).inserted else { return }
      // final_answer response items and legacy agent_message events alone do not prove completion.
      let reply = event == "task_complete" ? payload["last_agent_message"] as? String : nil
      var turn =
        pending ?? SessionTurn(index: completed.count + 1, prompt: nil, reply: nil, complete: false)
      turn.complete =
        reply.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
      turn.reply = turn.complete ? reply : nil
      turn.identity = turn.complete ? id : nil
      completed.append(turn)
      pending = nil
      activeID = nil
    }
  }
}
