import Foundation
import Testing
import os

@testable import ParlanceCore

struct TestDeadline: Error {}
func bounded<T: Sendable>(
  timeout duration: Duration = .seconds(2),
  _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  let (stream, continuation) = AsyncThrowingStream<T, any Error>.makeStream()
  let work = Task {
    do {
      continuation.yield(try await operation())
      continuation.finish()
    } catch { continuation.finish(throwing: error) }
  }
  let timeout = Task {
    do {
      try await ContinuousClock().sleep(for: duration)
      continuation.finish(throwing: TestDeadline())
    } catch {}
  }
  defer {
    work.cancel()
    timeout.cancel()
  }
  for try await value in stream { return value }
  throw TestDeadline()
}
struct Collected: Sendable {
  var events: [LLMEvent] = []
  var error: LLMError?
}
func collect(_ stream: AsyncThrowingStream<LLMEvent, any Error>) async -> Collected {
  var result = Collected()
  do { for try await event in stream { result.events.append(event) } } catch {
    result.error = error as? LLMError
    #expect(error is LLMError)
  }
  return result
}
func sse(_ value: String) -> Data { Data("data: \(value)\n\n".utf8) }

struct ManualClock: Clock {
  struct Instant: InstantProtocol {
    var offset: Duration
    func advanced(by duration: Duration) -> Self { Self(offset: offset + duration) }
    func duration(to other: Self) -> Duration { other.offset - offset }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
  }
  struct Waiter {
    var deadline: Instant
    var continuation: CheckedContinuation<Void, any Error>
  }
  struct State {
    var now = Instant(offset: .zero)
    var waiters: [UUID: Waiter] = [:]
  }
  private let state = OSAllocatedUnfairLock(initialState: State())
  let changes = AsyncStream<Int>.makeStream()
  var now: Instant { state.withLock { $0.now } }
  var minimumResolution: Duration { .nanoseconds(1) }
  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let result: Result<Void, any Error>? = state.withLock { state in
          if Task.isCancelled { return .failure(CancellationError()) }
          if deadline <= state.now { return .success(()) }
          state.waiters[id] = Waiter(deadline: deadline, continuation: continuation)
          changes.continuation.yield(state.waiters.count)
          return nil
        }
        if let result { continuation.resume(with: result) }
      }
    } onCancel: {
      let waiter = state.withLock { state -> Waiter? in
        if let waiter = state.waiters.removeValue(forKey: id) { return waiter }
        return nil
      }
      waiter?.continuation.resume(throwing: CancellationError())
    }
  }
  func advance(by duration: Duration) {
    let ready = state.withLock { state in
      state.now = state.now.advanced(by: duration)
      let ready = state.waiters.filter { $0.value.deadline <= state.now }
      for id in ready.keys { state.waiters.removeValue(forKey: id) }
      return Array(ready.values)
    }
    for waiter in ready { waiter.continuation.resume() }
  }
  func waitForSleepers(_ count: Int) async throws {
    try await bounded {
      if state.withLock({ $0.waiters.count }) >= count { return }
      for await _ in changes.stream { if state.withLock({ $0.waiters.count }) >= count { return } }
    }
  }
  /// Waits until some sleeper is due at exactly `offset` from the clock's origin: proves a timer was
  /// re-armed to that deadline rather than merely still pending.
  func waitForSleeper(at offset: Duration) async throws {
    try await bounded {
      if self.hasSleeper(at: offset) { return }
      for await _ in changes.stream { if self.hasSleeper(at: offset) { return } }
    }
  }
  func hasSleeper(at offset: Duration) -> Bool {
    state.withLock { $0.waiters.values.contains { $0.deadline.offset == offset } }
  }
}

final class Harness: Sendable {
  enum Step: Sendable {
    case data(Data)
    case end, fail, hang
    case delay(Duration)
    case redirect(URL)
    case signal(@Sendable () -> Void)
  }
  struct State {
    var requests: [URLRequest] = []
    var stopped = 0
  }
  let state = OSAllocatedUnfairLock(initialState: State())
  let scripts: [[Step]]
  let status: Int
  let headers: [String: String]
  let clock: ManualClock
  let arrivals = AsyncStream<Int>.makeStream()
  let stops = AsyncStream<Int>.makeStream()
  init(scripts: [[Step]], status: Int, headers: [String: String], clock: ManualClock) {
    self.scripts = scripts
    self.status = status
    self.headers = headers
    self.clock = clock
  }
}
// URLProtocol inherits unchecked concurrency; mutable task storage is protected by a lock.
final class StubProtocol: URLProtocol, @unchecked Sendable {
  static let registry = OSAllocatedUnfairLock(initialState: [String: Harness]())
  private let running = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let harness = Self.registry.withLock({ $0[request.url!.host!] }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    let index = harness.state.withLock { state in
      state.requests.append(request)
      return state.requests.count - 1
    }
    running.withLock { running in
      running = Task { @Sendable [self, harness, index] in
        self.client?.urlProtocol(
          self,
          didReceive: HTTPURLResponse(
            url: self.request.url!, statusCode: harness.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"].merging(
              harness.headers, uniquingKeysWith: { _, new in new }))!,
          cacheStoragePolicy: .notAllowed)
        harness.arrivals.continuation.yield(index + 1)
        for step in harness.scripts[min(index, harness.scripts.count - 1)] {
          if Task.isCancelled { return }
          switch step {
          case .data(let bytes): self.client?.urlProtocol(self, didLoad: bytes)
          case .end:
            self.client?.urlProtocolDidFinishLoading(self)
            return
          case .fail:
            self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
          case .hang: return
          case .delay(let duration):
            do { try await harness.clock.sleep(for: duration) } catch { return }
          case .signal(let callback): callback()
          case .redirect(let url):
            self.client?.urlProtocol(
              self,
              wasRedirectedTo: URLRequest(
                url: URL(string: url.relativeString, relativeTo: self.request.url)!.absoluteURL),
              redirectResponse: HTTPURLResponse(
                url: self.request.url!, statusCode: harness.status, httpVersion: "HTTP/1.1",
                headerFields: ["Location": url.absoluteString])!)
            return
          }
        }
      }
    }
  }
  override func stopLoading() {
    running.withLock {
      $0?.cancel()
      $0 = nil
    }
    if let harness = Self.registry.withLock({ $0[request.url!.host!] }) {
      let count = harness.state.withLock {
        $0.stopped += 1
        return $0.stopped
      }
      harness.stops.continuation.yield(count)
    }
  }
}
final class Fixture: Sendable {
  let harness: Harness
  let session: URLSession
  let provider: HTTPProvider
  let host: String
  var requests: [URLRequest] { harness.state.withLock { $0.requests } }
  init(
    _ preset: ProviderPreset, status: Int = 200, headers: [String: String] = [:],
    scripts: [[Harness.Step]], clock: ManualClock = ManualClock(), model: String? = nil,
    override: ModelOverride? = nil, apiKey: String? = nil,
    firstTextTimeout: Duration = HTTPProvider.Limits.firstToken
  ) {
    host = UUID().uuidString.lowercased() + ".invalid"
    harness = Harness(scripts: scripts, status: status, headers: headers, clock: clock)
    let fixtureHost = host
    let fixtureHarness = harness
    StubProtocol.registry.withLock { $0[fixtureHost] = fixtureHarness }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    session = URLSession(configuration: config)
    let resolved = ResolvedProvider(
      preset: preset, baseURL: URL(string: "https://\(host)/v1/")!,
      model: model ?? preset.defaultModel ?? "local", override: override, apiKey: apiKey,
      firstTextTimeout: firstTextTimeout)
    provider = HTTPProvider(
      provider: resolved, session: session, clock: clock, jitter: { $0.lowerBound })
  }
  deinit {
    session.invalidateAndCancel()
    _ = StubProtocol.registry.withLock { $0.removeValue(forKey: host) }
  }
  func stream(_ token: LLMCancellation = LLMCancellation()) -> AsyncThrowingStream<
    LLMEvent, any Error
  > { provider.stream(sampleRequest, cancellation: token) }
  func waitForStop() async throws {
    try await bounded {
      if self.harness.state.withLock({ $0.stopped }) > 0 { return }
      for await _ in self.harness.stops.stream { return }
    }
  }
  func waitForRequests(_ count: Int) async throws {
    try await bounded {
      if self.requests.count >= count { return }
      for await value in self.harness.arrivals.stream { if value >= count { return } }
    }
  }
}

final class Probe: Sendable {
  let events: AsyncStream<LLMEvent>
  let result: Task<Collected, Never>
  init(_ stream: AsyncThrowingStream<LLMEvent, any Error>) {
    let pair = AsyncStream<LLMEvent>.makeStream()
    events = pair.stream
    result = Task {
      var result = Collected()
      do {
        for try await event in stream {
          result.events.append(event)
          pair.continuation.yield(event)
        }
      } catch {
        result.error = error as? LLMError
        #expect(error is LLMError)
      }
      pair.continuation.finish()
      return result
    }
  }
  func next() async throws -> LLMEvent? {
    try await bounded {
      for await event in self.events { return event }
      return nil
    }
  }
  func finished() async throws -> Collected { try await bounded { await self.result.value } }
}

func textChunk(_ text: String, preset: ProviderPreset) -> Data {
  let object: [String: Any] =
    preset.wire == .anthropicMessages
    ? ["type": "content_block_delta", "delta": ["type": "text_delta", "text": text]]
    : ["choices": [["delta": ["content": text]]]]
  return sse(String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self))
}
func finishChunk(_ reason: String, preset: ProviderPreset) -> Data {
  if preset.wire == .anthropicMessages {
    let mapped = ["stop": "end_turn", "length": "max_tokens", "content_filter": "refusal"]
    return sse(
      "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(mapped[reason] ?? reason)\"},\"usage\":{\"output_tokens\":3}}"
    )
  }
  return sse("{\"choices\":[{\"delta\":{},\"finish_reason\":\"\(reason)\"}]}")
}
func successfulScript(_ preset: ProviderPreset) -> [Harness.Step] {
  if preset.wire == .anthropicMessages {
    return [
      .data(sse(#"{"type":"message_start","message":{"usage":{"input_tokens":2}}}"#)),
      .data(
        sse(
          #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"secret"}}"#)),
      .data(textChunk("hello", preset: preset)), .data(finishChunk("stop", preset: preset)),
      .data(sse(#"{"type":"message_stop"}"#)), .data(sse("[DONE]")), .end,
    ]
  }
  return [
    .data(sse(#"{"choices":[{"delta":{"reasoning_content":"secret"}}]}"#)),
    .data(textChunk("hello", preset: preset)), .data(finishChunk("stop", preset: preset)),
    .data(sse(#"{"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":3}}"#)),
    .data(sse("[DONE]")), .end,
  ]
}
