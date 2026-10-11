import Foundation
import Testing

@testable import ParlanceCore

struct ProviderContractTests {
  @Test(arguments: ProviderPreset.all)
  func streaming(preset: ProviderPreset) async throws {
    let fixture = Fixture(preset, scripts: [successfulScript(preset)])
    let result = try await bounded { await collect(fixture.stream()) }
    #expect(result.error == nil)
    #expect(
      result.events == [.text("hello")]
        + (preset.requestsStreamUsage || preset.wire == .anthropicMessages
          ? [.usage(.init(promptTokens: 2, completionTokens: 3))] : [])
        + [.finished(.stop)])
    let request = try #require(fixture.requests.first)
    #expect(
      request.url?.path
        == (preset.wire == .anthropicMessages ? "/v1/messages" : "/v1/chat/completions"))
    #expect(
      request.value(forHTTPHeaderField: "anthropic-version")
        == (preset.wire == .anthropicMessages ? "2023-06-01" : nil))
    #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
  }
  @Test(arguments: ProviderPreset.all)
  func mapping(preset: ProviderPreset) async throws {
    let code: KnownProviderCode? = preset.wire == .anthropicMessages ? nil : .modelNotFound
    for (status, expected) in [
      (400, LLMError.invalidRequest(status: 400, providerCode: code)),
      (401, .auth(status: 401)), (402, .quota(status: 402)), (403, .auth(status: 403)),
      (404, .invalidRequest(status: 404, providerCode: code)),
      (409, .invalidRequest(status: 409, providerCode: code)),
      (413, .invalidRequest(status: 413, providerCode: code)),
      (422, .invalidRequest(status: 422, providerCode: code)),
      (429, .rateLimit(retryAfter: .seconds(6))),
    ] {
      let fixture = Fixture(
        preset, status: status, headers: ["Retry-After": "6"],
        scripts: [
          [
            .data(
              Data(
                (preset.wire == .anthropicMessages
                  ? #"{"type":"error","error":{"type":"not_found_error","message":"private"}}"#
                  : #"{"error":{"code":"model_not_found","message":"private"}}"#).utf8)), .end,
          ]
        ])
      let result = try await bounded { await collect(fixture.stream()) }
      #expect(result.error == expected)
      #expect(fixture.requests.count == 1)
    }
  }
  @Test(arguments: ProviderPreset.all)
  func disconnect(preset: ProviderPreset) async throws {
    let fixture = Fixture(
      preset, scripts: [[.data(textChunk("partial", preset: preset)), .end]])
    let result = try await bounded { await collect(fixture.stream()) }
    #expect(result.events == [.text("partial")])
    #expect(result.error == .transport)
    #expect(fixture.requests.count == 1)
  }
  @Test(arguments: ProviderPreset.all)
  func cancellation(preset: ProviderPreset) async throws {
    let fixture = Fixture(preset, scripts: [[.hang]])
    let token = LLMCancellation()
    token.cancel()
    #expect(try await bounded { await collect(fixture.stream(token)) }.error == .aborted)
    #expect(fixture.requests.isEmpty)
    let active = LLMCancellation()
    let stream = fixture.stream(active)
    try await fixture.waitForRequests(1)
    active.cancel()
    #expect(try await bounded { await collect(stream) }.error == .aborted)
  }
}
