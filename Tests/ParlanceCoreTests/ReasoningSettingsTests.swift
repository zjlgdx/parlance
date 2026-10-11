import Foundation
import Testing

@testable import ParlanceCore

private struct ReasoningCase: Sendable {
  let preset: ProviderPreset
  let model: String
  let allowed: [String]
  let onEffort: String
  let offType: String?
  let defaultEffort: String?
  let defaultOff: Bool

  var anthropic: Bool { preset.id == "claude" }
  func valid(_ effort: String?, _ thinking: String?) -> Bool {
    if let effort, !allowed.contains(effort) { return false }
    if thinking == "off" {
      if offType == nil { return false }
      if let effort { return anthropic && ["low", "medium", "high"].contains(effort) }
    }
    return true
  }
  func thinkingBody(effort: String?, off: Bool) -> [String: JSONValue] {
    var result: [String: JSONValue] = [:]
    if off {
      if offType == "none" {
        result["reasoning_effort"] = .string("none")
      } else {
        result["thinking"] = .object(["type": .string(offType!)])
      }
    } else if preset.id == "deepseek" {
      result["thinking"] = .object(["type": .string("enabled")])
    }
    if let effort {
      if anthropic {
        result["output_config"] = .object(["effort": .string(effort)])
      } else {
        result["reasoning_effort"] = .string(effort)
      }
    }
    return result
  }
  func body(_ thinking: [String: JSONValue], headroom: Int) -> [String: JSONValue] {
    var body = thinking
    body["model"] = .string(model)
    body["stream"] = .bool(true)
    body[preset.id == "openai" ? "max_completion_tokens" : "max_tokens"] = .integer(12 + headroom)
    let user: JSONValue = .object(["role": .string("user"), "content": .string("Hello")])
    if anthropic {
      body["system"] = .string("System")
      body["messages"] = .array([user])
    } else {
      body["messages"] = .array([
        .object([
          "role": .string(preset.id == "openai" ? "developer" : "system"),
          "content": .string("System"),
        ]), user,
      ])
      body["stream_options"] = .object(["include_usage": .bool(true)])
    }
    return body
  }
}

private let reasoningCases: [ReasoningCase] = [
  .init(
    preset: .deepseek, model: "deepseek-flash", allowed: ["low", "high", "max"], onEffort: "high",
    offType: "disabled", defaultEffort: nil, defaultOff: true),
  .init(
    preset: .deepseek, model: "deepseek-v4-pro", allowed: ["low", "high", "max"], onEffort: "high",
    offType: "disabled", defaultEffort: nil, defaultOff: true),
  .init(
    preset: .gemini, model: "gemini-3.5-flash-lite", allowed: ["minimal", "low", "medium", "high"],
    onEffort: "minimal", offType: nil, defaultEffort: "minimal", defaultOff: false),
  .init(
    preset: .gemini, model: "gemini-3.8-flash", allowed: ["low", "medium", "high"], onEffort: "low",
    offType: nil, defaultEffort: "low", defaultOff: false),
  .init(
    preset: .openai, model: "gpt-6-luna", allowed: ["low", "medium", "high", "xhigh", "max"],
    onEffort: "medium", offType: "none", defaultEffort: nil, defaultOff: true),
  .init(
    preset: .openai, model: "gpt-6.1-sol", allowed: ["low", "medium", "high", "xhigh", "max"],
    onEffort: "low", offType: nil, defaultEffort: "low", defaultOff: false),
  .init(
    preset: .claude, model: "claude-haiku-5-5", allowed: ["low", "medium", "high", "xhigh", "max"],
    onEffort: "medium", offType: "disabled", defaultEffort: "medium", defaultOff: false),
  .init(
    preset: .claude, model: "claude-sonnet-5-5",
    allowed: ["low", "medium", "high", "xhigh", "max"], onEffort: "low", offType: "between_tools",
    defaultEffort: "low", defaultOff: true),
]
private struct ReasoningCombination: Sendable {
  let model: ReasoningCase
  let effort: String?
  let thinking: String?
}
private let combinations = reasoningCases.flatMap { model in
  ([nil] + ReasoningSettings.Effort.allCases.map { Optional($0.rawValue) }).flatMap { effort in
    [nil, "on", "off"].map { ReasoningCombination(model: model, effort: effort, thinking: $0) }
  }
}

struct ReasoningSettingsTests {
  @Test(arguments: combinations)
  fileprivate func everyCombination(_ combination: ReasoningCombination) throws {
    let row = combination.model
    let effort = combination.effort
    let thinking = combination.thinking
    var provider = resolved(row.preset, model: row.model)
    provider.reasoning = .init(
      effort: effort.flatMap(ReasoningSettings.Effort.init),
      thinking: thinking.flatMap(ReasoningSettings.Thinking.init))
    guard row.valid(effort, thinking) else {
      let error = try #require(provider.reasoningValidationError())
      #expect(error.contains(row.model))
      #expect(error.contains("use ") || error.contains("omit "))
      #expect(error.contains("effort") || error.contains("thinking"))
      return
    }
    #expect(provider.reasoningValidationError() == nil)
    let expected: [String: JSONValue]
    if effort == nil && thinking == nil {
      expected = row.body(
        row.thinkingBody(effort: row.defaultEffort, off: row.defaultOff),
        headroom: row.model == "claude-haiku-5-5" ? 12288 : 0)
    } else {
      let off = thinking == "off"
      let effective = effort ?? row.onEffort
      let headroom =
        off
        ? 0
        : (["minimal", "low", "medium"].contains(effective)
          ? 12288 : effective == "high" ? 32768 : 49152)
      expected = row.body(
        row.thinkingBody(effort: off && !row.anthropic ? nil : effective, off: off),
        headroom: headroom)
      #expect(provider.effectiveThinking == (off ? "off" : "on"))
      #expect(provider.effectiveEffort == (off && !row.anthropic ? "none" : effective))
    }
    #expect(provider.requestBody(for: sampleRequest) == expected)
  }

  @Test(arguments: reasoningCases)
  fileprivate func defaultBytesAndTimeoutOnly(_ row: ReasoningCase) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let expected = try encoder.encode(
      row.body(
        row.thinkingBody(effort: row.defaultEffort, off: row.defaultOff),
        headroom: row.model == "claude-haiku-5-5" ? 12288 : 0))
    var provider = resolved(row.preset, model: row.model)
    #expect(try encoder.encode(provider.requestBody(for: sampleRequest)) == expected)
    provider.firstTextTimeout = .seconds(100)
    #expect(try encoder.encode(provider.requestBody(for: sampleRequest)) == expected)
  }

  @Test func sonnetExplicitOffMatchesRecommendedBytes() throws {
    var provider = resolved(.claude, model: "claude-sonnet-5-5")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let recommended = try encoder.encode(provider.requestBody(for: sampleRequest))
    provider.reasoning = .init(thinking: .off)
    #expect(try encoder.encode(provider.requestBody(for: sampleRequest)) == recommended)
  }

  @Test func extraBodyConflictAndNoOutputField() {
    var provider = resolved(
      .claude,
      override: .init(extraBody: [
        "output_config": .object(["effort": .string("high"), "other": .bool(true)]),
        "thinking": .object(["type": .string("disabled")]),
      ]))
    provider.reasoning = .init(effort: .low, thinking: .on)
    #expect(provider.reasoningValidationError()?.contains("extra_body.thinking") == true)
    provider.reasoning = .init()
    #expect(provider.reasoningValidationError() == nil)
    let body = provider.requestBody(for: sampleRequest)
    #expect(body["output_config"] == .object(["effort": .string("high"), "other": .bool(true)]))
    #expect(body["thinking"] == .object(["type": .string("disabled")]))
    provider.reasoning = .init(effort: .low)
    provider.override = .init(extraBody: ["output_config": .object(["other": .bool(true)])])
    #expect(provider.reasoningValidationError() == nil)
    #expect(
      provider.requestBody(for: sampleRequest)["output_config"]
        == .object([
          "effort": .string("low"), "other": .bool(true),
        ]))
    var chat = resolved(.gemini, override: .init(maxOutputField: MaxOutputField.none))
    chat.reasoning = .init(effort: .high)
    #expect(chat.requestBody(for: sampleRequest)["max_tokens"] == nil)
  }

  @Test(
    arguments: ProviderPreset.all,
    [ReasoningSettings(effort: .low), .init(thinking: .on), .init(thinking: .off)])
  func unknownModels(preset: ProviderPreset, settings: ReasoningSettings) throws {
    for model in ["unknown", "claude-opus-5-5"] {
      var provider = resolved(preset, model: model)
      provider.reasoning = settings
      let error = try #require(provider.reasoningValidationError())
      #expect(error.contains("[models.\"\(model)\"].extra_body"))
      provider.reasoning = .init()
      provider.firstTextTimeout = .seconds(60)
      #expect(provider.reasoningValidationError() == nil)
    }
  }
  @Test func deepseekThinkingInExtraBodyOverridesTheDefaultEffort() {
    let override = ModelOverride(extraBody: ["thinking": .object(["type": .string("enabled")])])
    let provider = resolved(.deepseek, override: override)
    #expect(provider.effortFromExtraBody)
    #expect(provider.thinkingFromExtraBody)
    #expect(!resolved(.claude, override: override).effortFromExtraBody)
  }
}
