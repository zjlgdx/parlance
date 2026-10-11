import Foundation
import os

@testable import ParlanceCore

/// Stable test-only representation; no request, headers, credentials or arbitrary error descriptions.
struct RecordedDuration: Codable, Sendable, Equatable {
  var seconds: Int64
  var attoseconds: Int64
  init(_ value: Duration) {
    seconds = value.components.seconds
    attoseconds = value.components.attoseconds
  }
  var value: Duration { Duration(secondsComponent: seconds, attosecondsComponent: attoseconds) }
}

enum RecordedFinish: String, Codable, Sendable {
  case stop, length, contentFilter, other
  init(_ value: LLMFinishReason) {
    switch value {
    case .stop: self = .stop
    case .length: self = .length
    case .contentFilter: self = .contentFilter
    case .other: self = .other
    }
  }
  var value: LLMFinishReason {
    switch self {
    case .stop: .stop
    case .length: .length
    case .contentFilter: .contentFilter
    case .other: .other
    }
  }
}

enum RecordedTimeout: String, Codable, Sendable {
  case firstToken, idle, total
  init(_ value: LLMTimeout) {
    switch value {
    case .firstToken: self = .firstToken
    case .idle: self = .idle
    case .total: self = .total
    }
  }
  var value: LLMTimeout {
    switch self {
    case .firstToken: .firstToken
    case .idle: .idle
    case .total: .total
    }
  }
}

enum RecordedError: Codable, Sendable, Equatable {
  case auth(status: Int?)
  case quota(status: Int)
  case invalidRequest(status: Int, modelNotFound: Bool)
  case rateLimit(retryAfter: RecordedDuration?)
  case server(status: Int)
  case transport, aborted, emptyResponse, malformedResponse
  case timeout(RecordedTimeout)

  init(_ error: LLMError) {
    switch error {
    case .auth(let status): self = .auth(status: status)
    case .quota(let status): self = .quota(status: status)
    case .invalidRequest(let status, let code):
      self = .invalidRequest(status: status, modelNotFound: code == .modelNotFound)
    case .rateLimit(let delay): self = .rateLimit(retryAfter: delay.map(RecordedDuration.init))
    case .server(let status): self = .server(status: status)
    case .transport: self = .transport
    case .aborted: self = .aborted
    case .emptyResponse: self = .emptyResponse
    case .malformedResponse: self = .malformedResponse
    case .timeout(let kind): self = .timeout(RecordedTimeout(kind))
    }
  }
  var value: LLMError {
    switch self {
    case .auth(let status): .auth(status: status)
    case .quota(let status): .quota(status: status)
    case .invalidRequest(let status, let found):
      .invalidRequest(status: status, providerCode: found ? .modelNotFound : nil)
    case .rateLimit(let delay): .rateLimit(retryAfter: delay?.value)
    case .server(let status): .server(status: status)
    case .transport: .transport
    case .aborted: .aborted
    case .emptyResponse: .emptyResponse
    case .malformedResponse: .malformedResponse
    case .timeout(let kind): .timeout(kind.value)
    }
  }
}

enum RecordedEvent: Codable, Sendable, Equatable {
  case text(String)
  case usage(promptTokens: Int, completionTokens: Int, reasoningTokens: Int?)
  case finished(RecordedFinish)
  case retrying(after: RecordedDuration, cause: LLMErrorCode)
  case failure(RecordedError)

  init(_ event: LLMEvent) {
    switch event {
    case .text(let text): self = .text(text)
    case .usage(let usage):
      self = .usage(
        promptTokens: usage.promptTokens, completionTokens: usage.completionTokens,
        reasoningTokens: usage.reasoningTokens)
    case .finished(let reason): self = .finished(RecordedFinish(reason))
    case .retrying(let delay, let cause):
      self = .retrying(after: RecordedDuration(delay), cause: cause)
    }
  }
  var step: MockProvider.Step {
    switch self {
    case .text(let text): .event(.text(text))
    case .usage(let prompt, let completion, let reasoning):
      .event(
        .usage(
          .init(promptTokens: prompt, completionTokens: completion, reasoningTokens: reasoning)))
    case .finished(let reason): .event(.finished(reason.value))
    case .retrying(let delay, let cause): .event(.retrying(after: delay.value, cause: cause))
    case .failure(let error): .error(error.value)
    }
  }
}

/// One provider.stream call. Chunk boundaries and event order are retained, including terminal errors.
struct Recording: Codable, Sendable, Equatable {
  var events: [RecordedEvent] = []
}

/// Wraps only the response boundary. A strict retry adds a second Recording.
final class RecordingProvider: LLMProvider {
  struct State {
    var attempts: [Recording] = []
    var firstToken: Duration?
  }
  let base: any LLMProvider
  let clock = ContinuousClock()
  let start: ContinuousClock.Instant
  private let state = OSAllocatedUnfairLock(initialState: State())
  init(_ base: any LLMProvider) {
    self.base = base
    start = clock.now
  }
  var attempts: [Recording] { state.withLock { $0.attempts } }
  var firstToken: Duration? { state.withLock { $0.firstToken } }
  var elapsed: Duration { start.duration(to: clock.now) }

  func stream(_ request: LLMRequest, cancellation: LLMCancellation) -> AsyncThrowingStream<
    LLMEvent, any Error
  > {
    let index = state.withLock {
      $0.attempts.append(Recording())
      return $0.attempts.count - 1
    }
    let (stream, continuation) = AsyncThrowingStream<LLMEvent, any Error>.makeStream()
    let task = Task {
      do {
        for try await event in base.stream(request, cancellation: cancellation) {
          state.withLock {
            $0.attempts[index].events.append(RecordedEvent(event))
            if case .text(let text) = event, !text.isEmpty, $0.firstToken == nil {
              $0.firstToken = start.duration(to: clock.now)
            }
          }
          continuation.yield(event)
        }
        continuation.finish()
      } catch {
        let failure = error as? LLMError ?? (Task.isCancelled ? .aborted : .transport)
        state.withLock { $0.attempts[index].events.append(.failure(RecordedError(failure))) }
        continuation.finish(throwing: failure)
      }
    }
    continuation.onTermination = { reason in
      if case .cancelled = reason {
        cancellation.cancel()
        task.cancel()
      }
    }
    return stream
  }
}
