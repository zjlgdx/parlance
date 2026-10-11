import ArgumentParser
import Foundation

/// Shared argument/stdin routing; request preprocessing removes escapes, not other controls.
enum CommandInput {
  static func read(_ text: [String], command: String, environment: CLIEnvironment) throws -> String
  {
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
      guard data.count <= stdinLimit else { try tooLong(environment) }
      guard let decoded = String(data: data, encoding: .utf8) else {
        try fail("input is not valid UTF-8. Pass UTF-8 text to pl \(command).", environment)
      }
      input = decoded
    }
    let cleaned = TerminalText.stripEscapes(input)
    guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      try fail("input is empty. Pass non-empty text to pl \(command).", environment)
    }
    guard cleaned.count <= 20_000 else { try tooLong(environment) }
    return cleaned
  }

  /// Far above 20,000 characters of UTF-8 plus escapes; stdin reading stops past it, so piping a
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

  static let contextBytes = 16 * 1024

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
    var tail = data.suffix(contextBytes)
    for _ in 0..<3 {
      guard let byte = tail.first, (0x80...0xBF).contains(byte) else { break }
      tail = tail.dropFirst()
    }
    guard let text = String(data: tail, encoding: .utf8) else {
      try fail("context is not valid UTF-8. Pass a UTF-8 file.", environment)
    }
    return TerminalText.stripEscapes(text)
  }

  /// `-` is stdin. Seeks for regular files; stdin, pipes, FIFOs and process substitution cannot
  /// seek, so they are read to EOF keeping only the last `contextBytes`.
  static func readFileTail(_ path: String) throws -> Data {
    if path == "-" { return try readTail(FileHandle.standardInput) }
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? file.close() }
    if let end = try? file.seekToEnd() {
      try file.seek(toOffset: end > contextBytes ? end - UInt64(contextBytes) : 0)
      return try file.read(upToCount: contextBytes) ?? Data()
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
        if tail.count > contextBytes { tail = Data(tail.suffix(contextBytes)) }
      }
    }
    return tail
  }

  static func fail(_ message: String, _ environment: CLIEnvironment) throws -> Never {
    environment.stderr("pl: \(message)\n")
    throw ExitCode(64)
  }
}
