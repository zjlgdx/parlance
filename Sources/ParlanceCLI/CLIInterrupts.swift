import Darwin
import Dispatch
import ParlanceCore
import os

/// Subscribes for interrupt counts and returns a function that removes the subscription.
public struct CLIInterruptSource: Sendable {
  public let subscribe: @Sendable (@escaping @Sendable (UInt) -> Void) -> @Sendable () -> Void

  public init(
    subscribe: @escaping @Sendable (@escaping @Sendable (UInt) -> Void) -> @Sendable () -> Void
  ) {
    self.subscribe = subscribe
  }

  public static let none = Self { _ in {} }

  static let process = Self { receive in
    let previous = signal(SIGINT, SIG_IGN)
    // A parent that ignores SIGINT (a background job of a script) keeps it ignored for `pl` too.
    // C function pointers are not Equatable; compare their addresses (SIG_IGN is address 1).
    let address = { (handler: sig_t?) in handler.map { unsafeBitCast($0, to: Int.self) } }
    if address(previous) == address(SIG_IGN) { return {} }
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler { [weak source] in
      if let source { receive(source.data) }
    }
    source.activate()
    return {
      source.cancel()
      signal(SIGINT, previous)
    }
  }
}

/// One command owns the subscription. Sequential operations can replace the active token,
/// but an interrupt permanently closes registration for that command.
final class CLIInterruptHandler: Sendable {
  private struct State {
    var token: LLMCancellation?
    var received: UInt = 0
    var interrupted = false
    var completed = false
  }
  private let state: OSAllocatedUnfairLock<State>
  private let unsubscribe: @Sendable () -> Void

  init(
    source: CLIInterruptSource, exitImmediately: @escaping @Sendable (Int32) -> Void,
    onInterrupt: @escaping @Sendable () -> Void = {},
    beforeImmediateExit: @escaping @Sendable () -> Void = {}
  ) {
    let state = OSAllocatedUnfairLock(initialState: State())
    self.state = state
    unsubscribe = source.subscribe { count in
      guard count > 0 else { return }
      let action = state.withLock { state -> (LLMCancellation?, Bool) in
        let second = state.received > 0 || count > 1
        state.received += count
        // A committed outcome stays; only a second interrupt (say, while output is blocked) exits.
        guard !state.completed else { return (nil, second) }
        state.interrupted = true
        return (state.token, second)
      }
      // A coalesced second interrupt takes the immediate path as well. Exit/cancellation must
      // precede best-effort UI cleanup, which must not hold up the signal callback.
      if action.1 {
        beforeImmediateExit()
        exitImmediately(130)
      }
      action.0?.cancel()
      onInterrupt()
    }
  }

  func beginOperation() throws -> LLMCancellation {
    try state.withLock { state in
      guard !state.interrupted && !state.completed else { throw LLMError.aborted }
      precondition(state.token == nil)
      let token = LLMCancellation()
      state.token = token
      return token
    }
  }

  func endOperation() { state.withLock { $0.token = nil } }

  /// Commits the command's terminal outcome before output. Later signals cannot change it; a
  /// second interrupt still exits immediately.
  /// The return value gives interruption precedence over a concurrently buffered result.
  func complete() -> Bool {
    state.withLock {
      $0.completed = true
      $0.token = nil
      return $0.interrupted
    }
  }

  var isInterrupted: Bool { state.withLock { $0.interrupted } }

  func stop() {
    _ = complete()
    unsubscribe()
  }
}
