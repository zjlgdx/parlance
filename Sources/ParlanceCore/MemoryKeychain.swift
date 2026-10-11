import Foundation
import Security
import os

/// In-memory storage with persistent, per-account failures for CLI and App tests. Each operation
/// branches the way `KeychainStore` does: `exists` reports an injected `.notFound` as `false`, and an
/// empty secret is rejected before the injected failure is consulted.
public final class MemoryKeychain: KeychainStoring {
  private struct State: Sendable {
    var secrets: [String: String]
    var failures: [String: KeychainError] = [:]
  }

  private let state: OSAllocatedUnfairLock<State>

  public init(initial: [String: String] = [:]) {
    state = OSAllocatedUnfairLock(initialState: State(secrets: initial))
  }

  /// Every later operation on `account` throws `error` instead of acting, with one exception that
  /// mirrors the real store: `exists` reports an injected `.notFound` as `false`. Inject only errors the
  /// real store can produce for the operation under test; the fake does not translate them.
  public func fail(account: String, with error: KeychainError) {
    state.withLock { $0.failures[account] = error }
  }

  public var secrets: [String: String] { state.withLock { $0.secrets } }

  public func read(account: String) throws -> String {
    try state.withLock {
      if let error = $0.failures[account] { throw error }
      guard let secret = $0.secrets[account] else { throw KeychainError.notFound }
      return secret
    }
  }

  public func exists(account: String) throws -> Bool {
    try state.withLock {
      if let error = $0.failures[account] {
        if error == .notFound { return false }
        throw error
      }
      return $0.secrets[account] != nil
    }
  }

  public func write(account: String, secret: String) throws {
    guard !secret.isEmpty else { throw KeychainError.other(errSecParam) }
    try state.withLock {
      if let error = $0.failures[account] { throw error }
      $0.secrets[account] = secret
    }
  }

  public func delete(account: String) throws {
    try state.withLock {
      if let error = $0.failures[account] { throw error }
      guard $0.secrets.removeValue(forKey: account) != nil else { throw KeychainError.notFound }
    }
  }
}
