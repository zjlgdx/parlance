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
    requestClock: CLIRequestClock = .inactive
  ) {
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
      }, requestClock: .continuous)
  }
}
