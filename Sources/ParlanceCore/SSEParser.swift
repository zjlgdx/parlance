import Foundation

public struct SSEEvent: Sendable, Equatable {
  public var event: String?
  public var data: String
  public var id: String?
  public var retry: Int?
  public init(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
    self.event = event
    self.data = data
    self.id = id
    self.retry = retry
  }
}
public struct SSEParser: Sendable {
  public enum Item: Sendable, Equatable {
    case event(SSEEvent)
    case comment
  }
  private var line: [UInt8] = []
  private var skipLF = false
  private var firstLine = true
  private var data: [String] = []
  private var event: String?
  private var id: String?
  private var retry: Int?
  public init() {}
  public mutating func feed(_ bytes: some Sequence<UInt8>) -> [Item] {
    var items: [Item] = []
    for byte in bytes {
      if skipLF {
        skipLF = false
        if byte == 10 { continue }
      }
      if byte == 10 || byte == 13 {
        items += consumeLine()
        skipLF = byte == 13
      } else {
        line.append(byte)
      }
    }
    return items
  }
  /// Ends the stream. Complete lines that only lack the final blank line are dispatched; a line cut
  /// before its newline means the event is incomplete, and the whole pending event is dropped (the
  /// EventSource rule), so the caller sees a stream that closed early, not a malformed event.
  public mutating func finish() -> [Item] {
    if !line.isEmpty {
      line.removeAll()
      data.removeAll()
      event = nil
      retry = nil
      return []
    }
    return dispatch()
  }
  private mutating func consumeLine() -> [Item] {
    var value = String(decoding: line, as: UTF8.self)
    line.removeAll(keepingCapacity: true)
    if firstLine {
      firstLine = false
      if value.first == "\u{feff}" { value.removeFirst() }
    }
    if value.isEmpty { return dispatch() }
    if value.first == ":" { return [.comment] }
    let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let field = String(parts[0])
    var content = parts.count == 2 ? String(parts[1]) : ""
    if content.first == " " { content.removeFirst() }
    switch field {
    case "data": data.append(content)
    case "event": event = content
    case "id": if !content.contains("\0") { id = content }
    case "retry":
      if !content.isEmpty && content.utf8.allSatisfy({ (48...57).contains($0) }) {
        retry = Int(content)
      }
    default: break
    }
    return []
  }
  private mutating func dispatch() -> [Item] {
    defer {
      data.removeAll(keepingCapacity: true)
      event = nil
      retry = nil
    }
    guard !data.isEmpty else { return [] }
    return [
      .event(SSEEvent(event: event, data: data.joined(separator: "\n"), id: id, retry: retry))
    ]
  }
}
