import Foundation
import Testing
import os

@testable import ParlanceCore

struct ProviderEdgeCaseTests {
  @Test(arguments: ProviderPreset.all)
  func actualRequestBody(preset: ProviderPreset) async throws {
    for model in [preset.defaultModel ?? "local"] + preset.alternateModels + ["unknown"] {
      let extra = ModelOverride(extraBody: ["vendor_option": .object(["nested": .integer(1)])])
      let fixture = Fixture(
        preset,
        scripts: [successfulScript(preset)], model: model, override: extra, apiKey: "fake-test-key")
      _ = try await bounded { await collect(fixture.stream()) }
      let request = try #require(fixture.requests.first)
      #expect(request.httpMethod == "POST")
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
      #expect(
        request.value(forHTTPHeaderField: "Authorization")
          == (preset.wire == .anthropicMessages ? nil : "Bearer fake-test-key"))
      #expect(
        request.value(forHTTPHeaderField: "x-api-key")
          == (preset.wire == .anthropicMessages ? "fake-test-key" : nil))
      let bytes = try #require(request.httpBody ?? readBody(request.httpBodyStream))
      let body = try JSONDecoder().decode([String: JSONValue].self, from: bytes)
      #expect(body["model"] == .string(model))
      #expect(body["stream"] == .bool(true))
      #expect(body["vendor_option"] == .object(["nested": .integer(1)]))
      #expect(
        body["stream_options"]
          == (preset.requestsStreamUsage ? .object(["include_usage": .bool(true)]) : nil))
      if let profile = preset.modelProfiles[model] {
        #expect(body[profile.maxOutputField.rawValue] == .integer(12 + profile.thinkingHeadroom))
        for (key, value) in profile.thinkingBody { #expect(body[key] == value) }
      } else {
        #expect(body["thinking"] == nil)
        #expect(body["reasoning_effort"] == nil)
        #expect(body["max_tokens"] == (preset.wire == .anthropicMessages ? .integer(12) : nil))
        #expect(body["max_completion_tokens"] == nil)
      }
      let role = preset.modelProfiles[model]?.systemRole.rawValue ?? "system"
      #expect(
        body["messages"]
          == .array(
            (preset.wire == .anthropicMessages
              ? []
              : [
                .object(["role": .string(role), "content": .string("System")])
              ]) + [.object(["role": .string("user"), "content": .string("Hello")])]))
      #expect(body["system"] == (preset.wire == .anthropicMessages ? .string("System") : nil))
    }
  }
  private func readBody(_ stream: InputStream?) -> Data? {
    guard let stream else { return nil }
    stream.open()
    defer { stream.close() }
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { return count == 0 ? output : nil }
      output.append(contentsOf: buffer.prefix(count))
    }
  }
  @Test(arguments: [408, 500, 503, 429])
  func retryBeforeText(status: Int) async throws {
    let clock = ManualClock()
    let fixture = Fixture(
      .openai, status: status, headers: ["Retry-After": "1"], scripts: [[.end]], clock: clock)
    let probe = Probe(fixture.stream())
    let cause: LLMErrorCode = status == 429 ? .rateLimit : .server
    let delay: Duration = status == 429 ? .seconds(1) : .milliseconds(500)
    #expect(try await probe.next() == .retrying(after: delay, cause: cause))
    try await clock.waitForSleepers(2)
    clock.advance(by: delay)
    let result = try await probe.finished()
    #expect(result.error?.code == cause)
    #expect(result.events.count == 1)
    #expect(fixture.requests.count == 2)
  }
  @Test func retryTransportThenSucceed() async throws {
    let clock = ManualClock()
    let fixture = Fixture(
      .compatible,
      scripts: [
        [.fail],
        [.data(sse(#"{"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#)), .end],
      ], clock: clock)
    let probe = Probe(fixture.stream())
    #expect(try await probe.next() == .retrying(after: .milliseconds(500), cause: .transport))
    try await clock.waitForSleepers(2)
    clock.advance(by: .milliseconds(500))
    let result = try await probe.finished()
    #expect(
      result.events == [
        .retrying(after: .milliseconds(500), cause: .transport), .text("ok"), .finished(.stop),
      ])
    #expect(result.error == nil)
  }
  @Test func totalDeadlineSurvivesHeartbeats() async throws {
    let clock = ManualClock()
    let fixture = Fixture(
      .openai, scripts: [[.data(sse(#"{"choices":[{"delta":{"content":"start"}}]}"#)), .hang]],
      clock: clock)
    let probe = Probe(fixture.stream())
    #expect(try await probe.next() == .text("start"))
    let task = try await dataTask(fixture)
    for _ in 0..<11 {
      clock.advance(by: .seconds(10))
      deliver(Data(": heartbeat\n\n".utf8), fixture: fixture, task: task)
    }
    clock.advance(by: .seconds(10))
    let result = try await probe.finished()
    #expect(result.error == .timeout(.total))
    #expect(result.events == [.text("start")])
  }
  @Test func heartbeatExtendsIdle() async throws {
    let clock = ManualClock()
    let fixture = Fixture(
      .openai, scripts: [[.data(sse(#"{"choices":[{"delta":{"content":"start"}}]}"#)), .hang]],
      clock: clock)
    let probe = Probe(fixture.stream())
    #expect(try await probe.next() == .text("start"))
    let task = try await dataTask(fixture)
    clock.advance(by: .seconds(14))
    deliver(Data(": heartbeat\n\n".utf8), fixture: fixture, task: task)
    // The heartbeat must have re-armed the idle timer to 14s + 15s before time moves past the old deadline.
    try await clock.waitForSleeper(at: .seconds(29))
    clock.advance(by: .seconds(14))
    deliver(
      sse(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#), fixture: fixture, task: task)
    deliver(sse("[DONE]"), fixture: fixture, task: task)
    #expect(try await probe.finished().events == [.text("start"), .finished(.stop)])
  }
  @Test(arguments: [false, true])
  func dropsLateBytesAfterTerminalRecorded(drain: Bool) async throws {
    let clock = ManualClock()
    let fixture = Fixture(
      .openai,
      scripts: [
        drain
          ? [
            .data(sse(#"{"choices":[{"delta":{"content":"start"},"finish_reason":"stop"}]}"#)),
            .hang,
          ] : [.hang]
      ], clock: clock)
    let taskBox = OSAllocatedUnfairLock<URLSessionDataTask?>(initialState: nil)
    var provider = fixture.provider
    provider.afterTerminalRecorded = {
      if let task = taskBox.withLock({ $0 }) {
        deliver(sse(#"{"choices":[{"delta":{"content":"late"}}]}"#), fixture: fixture, task: task)
        deliver(
          sse(#"{"choices":[],"usage":{"prompt_tokens":9,"completion_tokens":9}}"#),
          fixture: fixture, task: task)
      }
    }
    let probe = Probe(provider.stream(sampleRequest, cancellation: LLMCancellation()))
    if drain {
      #expect(try await probe.next() == .text("start"))
    } else {
      try await fixture.waitForRequests(1)
    }
    let task = try await dataTask(fixture)
    taskBox.withLock { $0 = task }
    clock.advance(by: drain ? .seconds(2) : HTTPProvider.Limits.firstToken)
    let result = try await probe.finished()
    #expect(result.events == (drain ? [.text("start"), .finished(.stop)] : []))
    #expect(result.error == (drain ? nil : .timeout(.firstToken)))
  }
  @Test func consumerStopsAndCancels() async throws {
    let fixture = Fixture(
      .openai, scripts: [[.data(sse(#"{"choices":[{"delta":{"content":"start"}}]}"#)), .hang]])
    let token = LLMCancellation()
    let stream = fixture.stream(token)
    try await bounded { for try await _ in stream { break } }
    token.cancel()
    try await fixture.waitForStop()
    withExtendedLifetime(stream) {}
  }
  @Test func usageChunkWithoutChoices() async throws {
    let fixture = Fixture(
      .openai,
      scripts: [
        [
          .data(sse(#"{"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#)),
          .data(sse(#"{"usage":{"prompt_tokens":1,"completion_tokens":1}}"#)), .end,
        ]
      ])
    let result = try await bounded { await collect(fixture.stream()) }
    #expect(
      result.events == [
        .text("ok"), .usage(.init(promptTokens: 1, completionTokens: 1)), .finished(.stop),
      ])
    #expect(result.error == nil)
  }
  @Test func malformedResponse() async throws {
    let fixture = Fixture(.openai, scripts: [[.data(sse("not-json")), .hang]])
    let result = try await bounded { await collect(fixture.stream()) }
    #expect(result.error == .malformedResponse)
    #expect(fixture.requests.count == 1)
  }
  @Test func invalidOverrideDoesNotConnect() async throws {
    let fixture = Fixture(
      .openai, scripts: [[.hang]], override: ModelOverride(extraBody: ["model": .string("bad")]))
    #expect(
      try await bounded { await collect(fixture.stream()) }.error
        == .invalidRequest(status: 400, providerCode: nil))
    #expect(fixture.requests.isEmpty)
  }
}
func dataTask(_ fixture: Fixture) async throws -> URLSessionDataTask {
  let tasks = try await bounded {
    await withCheckedContinuation { continuation in
      fixture.session.getAllTasks { continuation.resume(returning: $0) }
    }
  }
  let task = try #require(tasks.first as? URLSessionDataTask)
  // Manual delegate delivery starts with its response callback; URLProtocol delivery is asynchronous.
  let response = HTTPURLResponse(
    url: task.originalRequest!.url!, statusCode: 200, httpVersion: "HTTP/1.1",
    headerFields: ["Content-Type": "text/event-stream"])!
  func deliverResponse() {
    (task.delegate as? any URLSessionDataDelegate)?.urlSession?(
      fixture.session, dataTask: task, didReceive: response,
      completionHandler: { disposition in
        #expect(disposition == .allow)
      })
  }
  deliverResponse()
  return task
}
// Invoke the stub's delivery path synchronously so the timer hook returns only after handling data.
func deliver(_ data: Data, fixture: Fixture, task: URLSessionDataTask) {
  let delegate = task.delegate as? any URLSessionDataDelegate
  #expect(delegate != nil)
  delegate?.urlSession?(fixture.session, dataTask: task, didReceive: data)
}
extension ProviderEdgeCaseTests {
  @Test func heartbeatDoesNotExtendFirstToken() async throws {
    let clock = ManualClock()
    let fixture = Fixture(.openai, scripts: [[.hang]], clock: clock)
    let probe = Probe(fixture.stream())
    try await fixture.waitForRequests(1)
    let task = try await dataTask(fixture)
    clock.advance(by: HTTPProvider.Limits.firstToken - .seconds(1))
    deliver(Data(":heartbeat\n\n".utf8), fixture: fixture, task: task)
    clock.advance(by: .seconds(1))
    #expect(try await probe.finished().error == .timeout(.firstToken))
    #expect(fixture.requests.count == 1)
  }
  @Test(arguments: ["5", "Wed, 21 Oct 2015 07:28:00 GMT", "1.5", "-1"])
  func retryAfterParsing(header: String) async throws {
    let clock = ManualClock()
    let fixture = Fixture(
      .gemini, status: 429, headers: ["Retry-After": header], scripts: [[.end]], clock: clock)
    let token = LLMCancellation()
    let probe = Probe(fixture.stream(token))
    let delay: Duration = header == "5" ? .seconds(5) : .milliseconds(500)
    #expect(try await probe.next() == .retrying(after: delay, cause: .rateLimit))
    try await clock.waitForSleepers(2)
    clock.advance(by: delay)
    let result = try await probe.finished()
    #expect(result.error == .rateLimit(retryAfter: header == "5" ? .seconds(5) : nil))
    #expect(fixture.requests.count == 2)
  }
  @Test func emptyFinishedResponseRetries() async throws {
    let clock = ManualClock()
    let fixture = Fixture(
      .compatible,
      scripts: [[.data(sse(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)), .end]],
      clock: clock)
    let probe = Probe(fixture.stream())
    #expect(try await probe.next() == .retrying(after: .milliseconds(500), cause: .emptyResponse))
    try await clock.waitForSleepers(2)
    clock.advance(by: .milliseconds(500))
    #expect(try await probe.finished().error == .emptyResponse)
    #expect(fixture.requests.count == 2)
  }
  @Test func usageDrainReplacesTotalDeadline() async throws {
    let clock = ManualClock()
    let fixture = Fixture(
      .openai, scripts: [[.data(sse(#"{"choices":[{"delta":{"content":"start"}}]}"#)), .hang]],
      clock: clock)
    let probe = Probe(fixture.stream())
    #expect(try await probe.next() == .text("start"))
    let task = try await dataTask(fixture)
    for _ in 0..<11 {
      clock.advance(by: .seconds(10))
      deliver(Data(": heartbeat\n\n".utf8), fixture: fixture, task: task)
    }
    clock.advance(by: .seconds(9))
    deliver(
      sse(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#), fixture: fixture, task: task)
    // Disarming cancels the total timer synchronously, so once the drain sleeper (121s) exists there
    // must be no sleeper left at the total deadline (120s); a missing disarm fails here, not by a race.
    try await clock.waitForSleeper(at: .seconds(121))
    #expect(!clock.hasSleeper(at: .seconds(120)))
    clock.advance(by: .seconds(2))
    let result = try await probe.finished()
    #expect(result.events == [.text("start"), .finished(.stop)])
    #expect(result.error == nil)
  }
  @Test func midLineCloseIsTransport() async throws {
    let fixture = Fixture(
      .openai,
      scripts: [
        [
          .data(sse(#"{"choices":[{"delta":{"content":"partial"}}]}"#)),
          .data(Data(#"data: {"choices":[{"delta":{"content":"cu"#.utf8)), .end,
        ]
      ])
    let result = try await bounded { await collect(fixture.stream()) }
    #expect(result.events == [.text("partial")])
    #expect(result.error == .transport)
  }
  @Test func consumerTaskCancellation() async throws {
    let fixture = Fixture(.compatible, scripts: [[.hang]])
    let stream = fixture.stream()
    let consumer = Task { for try await _ in stream {} }
    try await fixture.waitForRequests(1)
    consumer.cancel()
    do { try await bounded { try await consumer.value } } catch is CancellationError {}
    try await fixture.waitForStop()
  }
}
