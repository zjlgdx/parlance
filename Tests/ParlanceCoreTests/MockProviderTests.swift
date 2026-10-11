import Testing

@testable import ParlanceCore

struct MockProviderTests {
  @Test func replay() async throws {
    let provider = MockProvider(scripts: [
      [.event(.text("one")), .event(.finished(.stop))], [.error(.auth(status: nil))],
    ])
    let first = try await bounded {
      await collect(provider.stream(sampleRequest, cancellation: LLMCancellation()))
    }
    #expect(first.events == [.text("one"), .finished(.stop)])
    #expect(first.error == nil)
    for _ in 0..<2 {
      let next = try await bounded {
        await collect(provider.stream(sampleRequest, cancellation: LLMCancellation()))
      }
      #expect(next.error == .auth(status: nil))
    }
    #expect(provider.recordedRequests.count == 3)
  }
  @Test func heldStreamCancellation() async throws {
    let token = LLMCancellation()
    let provider = MockProvider(scripts: [[.hang]])
    let stream = provider.stream(sampleRequest, cancellation: token)
    token.cancel()
    let result = try await bounded { await collect(stream) }
    #expect(result.error == .aborted)
    #expect(
      try await bounded { await collect(provider.stream(sampleRequest, cancellation: token)) }.error
        == .aborted)
  }
}
extension MockProviderTests {
  @Test func delayAndCancel() async throws {
    let clock = ManualClock()
    let provider = MockProvider(
      scripts: [
        [.event(.text("one")), .delay(.seconds(3)), .event(.text("two")), .event(.finished(.stop))]
      ], clock: clock)
    let probe = Probe(provider.stream(sampleRequest, cancellation: LLMCancellation()))
    #expect(try await probe.next() == .text("one"))
    try await clock.waitForSleepers(1)
    clock.advance(by: .seconds(3))
    #expect(try await probe.finished().events == [.text("one"), .text("two"), .finished(.stop)])
    let token = LLMCancellation()
    let next = Probe(provider.stream(sampleRequest, cancellation: token))
    #expect(try await next.next() == .text("one"))
    token.cancel()
    #expect(try await next.finished().error == .aborted)
  }
  @Test func unfinishedScript() async throws {
    let provider = MockProvider(scripts: [[], [.event(.text("partial"))]])
    #expect(
      try await bounded {
        await collect(provider.stream(sampleRequest, cancellation: LLMCancellation()))
      }.error
        == .emptyResponse)
    #expect(
      try await bounded {
        await collect(provider.stream(sampleRequest, cancellation: LLMCancellation()))
      }.error
        == .transport)
  }
}
