/// User choices remain optional so an untouched profile keeps its recommended request verbatim.
public struct ReasoningSettings: Sendable, Equatable {
  public enum Effort: String, Sendable, CaseIterable {
    case minimal, low, medium, high, xhigh, max
  }
  public enum Thinking: String, Sendable, CaseIterable { case on, off }
  public var effort: Effort?
  public var thinking: Thinking?
  public init(effort: Effort? = nil, thinking: Thinking? = nil) {
    self.effort = effort
    self.thinking = thinking
  }
  public var isSet: Bool { effort != nil || thinking != nil }
}

/// The model's accepted choices and wire mapping, separate from its recommended request.
public struct ReasoningProfile: Sendable, Equatable {
  public enum Mapping: Sendable { case effort, deepseek, anthropic }
  public var efforts: [ReasoningSettings.Effort]
  public var onEffort: ReasoningSettings.Effort
  public var offBody: [String: JSONValue]?
  public var offEfforts: [ReasoningSettings.Effort]
  public var mapping: Mapping
  public var recommendedEffort: String
  public var recommendedThinking: ReasoningSettings.Thinking

  public init(
    efforts: [ReasoningSettings.Effort], onEffort: ReasoningSettings.Effort,
    offBody: [String: JSONValue]? = nil, offEfforts: [ReasoningSettings.Effort] = [],
    mapping: Mapping = .effort, recommendedEffort: String,
    recommendedThinking: ReasoningSettings.Thinking = .on
  ) {
    self.efforts = efforts
    self.onEffort = onEffort
    self.offBody = offBody
    self.offEfforts = offEfforts
    self.mapping = mapping
    self.recommendedEffort = recommendedEffort
    self.recommendedThinking = recommendedThinking
  }

  public func validationError(_ settings: ReasoningSettings, model: String) -> String? {
    if let effort = settings.effort, !efforts.contains(effort) {
      return
        "\(model) does not support effort \(effort.rawValue); use effort \(efforts.map(\.rawValue).joined(separator: ", "))"
    }
    if settings.thinking == .off {
      guard offBody != nil else {
        return "\(model) cannot turn thinking off; use thinking = \"on\""
      }
      if let effort = settings.effort, !offEfforts.contains(effort) {
        if mapping == .anthropic {
          return
            "\(model) cannot turn thinking off at effort \(effort.rawValue); use effort high or lower, or thinking = \"on\""
        }
        return
          "\(model) cannot set effort with thinking off; omit effort or use thinking = \"on\" (effort: \(efforts.map(\.rawValue).joined(separator: ", ")))"
      }
    }
    return nil
  }

  public func effectiveThinking(_ settings: ReasoningSettings) -> ReasoningSettings.Thinking {
    settings.isSet ? settings.thinking ?? .on : recommendedThinking
  }

  public func effectiveEffort(_ settings: ReasoningSettings) -> String {
    guard settings.isSet else { return recommendedEffort }
    guard effectiveThinking(settings) == .on || mapping == .anthropic else { return "none" }
    return (settings.effort ?? onEffort).rawValue
  }

  func body(_ settings: ReasoningSettings) -> [String: JSONValue] {
    if effectiveThinking(settings) == .off {
      var body = offBody ?? [:]
      if mapping == .anthropic {
        body["output_config"] = .object(["effort": .string(effectiveEffort(settings))])
      }
      return body
    }
    let effort = JSONValue.string(effectiveEffort(settings))
    switch mapping {
    case .effort: return ["reasoning_effort": effort]
    case .deepseek:
      return ["reasoning_effort": effort, "thinking": .object(["type": .string("enabled")])]
    case .anthropic: return ["output_config": .object(["effort": effort])]
    }
  }

  func headroom(_ settings: ReasoningSettings) -> Int {
    guard effectiveThinking(settings) == .on else { return 0 }
    switch settings.effort ?? onEffort {
    case .minimal, .low, .medium: return 12288
    case .high: return 32768
    case .xhigh, .max: return 49152
    }
  }
}

extension ResolvedProvider {
  public func reasoningValidationError() -> String? {
    guard reasoning.isSet else { return nil }
    guard let rules = profile?.reasoning else {
      return
        "\(model) has no reasoning profile; use [models.\"\(model)\"].extra_body for this model's accepted fields instead of effort or thinking"
    }
    let extra = override?.extraBody ?? [:]
    let conflict: String?
    if extra["thinking"] != nil {
      conflict = "thinking"
    } else if extra["reasoning_effort"] != nil {
      conflict = "reasoning_effort"
    } else if case .object(let output) = extra["output_config"] {
      conflict = output["effort"] != nil ? "output_config.effort" : nil
    } else {
      // A scalar would replace the mapped object rather than merge its other fields.
      conflict = extra["output_config"] != nil ? "output_config" : nil
    }
    if let conflict {
      return
        "\(model) extra_body.\(conflict) conflicts with configured effort or thinking; remove that extra_body field or unset effort and thinking"
    }
    return rules.validationError(reasoning, model: model)
  }
  /// Reports only field presence; extra_body values must not enter display metadata.
  public var effortFromExtraBody: Bool {
    guard !reasoning.isSet, let extra = override?.extraBody else { return false }
    if extra["reasoning_effort"] != nil { return true }
    // Outside Anthropic the thinking switch decides whether any effort applies at all.
    if extra["thinking"] != nil, profile?.reasoning?.mapping != .anthropic { return true }
    if case .object(let output) = extra["output_config"] { return output["effort"] != nil }
    return extra["output_config"] != nil
  }
  public var thinkingFromExtraBody: Bool {
    guard !reasoning.isSet, let extra = override?.extraBody else { return false }
    // reasoning_effort also controls thinking (for example, OpenAI's "none").
    return extra["thinking"] != nil || extra["reasoning_effort"] != nil
  }
  public var effectiveEffort: String {
    profile?.reasoning?.effectiveEffort(reasoning) ?? "unspecified"
  }
  public var effectiveThinking: String {
    profile?.reasoning?.effectiveThinking(reasoning).rawValue ?? "unspecified"
  }
  var thinkingHeadroom: Int {
    guard reasoning.isSet else { return profile?.thinkingHeadroom ?? 0 }
    return profile?.reasoning?.headroom(reasoning) ?? 0
  }
}
