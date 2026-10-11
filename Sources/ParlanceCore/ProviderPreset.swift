import Foundation

public enum JSONValue: Sendable, Equatable, Codable {
  case string(String)
  case integer(Int)
  case number(Double)
  case bool(Bool)
  case null
  case array([JSONValue])
  case object([String: JSONValue])
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
  static func merge(_ base: [String: JSONValue], _ overlay: [String: JSONValue]) -> [String:
    JSONValue]
  {
    base.merging(overlay) { old, new in
      if case .object(let lhs) = old, case .object(let rhs) = new {
        return .object(merge(lhs, rhs))
      }
      return new
    }
  }
}
public enum MaxOutputField: String, Sendable {
  case maxTokens = "max_tokens"
  case maxCompletionTokens = "max_completion_tokens"
  case none
}
public enum SystemRole: String, Sendable { case system, developer }
public struct ModelProfile: Sendable, Equatable {
  public var reasoning: ReasoningProfile?
  public var thinkingBody: [String: JSONValue]
  public var maxOutputField: MaxOutputField
  public var systemRole: SystemRole
  /// Tokens added to a request's output limit for a model that thinks before answering: its
  /// thinking counts toward the same limit, and the request's limit is sized for the visible text.
  public var thinkingHeadroom: Int
  public init(
    thinkingBody: [String: JSONValue] = [:], maxOutputField: MaxOutputField = .none,
    systemRole: SystemRole = .system, thinkingHeadroom: Int = 0, reasoning: ReasoningProfile? = nil
  ) {
    self.reasoning = reasoning
    self.thinkingBody = thinkingBody
    self.maxOutputField = maxOutputField
    self.systemRole = systemRole
    self.thinkingHeadroom = thinkingHeadroom
  }
}
public struct ModelOverride: Sendable, Equatable {
  public enum ValidationError: Error, Sendable, Equatable { case reservedField(String) }
  public var extraBody: [String: JSONValue]?
  public var maxOutputField: MaxOutputField?
  public var systemRole: SystemRole?
  public init(
    extraBody: [String: JSONValue]? = nil, maxOutputField: MaxOutputField? = nil,
    systemRole: SystemRole? = nil
  ) {
    self.extraBody = extraBody
    self.maxOutputField = maxOutputField
    self.systemRole = systemRole
  }
  public func validate() throws {
    for key in ["model", "messages", "stream", "stream_options", "system"]
    where extraBody?[key] != nil {
      throw ValidationError.reservedField(key)
    }
  }
}
public enum WireFormat: String, Sendable, Equatable { case chatCompletions, anthropicMessages }

public struct ProviderPreset: Sendable, Equatable {
  public var id: String
  public var wire: WireFormat
  public var baseURL: URL?
  public var apiKeyEnvironmentVariable: String
  public var requiresKey: Bool
  public var defaultModel: String?
  public var alternateModels: [String]
  public var ignoredDeltaFields: Set<String>
  public var requestsStreamUsage: Bool
  public var modelProfiles: [String: ModelProfile]
  public init(
    id: String, wire: WireFormat = .chatCompletions, baseURL: URL?,
    apiKeyEnvironmentVariable: String, requiresKey: Bool,
    defaultModel: String?, alternateModels: [String], ignoredDeltaFields: Set<String>,
    requestsStreamUsage: Bool, modelProfiles: [String: ModelProfile]
  ) {
    self.id = id
    self.wire = wire
    self.baseURL = baseURL
    self.apiKeyEnvironmentVariable = apiKeyEnvironmentVariable
    self.requiresKey = requiresKey
    self.defaultModel = defaultModel
    self.alternateModels = alternateModels
    self.ignoredDeltaFields = ignoredDeltaFields
    self.requestsStreamUsage = requestsStreamUsage
    self.modelProfiles = modelProfiles
  }
  public static let deepseek = ProviderPreset(
    id: "deepseek", baseURL: URL(string: "https://api.deepseek.com"),
    apiKeyEnvironmentVariable: "DEEPSEEK_API_KEY", requiresKey: true,
    defaultModel: "deepseek-flash", alternateModels: ["deepseek-v4-pro"],
    ignoredDeltaFields: ["reasoning_content"], requestsStreamUsage: true,
    modelProfiles: Dictionary(
      uniqueKeysWithValues: ["deepseek-flash", "deepseek-v4-pro"].map {
        (
          $0,
          ModelProfile(
            thinkingBody: ["thinking": .object(["type": .string("disabled")])],
            maxOutputField: .maxTokens,
            reasoning: ReasoningProfile(
              efforts: [.low, .high, .max], onEffort: .high,
              offBody: ["thinking": .object(["type": .string("disabled")])],
              mapping: .deepseek, recommendedEffort: "none", recommendedThinking: .off))
        )
      }))
  public static let gemini = ProviderPreset(
    id: "gemini", baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/"),
    apiKeyEnvironmentVariable: "GEMINI_API_KEY", requiresKey: true,
    defaultModel: "gemini-3.5-flash-lite", alternateModels: ["gemini-3.8-flash"],
    ignoredDeltaFields: ["reasoning_content"], requestsStreamUsage: true,
    modelProfiles: [
      "gemini-3.5-flash-lite": ModelProfile(
        thinkingBody: ["reasoning_effort": .string("minimal")], maxOutputField: .maxTokens,
        reasoning: ReasoningProfile(
          efforts: [.minimal, .low, .medium, .high], onEffort: .minimal,
          recommendedEffort: "minimal")),
      "gemini-3.8-flash": ModelProfile(
        thinkingBody: ["reasoning_effort": .string("low")], maxOutputField: .maxTokens,
        reasoning: ReasoningProfile(
          efforts: [.low, .medium, .high], onEffort: .low, recommendedEffort: "low")),
    ])
  public static let openai = ProviderPreset(
    id: "openai", baseURL: URL(string: "https://api.openai.com/v1"),
    apiKeyEnvironmentVariable: "OPENAI_API_KEY", requiresKey: true, defaultModel: "gpt-6-luna",
    alternateModels: ["gpt-6.1-sol"], ignoredDeltaFields: ["reasoning_content"],
    requestsStreamUsage: true,
    modelProfiles: [
      "gpt-6-luna": ModelProfile(
        thinkingBody: ["reasoning_effort": .string("none")], maxOutputField: .maxCompletionTokens,
        systemRole: .developer,
        reasoning: ReasoningProfile(
          efforts: [.low, .medium, .high, .xhigh, .max], onEffort: .medium,
          offBody: ["reasoning_effort": .string("none")], recommendedEffort: "none",
          recommendedThinking: .off)),
      "gpt-6.1-sol": ModelProfile(
        thinkingBody: ["reasoning_effort": .string("low")], maxOutputField: .maxCompletionTokens,
        systemRole: .developer,
        reasoning: ReasoningProfile(
          efforts: [.low, .medium, .high, .xhigh, .max], onEffort: .low, recommendedEffort: "low")),
    ])
  public static let claude = ProviderPreset(
    id: "claude", wire: .anthropicMessages, baseURL: URL(string: "https://api.anthropic.com/v1"),
    apiKeyEnvironmentVariable: "ANTHROPIC_API_KEY", requiresKey: true,
    defaultModel: "claude-haiku-5-5", alternateModels: ["claude-sonnet-5-5"],
    ignoredDeltaFields: ["thinking_delta", "signature_delta"], requestsStreamUsage: false,
    modelProfiles: [
      "claude-haiku-5-5": ModelProfile(
        thinkingBody: ["output_config": .object(["effort": .string("medium")])],
        maxOutputField: .maxTokens, thinkingHeadroom: 12288,
        reasoning: ReasoningProfile(
          efforts: [.low, .medium, .high, .xhigh, .max], onEffort: .medium,
          offBody: ["thinking": .object(["type": .string("disabled")])],
          offEfforts: [.low, .medium, .high], mapping: .anthropic, recommendedEffort: "medium")),
      "claude-sonnet-5-5": ModelProfile(
        thinkingBody: [
          "thinking": .object(["type": .string("between_tools")]),
          "output_config": .object(["effort": .string("low")]),
        ], maxOutputField: .maxTokens,
        reasoning: ReasoningProfile(
          efforts: [.low, .medium, .high, .xhigh, .max], onEffort: .low,
          offBody: ["thinking": .object(["type": .string("between_tools")])],
          offEfforts: [.low, .medium, .high], mapping: .anthropic, recommendedEffort: "low",
          recommendedThinking: .off)),
    ])
  public static let compatible = ProviderPreset(
    id: "compatible", baseURL: nil, apiKeyEnvironmentVariable: "PARLANCE_API_KEY",
    requiresKey: false, defaultModel: nil, alternateModels: [],
    ignoredDeltaFields: ["reasoning_content"], requestsStreamUsage: false, modelProfiles: [:])
  public static let all = [deepseek, gemini, openai, claude, compatible]
  public static func named(_ id: String) -> ProviderPreset? { all.first { $0.id == id } }
}
public struct ResolvedProvider: Sendable, Equatable {
  public var preset: ProviderPreset
  public var baseURL: URL
  public var model: String
  public var override: ModelOverride?
  public var apiKey: String?
  public var reasoning: ReasoningSettings
  public var firstTextTimeout: Duration
  public init(
    preset: ProviderPreset, baseURL: URL, model: String, override: ModelOverride? = nil,
    apiKey: String? = nil, reasoning: ReasoningSettings = .init(),
    firstTextTimeout: Duration = HTTPProvider.Limits.firstToken
  ) {
    self.preset = preset
    self.baseURL = baseURL
    self.model = model
    self.override = override
    self.apiKey = apiKey
    self.reasoning = reasoning
    self.firstTextTimeout = firstTextTimeout
  }
  public var profile: ModelProfile? { preset.modelProfiles[model] }
  public var isKnownModel: Bool { profile != nil }
  public func requestBody(for request: LLMRequest) -> [String: JSONValue] {
    let thinking = reasoning.isSet ? profile?.reasoning?.body(reasoning) : profile?.thinkingBody
    var body = JSONValue.merge(thinking ?? [:], override?.extraBody ?? [:])
    if preset.wire == .anthropicMessages {
      body["model"] = .string(model)
      body["stream"] = .bool(true)
      // Messages always uses a top-level system field and requires max_tokens, regardless of profile.
      body["max_tokens"] = .integer(
        request.maxOutputTokens.map { $0 + thinkingHeadroom }
          ?? HTTPProvider.Limits.defaultMaxTokens)
      let system = request.messages.filter { $0.role == .system }.map(\.content)
        .joined(separator: "\n")
      if !system.isEmpty { body["system"] = .string(system) }
      body["messages"] = .array(
        request.messages.filter { $0.role != .system }.map {
          .object(["role": .string($0.role.rawValue), "content": .string($0.content)])
        })
      return body
    }
    let role = override?.systemRole ?? profile?.systemRole ?? .system
    let field = override?.maxOutputField ?? profile?.maxOutputField ?? .none
    if field != .none, let limit = request.maxOutputTokens {
      body[field.rawValue] = .integer(limit + thinkingHeadroom)
    }
    body["model"] = .string(model)
    body["messages"] = .array(
      request.messages.map {
        .object([
          "role": .string($0.role == .system ? role.rawValue : $0.role.rawValue),
          "content": .string($0.content),
        ])
      })
    body["stream"] = .bool(true)
    if preset.requestsStreamUsage {
      body["stream_options"] = .object(["include_usage": .bool(true)])
    }
    return body
  }
}
