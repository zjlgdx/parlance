import Darwin
import Foundation
import ParlanceCore

public struct CLIEnvironment: Sendable {
  @TaskLocal public static var override: CLIEnvironment?
  public var variables: [String: String]
  public var stdinIsTTY: Bool
  public var stdoutIsTTY: Bool
  public var stderrIsTTY: Bool
  public var readContextTail: @Sendable (String) throws -> Data
  public var readStdin: @Sendable () throws -> Data
  public var stdout: @Sendable (String) -> Void
  public var stderr: @Sendable (String) -> Void
  public var interruptSource: CLIInterruptSource
  public var requestClock: CLIRequestClock
  public var exitImmediately: @Sendable (Int32) -> Void
  public var currentDirectory: String
  public var listSessionDirectory: @Sendable (String) throws -> [String]
  public var sessionModificationDate: @Sendable (String) throws -> Date
  public var readSessionLines: @Sendable (String, (Data) -> Bool) throws -> Void
  public var sessionFileStatus: @Sendable (String) throws -> SessionFileStatus
  public var readSessionBytes: @Sendable (String, UInt64, Int) throws -> Data
  public var timeZone: TimeZone = .current
  public var wallDate: @Sendable () -> Date
  public var glossaryStoreOverride: GlossaryStore?
  public var homeDirectory: String
  public var readConfig: @Sendable (String) throws -> Data?
  public var makeKeychain: @Sendable (Bool) -> any KeychainStoring
  public var runKeyCommand: @Sendable (String, TimeInterval) async -> APIKeyCommandResult
  public var readPassphrase: @Sendable () throws -> String
  public var readKeyLine: @Sendable () throws -> Data
  public var makeProvider: @Sendable (ResolvedProvider) -> any LLMProvider

  public init(
    variables: [String: String], stdinIsTTY: Bool, stdoutIsTTY: Bool, stderrIsTTY: Bool,
    readStdin: @escaping @Sendable () throws -> Data,
    stdout: @escaping @Sendable (String) -> Void, stderr: @escaping @Sendable (String) -> Void,
    makeProvider: @escaping @Sendable (ResolvedProvider) -> any LLMProvider,
    interruptSource: CLIInterruptSource = .none,
    exitImmediately: @escaping @Sendable (Int32) -> Void = { _ in },
    homeDirectory: String = "/test-home",
    readConfig: @escaping @Sendable (String) throws -> Data? = { _ in nil },
    makeKeychain: @escaping @Sendable (Bool) -> any KeychainStoring = { _ in MemoryKeychain() },
    runKeyCommand: @escaping @Sendable (String, TimeInterval) async -> APIKeyCommandResult = {
      _, _ in .init(termination: .launchFailed)
    },
    readPassphrase: @escaping @Sendable () throws -> String = { "" },
    readKeyLine: (@Sendable () throws -> Data)? = nil,
    readContextTail: (@Sendable (String) throws -> Data)? = nil,
    currentDirectory: String = "/test-cwd",
    listSessionDirectory: @escaping @Sendable (String) throws -> [String] = { path in
      try FileManager.default.contentsOfDirectory(atPath: path).map {
        URL(fileURLWithPath: path).appendingPathComponent($0).path
      }
    },
    sessionModificationDate: @escaping @Sendable (String) throws -> Date = { path in
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        let date = attributes[.modificationDate] as? Date
      else { throw CocoaError(.fileReadUnknown) }
      return date
    },
    readSessionLines: (@Sendable (String, (Data) -> Bool) throws -> Void)? = nil,
    requestClock: CLIRequestClock = .inactive,
    sessionFileStatus: (@Sendable (String) throws -> SessionFileStatus)? = nil,
    readSessionBytes: (@Sendable (String, UInt64, Int) throws -> Data)? = nil,
    wallDate: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.sessionFileStatus = sessionFileStatus ?? { try SessionFileStatus.read($0) }
    self.readSessionBytes =
      readSessionBytes ?? { path, offset, count in
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        try file.seek(toOffset: offset)
        return try file.read(upToCount: count) ?? Data()
      }
    self.wallDate = wallDate
    self.currentDirectory = currentDirectory
    self.listSessionDirectory = listSessionDirectory
    self.sessionModificationDate = sessionModificationDate
    self.readSessionLines = readSessionLines ?? { try SessionLines.read($0, visit: $1) }
    self.requestClock = requestClock
    self.readContextTail = readContextTail ?? { try CommandInput.readFileTail($0) }
    self.homeDirectory = homeDirectory
    self.readConfig = readConfig
    self.makeKeychain = makeKeychain
    self.runKeyCommand = runKeyCommand
    self.readPassphrase = readPassphrase
    self.readKeyLine = readKeyLine ?? readStdin
    self.variables = variables
    self.stdinIsTTY = stdinIsTTY
    self.stdoutIsTTY = stdoutIsTTY
    self.stderrIsTTY = stderrIsTTY
    self.readStdin = readStdin
    self.stdout = stdout
    self.stderr = stderr
    self.makeProvider = makeProvider
    self.interruptSource = interruptSource
    self.exitImmediately = exitImmediately
  }

  public static var current: CLIEnvironment {
    if let override { return override }
    let variables = ProcessInfo.processInfo.environment
    return CLIEnvironment(
      variables: variables,
      stdinIsTTY: isatty(0) != 0, stdoutIsTTY: isatty(1) != 0, stderrIsTTY: isatty(2) != 0,
      readStdin: {
        try CommandInput.readHead(FileHandle.standardInput, limit: CommandInput.stdinLimit)
      },
      stdout: { FileHandle.standardOutput.write(Data($0.utf8)) },
      stderr: { FileHandle.standardError.write(Data($0.utf8)) },
      makeProvider: { HTTPProvider(provider: $0, session: .shared) },
      interruptSource: .process, exitImmediately: { _exit($0) },
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
      readConfig: { path in
        do { return try Data(contentsOf: URL(fileURLWithPath: path)) } catch let error as CocoaError
          where error.code == .fileReadNoSuchFile
        { return nil }
      },
      makeKeychain: { KeychainStore(allowsInteraction: $0) },
      runKeyCommand: { await APIKeyCommand.run($0, timeout: $1, environment: variables) },
      readPassphrase: {
        var buffer = [CChar](repeating: 0, count: 8192)
        guard
          readpassphrase("API key: ", &buffer, buffer.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) != nil
        else {
          throw KeychainError.unavailable
        }
        return String(cString: buffer)
      },
      readKeyLine: {
        var data = Data()
        while let byte = try FileHandle.standardInput.read(upToCount: 1), !byte.isEmpty {
          if byte.first == 10 { break }
          data.append(byte)
        }
        return data
      }, currentDirectory: FileManager.default.currentDirectoryPath, requestClock: .continuous)
  }
}
