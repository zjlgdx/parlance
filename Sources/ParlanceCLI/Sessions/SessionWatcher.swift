import ArgumentParser
import Foundation
import ParlanceCore
import os

/// The event loop owns parsing and the queue; only the active explanation runs concurrently.
struct SessionWatcher {
  let binding: SessionInput.Binding
  var file: SessionWatchFile
  let environment: CLIEnvironment
  let resolved: ResolvedProvider
  let settings: ExplainSettings
  let noColor: Bool
  let verbose: Bool
  let showSent: Bool

  // Internal observations let tests await event handling rather than a filesystem call within it.
  enum Observation: Sendable { case handledTick, handledCompletion, scheduledRequest }
  @TaskLocal static var observe: (@Sendable (Observation) -> Void)?

  private enum Event: Sendable {
    case ready, tick, interrupted
    case finished(Int32)
  }

  mutating func run() async throws {
    let reporter = RequestReporter(environment: environment, provider: resolved, verbose: verbose)
    let outputEnvironment = reporter.wrapping(environment)
    let glossaryWarnings = OSAllocatedUnfairLock(initialState: Set<String>())
    let reportGlossaryWarning: @Sendable (String) -> Void = { warning in
      if glossaryWarnings.withLock({ $0.insert(warning).inserted }) {
        outputEnvironment.stderr("pl: \(warning)\n")
      }
    }
    let events = AsyncStream<Event>.makeStream()
    let interrupts = CLIInterruptHandler(
      source: environment.interruptSource, exitImmediately: environment.exitImmediately,
      onInterrupt: {
        reporter.interrupt()
        events.continuation.yield(.interrupted)
      }, beforeImmediateExit: { reporter.clearBeforeExit() })
    let stopTicker = reporter.startTicker()
    let stopPolling = environment.requestClock.subscribe { events.continuation.yield(.tick) }
    defer {
      stopPolling()
      stopTicker()
      interrupts.stop()
      reporter.finish()
      events.continuation.finish()
    }

    let initial = file.parser.turns
    var seen = Set(initial.filter(Self.explainable).compactMap(\.identity))
      .union(file.parser.settledIdentities)
    var queue: [String: Date] = [:]
    if let identity = initial.last(where: Self.explainable)?.identity {
      queue[identity] = environment.wallDate()
    }
    var request: Task<Void, Never>?
    var terminal: Int32?
    var ticks = 0
    var announcedNewer = false
    events.continuation.yield(.ready)
    for await event in events.stream {
      defer {
        switch event {
        case .tick: Self.observe?(.handledTick)
        case .finished: Self.observe?(.handledCompletion)
        default: break
        }
      }
      if Task.isCancelled { break }
      switch event {
      case .ready: break
      case .interrupted:
        terminal = 130
      case .finished(let code):
        if let request { await request.value }
        request = nil
        if [3, 5, 78, 130].contains(code) { terminal = terminal ?? code }
      case .tick:
        guard terminal == nil else { continue }
        do {
          try file.read(environment: environment)
          let turns = file.parser.turns
          for position in turns.indices {
            // Check identity first so idle ticks skip the escape scan of every earlier reply.
            // Text appended under an identity already sent is not explained again.
            guard let identity = turns[position].identity, !seen.contains(identity),
              Self.explainable(turns[position])
            else { continue }
            seen.insert(identity)
            queue[identity] = environment.wallDate()
          }
          ticks += 1
          if ticks % 10 == 0 && !announcedNewer {
            let sessions = (try? binding.source.sessions(cwd: environment.currentDirectory)) ?? []
            if sessions.contains(where: {
              !binding.initialSessionIDs.contains($0.id)
            }) {
              announcedNewer = true
              outputEnvironment.stderr(
                "pl: a newer \(binding.name) session started here; rerun pl session watch to follow it.\n"
              )
            }
          }
        } catch {
          outputEnvironment.stderr(
            "pl: the bound session file disappeared, was replaced, or became unreadable.\n")
          terminal = 66
        }
      }
      if let terminal {
        if let request {
          interrupts.cancelOperations()
          request.cancel()
          await request.value
        }
        if terminal == 130 { outputEnvironment.stderr(RewriteDiagnostic.forError(.aborted).line) }
        throw ExitCode(terminal)
      }
      guard request == nil else { continue }
      let turns = file.parser.turns
      let positions = turns.indices.filter {
        guard let identity = turns[$0].identity, queue[identity] != nil else { return false }
        return Self.explainable(turns[$0])
      }
      let date = positions.last.flatMap { turns[$0].identity }.flatMap { queue[$0] }
      queue.removeAll()
      guard let position = positions.last, let date else { continue }
      if positions.count > 1 {
        let skipped = positions.dropLast().map { String(turns[$0].index) }.joined(separator: ", ")
        let id = SessionInput.diagnostic(binding.session.id, limit: 64)
        outputEnvironment.stderr(
          "pl: skipped turns \(skipped); look up a phrase from them with pl explain --session \(binding.agent):\(id) \"<phrase>\".\n"
        )
      }
      let name = binding.name
      let resolved = resolved
      let settings = settings
      let noColor = noColor
      let showSent = showSent
      Self.observe?(.scheduledRequest)
      request = Task {
        let code: Int32
        do {
          try Task.checkCancellation()
          let prepared = try SessionInput.reply(
            turns: turns, at: position, environment: outputEnvironment)
          let formatter = DateFormatter()
          formatter.locale = Locale(identifier: "en_US_POSIX")
          formatter.dateFormat = "HH:mm"
          outputEnvironment.stdout(
            "── \(name) · turn \(turns[position].index) · \(formatter.string(from: date)) ──\n")
          var execution = ExplainExecution(
            output: ExplainOutput(environment: outputEnvironment, json: false, noColor: noColor),
            interrupts: interrupts, showSent: showSent, reporter: reporter, completesCommand: false,
            reportsAbort: false, reportGlossaryWarning: reportGlossaryWarning)
          try await execution.run(
            prepared: prepared, sections: [], settings: settings, resolved: resolved)
          code = 0
        } catch let error as ExitCode {
          code = error.rawValue
        } catch is CancellationError {
          code = 130
        } catch {
          outputEnvironment.stderr(RewriteDiagnostic.forError(.transport).line)
          code = 4
        }
        events.continuation.yield(.finished(code))
      }
    }
    interrupts.cancelOperations()
    request?.cancel()
    if let request { await request.value }
    outputEnvironment.stderr(RewriteDiagnostic.forError(.aborted).line)
    throw ExitCode(130)
  }

  private static func explainable(_ turn: SessionTurn) -> Bool {
    turn.complete && turn.identity != nil && !SessionInput.visible(turn.reply).isEmpty
  }
}
