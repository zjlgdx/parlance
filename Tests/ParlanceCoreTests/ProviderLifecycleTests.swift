import Foundation
import Testing
import os

@testable import ParlanceCore

struct ProviderLifecycleTests {
  @Test(arguments: ProviderPreset.all)
  func firstTokenTimeout(preset: ProviderPreset) async throws {
    let clock = ManualClock()
    let fixture = Fixture(
      preset, scripts: [[.data(Data(": heartbeat\n\n".utf8)), .hang]], clock: clock)
    let probe = Probe(fixture.stream())
    try await fixture.waitForRequests(1)
    try await clock.waitForSleepers(2)
    clock.advance(by: HTTPProvider.Limits.firstToken)
    let result = try await probe.finished()
    #expect(result.error == .timeout(.firstToken))
    #expect(result.events.isEmpty)
    #expect(fixture.requests.count == 1)
    try await fixture.waitForStop()
    let stopped = fixture.harness.state.withLock { $0.stopped }
    #expect(stopped == 1)
  }
  @Test(arguments: ProviderPreset.all)
  func idleTimeout(preset: ProviderPreset) async throws {
    let clock = ManualClock()
    let fixture = Fixture(
      preset, scripts: [[.data(textChunk("partial", preset: preset)), .hang]],
      clock: clock)
    let probe = Probe(fixture.stream())
    #expect(try await probe.next() == .text("partial"))
    try await clock.waitForSleepers(2)
    clock.advance(by: .seconds(15))
    let result = try await probe.finished()
    #expect(result.events == [.text("partial")])
    #expect(result.error == .timeout(.idle))
    #expect(fixture.requests.count == 1)
  }
  @Test(arguments: ProviderPreset.all)
  func emptyResponseRetriesOnce(preset: ProviderPreset) async throws {
    let clock = ManualClock()
    let fixture = Fixture(preset, scripts: [[.end]], clock: clock)
    let probe = Probe(fixture.stream())
    #expect(try await probe.next() == .retrying(after: .milliseconds(500), cause: .emptyResponse))
    try await clock.waitForSleepers(2)
    clock.advance(by: .milliseconds(500))
    let result = try await probe.finished()
    #expect(result.error == .emptyResponse)
    #expect(fixture.requests.count == 2)
  }
  @Test(arguments: ProviderPreset.all)
  func cancelRetry(preset: ProviderPreset) async throws {
    let fixture = Fixture(preset, status: 503, scripts: [[.end]])
    let token = LLMCancellation()
    let probe = Probe(fixture.stream(token))
    #expect(try await probe.next() == .retrying(after: .milliseconds(500), cause: .server))
    token.cancel()
    #expect(try await probe.finished().error == .aborted)
    fixture.harness.clock.advance(by: HTTPProvider.Limits.firstToken)
    #expect(fixture.requests.count == 1)
  }
  @Test(arguments: ProviderPreset.all)
  func cancelBetweenChunks(preset: ProviderPreset) async throws {
    let fixture = Fixture(
      preset, scripts: [[.data(textChunk("partial", preset: preset)), .hang]])
    let token = LLMCancellation()
    let stream = fixture.stream(token)
    let probe = Probe(stream)
    #expect(try await probe.next() == .text("partial"))
    token.cancel()
    let result = try await probe.finished()
    #expect(result.events == [.text("partial")])
    #expect(result.error == .aborted)
    #expect(fixture.requests.count == 1)
    try await fixture.waitForStop()
    let stopped = fixture.harness.state.withLock { $0.stopped }
    #expect(stopped == 1)
    withExtendedLifetime(stream) {}
  }
  @Test func drainLimit() async throws {
    let clock = ManualClock()
    let fixture = Fixture(
      .openai,
      scripts: [
        [
          .data(sse(#"{"choices":[{"delta":{"content":"answer"},"finish_reason":"stop"}]}"#)),
          .hang,
        ]
      ], clock: clock)
    let token = LLMCancellation()
    let probe = Probe(fixture.stream(token))
    #expect(try await probe.next() == .text("answer"))
    try await clock.waitForSleepers(1)
    clock.advance(by: .seconds(2))
    let result = try await probe.finished()
    #expect(result.events == [.text("answer"), .finished(.stop)])
    #expect(result.error == nil)
    try await fixture.waitForStop()
    let stopped = fixture.harness.state.withLock { $0.stopped }
    #expect(stopped == 1)
    token.cancel()
    #expect(try await probe.finished().events == result.events)
  }
  @Test(arguments: [false, true])
  func cancellationWinsRecordedResult(drain: Bool) async throws {
    let clock = ManualClock()
    let fixture = Fixture(
      .openai,
      scripts: [
        drain
          ? [
            .data(sse(#"{"choices":[{"delta":{"content":"answer"},"finish_reason":"stop"}]}"#)),
            .hang,
          ] : [.hang]
      ], clock: clock)
    let token = LLMCancellation()
    var provider = fixture.provider
    provider.afterTerminalRecorded = { token.cancel() }
    let probe = Probe(provider.stream(sampleRequest, cancellation: token))
    if drain {
      #expect(try await probe.next() == .text("answer"))
    } else {
      try await fixture.waitForRequests(1)
    }
    try await clock.waitForSleepers(drain ? 1 : 2)
    clock.advance(by: drain ? .seconds(2) : HTTPProvider.Limits.firstToken)
    #expect(try await probe.finished().error == .aborted)
    #expect(fixture.requests.count == 1)
  }
  @Test(arguments: [200, 429, 503]) func invalidatedSessionDoesNotRetry(status: Int) async throws {
    let fixture = Fixture(.openai, status: status, scripts: [[.hang]])
    let probe = Probe(fixture.stream())
    try await fixture.waitForRequests(1)
    fixture.session.invalidateAndCancel()
    let result = try await probe.finished()
    #expect(result.error == .transport)
    #expect(result.events.isEmpty)
    #expect(fixture.requests.count == 1)
  }
  @Test(arguments: [301, 302, 303, 307, 308])
  func rejectsRedirects(status: Int) async throws {
    for target in ["https://other.invalid/target", "http://other.invalid/target", "/same-origin"] {
      let fixture = Fixture(.openai, status: status, scripts: [[.redirect(URL(string: target)!)]])
      let result = try await bounded { await collect(fixture.stream()) }
      #expect(result.error == .invalidRequest(status: status, providerCode: nil))
      #expect(fixture.requests.count == 1)
    }
  }
  @Test(arguments: ProviderPreset.all)
  func missingDoneAndFinishReasons(preset: ProviderPreset) async throws {
    for (reason, expected) in [
      ("stop", LLMFinishReason.stop), ("length", .length), ("content_filter", .contentFilter),
      ("private-provider-value", .other),
    ] {
      let fixture = Fixture(
        preset,
        scripts: [
          [
            .data(textChunk("answer", preset: preset)),
            .data(finishChunk(reason, preset: preset)), .end,
          ]
        ])
      let result = try await bounded { await collect(fixture.stream()) }
      #expect(
        result.events == [.text("answer")]
          + (preset.wire == .anthropicMessages
            ? [.usage(.init(promptTokens: 0, completionTokens: 3))] : [])
          + [.finished(expected)])
      #expect(result.error == nil)
    }
  }
  @Test func quotaAndKnownCodes() async throws {
    for (preset, body, expected) in [
      (
        ProviderPreset.openai, #"{"error":{"code":"insufficient_quota"}}"#,
        LLMError.quota(status: 429)
      ),
      (
        .gemini, #"[{"error":{"status":"RESOURCE_EXHAUSTED"}}]"#,
        .rateLimit(retryAfter: .seconds(6))
      ),
    ] {
      let fixture = Fixture(
        preset, status: 429, headers: ["Retry-After": "6"],
        scripts: [[.data(Data(body.utf8)), .end]])
      #expect(try await bounded { await collect(fixture.stream()) }.error == expected)
      #expect(fixture.requests.count == 1)
    }
    for code in ["private-code", "invalid_api_key"] {
      let fixture = Fixture(
        .openai, status: 404,
        scripts: [[.data(Data("{\"error\":{\"code\":\"\(code)\"}}".utf8)), .end]])
      #expect(
        try await bounded { await collect(fixture.stream()) }.error
          == .invalidRequest(status: 404, providerCode: nil))
    }
  }
}

extension ProviderLifecycleTests {
  @Test(arguments: ProviderPreset.all, [1, 60, 110])
  func configuredFirstTextTimeout(preset: ProviderPreset, seconds: Int) async throws {
    let clock = ManualClock()
    let deadline = Duration.seconds(seconds)
    let fixture = Fixture(preset, scripts: [[.hang]], clock: clock, firstTextTimeout: deadline)
    let probe = Probe(fixture.stream())
    try await fixture.waitForRequests(1)
    try await clock.waitForSleeper(at: deadline)
    let task = try await dataTask(fixture)
    clock.advance(by: deadline - .milliseconds(1))
    deliver(Data(": heartbeat\n\n".utf8), fixture: fixture, task: task)
    let reasoning =
      preset.wire == .anthropicMessages
      ? #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"private"}}"#
      : #"{"choices":[{"delta":{"reasoning_content":"private"}}]}"#
    deliver(sse(reasoning), fixture: fixture, task: task)
    #expect(clock.hasSleeper(at: deadline))
    #expect(!clock.hasSleeper(at: HTTPProvider.Limits.firstToken))
    #expect(fixture.harness.state.withLock { $0.stopped } == 0)
    clock.advance(by: .milliseconds(1))
    let result = try await probe.finished()
    #expect(result.error == .timeout(.firstToken))
    #expect(result.events.isEmpty)
    #expect(fixture.requests.count == 1)
    try await fixture.waitForStop()
  }

  @Test(arguments: [ProviderPreset.openai, .claude])
  func configuredDeadlineEndsAtFirstText(preset: ProviderPreset) async throws {
    let clock = ManualClock()
    let fixture = Fixture(preset, scripts: [[.hang]], clock: clock, firstTextTimeout: .seconds(60))
    let probe = Probe(fixture.stream())
    try await fixture.waitForRequests(1)
    try await clock.waitForSleeper(at: .seconds(60))
    let task = try await dataTask(fixture)
    clock.advance(by: .seconds(59))
    deliver(textChunk("first", preset: preset), fixture: fixture, task: task)
    #expect(try await probe.next() == .text("first"))
    try await clock.waitForSleeper(at: .seconds(74))
    #expect(!clock.hasSleeper(at: .seconds(60)))
    clock.advance(by: .seconds(15))
    #expect(try await probe.finished().error == .timeout(.idle))
  }
}
