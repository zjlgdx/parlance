import ArgumentParser
import Foundation
import ParlanceCore

public struct Session: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "session", abstract: "Follow local agent sessions.", subcommands: [Watch.self])

  public init() {}

  struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "watch",
      abstract: "Follow agent replies with explanations in an adjacent terminal.")

    @Argument(help: "Local session: claude, codex or pi, optionally followed by :ID.")
    var selection: String
    @Option(help: "Target language (BCP 47).") var target: String?
    @Option(help: "Native language (BCP 47).") var native: String?
    @Option(help: "Provider preset ID.") var provider: String?
    @Option(help: "Model ID.") var model: String?
    @OptionGroup var reasoning: ReasoningOptions
    @Flag(help: "Disable color.") var noColor = false
    @Flag(help: "Write request metadata to stderr.") var verbose = false
    @Flag(help: "Show the redacted text sent to the provider on stderr.") var showSent = false

    mutating func run() async throws {
      let environment = CLIEnvironment.current
      guard environment.stdoutIsTTY else {
        try CommandInput.fail("session watch requires a terminal on stdout.", environment)
      }
      let selection = try SessionInput.syntax(selection, positional: true, environment: environment)
      let config = try CLIConfiguration.load(environment)
      var resolved = try config.resolve(
        provider, model: model, reasoning: reasoning, environment: environment)
      resolved.apiKey = try await KeyLookup(
        preset: resolved.preset, baseURL: resolved.baseURL,
        command: config.providers?[resolved.preset.id]?.apiKeyCommand, environment: environment
      ).key(for: resolved)
      let binding = try SessionInput.select(selection, environment: environment)
      let file: SessionWatchFile
      do {
        var initial = try SessionWatchFile(binding: binding, environment: environment)
        try initial.read(environment: environment)
        file = initial
      } catch {
        try cliFail(66, "could not read the bound session file.", environment)
      }
      SessionInput.announce(
        binding.session, name: binding.name, turns: file.parser.turns, environment: environment)
      let providerName = RequestReporter.safeField(resolved.preset.id, key: resolved.apiKey)
      let modelName = RequestReporter.safeField(resolved.model, key: resolved.apiKey)
      environment.stderr(
        "pl: watching; the latest completed reply at start and each new reply are sent to \(providerName) (\(modelName)) with up to 3,000 characters of earlier conversation, redacted. While an explanation runs, only the newest new reply is kept. Ctrl-C to stop.\n"
      )
      RequestReporter.noteUnknownModel(resolved, environment: environment)
      var watcher = SessionWatcher(
        binding: binding, file: file, environment: environment, resolved: resolved,
        settings: ExplainSettings(
          targetLanguage: target ?? config.targetLanguage ?? "en",
          nativeLanguage: native ?? config.nativeLanguage ?? "zh-Hans"),
        noColor: noColor, verbose: verbose, showSent: showSent)
      try await watcher.run()
    }
  }
}
