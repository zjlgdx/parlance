import Dispatch
import Foundation
import ParlanceCore
import os

/// Monotonic time and one-second notifications. Tests advance both without sleeping.
public struct CLIRequestClock: Sendable {
  public var now: @Sendable () -> Duration
  public var subscribe: @Sendable (@escaping @Sendable () -> Void) -> @Sendable () -> Void

  public init(
    now: @escaping @Sendable () -> Duration,
    subscribe: @escaping @Sendable (@escaping @Sendable () -> Void) -> @Sendable () -> Void
  ) {
    self.now = now
    self.subscribe = subscribe
  }

  public static let inactive = Self(now: { .zero }, subscribe: { _ in {} })

  public static var continuous: Self {
    let origin = ContinuousClock.now
    return Self(
      now: { origin.duration(to: .now) },
      subscribe: { tick in
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler(handler: tick)
        timer.activate()
        return { timer.cancel() }
      })
  }
}

/// Owns stderr while a command runs. All writes and timer callbacks share the lock so a cleared
/// status cannot be redrawn between clearing it and writing a diagnostic. No request/reply text
/// is retained here; verbose output is assembled only from the metadata below.
/// HTTP metadata: success is `2xx` (the provider checks before streaming), errors with a carried
/// status report that number, and other errors report `none`. Core exposes no exact success status.
/// Known limit: in-stream errors carry mapped provider statuses (e.g. overloaded -> 529), even
/// though the HTTP response that started the stream was 2xx.
final class RequestReporter: Sendable {
  enum Request: String { case fix, quick, vocab, domain }
  private struct State {
    var request: Request?
    var started: Duration = .zero
    var waitingSince: Duration = .zero
    var firstToken: Duration?
    var retries = 0
    var retry: (deadline: Duration, cause: LLMErrorCode)?
    var waiting = false
    var visible = false
    var interrupted = false
  }
  private let state = OSAllocatedUnfairLock(initialState: State())
  private let clock: CLIRequestClock
  private let stderr: @Sendable (String) -> Void
  private let tty: Bool
  private let verbose: Bool
  private let preset: String
  private let model: String
  private let reasoningMetadata: String

  init(environment: CLIEnvironment, provider: ResolvedProvider, verbose: Bool) {
    clock = environment.requestClock
    stderr = environment.stderr
    tty = environment.stderrIsTTY && environment.variables["TERM"] != "dumb"
    self.verbose = verbose
    preset = Self.safeField(provider.preset.id, key: provider.apiKey)
    model = Self.safeField(provider.model, key: provider.apiKey)
    let marker = provider.reasoning.isSet ? "" : "(default)"
    let effort = provider.effortFromExtraBody ? "(extra_body)" : provider.effectiveEffort + marker
    let thinking =
      provider.thinkingFromExtraBody ? "(extra_body)" : provider.effectiveThinking + marker
    reasoningMetadata =
      "effort=\(effort) thinking=\(thinking) first_text_timeout=\(provider.firstTextTimeout.components.seconds)"
  }

  private static func safeField(_ value: String, key: String?) -> String {
    // A field with terminal controls is printed as a fixed marker: rewriting controls can split or
    // rebuild a secret, and real preset or model IDs never contain them. Redactor recognizes common
    // key formats; an arbitrary compatible-provider key also stays private.
    guard sanitized(value) == value else { return "[invalid]" }
    let value =
      key.flatMap { $0.isEmpty ? nil : $0 }.map {
        value.replacingOccurrences(of: $0, with: Redactor.placeholder)
      } ?? value
    return Redactor.redact(value).text
  }

  private static func sanitized(_ value: String) -> String {
    TerminalText.display(TerminalText.stripEscapes(value))
      .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
  }

  func wrapping(_ environment: CLIEnvironment) -> CLIEnvironment {
    var environment = environment
    environment.stderr = { self.write($0) }
    return environment
  }

  func startTicker() -> @Sendable () -> Void {
    guard tty else { return {} }
    return clock.subscribe { self.tick() }
  }

  func begin(_ request: Request) {
    state.withLock {
      $0.request = request
      $0.started = clock.now()
      $0.waitingSince = $0.started
      $0.firstToken = nil
      $0.retries = 0
      $0.retry = nil
      $0.waiting = !$0.interrupted
      render(&$0)
    }
  }

  func firstToken() {
    state.withLock {
      guard $0.request != nil else { return }
      if $0.firstToken == nil { $0.firstToken = clock.now() - $0.started }
      $0.waiting = false
      clear(&$0)
    }
  }

  func retry(after: Duration, cause: LLMErrorCode) {
    state.withLock {
      $0.retries += 1
      $0.retry = (clock.now() + after, cause)
      render(&$0)
    }
  }

  func strictRetry() {
    state.withLock {
      $0.retries += 1
      $0.waitingSince = clock.now()
      $0.retry = nil
      $0.waiting = !$0.interrupted
      render(&$0)
    }
  }

  /// Clears the status line before an immediate exit, only when no writer holds the lock: the line
  /// exists only on a terminal stderr, and an idle terminal accepts a few bytes at once. Known
  /// limit: a terminal stopped with Ctrl-S blocks this write, and with a busy writer the line
  /// stays on screen.
  func clearBeforeExit() {
    state.withLockIfAvailable { clear(&$0) }
  }

  /// Best effort from the signal path; normal completion also clears the line.
  func interrupt() {
    state.withLockIfAvailable {
      $0.interrupted = true
      $0.waiting = false
    }
    // Never perform terminal I/O on the signal callback: even an uncontended lock does not
    // guarantee a nonblocking write. Skip busy writers; normal completion also clears the line.
    DispatchQueue.global().async {
      self.state.withLockIfAvailable {
        $0.interrupted = true
        $0.waiting = false
        self.clear(&$0)
      }
    }
  }

  func write(_ text: String) {
    state.withLock {
      clear(&$0)
      stderr(text)
    }
  }

  func finish(eligibility: Eligibility) {
    if case .incomplete(.error(let error)) = eligibility {
      finish(error: error)
    } else {
      finish()
    }
  }

  func finish(error: LLMError? = nil) {
    state.withLock {
      guard let request = $0.request else { return }
      $0.waiting = false
      clear(&$0)
      if verbose {
        let http: String
        if let error {
          http =
            RewriteDiagnostic.forError(error).httpStatus.map(String.init)
            ?? "none"
        } else {
          // The caller owns the committed outcome, including interrupt priority.
          http = "2xx"
        }
        let first = $0.firstToken.map(Self.milliseconds) ?? "null"
        let total = Self.milliseconds(clock.now() - $0.started)
        stderr(
          "pl: request=\(request.rawValue) preset=\(preset) model=\(model) \(reasoningMetadata) http=\(http) first_token_ms=\(first) total_ms=\(total) retries=\($0.retries)\n"
        )
      }
      $0.request = nil
    }
  }

  private static func milliseconds(_ duration: Duration) -> String {
    String(
      Int64(
        max(
          0,
          Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15)))
  }

  private func tick() { state.withLock { render(&$0) } }

  private func render(_ state: inout State) {
    guard tty && state.waiting else { return }
    let now = clock.now()
    let text: String
    if let retry = state.retry, retry.deadline > now {
      let remaining = retry.deadline - now
      let seconds = remaining.components.seconds + (remaining.components.attoseconds > 0 ? 1 : 0)
      let cause = retry.cause == .rateLimit ? "rate limited" : "provider unavailable"
      text = "retrying in \(seconds)s (\(cause))"
    } else {
      if let retry = state.retry {
        state.waitingSince = retry.deadline
        state.retry = nil
      }
      text = "waiting for first token \(max(0, (now - state.waitingSince).components.seconds))s"
    }
    stderr("\r\u{1B}[2Kpl: \(text)")
    state.visible = true
  }

  private func clear(_ state: inout State) {
    if state.visible { stderr("\r\u{1B}[2K") }
    state.visible = false
  }
}
