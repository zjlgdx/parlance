import Foundation
import Testing

@testable import ParlanceCore

struct LiveSmokeTests {
  static func enabled(_ preset: ProviderPreset) -> Bool {
    let env = ProcessInfo.processInfo.environment
    return env["CI"] == nil && env["PARLANCE_LIVE_TESTS"] == "1"
      && !(env[preset.apiKeyEnvironmentVariable] ?? "").isEmpty
  }
  @Test(.enabled(if: enabled(.deepseek))) func deepseek() async throws {
    try await smoke(.deepseek)
  }
  @Test(.enabled(if: enabled(.gemini))) func gemini() async throws { try await smoke(.gemini) }
  @Test(.enabled(if: enabled(.openai))) func openai() async throws { try await smoke(.openai) }
  @Test(.enabled(if: enabled(.claude))) func claude() async throws { try await smoke(.claude) }
  @Test(.enabled(if: enabled(.compatible))) func compatible() async throws {
    try await smoke(.compatible)
  }
  func smoke(_ preset: ProviderPreset) async throws {
    let env = ProcessInfo.processInfo.environment
    let base = try #require(preset.baseURL ?? env["PARLANCE_BASE_URL"].flatMap(URL.init(string:)))
    let model = try #require(preset.defaultModel ?? env["PARLANCE_MODEL"])
    let provider = HTTPProvider(
      provider: .init(
        preset: preset, baseURL: base, model: model, apiKey: env[preset.apiKeyEnvironmentVariable]),
      session: .shared)
    let clock = ContinuousClock()
    let start = clock.now
    let token = LLMCancellation()
    defer { token.cancel() }
    var text = ""
    for try await event in provider.stream(
      .init(messages: [.init(role: .user, content: "Reply with only OK.")]), cancellation: token)
    {
      if case .text(let part) = event {
        if text.isEmpty { print("\(preset.id) first token: \(start.duration(to: clock.now))") }
        text += part
      }
    }
    #expect(!text.isEmpty)
    #expect(!text.contains("<think>"))
    #expect(!text.contains("<thinking>"))
  }
}
