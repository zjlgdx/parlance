import ArgumentParser
import Foundation
import ParlanceCore

public struct Auth: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "auth", abstract: "Manage API keys in Keychain.",
    subcommands: [SetKey.self, Status.self, Remove.self])
  public init() {}

  struct Options: ParsableArguments {
    @Option(help: "Provider preset ID.") var provider: String?

    func account(_ environment: CLIEnvironment) throws -> String {
      let config = try CLIConfiguration.load(environment)
      let preset = try config.selectProvider(provider, environment: environment)
      let base = try CLIConfiguration.baseURL(
        for: preset, entry: config.providers?[preset.id], environment: environment)
      guard let account = KeychainAccount.for(preset, baseURL: base) else {
        try cliFail(
          78,
          "missing providers.compatible.base_url. Set it in config.toml before managing its key.",
          environment)
      }
      return account
    }
  }

  struct SetKey: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "set", abstract: "Store a key read without echo or from stdin's first line.")
    @OptionGroup var options: Options

    mutating func run() async throws {
      let environment = CLIEnvironment.current
      let account = try options.account(environment)
      let key: String
      do {
        if environment.stdinIsTTY {
          key = try environment.readPassphrase()
        } else {
          let line = try environment.readKeyLine().prefix { $0 != 10 }
          guard let decoded = String(data: line, encoding: .utf8) else {
            try cliFail(
              3, "the key is not valid UTF-8. Provide a key on the first line of stdin.",
              environment)
          }
          key = decoded.hasSuffix("\r") ? String(decoded.dropLast()) : decoded
        }
      } catch let error as ExitCode { throw error } catch {
        try cliFail(
          3, "could not read the API key. Use a terminal or pipe the key on stdin.", environment)
      }
      guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        key.rangeOfCharacter(from: .newlines) == nil
      else {
        try cliFail(
          3, "the API key is empty or has multiple lines. Provide one non-empty line.", environment)
      }
      do { try keychain(environment).write(account: account, secret: key) } catch {
        try cliFail(3, "could not store the key. Check Keychain access.", environment)
      }
    }
  }

  struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "remove", abstract: "Remove a stored Keychain key.")
    @OptionGroup var options: Options

    mutating func run() async throws {
      let environment = CLIEnvironment.current
      let account = try options.account(environment)
      do {
        try keychain(environment).delete(account: account)
      } catch KeychainError.notFound {
        // Removing an absent key is already complete.
      } catch {
        try cliFail(3, "could not remove the key. Check Keychain access.", environment)
      }
    }
  }

  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "status",
      abstract: "Show key sources without reading secrets or running helpers.")
    @OptionGroup var options: Options

    mutating func run() async throws {
      let environment = CLIEnvironment.current
      let config = try CLIConfiguration.load(environment)
      let presets =
        try options.provider.map { [try config.selectProvider($0, environment: environment)] }
        ?? ProviderPreset.all
      for preset in presets {
        let entry = config.providers?[preset.id]
        let base = try CLIConfiguration.baseURL(for: preset, entry: entry, environment: environment)
        let status = KeyLookup(
          preset: preset, baseURL: base, command: entry?.apiKeyCommand, environment: environment
        ).status()
        environment.stdout("\(preset.id): \(status)\n")
      }
    }
  }

  private static func keychain(_ environment: CLIEnvironment) -> any KeychainStoring {
    environment.makeKeychain(
      KeychainStore.interactionAllowed(
        stderrIsTerminal: environment.stderrIsTTY, environment: environment.variables))
  }
}
