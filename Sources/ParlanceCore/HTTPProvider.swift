import Foundation
import os

public struct HTTPProvider: LLMProvider {
  public enum Limits: Sendable {
    public static let defaultMaxTokens = 16384
    // Sized for adaptive thinking (#89): thinking time counts toward this limit, so it leaves room
    // well beyond the first-text times measured in docs/notes/2026-10-11-prompt-eval-baseline.md.
    public static let firstToken: Duration = .seconds(30)
    public static let idle: Duration = .seconds(15)
    public static let total: Duration = .seconds(120)
    public static let usageDrain: Duration = .seconds(2)
    public static let maxRetryAfter: Duration = .seconds(5)
  }
  private let provider: ResolvedProvider
  private let session: URLSession
  private let clock: any Clock<Duration>
  private let jitter: @Sendable (ClosedRange<Int>) -> Int
  internal var afterTerminalRecorded: (@Sendable () -> Void)?
  /// `session` must stay valid while streams started on it are live: a session that is invalidated
  /// during an active request ends that stream with `transport`, but Foundation raises an uncatchable
  /// exception when a task is created on an invalidated session, so invalidating it during the retry
  /// wait is a caller error. Cancel the streams first, then invalidate.
  public init(
    provider: ResolvedProvider, session: URLSession, clock: any Clock<Duration> = ContinuousClock(),
    jitter: @escaping @Sendable (ClosedRange<Int>) -> Int = { Int.random(in: $0) }
  ) {
    self.provider = provider
    self.session = session
    self.clock = clock
    self.jitter = jitter
  }
  public func stream(_ request: LLMRequest, cancellation: LLMCancellation) -> AsyncThrowingStream<
    LLMEvent, any Error
  > {
    let (stream, continuation) = AsyncThrowingStream<LLMEvent, any Error>.makeStream()
    let operation = ChatOperation(
      provider: provider, session: session, clock: clock, jitter: jitter,
      cancellation: cancellation, continuation: continuation, hook: afterTerminalRecorded)
    operation.start(request)
    return stream
  }
}

// Delegate callbacks and timer tasks share only lock-protected state.
private final class ChatOperation: NSObject, URLSessionDataDelegate {
  enum Outcome {
    case failure(LLMError)
    case success
  }
  enum TimerKind: Hashable { case first, idle, total, drain }
  struct State {
    var continuation: AsyncThrowingStream<LLMEvent, any Error>.Continuation?
    var task: URLSessionDataTask?
    var retryTask: Task<Void, Never>?
    var timers: [TimerKind: (UUID, Task<Void, Never>)] = [:]
    var request: URLRequest?
    var parser = SSEParser()
    var response: HTTPURLResponse?
    var errorBody = Data()
    var hasText = false
    var reason: LLMFinishReason?
    var promptTokens = 0
    var usage: LLMUsage?
    var pending: Outcome?
    var committed = false
    var attempts = 0
  }
  private let state: OSAllocatedUnfairLock<State>
  private let provider: ResolvedProvider
  private let session: URLSession
  private let clock: any Clock<Duration>
  private let jitter: @Sendable (ClosedRange<Int>) -> Int
  private let cancellation: LLMCancellation
  private let hook: (@Sendable () -> Void)?
  init(
    provider: ResolvedProvider, session: URLSession, clock: any Clock<Duration>,
    jitter: @escaping @Sendable (ClosedRange<Int>) -> Int, cancellation: LLMCancellation,
    continuation: AsyncThrowingStream<LLMEvent, any Error>.Continuation,
    hook: (@Sendable () -> Void)?
  ) {
    self.provider = provider
    self.session = session
    self.clock = clock
    self.jitter = jitter
    self.cancellation = cancellation
    self.hook = hook
    state = OSAllocatedUnfairLock(initialState: State(continuation: continuation))
  }
  func start(_ request: LLMRequest) {
    let continuation = state.withLock { $0.continuation }
    continuation?.onTermination = { [self] _ in cancel() }
    cancellation.onCancel { [weak self] in self?.cancel() }
    do {
      try provider.override?.validate()
      guard provider.reasoningValidationError() == nil else {
        record(.failure(.invalidRequest(status: 400, providerCode: nil)))
        return
      }
      let path = provider.preset.wire == .anthropicMessages ? "messages" : "chat/completions"
      var urlRequest = URLRequest(url: provider.baseURL.appendingPathComponent(path))
      urlRequest.httpMethod = "POST"
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
      switch provider.preset.wire {
      case .chatCompletions:
        if let key = provider.apiKey {
          urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
      case .anthropicMessages:
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let key = provider.apiKey { urlRequest.setValue(key, forHTTPHeaderField: "x-api-key") }
      }
      urlRequest.httpBody = try JSONEncoder().encode(provider.requestBody(for: request))
      let preparedRequest = urlRequest
      state.withLock { state in
        guard !state.committed else { return }
        state.request = preparedRequest
        arm(.total, after: HTTPProvider.Limits.total, state: &state)
      }
      launch()
    } catch { record(.failure(.invalidRequest(status: 400, providerCode: nil))) }
  }
  private func launch() {
    let shouldCommit = state.withLock { state in
      guard !state.committed, state.pending == nil, let request = state.request else {
        return false
      }
      if cancellation.isCancelled {
        state.pending = .failure(.aborted)
        return true
      }
      state.attempts += 1
      state.parser = SSEParser()
      state.response = nil
      state.errorBody = Data()
      state.reason = nil
      state.usage = nil
      state.promptTokens = 0
      let task = session.dataTask(with: request)
      task.delegate = self
      state.task = task
      arm(.first, after: provider.firstTextTimeout, state: &state)
      task.resume()
      return false
    }
    if shouldCommit { commit() }
  }
  private func disarm(_ kind: TimerKind, state: inout State) {
    state.timers.removeValue(forKey: kind)?.1.cancel()
  }
  private func arm(_ kind: TimerKind, after duration: Duration, state: inout State) {
    disarm(kind, state: &state)
    let id = UUID()
    let task = clock.scheduled(after: duration) { [weak self] in self?.timerFired(kind, id: id) }
    state.timers[kind] = (id, task)
  }
  private func timerFired(_ kind: TimerKind, id: UUID) {
    let action = state.withLock { state -> (Bool, URLSessionDataTask?) in
      guard !state.committed, state.pending == nil, state.timers[kind]?.0 == id else {
        return (false, nil)
      }
      switch kind {
      case .drain: state.pending = state.hasText ? .success : .failure(.emptyResponse)
      case .first: state.pending = .failure(.timeout(.firstToken))
      case .idle: state.pending = .failure(.timeout(.idle))
      case .total: state.pending = .failure(.timeout(.total))
      }
      return (true, state.task)
    }
    guard action.0 else { return }
    hook?()
    if let task = action.1 { task.cancel() } else { commit() }
  }
  private func cancel() {
    let task = state.withLock { state -> URLSessionDataTask? in
      guard !state.committed else { return nil }
      state.pending = .failure(.aborted)
      state.retryTask?.cancel()
      state.retryTask = nil
      return state.task
    }
    if let task { task.cancel() } else { commit() }
  }
  private func record(_ outcome: Outcome) {
    let action = state.withLock { state -> (Bool, URLSessionDataTask?) in
      guard !state.committed, state.pending == nil else { return (false, nil) }
      state.pending = outcome
      return (true, state.task)
    }
    guard action.0 else { return }
    if let task = action.1 { task.cancel() } else { commit() }
  }
  private func commit() {
    let result = state.withLock {
      state -> (AsyncThrowingStream<LLMEvent, any Error>.Continuation, LLMError?)? in
      guard !state.committed, let pending = state.pending, let continuation = state.continuation
      else { return nil }
      // Finish outside this lock: onTermination can synchronously call cancel().
      let outcome: Outcome = cancellation.isCancelled ? .failure(.aborted) : pending
      state.committed = true
      for (_, timer) in state.timers.values { timer.cancel() }
      state.timers.removeAll()
      state.retryTask?.cancel()
      state.retryTask = nil
      state.task = nil
      state.continuation = nil
      switch outcome {
      case .failure(let error): return (continuation, error)
      case .success:
        if let usage = state.usage { continuation.yield(.usage(usage)) }
        continuation.yield(.finished(state.reason ?? .other))
        return (continuation, nil)
      }
    }
    if let (continuation, error) = result { continuation.finish(throwing: error) }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
    record(.failure(.invalidRequest(status: response.statusCode, providerCode: nil)))
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    let accept = state.withLock { state in
      guard !state.committed, state.pending == nil, state.task === dataTask else { return false }
      state.response = response as? HTTPURLResponse
      return true
    }
    completionHandler(accept ? .allow : .cancel)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let stop = state.withLock { state in
      guard !state.committed, state.pending == nil, state.task === dataTask else { return false }
      guard let response = state.response else {
        state.pending = .failure(.malformedResponse)
        return true
      }
      if !(200..<300).contains(response.statusCode) {
        state.errorBody.append(data)
        return false
      }
      if state.hasText && state.reason == nil {
        arm(.idle, after: HTTPProvider.Limits.idle, state: &state)
      }
      let items = state.parser.feed(data)
      consume(items, state: &state)
      return state.pending != nil
    }
    if stop { dataTask.cancel() }
  }
  private func consume(_ items: [SSEParser.Item], state: inout State) {
    for item in items {
      guard state.pending == nil else { break }
      guard case .event(let event) = item else { continue }
      if event.data == "[DONE]" {
        state.pending =
          state.reason != nil && state.hasText
          ? .success : .failure(state.hasText ? .transport : .emptyResponse)
        continue
      }
      guard let bytes = event.data.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
      else {
        state.pending = .failure(.malformedResponse)
        continue
      }
      if provider.preset.wire == .anthropicMessages {
        consumeMessage(json, state: &state)
        continue
      }
      // A usage-only chunk may omit `choices` altogether; only a non-object payload is malformed.
      let choices = json["choices"] as? [[String: Any]] ?? []
      if let usage = json["usage"] as? [String: Any], let prompt = usage["prompt_tokens"] as? Int,
        let completion = usage["completion_tokens"] as? Int
      {
        state.usage = LLMUsage(
          promptTokens: prompt, completionTokens: completion,
          reasoningTokens: (usage["completion_tokens_details"] as? [String: Any])?[
            "reasoning_tokens"] as? Int)
        if state.reason != nil {
          state.pending = state.hasText ? .success : .failure(.emptyResponse)
          continue
        }
      }
      guard state.reason == nil, let choice = choices.first else { continue }
      // Timers are armed before the text is yielded, so a consumer that has seen an event can rely
      // on the timer that event implies (the usage drain after finish_reason) being in place.
      var text: String?
      if let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String,
        !content.isEmpty
      {
        guard !cancellation.isCancelled else {
          state.pending = .failure(.aborted)
          continue
        }
        state.hasText = true
        text = content
        disarm(.first, state: &state)
        arm(.idle, after: HTTPProvider.Limits.idle, state: &state)
      }
      defer { if let text { state.continuation?.yield(.text(text)) } }
      if let reason = choice["finish_reason"] as? String {
        switch reason {
        case "stop": state.reason = .stop
        case "length": state.reason = .length
        case "content_filter": state.reason = .contentFilter
        default: state.reason = .other
        }
        disarm(.first, state: &state)
        disarm(.idle, state: &state)
        if state.hasText { disarm(.total, state: &state) }
        if provider.preset.requestsStreamUsage {
          arm(.drain, after: HTTPProvider.Limits.usageDrain, state: &state)
        } else {
          state.pending = state.hasText ? .success : .failure(.emptyResponse)
        }
      }
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    state.withLock { state in
      guard !state.committed, state.task === task else { return }
      state.task = nil
      disarm(.first, state: &state)
      disarm(.idle, state: &state)
      disarm(.drain, state: &state)
      if cancellation.isCancelled { state.pending = .failure(.aborted) }
      let externallyCancelled = (error as? URLError)?.code == .cancelled && state.pending == nil
      if let pending = state.pending {
        guard case .failure = pending else { return }
      } else if externallyCancelled {
        state.pending = .failure(.transport)
      } else if let response = state.response, !(200..<300).contains(response.statusCode) {
        state.pending = .failure(httpError(response, body: state.errorBody))
      } else if error != nil {
        state.pending = .failure(.transport)
      } else {
        let tail = state.parser.finish()
        consume(tail, state: &state)
        if state.pending == nil {
          state.pending =
            state.reason != nil && state.hasText
            ? .success : .failure(state.hasText ? .transport : .emptyResponse)
        }
      }
      // An externally invalidated session cannot be used for another attempt.
      if !externallyCancelled, case .failure(let failure) = state.pending, !state.hasText,
        state.attempts == 1, let delay = retryDelay(failure), !cancellation.isCancelled
      {
        state.pending = nil
        // Scheduled before the event is yielded: once a consumer sees `.retrying`, the wait exists.
        state.retryTask = clock.scheduled(after: delay) { [weak self] in self?.launch() }
        state.continuation?.yield(.retrying(after: delay, cause: failure.code))
      }
    }
    commit()
  }
  private func consumeMessage(_ json: [String: Any], state: inout State) {
    switch json["type"] as? String {
    case "message_start":
      let message = json["message"] as? [String: Any]
      let usage = message?["usage"] as? [String: Any]
      state.promptTokens =
        (usage?["input_tokens"] as? Int ?? 0)
        + (usage?["cache_creation_input_tokens"] as? Int ?? 0)
        + (usage?["cache_read_input_tokens"] as? Int ?? 0)
    case "content_block_delta":
      guard let delta = json["delta"] as? [String: Any],
        delta["type"] as? String == "text_delta", let text = delta["text"] as? String,
        !text.isEmpty
      else { return }
      guard !cancellation.isCancelled else {
        state.pending = .failure(.aborted)
        return
      }
      state.hasText = true
      disarm(.first, state: &state)
      arm(.idle, after: HTTPProvider.Limits.idle, state: &state)
      state.continuation?.yield(.text(text))
    case "message_delta":
      // Usage is cumulative; only a message_delta that carries a stop_reason ends the message.
      let usage = json["usage"] as? [String: Any]
      state.usage = LLMUsage(
        promptTokens: state.promptTokens,
        completionTokens: usage?["output_tokens"] as? Int ?? state.usage?.completionTokens ?? 0,
        reasoningTokens: (usage?["output_tokens_details"] as? [String: Any])?["thinking_tokens"]
          as? Int ?? state.usage?.reasoningTokens)
      guard let reason = (json["delta"] as? [String: Any])?["stop_reason"] as? String else {
        return
      }
      switch reason {
      case "end_turn", "stop_sequence": state.reason = .stop
      case "max_tokens", "model_context_window_exceeded": state.reason = .length
      case "refusal": state.reason = .contentFilter
      default: state.reason = .other
      }
      state.pending = state.hasText ? .success : .failure(.emptyResponse)
    case "error":
      let error = json["error"] as? [String: Any]
      let failure: LLMError
      switch error?["type"] as? String {
      case "overloaded_error": failure = .server(status: 529)
      case "api_error": failure = .server(status: 500)
      case "timeout_error": failure = .server(status: 504)
      case "rate_limit_error":
        failure = isSpendCap(error) ? .quota(status: 429) : .rateLimit(retryAfter: nil)
      case "authentication_error", "permission_error": failure = .auth(status: nil)
      case "billing_error": failure = .quota(status: 402)
      case "invalid_request_error", "not_found_error", "request_too_large", "conflict_error":
        failure = .invalidRequest(status: 400, providerCode: nil)
      default: failure = .transport
      }
      state.pending = .failure(failure)
    default: break
    }
  }
  /// The Messages API reports the monthly spend cap as a 429 whose `error.details.error_code` is set.
  private func isSpendCap(_ error: [String: Any]?) -> Bool {
    (error?["details"] as? [String: Any])?["error_code"] as? String
      == "enforced_spend_limit_reached"
  }
  private func retryDelay(_ error: LLMError) -> Duration? {
    switch error {
    case .rateLimit(let after):
      if let after { return after <= HTTPProvider.Limits.maxRetryAfter ? after : nil }
    case .server, .transport, .emptyResponse: break
    default: return nil
    }
    return .milliseconds(max(500, min(1500, jitter(500...1500))))
  }
  private func httpError(_ response: HTTPURLResponse, body: Data) -> LLMError {
    let decoded = try? JSONSerialization.jsonObject(with: body)
    let object = (decoded as? [String: Any]) ?? (decoded as? [[String: Any]])?.first
    let fields = object?["error"] as? [String: Any]
    let code = fields?["code"] as? String
    let type = fields?["type"] as? String
    let status = fields?["status"] as? String
    let statusCode = response.statusCode
    switch statusCode {
    case 401, 403: return .auth(status: statusCode)
    case 402: return .quota(status: statusCode)
    case 429:
      if provider.preset.id == "openai" && [code, type, status].contains("insufficient_quota") {
        return .quota(status: statusCode)
      }
      if provider.preset.wire == .anthropicMessages && isSpendCap(fields) {
        return .quota(status: statusCode)
      }
      let value = response.value(forHTTPHeaderField: "Retry-After")
      let seconds = value.flatMap { text -> Int64? in
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(text)
      }
      return .rateLimit(retryAfter: seconds.map { .seconds($0) })
    case 408, 500...599: return .server(status: statusCode)
    default:
      return .invalidRequest(
        status: statusCode,
        providerCode: [code, type, status].compactMap {
          $0.flatMap(KnownProviderCode.init(rawValue:))
        }.first)
    }
  }
}

extension Clock where Duration == Swift.Duration {
  fileprivate func scheduled(after duration: Duration, action: @escaping @Sendable () -> Void)
    -> Task<Void, Never>
  {
    let deadline = now.advanced(by: duration)
    return Task {
      do { try await self.sleep(until: deadline, tolerance: nil) } catch { return }
      guard !Task.isCancelled else { return }
      action()
    }
  }
}
