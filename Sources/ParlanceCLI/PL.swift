import ArgumentParser

/// The root command of `pl`. Without arguments it prints its help.
public struct PL: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "pl",
    abstract: "Read and write the language of coding agents.",
    discussion:
      "fix and explain accept --effort minimal|low|medium|high|xhigh|max, --thinking on|off (model-dependent), and --first-text-timeout 1–110 seconds (default 30).",
    version: Version.current,
    subcommands: [Fix.self, Explain.self, Auth.self, Config.self]
  )

  public init() {}

  public mutating func run() async throws { throw CleanExit.helpRequest(self) }

  /// Uses the same injected I/O for argument errors, help and command output.
  public static func execute(arguments: [String]) async -> ExitCode {
    let environment = CLIEnvironment.current
    do {
      var command = try await asyncParseAsRoot(arguments)
      if var asynchronous = command as? any AsyncParsableCommand {
        try await asynchronous.run()
      } else {
        try command.run()
      }
      return .success
    } catch {
      let code = exitCode(for: error)
      if code == .success {
        environment.stdout(TerminalText.display(message(for: error)) + "\n")
      } else if !(error is ExitCode) {
        // ArgumentParser's own message names the offending option; the value came from the command
        // line, so it is still sanitised before it reaches the terminal.
        environment.stderr(TerminalText.display(fullMessage(for: error)) + "\n")
      }
      return code
    }
  }

}
