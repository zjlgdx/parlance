import ArgumentParser
import Foundation
import ParlanceCore

public struct Fix: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "fix", abstract: "Rewrite text in the target language.")

  @Argument(help: "Text to rewrite, or - to read stdin.") var text: [String] = []
  @Option(help: "Tone preset: agent or casual.") var tone: String?
  @Option(help: "Target language (BCP 47).") var target: String?
  @Option(help: "Native language (BCP 47).") var native: String?
  @Option(help: "Provider preset ID.") var provider: String?
  @Option(help: "Model ID.") var model: String?
  @OptionGroup var reasoning: ReasoningOptions
  @Flag(help: "Write one JSON object.") var json = false
  @Flag(help: "Disable color.") var noColor = false
  @Flag(help: "Write request metadata to stderr.") var verbose = false

  public init() {}

  public mutating func run() async throws {
    var environment = CLIEnvironment.current
    let config = try CLIConfiguration.load(environment)
    guard let tone = RewriteSettings.Tone(rawValue: tone ?? config.tone ?? "agent") else {
      try fail(64, "unknown tone. Choose --tone agent or --tone casual.", environment)
    }
    let input = try CommandInput.read(text, command: "fix", environment: environment)
    var resolved = try config.resolve(
      provider, model: model, reasoning: reasoning, environment: environment)
    let entry = config.providers?[resolved.preset.id]
    do {
      resolved.apiKey = try await KeyLookup(
        preset: resolved.preset, baseURL: resolved.baseURL, command: entry?.apiKeyCommand,
        environment: environment
      ).key(for: resolved)
    } catch let code as ExitCode where code.rawValue == 3 {
      // Key lookup already wrote its diagnostic. Auth failures still get a JSON object, as in
      // explain; usage/configuration errors keep their pre-request, no-JSON contract.
      try FixOutput(environment: environment, json: json, noColor: noColor).failure(
        RewriteDiagnostic(
          code: "auth", exitCode: 3, message: "authentication failed.",
          nextStep: "Check the provider API key."),
        provider: resolved,
        timing: [
          "first_token_ms": .null, "total_ms": .number(0),
          "retried": .bool(false), "strict_retry": .bool(false),
        ])
      throw code
    }
    let reporter = RequestReporter(environment: environment, provider: resolved, verbose: verbose)
    environment = reporter.wrapping(environment)
    let stopTicker = reporter.startTicker()
    defer {
      stopTicker()
      reporter.finish()
    }
    // Subscribed only now: until here Ctrl-C keeps its default action, so it still ends a blocked
    // stdin read, and a helper process started while resolving the key does not inherit SIG_IGN.
    let interrupts = CLIInterruptHandler(
      source: environment.interruptSource, exitImmediately: environment.exitImmediately,
      onInterrupt: { reporter.interrupt() }, beforeImmediateExit: { reporter.clearBeforeExit() })
    defer { interrupts.stop() }
    let started = ContinuousClock.now
    var firstToken: Duration?
    var retried = false
    var output = FixOutput(environment: environment, json: json, noColor: noColor)
    let settings = RewriteSettings(
      targetLanguage: target ?? config.targetLanguage ?? "en",
      nativeLanguage: native ?? config.nativeLanguage ?? "zh-Hans", tone: tone,
      includeFixes: config.fixes ?? true)
    func timing(strictRetried: Bool = false) -> [String: JSONValue] {
      [
        "first_token_ms": firstToken.map { .number(milliseconds($0)) } ?? .null,
        "total_ms": .number(milliseconds(started.duration(to: .now))),
        "retried": .bool(retried), "strict_retry": .bool(strictRetried),
      ]
    }
    do {
      let cancellation = try interrupts.beginOperation()
      reporter.begin(.fix)
      for try await update in RewriteRunner.run(
        input: input, settings: settings, provider: environment.makeProvider(resolved),
        cancellation: cancellation)
      {
        switch update {
        case .sections(let snapshot):
          guard !interrupts.isInterrupted else { continue }
          if !snapshot.rawText.isEmpty { reporter.firstToken() }
          if firstToken == nil && !snapshot.rawText.isEmpty {
            firstToken = started.duration(to: .now)
          }
          output.render(snapshot)
        case .retrying(let after, let cause):
          guard !interrupts.isInterrupted else { continue }
          retried = true
          reporter.retry(after: after, cause: cause)
        case .strictRetry:
          guard !interrupts.isInterrupted else { continue }
          environment.stderr(
            TerminalText.display(
              "pl: the model changed identifiers; retrying with a stricter prompt.\n"))
          output.startNewBlock()
          reporter.strictRetry()
        case .completed(let result):
          let interrupted = interrupts.complete()
          if interrupted {
            reporter.finish(error: .aborted)
          } else {
            reporter.finish(eligibility: result.bestEligibility)
          }
          if interrupted {
            let diagnostic = try output.failure(
              .aborted, provider: resolved, timing: timing(strictRetried: result.strictRetried))
            environment.stderr(diagnostic.line)
            throw ExitCode(diagnostic.exitCode)
          }
          if result.fallback == .firstBest {
            environment.stderr(
              TerminalText.display("pl: the retry failed; using the first result.\n"))
          }
          if let diagnostic = try output.complete(
            result, provider: resolved, timing: timing(strictRetried: result.strictRetried))
          {
            environment.stderr(diagnostic.line)
            throw ExitCode(diagnostic.exitCode)
          }
        }
      }
    } catch let error as LLMError {
      let interrupted = interrupts.complete()
      reporter.finish(error: interrupted ? .aborted : error)
      let diagnostic = try output.failure(
        interrupted ? .aborted : error, provider: resolved, timing: timing())
      environment.stderr(diagnostic.line)
      throw ExitCode(diagnostic.exitCode)
    }
  }

  private func fail(_ code: Int32, _ message: String, _ environment: CLIEnvironment) throws -> Never
  {
    environment.stderr("pl: \(message)\n")
    throw ExitCode(code)
  }

  private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }
}
