import ArgumentParser
import Foundation
import ParlanceCore

public struct Explain: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "explain", abstract: "Translate and explain text with optional background context."
  )

  @Argument(help: "Text to explain, or - to read stdin.") var text: [String] = []
  @Option(help: "Background context file, or - to read stdin.") var context: String?
  @Option(help: "Deep section: vocab or domain (repeatable, in request order).") var deep:
    [String] = []
  @Flag(help: "Show the redacted text sent to the provider on stderr.") var showSent = false
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
    let sections = try deep.map { value in
      guard let section = ExplainDeepSection(rawValue: value) else {
        try CommandInput.fail(
          "unknown deep section. Choose --deep vocab or --deep domain.", environment)
      }
      return section
    }
    if context == "-" && (text.isEmpty || text == ["-"]) {
      try CommandInput.fail(
        "input and context cannot both read stdin. Pass TEXT or a context file.", environment)
    }
    let config = try CLIConfiguration.load(environment)
    let input = try CommandInput.read(text, command: "explain", environment: environment)
    let background = try CommandInput.context(context, environment: environment)
    var resolved = try config.resolve(
      provider, model: model, reasoning: reasoning, environment: environment)
    let entry = config.providers?[resolved.preset.id]
    do {
      resolved.apiKey = try await KeyLookup(
        preset: resolved.preset, baseURL: resolved.baseURL, command: entry?.apiKeyCommand,
        environment: environment
      ).key(for: resolved)
    } catch let code as ExitCode where code.rawValue == 3 {
      // Key lookup already emitted its actionable diagnostic. Auth failures still get a JSON object;
      // usage/configuration errors keep their pre-request, no-JSON contract.
      try ExplainOutput(environment: environment, json: json, noColor: noColor).complete(
        quick: nil, deep: [],
        diagnostic: RewriteDiagnostic(
          code: "auth", exitCode: 3, message: "authentication failed.",
          nextStep: "Check the provider API key."),
        section: nil, provider: resolved,
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
    // Match fix: blocked input and key helpers retain the default SIGINT action until this point.
    let interrupts = CLIInterruptHandler(
      source: environment.interruptSource, exitImmediately: environment.exitImmediately,
      onInterrupt: { reporter.interrupt() }, beforeImmediateExit: { reporter.clearBeforeExit() })
    defer { interrupts.stop() }
    var execution = ExplainExecution(
      output: ExplainOutput(environment: environment, json: json, noColor: noColor),
      interrupts: interrupts, showSent: showSent, reporter: reporter)
    try await execution.run(
      subject: ExplainSubject(
        input: input, context: background.map(ExplainContext.tail), inputRedaction: .redact),
      sections: sections,
      settings: ExplainSettings(
        targetLanguage: target ?? config.targetLanguage ?? "en",
        nativeLanguage: native ?? config.nativeLanguage ?? "zh-Hans"),
      resolved: resolved)
  }
}

private struct ExplainFailure: Error {
  let diagnostic: RewriteDiagnostic
}

private struct ExplainExecution {
  var output: ExplainOutput
  let interrupts: CLIInterruptHandler
  let showSent: Bool
  let reporter: RequestReporter
  let started = ContinuousClock.now
  var firstToken: Duration?
  var retried = false

  mutating func run(
    subject: ExplainSubject, sections: [ExplainDeepSection], settings: ExplainSettings,
    resolved: ResolvedProvider
  ) async throws {
    var quick: ExplainQuick?
    var deep: [ExplainDeep] = []
    var activeSection: ExplainDeepSection?
    var diagnostic: RewriteDiagnostic?
    do {
      let cancellation = try interrupts.beginOperation()
      let provider = output.environment.makeProvider(resolved)
      reporter.begin(.quick)
      let quickResult = try await consume(
        ExplainRunner.quick(
          subject: subject, settings: settings, provider: provider, cancellation: cancellation))
      quick = quickResult
      try finishOperation(quickResult.snapshot, eligibility: quickResult.eligibility)
      for section in sections {
        let cancellation = try interrupts.beginOperation()
        activeSection = section
        output.startOperation()
        reporter.begin(section == .vocab ? .vocab : .domain)
        let result = try await consume(
          ExplainRunner.deep(
            section, from: quickResult, settings: settings, provider: provider,
            cancellation: cancellation))
        deep.append(result)
        try finishOperation(result.snapshot, eligibility: result.eligibility)
        activeSection = nil
      }
    } catch let failure as ExplainFailure {
      diagnostic = failure.diagnostic
    } catch let error as LLMError {
      // complete() first, as fix does, so the metadata matches the final outcome.
      reporter.finish(error: interrupts.complete() ? .aborted : error)
      diagnostic = RewriteDiagnostic.forError(error)
    }
    if interrupts.complete() { diagnostic = RewriteDiagnostic.forError(.aborted) }
    let timing: [String: JSONValue] = [
      "first_token_ms": firstToken.map { .number(milliseconds($0)) } ?? .null,
      "total_ms": .number(milliseconds(started.duration(to: .now))),
      "retried": .bool(retried), "strict_retry": .bool(false),
    ]
    try output.complete(
      quick: quick, deep: deep, diagnostic: diagnostic, section: activeSection,
      provider: resolved, timing: timing)
    if let diagnostic {
      output.environment.stderr(diagnostic.line)
      throw ExitCode(diagnostic.exitCode)
    }
  }

  mutating func consume<Result>(
    _ stream: AsyncThrowingStream<ExplainUpdate<Result>, any Error>
  ) async throws -> Result {
    for try await update in stream {
      switch update {
      case .prepared(let subject):
        if showSent {
          output.environment.stderr(
            TerminalText.display(ExplainPrompt.user(subject: subject)) + "\n")
        }
        if subject.pemRedacted {
          output.environment.stderr(
            "pl: a PEM block was redacted from the text sent; a stray marker takes the text around it too. Use --show-sent to inspect.\n"
          )
        }
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
      case .completed(let result): return result
      }
    }
    throw LLMError.emptyResponse
  }

  mutating func finishOperation(_ snapshot: SectionsSnapshot, eligibility: Eligibility) throws {
    interrupts.endOperation()
    if interrupts.isInterrupted { throw LLMError.aborted }
    reporter.finish(eligibility: eligibility)
    output.finishOperation(snapshot, eligibility: eligibility)
    if let diagnostic = RewriteDiagnostic.forEligibility(eligibility) {
      throw ExplainFailure(diagnostic: diagnostic)
    }
  }

  private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }
}
