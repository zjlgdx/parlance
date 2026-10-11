import Foundation
import Testing

@testable import ParlanceCore

struct MessagesWireTests {
  @Test func requestBody() {
    let provider = resolved(.claude)
    let messages: [LLMMessage] = [
      .init(role: .system, content: "First"), .init(role: .system, content: "Second"),
      .init(role: .user, content: "Question"), .init(role: .assistant, content: "Answer"),
    ]
    let request = LLMRequest(messages: messages)
    let body = provider.requestBody(for: request)
    #expect(HTTPProvider.Limits.defaultMaxTokens == 16384)
    #expect(body["max_tokens"] == .integer(16384))
    #expect(body["system"] == .string("First\nSecond"))
    #expect(
      body["messages"]
        == .array([
          .object(["role": .string("user"), "content": .string("Question")]),
          .object(["role": .string("assistant"), "content": .string("Answer")]),
        ]))
    #expect(body["stream_options"] == nil)
    #expect(body["stream"] == .bool(true))
    #expect(body["model"] == .string("claude-haiku-5-5"))
    #expect(provider.requestBody(for: .init(messages: []))["system"] == nil)
    #expect(
      provider.requestBody(for: .init(messages: [.init(role: .system, content: "")]))["system"]
        == nil)
    for field in [MaxOutputField.none, .maxCompletionTokens] {
      let override = ModelOverride(
        extraBody: ["output_config": .object(["effort": .string("high"), "extra": .bool(true)])],
        maxOutputField: field, systemRole: .developer)
      var provider = resolved(.claude, override: override)
      provider.preset.requestsStreamUsage = true
      provider.preset.modelProfiles[provider.model]?.maxOutputField = .maxCompletionTokens
      provider.preset.modelProfiles[provider.model]?.systemRole = .developer
      let body = provider.requestBody(for: .init(messages: messages, maxOutputTokens: 7))
      // Haiku thinks before answering, and its thinking counts toward max_tokens (#89).
      #expect(body["max_tokens"] == .integer(7 + 12288))
      #expect(body["max_completion_tokens"] == nil)
      #expect(body["system"] == .string("First\nSecond"))
      #expect(body["messages"] == bodyMessages())
      #expect(body["stream_options"] == nil)
      // claude-haiku-5-5 keeps the API default, adaptive thinking (#89).
      #expect(body["thinking"] == nil)
      #expect(
        body["output_config"] == .object(["effort": .string("high"), "extra": .bool(true)]))
    }
    let unknown = resolved(.claude, model: "off-table").requestBody(for: request)
    #expect(unknown["thinking"] == nil)
    #expect(unknown["output_config"] == nil)
    #expect(unknown["max_tokens"] == .integer(16384))
  }
  private func bodyMessages() -> JSONValue {
    .array([
      .object(["role": .string("user"), "content": .string("Question")]),
      .object(["role": .string("assistant"), "content": .string("Answer")]),
    ])
  }
  @Test(arguments: [false, true])
  func usageAndImmediateFinish(cache: Bool) async throws {
    let start =
      cache
      ? #"{"type":"message_start","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":5,"cache_read_input_tokens":7,"output_tokens":1}}}"#
      : #"{"type":"message_start","message":{"usage":{}}}"#
    let fixture = Fixture(
      .claude,
      scripts: [
        [
          .data(sse(start)),
          .data(sse(#"{"type":"content_block_start"}"#)),
          .data(
            sse(
              #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"secret","text":"secret"}}"#
            )),
          .data(
            sse(
              #"{"type":"content_block_delta","delta":{"type":"signature_delta","signature":"secret","text":"secret"}}"#
            )),
          .data(
            sse(#"{"type":"content_block_delta","delta":{"type":"unknown_delta","text":"secret"}}"#)
          ),
          .data(sse(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":""}}"#)),
          .data(sse(#"{"type":"content_block_stop"}"#)),
          .data(sse(#"{"type":"future_event","text":"secret"}"#)),
          // An unrelated SSE event name must not override the JSON type.
          .data(Data("event: error\n".utf8) + textChunk("hello", preset: .claude)),
          .data(
            finishChunk("stop", preset: .claude)
              + sse(#"{"type":"message_stop"}"#) + textChunk("late", preset: .claude)), .hang,
        ]
      ])
    let result = try await bounded { await collect(fixture.stream()) }
    #expect(result.error == nil)
    #expect(
      result.events == [
        .text("hello"), .usage(.init(promptTokens: cache ? 14 : 0, completionTokens: 3)),
        .finished(.stop),
      ])
    try await fixture.waitForStop()
  }
  @Test(arguments: [
    "end_turn", "stop_sequence", "max_tokens", "model_context_window_exceeded", "refusal",
    "unknown",
  ])
  func stopReasons(reason: String) async throws {
    let fixture = Fixture(
      .claude,
      scripts: [
        [
          .data(textChunk("hello", preset: .claude)),
          .data(
            sse(
              "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(reason)\"},\"usage\":{\"output_tokens\":3}}"
            )), .hang,
        ]
      ])
    let expected: LLMFinishReason =
      switch reason {
      case "end_turn", "stop_sequence": .stop
      case "max_tokens", "model_context_window_exceeded": .length
      case "refusal": .contentFilter
      default: .other
      }
    let result = try await bounded { await collect(fixture.stream()) }
    #expect(result.error == nil)
    #expect(
      result.events == [
        .text("hello"), .usage(.init(promptTokens: 0, completionTokens: 3)), .finished(expected),
      ])
  }
  @Test(arguments: [402, 429, 529])
  func httpErrors(status: Int) async throws {
    let clock = ManualClock()
    let fixture = Fixture(
      .claude, status: status,
      scripts: [
        [
          .data(
            Data(
              #"{"type":"error","error":{"type":"rate_limit_error","details":{"error_code":"enforced_spend_limit_reached"}}}"#
                .utf8)), .end,
        ]
      ], clock: clock)
    let probe = Probe(fixture.stream())
    if status == 529 {
      #expect(try await probe.next() == .retrying(after: .milliseconds(500), cause: .server))
      try await clock.waitForSleeper(at: .milliseconds(500))
      clock.advance(by: .milliseconds(500))
    }
    let result = try await probe.finished()
    #expect(result.error == (status == 529 ? .server(status: 529) : .quota(status: status)))
    #expect(
      result.events == (status == 529 ? [.retrying(after: .milliseconds(500), cause: .server)] : [])
    )
    #expect(fixture.requests.count == (status == 529 ? 2 : 1))
  }
  @Test(
    arguments: [
      "overloaded_error", "api_error", "timeout_error", "rate_limit_error", "authentication_error",
      "permission_error", "billing_error", "invalid_request_error", "not_found_error",
      "request_too_large", "conflict_error", "spend_cap", "unknown",
    ], [false, true])
  func streamErrors(type: String, afterText: Bool) async throws {
    let expected: LLMError =
      switch type {
      case "overloaded_error": .server(status: 529)
      case "api_error": .server(status: 500)
      case "timeout_error": .server(status: 504)
      case "rate_limit_error": .rateLimit(retryAfter: nil)
      case "spend_cap": .quota(status: 429)
      case "authentication_error", "permission_error": .auth(status: nil)
      case "billing_error": .quota(status: 402)
      case "invalid_request_error", "not_found_error", "request_too_large", "conflict_error":
        .invalidRequest(status: 400, providerCode: nil)
      default: .transport
      }
    // The spend cap is a rate_limit_error whose details carry the structured code.
    let payload =
      type == "spend_cap"
      ? #"{"type":"error","error":{"type":"rate_limit_error","message":"private","details":{"error_code":"enforced_spend_limit_reached"}}}"#
      : "{\"type\":\"error\",\"error\":{\"type\":\"\(type)\",\"message\":\"private\"}}"
    let retry = !afterText && [.server, .rateLimit, .transport].contains(expected.code)
    let clock = ManualClock()
    let steps: [Harness.Step] =
      (afterText ? [.data(textChunk("partial", preset: .claude))] : []) + [
        .data(sse(payload)), .hang,
      ]
    let fixture = Fixture(.claude, scripts: [steps], clock: clock)
    let probe = Probe(fixture.stream())
    if retry {
      #expect(try await probe.next() == .retrying(after: .milliseconds(500), cause: expected.code))
      try await clock.waitForSleeper(at: .milliseconds(500))
      clock.advance(by: .milliseconds(500))
    }
    let result = try await probe.finished()
    #expect(result.error == expected)
    #expect(
      result.events
        == (afterText
          ? [.text("partial")]
          : (retry ? [.retrying(after: .milliseconds(500), cause: expected.code)] : [])))
    #expect(fixture.requests.count == (retry ? 2 : 1))
  }
  @Test func textTimers() async throws {
    let clock = ManualClock()
    let fixture = Fixture(.claude, scripts: [[.hang]], clock: clock)
    let probe = Probe(fixture.stream())
    try await fixture.waitForRequests(1)
    try await clock.waitForSleeper(at: HTTPProvider.Limits.firstToken)
    let task = try await dataTask(fixture)
    deliver(textChunk("first", preset: .claude), fixture: fixture, task: task)
    #expect(try await probe.next() == .text("first"))
    try await clock.waitForSleeper(at: .seconds(15))
    #expect(!clock.hasSleeper(at: HTTPProvider.Limits.firstToken))
    clock.advance(by: .seconds(14))
    deliver(textChunk("second", preset: .claude), fixture: fixture, task: task)
    #expect(try await probe.next() == .text("second"))
    try await clock.waitForSleeper(at: .seconds(29))
    clock.advance(by: .seconds(15))
    let result = try await probe.finished()
    #expect(result.events == [.text("first"), .text("second")])
    #expect(result.error == .timeout(.idle))
    #expect(fixture.requests.count == 1)
  }
  // claude-haiku-5-5 thinks before its first text (#89); none of these events is text.
  @Test func thinkingEventsDoNotStopFirstTokenTimer() async throws {
    let clock = ManualClock()
    let fixture = Fixture(.claude, scripts: [[.hang]], clock: clock)
    let probe = Probe(fixture.stream())
    try await fixture.waitForRequests(1)
    let task = try await dataTask(fixture)
    clock.advance(by: HTTPProvider.Limits.firstToken - .seconds(1))
    for event in [
      #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"x"}}"#,
      #"{"type":"ping"}"#,
      #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":""}}"#,
    ] {
      deliver(sse(event), fixture: fixture, task: task)
    }
    clock.advance(by: .seconds(1))
    let result = try await probe.finished()
    #expect(result.events.isEmpty)
    #expect(result.error == .timeout(.firstToken))
  }
  @Test func nullStopReasonIsNotTerminal() async throws {
    let fixture = Fixture(
      .claude,
      scripts: [
        [
          .data(textChunk("hello", preset: .claude)),
          .data(
            sse(
              #"{"type":"message_delta","delta":{"stop_reason":null},"usage":{"output_tokens":2}}"#)
          ),
          .data(textChunk(" again", preset: .claude)),
          .data(sse(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#)), .hang,
        ]
      ])
    let result = try await bounded { await collect(fixture.stream()) }
    #expect(result.error == nil)
    #expect(
      result.events == [
        .text("hello"), .text(" again"), .usage(.init(promptTokens: 0, completionTokens: 2)),
        .finished(.stop),
      ])
  }
  @Test func thinkingTokensBecomeReasoningTokens() async throws {
    let fixture = Fixture(
      .claude,
      scripts: [
        [
          .data(textChunk("hello", preset: .claude)),
          .data(
            sse(
              #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5,"output_tokens_details":{"thinking_tokens":3}}}"#
            )), .hang,
        ]
      ])
    let result = try await bounded { await collect(fixture.stream()) }
    #expect(result.error == nil)
    #expect(
      result.events == [
        .text("hello"),
        .usage(.init(promptTokens: 0, completionTokens: 5, reasoningTokens: 3)),
        .finished(.stop),
      ])
  }
  @Test func missingUsageDefaultsToZero() async throws {
    let fixture = Fixture(
      .claude,
      scripts: [
        [
          .data(textChunk("hello", preset: .claude)),
          .data(sse(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#)), .hang,
        ]
      ])
    let result = try await bounded { await collect(fixture.stream()) }
    #expect(result.error == nil)
    #expect(
      result.events == [
        .text("hello"), .usage(.init(promptTokens: 0, completionTokens: 0)), .finished(.stop),
      ])
  }
  @Test func pingExtendsIdle() async throws {
    let clock = ManualClock()
    let fixture = Fixture(
      .claude, scripts: [[.data(textChunk("start", preset: .claude)), .hang]], clock: clock)
    let probe = Probe(fixture.stream())
    #expect(try await probe.next() == .text("start"))
    let task = try await dataTask(fixture)
    clock.advance(by: .seconds(14))
    deliver(sse(#"{"type":"ping"}"#), fixture: fixture, task: task)
    try await clock.waitForSleeper(at: .seconds(29))
    clock.advance(by: .seconds(14))
    deliver(finishChunk("stop", preset: .claude), fixture: fixture, task: task)
    let result = try await probe.finished()
    #expect(result.error == nil)
    #expect(
      result.events == [
        .text("start"), .usage(.init(promptTokens: 0, completionTokens: 3)), .finished(.stop),
      ])
  }
  @Test(arguments: ["[]", "broken"])
  func malformedPayload(payload: String) async throws {
    let fixture = Fixture(.claude, scripts: [[.data(sse(payload)), .hang]])
    let result = try await bounded { await collect(fixture.stream()) }
    #expect(result.error == .malformedResponse)
    #expect(result.events.isEmpty)
    #expect(fixture.requests.count == 1)
  }
  @Test(arguments: [false, true])
  func emptyTerminalRetries(done: Bool) async throws {
    let clock = ManualClock()
    let fixture = Fixture(
      .claude,
      scripts: [
        [
          .data(sse(#"{"type":"message_start","message":{"usage":{"input_tokens":99}}}"#)),
          .data(done ? sse("[DONE]") : finishChunk("stop", preset: .claude)), .hang,
        ],
        [
          .data(textChunk("hello", preset: .claude)), .data(finishChunk("stop", preset: .claude)),
          .hang,
        ],
      ], clock: clock)
    let probe = Probe(fixture.stream())
    #expect(try await probe.next() == .retrying(after: .milliseconds(500), cause: .emptyResponse))
    try await clock.waitForSleeper(at: .milliseconds(500))
    clock.advance(by: .milliseconds(500))
    let result = try await probe.finished()
    #expect(result.error == nil)
    #expect(
      result.events == [
        .retrying(after: .milliseconds(500), cause: .emptyResponse), .text("hello"),
        .usage(.init(promptTokens: 0, completionTokens: 3)), .finished(.stop),
      ])
    #expect(fixture.requests.count == 2)
  }
}
