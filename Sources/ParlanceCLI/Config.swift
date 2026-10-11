import ArgumentParser
import Foundation
import ParlanceCore

public struct Config: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "config", abstract: "Inspect configuration without exposing secrets.",
    subcommands: [Show.self, Path.self], defaultSubcommand: Show.self)
  public init() {}

  struct Path: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "path")
    mutating func run() async throws {
      let environment = CLIEnvironment.current
      environment.stdout(TerminalText.display(CLIConfiguration.path(environment)) + "\n")
    }
  }

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show")
    @OptionGroup var reasoning: ReasoningOptions
    mutating func run() async throws {
      let environment = CLIEnvironment.current
      let config = try CLIConfiguration.load(environment)
      let resolved = try config.resolve(
        nil, model: nil, reasoning: reasoning, environment: environment)
      let preset = resolved.preset
      let entry = config.providers?[preset.id]
      let model = config.models?[resolved.model]
      func show(_ field: String, _ value: String, _ source: String) {
        environment.stdout("\(field) = \(safeConfigValue(value)) [\(source)]\n")
      }
      func reasoningSource(_ flag: String?, _ modelValue: JSONValue?, _ root: JSONValue?) -> String
      {
        if flag != nil { return "flag" }
        if modelValue != nil { return "models.\"\(safeConfigValue(resolved.model))\"" }
        return root != nil ? "config" : "default"
      }
      let effortSource = reasoningSource(reasoning.effort, model?.effort, config.effort)
      let thinkingSource = reasoningSource(reasoning.thinking, model?.thinking, config.thinking)
      // An inferred value is caused by the other setting, not by the untouched recommendation.
      let effectiveThinkingSource = thinkingSource == "default" ? effortSource : thinkingSource
      let effectiveEffortSource =
        resolved.reasoning.isSet && resolved.effectiveEffort == "none"
        ? effectiveThinkingSource : (effortSource == "default" ? thinkingSource : effortSource)
      func source(_ configured: Bool) -> String { configured ? "config" : "default" }
      show("provider", preset.id, config.provider == nil ? "env" : "config")
      show("target_language", config.targetLanguage ?? "en", source(config.targetLanguage != nil))
      show(
        "native_language", config.nativeLanguage ?? "zh-Hans",
        source(config.nativeLanguage != nil))
      show("tone", config.tone ?? "agent", source(config.tone != nil))
      show("fixes", String(config.fixes ?? true), source(config.fixes != nil))
      show("model", resolved.model, source(entry?.model != nil))
      show(
        "effort", resolved.effortFromExtraBody ? "<set>" : resolved.effectiveEffort,
        resolved.effortFromExtraBody ? "extra_body" : effectiveEffortSource)
      show(
        "thinking", resolved.thinkingFromExtraBody ? "<set>" : resolved.effectiveThinking,
        resolved.thinkingFromExtraBody ? "extra_body" : effectiveThinkingSource)
      show(
        "first_text_timeout", String(resolved.firstTextTimeout.components.seconds),
        reasoningSource(
          reasoning.firstTextTimeout, model?.firstTextTimeout, config.firstTextTimeout))
      let origin = KeychainAccount.origin(of: resolved.baseURL)!
      let path = resolved.baseURL.path.isEmpty ? "" : " <path set>"
      show("base_url", origin + path, source(entry?.baseURL != nil))
      show(
        "max_output_field",
        (resolved.override?.maxOutputField ?? resolved.profile?.maxOutputField ?? .none).rawValue,
        source(model?.maxOutputField != nil))
      show(
        "system_role",
        (resolved.override?.systemRole ?? resolved.profile?.systemRole ?? .system).rawValue,
        source(model?.systemRole != nil))
      if entry?.apiKeyCommand != nil { show("api_key_cmd", "<set>", "config") }
      if let extra = model?.extraBody {
        show("extra_body", "<set> (\(extra.count) fields)", "config")
      }
      let status = KeyLookup(
        preset: preset, baseURL: resolved.baseURL, command: entry?.apiKeyCommand,
        environment: environment
      ).status()
      environment.stdout("Key: \(status)\n")
    }
  }
}
