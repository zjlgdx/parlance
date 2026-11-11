import CoreFoundation
import Foundation
import os

// pi migration rewrites v1/v2 files in place; if the inode stays the same and the file grows,
// an existing watch reads from a stale offset. Restart watch after migration.
struct PiSessionSource: SessionSource {
  let environment: CLIEnvironment

  func sessions(cwd: String) throws -> [SessionRef] {
    let agentDir =
      environment.variables["PI_CODING_AGENT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
      ?? environment.homeDirectory + "/.pi/agent"
    let path = cwd.hasPrefix("/") || cwd.hasPrefix("\\") ? String(cwd.dropFirst()) : cwd
    let encoded = path.map { "/\\:".contains($0) ? "-" : String($0) }.joined()
    // pi's --session-dir flag and settings.sessionDir are not supported here.
    let sessionDir = environment.variables["PI_CODING_AGENT_SESSION_DIR"].flatMap {
      $0.isEmpty ? nil : $0
    }
    var directory = sessionDir ?? agentDir + "/sessions/--" + encoded + "--"
    if directory.hasPrefix("~") { directory = environment.homeDirectory + directory.dropFirst() }
    return try environment.listSessionDirectory(directory).compactMap { path in
      guard path.hasSuffix(".jsonl") else { return nil }
      var header: [String: Any]?
      do {
        try environment.readSessionLines(path) { data in
          header = SessionLines.object(data)
          return false
        }
        guard let header, header["type"] as? String == "session",
          header["cwd"] as? String == cwd, let id = header["id"] as? String
        else { return nil }
        let version = Self.version(header["version"]).map(String.init) ?? "unknown"
        return SessionRef(
          id: id, started: SessionLines.date(header["timestamp"]),
          modified: try environment.sessionModificationDate(path), path: path, version: version)
      } catch { return nil }
    }
  }

  static func version(_ value: Any?) -> Int? {
    guard let value, !(value is NSNull) else { return 1 }
    if let number = value as? NSNumber {
      guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
      return Int(number.stringValue) ?? Int(exactly: number.doubleValue)
    }
    return (value as? String).flatMap(Int.init)
  }

  func turns(in session: SessionRef) throws -> [SessionTurn] {
    var parser = PiSessionParser()
    try environment.readSessionLines(session.path) { data in
      parser.feed(data)
      return true
    }
    return parser.turns
  }

  func makeParser() -> any SessionParsing { PiSessionParser() }
}

struct PiSessionParser: SessionParsing {
  private enum Replacement: Sendable {
    case removed
    case content([String])
  }

  private enum Kind: Sendable {
    case user([String])
    case assistant([String], stop: String?)
    case edit(target: String, replacement: Replacement)
    case ignored
  }

  private struct Entry: Sendable {
    let id: String
    let parent: String?
    let kind: Kind
  }

  private var entries: [String: Entry] = [:]
  private var leaf: String?
  private var linear = false
  private var line = 0
  private var cache = OSAllocatedUnfairLock<[SessionTurn]?>(initialState: nil)

  var turns: [SessionTurn] {
    cache.withLock { cached in
      if let cached { return cached }
      let result = buildTurns()
      cached = result
      return result
    }
  }

  /// A stop reply counts when its own text or any edit's replacement for it has visible text, so a
  /// reply made visible by an edit on another branch is not explained when that branch returns.
  var settledIdentities: Set<String> {
    var edited: Set<String> = []
    for entry in entries.values {
      if case .edit(let target, .content(let blocks)) = entry.kind,
        !SessionInput.visible(blocks.joined()).isEmpty
      {
        edited.insert(target)
      }
    }
    return Set(
      entries.values.compactMap { entry in
        guard case .assistant(let blocks, let stop) = entry.kind, stop == "stop",
          !SessionInput.visible(blocks.joined()).isEmpty || edited.contains(entry.id)
        else { return nil }
        return entry.id
      })
  }

  mutating func feed(_ data: Data) {
    // A fresh cache preserves value semantics when a parser has been copied.
    cache = OSAllocatedUnfairLock(initialState: nil)
    line += 1
    guard let record = SessionLines.object(data), let type = record["type"] as? String else {
      return
    }
    if type == "session" {
      linear = PiSessionSource.version(record["version"]).map { $0 < 2 } ?? false
      return
    }
    let id: String
    let parent: String?
    if linear {
      id = "line-\(line)"
      parent = leaf
    } else {
      guard let entryID = record["id"] as? String else { return }
      id = entryID
      parent = record["parentId"] as? String
    }
    var kind = Kind.ignored
    if type == "message", let message = record["message"] as? [String: Any] {
      switch message["role"] as? String {
      case "user": kind = .user(Self.textBlocks(message["content"]))
      case "assistant":
        kind = .assistant(
          Self.textBlocks(message["content"]), stop: message["stopReason"] as? String)
      default: break
      }
    } else if type == "context_edit", let target = record["targetId"] as? String {
      if record["replacement"] is NSNull {
        kind = .edit(target: target, replacement: .removed)
      } else if let replacement = record["replacement"] as? [String: Any] {
        kind = .edit(target: target, replacement: .content(Self.textBlocks(replacement["content"])))
      }
    }
    entries[id] = Entry(id: id, parent: parent, kind: kind)
    leaf = id
  }

  private static func textBlocks(_ content: Any?) -> [String] {
    if let text = content as? String { return [text] }
    return (content as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
      .compactMap { $0["text"] as? String }
  }

  private func buildTurns() -> [SessionTurn] {
    var path: [Entry] = []
    var cursor = leaf
    var seen: Set<String> = []
    while let id = cursor, seen.insert(id).inserted, let entry = entries[id] {
      path.append(entry)
      cursor = entry.parent
    }
    path.reverse()
    var edits: [String: Replacement] = [:]
    for entry in path {
      if case .edit(let target, let replacement) = entry.kind { edits[target] = replacement }
    }
    var turns: [SessionTurn] = []
    var invisibleBoundary = false
    for entry in path {
      let replacement = edits[entry.id]
      if case .removed = replacement {
        if case .user = entry.kind { invisibleBoundary = true }
        continue
      }
      let blocks: [String]
      switch entry.kind {
      case .user(let original), .assistant(let original, _):
        if case .content(let edited) = replacement { blocks = edited } else { blocks = original }
      default: continue
      }
      switch entry.kind {
      case .user:
        invisibleBoundary = false
        turns.append(
          SessionTurn(
            index: turns.count + 1, prompt: SessionPrompt.text(blocks), reply: nil, complete: false)
        )
      case .assistant(_, let stop):
        if invisibleBoundary {
          turns.append(
            SessionTurn(index: turns.count + 1, prompt: nil, reply: nil, complete: false))
          invisibleBoundary = false
        }
        guard !turns.isEmpty else { continue }
        let reply = blocks.joined()
        let complete = stop == "stop" && !SessionInput.visible(reply).isEmpty
        let last = turns.count - 1
        turns[last].reply = complete ? reply : nil
        turns[last].complete = complete
        turns[last].identity = complete ? entry.id : nil
      default: break
      }
    }
    return turns
  }
}
