import Foundation

struct ClaudeSessionSource: SessionSource {
  let environment: CLIEnvironment

  func sessions(cwd: String) throws -> [SessionRef] {
    let encoded = cwd.unicodeScalars.map { scalar -> String in
      let value = scalar.value
      return (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value)
        ? String(scalar) : "-"
    }.joined()
    let directory = environment.homeDirectory + "/.claude/projects/" + encoded
    return try environment.listSessionDirectory(directory).compactMap { path in
      guard path.hasSuffix(".jsonl") else { return nil }
      var metadata: [String: Any]?
      do {
        try environment.readSessionLines(path) { data in
          guard let record = SessionLines.object(data), record["isSidechain"] as? Bool != true,
            record["cwd"] is String
          else { return true }
          metadata = record
          return false
        }
        guard let metadata, metadata["cwd"] as? String == cwd else { return nil }
        return SessionRef(
          id: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
          started: SessionLines.date(metadata["timestamp"]),
          modified: try environment.sessionModificationDate(path), path: path,
          version: metadata["version"] as? String ?? "unknown")
      } catch { return nil }
    }
  }

  func turns(in session: SessionRef) throws -> [SessionTurn] {
    var parser = ClaudeSessionParser()
    try environment.readSessionLines(session.path) { data in
      parser.feed(data)
      return true
    }
    return parser.turns
  }

  func makeParser() -> any SessionParsing { ClaudeSessionParser() }
}

struct ClaudeSessionParser: SessionParsing {
  var completed: [SessionTurn] = []
  var pending: SessionTurn?
  var texts: [String: String] = [:]
  var endingMessage: String?
  var seen: Set<String> = []

  var turns: [SessionTurn] { completed + (pending.map { [$0] } ?? []) }

  mutating func feed(_ data: Data) {
    guard let record = SessionLines.object(data), record["isSidechain"] as? Bool != true,
      let type = record["type"] as? String, type == "user" || type == "assistant",
      let message = record["message"] as? [String: Any]
    else { return }
    if let uuid = record["uuid"] as? String, !seen.insert(uuid).inserted { return }
    if type == "user" {
      guard record["isMeta"] as? Bool != true,
        record["isCompactSummary"] as? Bool != true,
        record["isVisibleInTranscriptOnly"] as? Bool != true,
        let blocks = Self.userBlocks(message["content"])
      else { return }
      if let pending { completed.append(pending) }
      pending = SessionTurn(
        index: completed.count + 1,
        prompt: SessionPrompt.text(blocks, excluding: "[Request interrupted"),
        reply: nil, complete: false)
      endingMessage = nil
      texts.removeAll()
    } else {
      guard message["model"] as? String != "<synthetic>",
        record["isApiErrorMessage"] as? Bool != true,
        let id = message["id"] as? String,
        let blocks = message["content"] as? [[String: Any]]
      else { return }
      if pending == nil {
        pending = SessionTurn(index: completed.count + 1, prompt: nil, reply: nil, complete: false)
      }
      let text = blocks.filter { $0["type"] as? String == "text" }
        .compactMap { $0["text"] as? String }.joined()
      // The end marker identifies which message owns the reply, including its earlier blocks.
      texts[id, default: ""] += text
      let stop = message["stop_reason"] as? String
      if stop == "end_turn" || stop == "stop_sequence" {
        endingMessage = id
        pending?.identity = record["uuid"] as? String
      } else if endingMessage != id {
        // A later message without an end marker (a Stop hook continuation, a tool call) means
        // the earlier final text no longer ends the turn.
        endingMessage = nil
        pending?.reply = nil
        pending?.complete = false
        pending?.identity = nil
      }
      if let endingMessage {
        let reply = texts[endingMessage] ?? ""
        pending?.reply = reply.isEmpty ? nil : reply
        pending?.complete = !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
    }
  }

  private static func userBlocks(_ content: Any?) -> [String]? {
    if let text = content as? String { return [text] }
    guard let blocks = content as? [[String: Any]],
      !blocks.contains(where: { $0["type"] as? String == "tool_result" })
    else { return nil }
    return blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
  }
}
