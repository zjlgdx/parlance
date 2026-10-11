import Foundation
import Testing

@testable import ParlanceCore

let sampleRequest = LLMRequest(
  messages: [.init(role: .system, content: "System"), .init(role: .user, content: "Hello")],
  maxOutputTokens: 12)
func resolved(_ preset: ProviderPreset, model: String? = nil, override: ModelOverride? = nil)
  -> ResolvedProvider
{
  ResolvedProvider(
    preset: preset, baseURL: URL(string: "https://provider.invalid/v1/")!,
    model: model ?? preset.defaultModel ?? "local", override: override, apiKey: nil)
}
struct ModelProfileTests {
  @Test func thinkingHeadroomRaisesEitherWiresLimit() {
    for preset in [ProviderPreset.gemini, .claude] {
      var provider = resolved(preset)
      provider.preset.modelProfiles[provider.model]?.thinkingHeadroom = 100
      let field = provider.profile?.maxOutputField ?? .none
      #expect(provider.requestBody(for: sampleRequest)[field.rawValue] == .integer(112))
    }
  }
  @Test(arguments: ProviderPreset.all)
  func profiles(preset: ProviderPreset) throws {
    for model in [preset.defaultModel].compactMap({ $0 }) + preset.alternateModels {
      let provider = resolved(preset, model: model)
      let profile = try #require(provider.profile)
      let body = provider.requestBody(for: sampleRequest)
      for (key, value) in profile.thinkingBody { #expect(body[key] == value) }
      #expect(body[profile.maxOutputField.rawValue] == .integer(12 + profile.thinkingHeadroom))
      #expect(
        body[profile.maxOutputField == .maxTokens ? "max_completion_tokens" : "max_tokens"] == nil)
      #expect(
        body["messages"]
          == .array(
            (preset.wire == .anthropicMessages
              ? []
              : [
                .object([
                  "role": .string(profile.systemRole.rawValue), "content": .string("System"),
                ])
              ]) + [.object(["role": .string("user"), "content": .string("Hello")])]))
      #expect(body["system"] == (preset.wire == .anthropicMessages ? .string("System") : nil))
    }
    let unknown = resolved(preset, model: "outside-table")
    #expect(!unknown.isKnownModel)
    #expect(unknown.profile == nil)
    let body = unknown.requestBody(for: sampleRequest)
    #expect(
      Set(body.keys)
        == Set(
          ["model", "messages", "stream"]
            + (preset.wire == .anthropicMessages ? ["system", "max_tokens"] : [])
            + (preset.requestsStreamUsage ? ["stream_options"] : [])))
    #expect(String(data: try JSONEncoder().encode(JSONValue.integer(12)), encoding: .utf8) == "12")
  }
  @Test func overrides() throws {
    let override = ModelOverride(
      extraBody: ["thinking": .object(["budget": .integer(4)])],
      maxOutputField: MaxOutputField.none, systemRole: .developer)
    try override.validate()
    let provider = resolved(.deepseek, override: override)
    let body = provider.requestBody(for: sampleRequest)
    #expect(body["thinking"] == .object(["type": .string("disabled"), "budget": .integer(4)]))
    #expect(body["max_tokens"] == nil)
    for key in ["model", "messages", "stream", "stream_options", "system"] {
      #expect(throws: ModelOverride.ValidationError.reservedField(key)) {
        try ModelOverride(extraBody: [key: .null]).validate()
      }
    }
  }
}
extension ModelProfileTests {
  @Test func presetValues() {
    #expect(
      ProviderPreset.all.map(\.id) == ["deepseek", "gemini", "openai", "claude", "compatible"])
    #expect(ProviderPreset.named("missing") == nil)
    #expect(ProviderPreset.named("openai") == .openai)
    #expect(ProviderPreset.deepseek.defaultModel == "deepseek-flash")
    #expect(ProviderPreset.gemini.defaultModel == "gemini-3.5-flash-lite")
    #expect(ProviderPreset.openai.defaultModel == "gpt-6-luna")
    #expect(
      ProviderPreset.all.filter { $0.id != "claude" }.allSatisfy { $0.wire == .chatCompletions })
    #expect(ProviderPreset.claude.wire == .anthropicMessages)
    #expect(WireFormat(rawValue: "anthropicMessages") == .anthropicMessages)
    #expect(WireFormat.chatCompletions.rawValue == "chatCompletions")
    #expect(ProviderPreset.named("claude") == .claude)
    #expect(ProviderPreset.claude.baseURL?.absoluteString == "https://api.anthropic.com/v1")
    #expect(ProviderPreset.claude.apiKeyEnvironmentVariable == "ANTHROPIC_API_KEY")
    #expect(ProviderPreset.claude.requiresKey)
    #expect(ProviderPreset.claude.defaultModel == "claude-haiku-5-5")
    #expect(ProviderPreset.claude.alternateModels == ["claude-sonnet-5-5"])
    #expect(ProviderPreset.claude.ignoredDeltaFields == ["thinking_delta", "signature_delta"])
    #expect(!ProviderPreset.claude.requestsStreamUsage)
    #expect(
      ProviderPreset.claude.modelProfiles["claude-haiku-5-5"]?.recommendationOnly
        == ModelProfile(
          thinkingBody: ["output_config": .object(["effort": .string("medium")])],
          maxOutputField: .maxTokens, systemRole: .system, thinkingHeadroom: 12288))
    #expect(
      ProviderPreset.claude.modelProfiles["claude-sonnet-5-5"]?.recommendationOnly
        == ModelProfile(
          thinkingBody: [
            "thinking": .object(["type": .string("between_tools")]),
            "output_config": .object(["effort": .string("low")]),
          ],
          maxOutputField: .maxTokens, systemRole: .system))
    #expect(ProviderPreset.compatible.baseURL == nil)
    #expect(!ProviderPreset.compatible.requiresKey)
    for (preset, model, effort, field, role) in [
      (
        ProviderPreset.gemini, "gemini-3.5-flash-lite", "minimal", MaxOutputField.maxTokens,
        SystemRole.system
      ), (.gemini, "gemini-3.8-flash", "low", .maxTokens, .system),
      (.openai, "gpt-6-luna", "none", .maxCompletionTokens, .developer),
      (.openai, "gpt-6.1-sol", "low", .maxCompletionTokens, .developer),
    ] {
      #expect(
        preset.modelProfiles[model]?.recommendationOnly
          == ModelProfile(
            thinkingBody: ["reasoning_effort": .string(effort)], maxOutputField: field,
            systemRole: role))
    }
    for model in ["deepseek-flash", "deepseek-v4-pro"] {
      #expect(
        ProviderPreset.deepseek.modelProfiles[model]?.recommendationOnly
          == ModelProfile(
            thinkingBody: ["thinking": .object(["type": .string("disabled")])],
            maxOutputField: .maxTokens, systemRole: .system))
    }
  }
  @Test func unknownModelOverrideAndDeepMerge() throws {
    let override = ModelOverride(
      extraBody: ["reasoning_effort": .string("low"), "nested": .object(["a": .integer(1)])],
      maxOutputField: .maxTokens, systemRole: .developer)
    for preset in ProviderPreset.all {
      let provider = resolved(preset, model: "custom", override: override)
      #expect(provider.profile == nil)
      #expect(!provider.isKnownModel)
      let body = provider.requestBody(for: sampleRequest)
      #expect(body["system"] == (preset.wire == .anthropicMessages ? .string("System") : nil))
      #expect(
        body["messages"]
          == .array(
            (preset.wire == .anthropicMessages
              ? []
              : [
                .object(["role": .string("developer"), "content": .string("System")])
              ]) + [.object(["role": .string("user"), "content": .string("Hello")])]))
      #expect(body["reasoning_effort"] == .string("low"))
      #expect(body["max_tokens"] == .integer(12))
    }
    #expect(
      JSONValue.merge(
        ["o": .object(["x": .object(["a": .integer(1), "b": .bool(true)])])],
        ["o": .object(["x": .object(["a": .null, "c": .array([.integer(3)])])])]) == [
          "o": .object(["x": .object(["a": .null, "b": .bool(true), "c": .array([.integer(3)])])])
        ])
    let value: JSONValue = .object([
      "s": .string("str"), "b": .bool(false), "i": .integer(2), "n": .number(2.5), "nil": .null,
      "a": .array([]),
    ])
    #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
  }
}

extension ModelProfile {
  fileprivate var recommendationOnly: Self {
    var copy = self
    copy.reasoning = nil
    return copy
  }
}
