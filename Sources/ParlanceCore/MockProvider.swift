import Foundation
import os

public struct MockProvider: LLMProvider {
  public enum Step: Sendable {
    case event(LLMEvent)
    case delay(Duration)
    case error(LLMError)
    case hang
  }
  private final class Storage: Sendable {
    let requests = OSAllocatedUnfairLock(initialState: [LLMRequest]())
  }
  private let storage = Storage()
  private let scripts: [[Step]]
  private let clock: any Clock<Duration>
  public init(scripts: [[Step]], clock: any Clock<Duration> = ContinuousClock()) {
    self.scripts = scripts
    self.clock = clock
  }
  public var recordedRequests: [LLMRequest] { storage.requests.withLock { $0 } }
  public func stream(_ request: LLMRequest, cancellation: LLMCancellation) -> AsyncThrowingStream<
    LLMEvent, any Error
  > {
    let index = storage.requests.withLock { requests in
      requests.append(request)
      return requests.count - 1
    }
    let steps = scripts.isEmpty ? [] : scripts[min(index, scripts.count - 1)]
    let operation = MockOperation(cancellation: cancellation)
    let (stream, continuation) = AsyncThrowingStream<LLMEvent, any Error>.makeStream()
    operation.start(continuation: continuation, steps: steps, clock: clock)
    return stream
  }
}
private final class MockOperation: Sendable {
  struct State {
    var continuation: AsyncThrowingStream<LLMEvent, any Error>.Continuation?
    var task: Task<Void, Never>?
    var ended = false
    var hasText = false
  }
  let state = OSAllocatedUnfairLock(initialState: State())
  let cancellation: LLMCancellation
  init(cancellation: LLMCancellation) { self.cancellation = cancellation }
  func start(
    continuation: AsyncThrowingStream<LLMEvent, any Error>.Continuation, steps: [MockProvider.Step],
    clock: any Clock<Duration>
  ) {
    state.withLock { $0.continuation = continuation }
    continuation.onTermination = { [self] _ in end(.aborted) }
    cancellation.onCancel { [weak self] in self?.end(.aborted) }
    state.withLock { state in
      guard !state.ended else { return }
      state.task = Task { [self] in
        do {
          for step in steps {
            if cancellation.isCancelled || Task.isCancelled {
              end(.aborted)
              return
            }
            switch step {
            case .event(let event):
              let finished = self.state.withLock { state in
                guard !state.ended else { return true }
                if case .finished = event { return true }
                if case .text(let text) = event, !text.isEmpty { state.hasText = true }
                state.continuation?.yield(event)
                return false
              }
              if finished {
                if case .finished(let reason) = event { end(nil, reason: reason) }
                return
              }
            case .delay(let duration): try await clock.sleep(for: duration)
            case .error(let error):
              end(error)
              return
            case .hang:
              // The continuation retains the operation until cancellation.
              return
            }
          }
          end(self.state.withLock { $0.hasText ? .transport : .emptyResponse })
        } catch { end(.aborted) }
      }
    }
  }
  func end(_ error: LLMError?, reason: LLMFinishReason? = nil) {
    let result = state.withLock {
      state -> (AsyncThrowingStream<LLMEvent, any Error>.Continuation, LLMError?)? in
      guard !state.ended, let continuation = state.continuation else { return nil }
      state.ended = true
      let finalError =
        cancellation.isCancelled ? .aborted : error ?? (state.hasText ? nil : .emptyResponse)
      if finalError == nil, let reason { continuation.yield(.finished(reason)) }
      state.task?.cancel()
      state.task = nil
      state.continuation = nil
      return (continuation, finalError)
    }
    if let (continuation, error) = result { continuation.finish(throwing: error) }
  }
}
