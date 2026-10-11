import Foundation
import os

public protocol LLMProvider: Sendable {
  func stream(_ request: LLMRequest, cancellation: LLMCancellation) -> AsyncThrowingStream<
    LLMEvent, any Error
  >
}
public final class LLMCancellation: Sendable {
  private struct State {
    var cancelled = false
    var handlers: [@Sendable () -> Void] = []
  }
  private let state = OSAllocatedUnfairLock(initialState: State())
  public init() {}
  public var isCancelled: Bool { state.withLock { $0.cancelled } }
  public func cancel() {
    let handlers = state.withLock { state in
      guard !state.cancelled else { return [@Sendable () -> Void]() }
      state.cancelled = true
      let handlers = state.handlers
      state.handlers.removeAll()
      return handlers
    }
    for handler in handlers { handler() }
  }
  public func onCancel(_ handler: @escaping @Sendable () -> Void) {
    let immediately = state.withLock { state in
      if state.cancelled { return true }
      state.handlers.append(handler)
      return false
    }
    if immediately { handler() }
  }
}
public struct LLMRequest: Sendable, Equatable {
  public var messages: [LLMMessage]
  public var maxOutputTokens: Int?
  public init(messages: [LLMMessage], maxOutputTokens: Int? = nil) {
    self.messages = messages
    self.maxOutputTokens = maxOutputTokens
  }
}
public struct LLMMessage: Sendable, Equatable {
  public enum Role: String, Sendable { case system, user, assistant }
  public var role: Role
  public var content: String
  public init(role: Role, content: String) {
    self.role = role
    self.content = content
  }
}
public enum LLMEvent: Sendable, Equatable {
  case retrying(after: Duration, cause: LLMErrorCode)
  case text(String)
  case usage(LLMUsage)
  case finished(LLMFinishReason)
}
public struct LLMUsage: Sendable, Equatable {
  public var promptTokens: Int
  public var completionTokens: Int
  public var reasoningTokens: Int?
  public init(promptTokens: Int, completionTokens: Int, reasoningTokens: Int? = nil) {
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.reasoningTokens = reasoningTokens
  }
}
public enum LLMFinishReason: Sendable, Equatable { case stop, length, contentFilter, other }
public enum LLMTimeout: Sendable, Equatable { case firstToken, idle, total }
public enum KnownProviderCode: String, Sendable, Equatable {
  case modelNotFound = "model_not_found"
}
public enum LLMErrorCode: String, Sendable, Codable, CaseIterable {
  case auth, quota
  case invalidRequest = "invalid_request"
  case rateLimit = "rate_limit"
  case server, transport, timeout, aborted
  case emptyResponse = "empty_response"
  case malformedResponse = "malformed_response"
}
public enum LLMError: Error, Sendable, Equatable {
  case auth(status: Int?)
  case quota(status: Int)
  case invalidRequest(status: Int, providerCode: KnownProviderCode?)
  case rateLimit(retryAfter: Duration?)
  case server(status: Int)
  case transport
  case timeout(LLMTimeout)
  case aborted
  case emptyResponse
  case malformedResponse
  public var code: LLMErrorCode {
    switch self {
    case .auth: .auth
    case .quota: .quota
    case .invalidRequest: .invalidRequest
    case .rateLimit: .rateLimit
    case .server: .server
    case .transport: .transport
    case .timeout: .timeout
    case .aborted: .aborted
    case .emptyResponse: .emptyResponse
    case .malformedResponse: .malformedResponse
    }
  }
}
