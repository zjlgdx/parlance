import ArgumentParser
import Foundation
import ParlanceCore

/// Shared argument/stdin routing; request preprocessing removes escapes, not other controls.
enum CommandInput {
  enum Limit {
    case standard, explainQuick, explainDocument

    var characters: Int { self == .explainDocument ? ExplainDocument.maximumCharacters : 20_000 }

    func exceeded(_ environment: CLIEnvironment) throws -> Never {
      switch self {
      case .standard: try CommandInput.tooLong(environment)
      case .explainQuick:
        try CommandInput.fail(
          "input exceeds 20,000 characters. Use --doc to explain a whole document.", environment)
      case .explainDocument:
        let count = characters.formatted(.number.locale(Locale(identifier: "en_US")))
        try CommandInput.fail(
          "input exceeds \(count) characters. Explain one part of the document at a time.",
          environment)
      }
    }
  }

  static func read(
    _ text: [String], command: String, environment: CLIEnvironment, limit: Limit = .standard
  ) throws -> String {
    let input: String
    if !text.isEmpty && text != ["-"] {
      input = text.joined(separator: " ")
    } else {
      if text.isEmpty && environment.stdinIsTTY {
        try fail("no input provided. Pass text or pipe input to pl \(command).", environment)
      }
      let data: Data
      do { data = try environment.readStdin() } catch {
        try fail("could not read stdin. Pass UTF-8 text to pl \(command).", environment)
      }
      guard data.count <= stdinLimit else { try limit.exceeded(environment) }
      guard let decoded = String(data: data, encoding: .utf8) else {
        try fail("input is not valid UTF-8. Pass UTF-8 text to pl \(command).", environment)
      }
      input = decoded
    }
    return try validate(input, command: command, environment: environment, limit: limit)
  }

  static func validate(
    _ input: String, command: String, environment: CLIEnvironment, limit: Limit = .standard
  ) throws -> String {
    let cleaned = TerminalText.stripEscapes(input)
    guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      try fail("input is empty. Pass non-empty text to pl \(command).", environment)
    }
    guard cleaned.count <= limit.characters else { try limit.exceeded(environment) }
    return cleaned
  }

  /// Byte ceiling independent of the character limit; stdin reading stops past it, so piping a
  /// large file in fails fast instead of buffering it.
  static let stdinLimit = 1 << 20

  static func tooLong(_ environment: CLIEnvironment) throws -> Never {
    try fail("input exceeds 20,000 characters. Use shorter input.", environment)
  }

  /// Reads until EOF or until more than `limit` bytes have arrived.
  static func readHead(_ file: FileHandle, limit: Int) throws -> Data {
    var data = Data()
    var done = false
    while !done && data.count <= limit {
      try autoreleasepool {
        guard let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty else {
          done = true
          return
        }
        data.append(chunk)
      }
    }
    return data
  }

  static let contextBytes = ExplainContext.marginBytes
  /// Escape codes are removed before the 16 KiB cut, so more than the margin is read; the extra
  /// byte tells a file that fills the read window from one that was cut.
  static let contextReadBytes = 4 * contextBytes + 1

  static func context(_ path: String?, environment: CLIEnvironment) throws -> String? {
    guard let path else { return nil }
    if path == "-" && environment.stdinIsTTY {
      try fail(
        "--context - reads stdin, but stdin is a terminal. Pipe the context in.", environment)
    }
    let data: Data
    do {
      data = try environment.readContextTail(path)
    } catch {
      try fail("could not read context. Pass a readable UTF-8 file.", environment)
    }
    // Only the last 16 KiB has to be valid UTF-8; earlier bytes are read for escape removal.
    let decoded =
      utf8(data).map { ($0, data.count == contextReadBytes) }
      ?? utf8(data.suffix(contextBytes)).map { ($0, true) }
    guard let (text, cut) = decoded else {
      try fail("context is not valid UTF-8. Pass a UTF-8 file.", environment)
    }
    let clipped = clip(TerminalText.stripEscapes(text), cut: cut)
    return clipped.isEmpty ? nil : clipped
  }

  /// Decodes strictly after skipping up to three continuation bytes left by a byte cut.
  private static func utf8(_ data: Data) -> String? {
    var tail = data[...]
    for _ in 0..<3 {
      guard let byte = tail.first, (0x80...0xBF).contains(byte) else { break }
      tail = tail.dropFirst()
    }
    return String(data: tail, encoding: .utf8)
  }

  /// Keeps the last `contextBytes` of escape-free text. The core leaves a cut first line out of
  /// its search only when the margin is nearly full (`ExplainContext.marginBytes - 64` bytes), so
  /// text that was cut but is shorter than that drops its partial first line here.
  static func clip(_ text: String, cut: Bool) -> String {
    var tail = Data(text.utf8.suffix(contextBytes))
    while let first = tail.first, (0x80...0xBF).contains(first) { tail.removeFirst() }
    let clipped = String(decoding: tail, as: UTF8.self)
    guard cut, tail.count <= contextBytes - 64 else { return clipped }
    guard let newline = clipped.firstIndex(where: \.isNewline) else { return "" }
    return String(clipped[clipped.index(after: newline)...])
  }

  /// `-` is stdin. Seeks for regular files; stdin, pipes, FIFOs and process substitution cannot
  /// seek, so they are read to EOF keeping only the last `contextReadBytes` (including the truncation indicator byte).
  static func readFileTail(_ path: String) throws -> Data {
    if path == "-" { return try readTail(FileHandle.standardInput) }
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? file.close() }
    if let end = try? file.seekToEnd() {
      try file.seek(toOffset: end > contextReadBytes ? end - UInt64(contextReadBytes) : 0)
      return try file.read(upToCount: contextReadBytes) ?? Data()
    }
    return try readTail(file)
  }

  private static func readTail(_ file: FileHandle) throws -> Data {
    var tail = Data()
    var done = false
    while !done {
      // Each read returns autoreleased storage; drain it per chunk so memory stays at the tail.
      try autoreleasepool {
        guard let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty else {
          done = true
          return
        }
        tail.append(chunk)
        if tail.count > contextReadBytes { tail = Data(tail.suffix(contextReadBytes)) }
      }
    }
    return tail
  }

  static func fail(_ message: String, _ environment: CLIEnvironment) throws -> Never {
    environment.stderr("pl: \(message)\n")
    throw ExitCode(64)
  }
}
