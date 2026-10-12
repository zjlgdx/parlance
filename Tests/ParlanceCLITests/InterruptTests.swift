import ArgumentParser
import Dispatch
import Foundation
import ParlanceCore
import Testing
import os

@testable import ParlanceCLI

/// A one-shot notification with a failure deadline; no polling or synchronization sleeps.
private final class InterruptNotice<Value: Sendable>: Sendable {
  private struct State {
    var result: Result<Value, NoticeTimeout>?
    var waiter: CheckedContinuation<Value, any Error>?
  }
  private struct NoticeTimeout: Error {}
  private let state = OSAllocatedUnfairLock(initialState: State())

  func send(_ value: Value) { resolve(.success(value)) }

  private func resolve(_ result: Result<Value, NoticeTimeout>) {
    let waiter = state.withLock { state in
      guard state.result == nil else { return CheckedContinuation<Value, any Error>?.none }
      state.result = result
      let waiter = state.waiter
      state.waiter = nil
      return waiter
    }
    waiter?.resume(with: result.mapError { $0 as any Error })
  }

  func wait() async throws -> Value {
    let deadline = DispatchWorkItem { self.resolve(.failure(NoticeTimeout())) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: deadline)
    defer { deadline.cancel() }
    return try await withCheckedThrowingContinuation { continuation in
      let result: Result<Value, NoticeTimeout>? = state.withLock { state in
        if let result = state.result { return result }
        state.waiter = continuation
        return nil
      }
      if let result { continuation.resume(with: result.mapError { $0 as any Error }) }
    }
  }
}

private final class TestInterruptSource: Sendable {
  let handler = OSAllocatedUnfairLock<(@Sendable (UInt) -> Void)?>(initialState: nil)
  let exits = OSAllocatedUnfairLock(initialState: [Int32]())
  let stopped = OSAllocatedUnfairLock(initialState: false)
  var source: CLIInterruptSource {
    CLIInterruptSource { handler in
      self.handler.withLock { $0 = handler }
      return {
        self.handler.withLock { $0 = nil }
        self.stopped.withLock { $0 = true }
      }
    }
  }
  func send(_ count: UInt = 1) { handler.withLock { $0 }?(count) }
}

/// Allows the test to hold a stream open even after cancellation, and explicitly release it.
private final class InterruptProvider: LLMProvider, Sendable {
  struct State {
    var tokens: [LLMCancellation] = []
    var pending: AsyncThrowingStream<LLMEvent, any Error>.Continuation?
  }
  let state = OSAllocatedUnfairLock(initialState: State())
  let ready = InterruptNotice<Bool>()
  let cancelled = InterruptNotice<Bool>()
  let strictRetry: Bool
  let ignoresCancellation: Bool
  init(strictRetry: Bool = false, ignoresCancellation: Bool = false) {
    self.strictRetry = strictRetry
    self.ignoresCancellation = ignoresCancellation
  }
  func stream(_ request: LLMRequest, cancellation: LLMCancellation) -> AsyncThrowingStream<
    LLMEvent, any Error
  > {
    let index = state.withLock {
      $0.tokens.append(cancellation)
      return $0.tokens.count
    }
    if strictRetry && index == 1 {
      return MockProvider(scripts: [
        [
          .event(
            .text(
              "<best>first ⟦0⟧</best><gloss>gloss</gloss><alts><alt><text>wrong</text><note>note</note></alt></alts>"
            )),
          .event(.finished(.stop)),
        ]
      ]).stream(request, cancellation: cancellation)
    }
    let (stream, continuation) = AsyncThrowingStream<LLMEvent, any Error>.makeStream()
    state.withLock { $0.pending = continuation }
    cancellation.onCancel { [self] in
      cancelled.send(true)
      if !ignoresCancellation { finish() }
    }
    continuation.yield(.text("<best>Shown already.</best><gloss>unfinished"))
    ready.send(true)
    return stream
  }
  func finish() {
    let continuation = state.withLock {
      let continuation = $0.pending
      $0.pending = nil
      return continuation
    }
    continuation?.finish(throwing: LLMError.aborted)
  }
}

private final class InterruptHarness: Sendable {
  struct State {
    var output = ""
    var error = ""
    var completed = false
    var subscribedDuringRead: Bool?
  }
  let state = OSAllocatedUnfairLock(initialState: State())
  let signals = TestInterruptSource()
  let provider: InterruptProvider
  let rendered = InterruptNotice<Bool>()
  let finished = InterruptNotice<Int32>()
  init(strictRetry: Bool = false, ignoresCancellation: Bool = false) {
    provider = InterruptProvider(strictRetry: strictRetry, ignoresCancellation: ignoresCancellation)
  }
  func start(
    json: Bool = false, tty: Bool = false, beforeStart: Bool = false, stdin: Bool = false
  ) -> Task<Void, Never> {
    Task {
      let environment = CLIEnvironment(
        variables: ["OPENAI_API_KEY": "fake-test-key"], stdinIsTTY: false,
        stdoutIsTTY: tty, stderrIsTTY: false,
        readStdin: {
          let subscribed = self.signals.handler.withLock { $0 != nil }
          self.state.withLock { $0.subscribedDuringRead = subscribed }
          return Data("fooBar".utf8)
        },
        stdout: { text in
          self.state.withLock { $0.output += text }
          if text.contains("Shown already.") { self.rendered.send(true) }
        },
        stderr: { text in self.state.withLock { $0.error += text } },
        makeProvider: { _ in self.provider },
        interruptSource: CLIInterruptSource { handler in
          let stop = self.signals.source.subscribe(handler)
          if beforeStart { handler(1) }
          return stop
        },
        exitImmediately: { code in self.signals.exits.withLock { $0.append(code) } })
      let code = await CLIEnvironment.$override.withValue(environment) {
        await PL.execute(
          arguments: ["fix", stdin ? "-" : "fooBar", "--no-color"] + (json ? ["--json"] : []))
      }
      self.state.withLock { $0.completed = true }
      self.finished.send(code.rawValue)
    }
  }
  var output: String { state.withLock { $0.output } }
  var error: String { state.withLock { $0.error } }
}

struct InterruptTests {
  @Test func interruptCancelsTokenAndSuppressesPipeOutput() async throws {
    let harness = InterruptHarness()
    let task = harness.start()
    defer {
      harness.provider.finish()
      task.cancel()
    }
    _ = try await harness.provider.ready.wait()
    harness.signals.send()
    #expect(try await harness.provider.cancelled.wait())
    #expect(harness.provider.state.withLock { $0.tokens.allSatisfy(\.isCancelled) })
    #expect(try await harness.finished.wait() == 130)
    #expect(harness.output.isEmpty)
    #expect(harness.error == RewriteDiagnostic.forError(.aborted).line)
    #expect(harness.signals.stopped.withLock { $0 })
    harness.signals.send()
    #expect(harness.signals.exits.withLock { $0.isEmpty })
  }

  @Test func interruptedJSONIsExactlyOneFailure() async throws {
    let harness = InterruptHarness()
    let task = harness.start(json: true)
    defer {
      harness.provider.finish()
      task.cancel()
    }
    _ = try await harness.provider.ready.wait()
    harness.signals.send()
    #expect(try await harness.finished.wait() == 130)
    try expectAbortedJSON(harness.output)
    #expect(harness.error == RewriteDiagnostic.forError(.aborted).line)
  }

  @Test func ttyKeepsPreviouslyRenderedText() async throws {
    let harness = InterruptHarness()
    let task = harness.start(tty: true)
    defer {
      harness.provider.finish()
      task.cancel()
    }
    _ = try await harness.rendered.wait()
    let before = harness.output
    harness.signals.send()
    #expect(try await harness.finished.wait() == 130)
    #expect(before == "Shown already.\n")
    #expect(harness.output == before)
    #expect(harness.error == RewriteDiagnostic.forError(.aborted).line)
  }

  @Test func strictRetryCancellationNeverFallsBack() async throws {
    for json in [false, true] {
      let harness = InterruptHarness(strictRetry: true)
      let task = harness.start(json: json)
      defer {
        harness.provider.finish()
        task.cancel()
      }
      _ = try await harness.provider.ready.wait()
      #expect(harness.provider.state.withLock { $0.tokens.count } == 2)
      harness.signals.send()
      #expect(try await harness.finished.wait() == 130)
      #expect(!harness.error.contains("using the first result"))
      if json { try expectAbortedJSON(harness.output) } else { #expect(harness.output.isEmpty) }
    }
  }

  @Test func secondInterruptExitsWhileProviderRemainsSuspended() async throws {
    let harness = InterruptHarness(ignoresCancellation: true)
    let task = harness.start()
    defer {
      harness.provider.finish()
      task.cancel()
    }
    _ = try await harness.provider.ready.wait()
    harness.signals.send()
    #expect(try await harness.provider.cancelled.wait())
    #expect(!harness.state.withLock { $0.completed })
    #expect(harness.signals.exits.withLock { $0.isEmpty })
    harness.signals.send()
    #expect(harness.signals.exits.withLock { $0 } == [130])
    #expect(!harness.state.withLock { $0.completed })
    harness.provider.finish()
    #expect(try await harness.finished.wait() == 130)
  }

  @Test func interruptBeforeRegistrationSendsNoRequest() async throws {
    for json in [false, true] {
      let harness = InterruptHarness()
      let task = harness.start(json: json, beforeStart: true)
      defer {
        harness.provider.finish()
        task.cancel()
      }
      #expect(try await harness.finished.wait() == 130)
      #expect(harness.provider.state.withLock { $0.tokens.isEmpty })
      if json { try expectAbortedJSON(harness.output) } else { #expect(harness.output.isEmpty) }
      #expect(harness.error == RewriteDiagnostic.forError(.aborted).line)
    }
  }

  @Test func coalescedInterruptsTakeImmediateExitPath() throws {
    let signals = TestInterruptSource()
    let handler = CLIInterruptHandler(
      source: signals.source,
      exitImmediately: { code in signals.exits.withLock { $0.append(code) } })
    defer { handler.stop() }
    let token = try handler.beginOperation()
    signals.send(2)
    #expect(signals.exits.withLock { $0 } == [130])
    #expect(token.isCancelled)
  }

  @Test func stdinIsReadBeforeSubscribing() async throws {
    // A Ctrl-C while `pl fix -` waits for input must keep its default action and end the process.
    let harness = InterruptHarness()
    let task = harness.start(stdin: true)
    defer {
      harness.provider.finish()
      task.cancel()
    }
    _ = try await harness.provider.ready.wait()
    #expect(harness.state.withLock { $0.subscribedDuringRead } == false)
    #expect(harness.signals.handler.withLock { $0 != nil })
    harness.signals.send()
    #expect(try await harness.finished.wait() == 130)
  }

  @Test func committedOutcomeIgnoresOneInterruptButNotTwo() throws {
    let signals = TestInterruptSource()
    let handler = CLIInterruptHandler(
      source: signals.source,
      exitImmediately: { code in signals.exits.withLock { $0.append(code) } })
    defer { handler.stop() }
    let token = try handler.beginOperation()
    #expect(!handler.complete())
    signals.send()
    #expect(!token.isCancelled)
    #expect(signals.exits.withLock { $0.isEmpty })
    signals.send()
    #expect(signals.exits.withLock { $0 } == [130])
  }

  @Test func handlerRefusesLaterOperationsAndExitsOnSecondInterruptAfterCompletion() throws {
    let signals = TestInterruptSource()
    let handler = CLIInterruptHandler(
      source: signals.source,
      exitImmediately: { code in signals.exits.withLock { $0.append(code) } })
    defer { handler.stop() }
    let first = try handler.beginOperation()
    handler.endOperation()
    let second = try handler.beginOperation()
    signals.send()
    #expect(!first.isCancelled)
    #expect(second.isCancelled)
    #expect(throws: LLMError.aborted) { try handler.beginOperation() }
    #expect(handler.complete())
    signals.send()
    #expect(signals.exits.withLock { $0 } == [130])
  }
}

private func expectAbortedJSON(_ output: String) throws {
  #expect(output.split(separator: "\n").count == 1)
  let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  #expect(object["status"] as? String == "error")
  #expect(object["result"] is NSNull)
  #expect(object["fallback"] is NSNull)
  #expect((object["error"] as? [String: Any])?["code"] as? String == "aborted")
}
