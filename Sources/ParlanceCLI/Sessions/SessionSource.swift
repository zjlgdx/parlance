import Foundation

struct SessionRef: Equatable, Sendable {
  let id: String
  let started: Date?
  let modified: Date
  let path: String
  let version: String
}

struct SessionTurn: Equatable, Sendable {
  let index: Int
  var prompt: String?
  var reply: String?
  var complete: Bool
  var identity: String? = nil

  // Content equality predates watch; completion identity is compared explicitly by the watcher.
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.index == rhs.index && lhs.prompt == rhs.prompt && lhs.reply == rhs.reply
      && lhs.complete == rhs.complete
  }
}

protocol SessionParsing: Sendable {
  var turns: [SessionTurn] { get }
  /// Identities of complete replies anywhere in the file, including entries off the active path.
  /// Watch treats them as already sent at startup.
  var settledIdentities: Set<String> { get }
  mutating func feed(_ data: Data)
}

extension SessionParsing {
  var settledIdentities: Set<String> { [] }
}

protocol SessionSource: Sendable {
  func makeParser() -> any SessionParsing
  func sessions(cwd: String) throws -> [SessionRef]
  func turns(in session: SessionRef) throws -> [SessionTurn]
}

/// Synchronous line delivery lets readers stop as soon as metadata identifies another directory.
/// Only one line and one read chunk are buffered; ignored JSON objects are released per line.
enum SessionLines {
  static func read(_ path: String, visit: (Data) -> Bool) throws {
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? file.close() }
    var pending = Data()
    var reading = true
    while reading {
      reading = try autoreleasepool {
        guard let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty else { return false }
        var start = chunk.startIndex
        for end in chunk.indices where chunk[end] == 10 {
          pending.append(chunk[start..<end])
          let more = autoreleasepool { visit(pending) }
          pending.removeAll(keepingCapacity: false)
          if !more { return false }
          start = end + 1
        }
        pending.append(chunk[start...])
        return true
      }
    }
    // An unterminated last record may still be in flight, even if its JSON happens to parse.
  }

  static func object(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  static func date(_ value: Any?) -> Date? {
    guard let value = value as? String else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}

/// Removes injected blocks before joining user text. A real question beginning with `<` (for
/// example, `<div> overflows`) is also discarded, so it is missing from the context; the turn
/// itself and its reply are kept.
enum SessionPrompt {
  static func text(_ blocks: [String], excluding prefix: String? = nil) -> String? {
    let kept = blocks.compactMap { block -> String? in
      let text = block.replacingOccurrences(
        of: "(?s)<system-reminder>.*?</system-reminder>", with: "", options: .regularExpression
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
      if let prefix, !prefix.isEmpty, text.hasPrefix(prefix) { return nil }
      return text
    }.joined(separator: "\n")
    return kept.isEmpty ? nil : kept
  }
}
