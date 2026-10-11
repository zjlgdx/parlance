import ArgumentParser
import ParlanceCore

struct ReasoningOptions: ParsableArguments {
  @Option(help: "Reasoning effort: minimal, low, medium, high, xhigh, or max (model-dependent).")
  var effort: String?
  @Option(help: "Thinking: on or off (model-dependent).") var thinking: String?
  @Option(help: "Seconds until first text: integer 1–110; default 30.") var firstTextTimeout:
    String?

  func validateValues(environment: CLIEnvironment) throws {
    if let effort, ReasoningSettings.Effort(rawValue: effort) == nil {
      try cliFail(
        64, "invalid --effort. Use minimal, low, medium, high, xhigh, or max.", environment)
    }
    if let thinking, ReasoningSettings.Thinking(rawValue: thinking) == nil {
      try cliFail(64, "invalid --thinking. Use on or off.", environment)
    }
    if let value = firstTextTimeout {
      guard let seconds = Int(value), (1...110).contains(seconds) else {
        try cliFail(
          64, "invalid --first-text-timeout. Use an integer from 1 to 110 seconds.", environment)
      }
    }
  }
}

extension CLIConfiguration {
  func applyReasoning(
    to provider: inout ResolvedProvider, options: ReasoningOptions?, environment: CLIEnvironment
  ) throws {
    let entry = models?[provider.model]
    func string(_ value: JSONValue?, field: String, allowed: [String]) throws -> String? {
      guard let value else { return nil }
      guard case .string(let text) = value, allowed.contains(text) else {
        try cliFail(
          78,
          "\(safeConfigValue(provider.model)) has invalid \(field); use \(allowed.joined(separator: ", ")). Check config.toml.",
          environment)
      }
      return text
    }
    let effort = try string(
      (options?.effort).map(JSONValue.string) ?? entry?.effort ?? effort, field: "effort",
      allowed: ReasoningSettings.Effort.allCases.map(\.rawValue))
    let thinking = try string(
      (options?.thinking).map(JSONValue.string) ?? entry?.thinking ?? thinking, field: "thinking",
      allowed: ReasoningSettings.Thinking.allCases.map(\.rawValue))
    provider.reasoning = ReasoningSettings(
      effort: effort.flatMap(ReasoningSettings.Effort.init),
      thinking: thinking.flatMap(ReasoningSettings.Thinking.init))
    if let value = (options?.firstTextTimeout).flatMap(Int.init).map(JSONValue.integer)
      ?? entry?.firstTextTimeout ?? firstTextTimeout
    {
      guard case .integer(let seconds) = value, (1...110).contains(seconds) else {
        try cliFail(
          78,
          "\(safeConfigValue(provider.model)) has invalid first_text_timeout; use an integer from 1 to 110 seconds. Check config.toml.",
          environment)
      }
      provider.firstTextTimeout = .seconds(seconds)
    }
    if let message = provider.reasoningValidationError() {
      try cliFail(78, safeConfigValue(message), environment)
    }
  }
}
