import ArgumentParser
import Foundation
import ParlanceCore

public struct Explain: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "explain", abstract: "Translate and explain text with optional background context."
  )

  @Argument(help: "Text to explain, or - to read stdin.") var text: [String] = []
  @Option(help: "Local session: claude, codex or pi, optionally followed by :ID.") var session:
    String?
  @Option(help: "Background context file, or - to read stdin.") var context: String?
  @Option(help: "Deep section: vocab or domain (repeatable, in request order).") var deep:
    [String] = []
  @Flag(help: "Explain a whole document (up to 60,000 characters).") var doc = false
  @Flag(help: "Show the redacted text sent to the provider on stderr.") var showSent = false
  @Option(help: "Target language (BCP 47).") var target: String?
  @Option(help: "Native language (BCP 47).") var native: String?
  @Option(help: "Provider preset ID.") var provider: String?
  @Option(help: "Model ID.") var model: String?
  @OptionGroup var reasoning: ReasoningOptions
  @Flag(help: "Write one JSON object.") var json = false
  @Flag(help: "Do not read or send the glossary.") var noGlossary = false
  @Flag(help: "Disable color.") var noColor = false
  @Flag(help: "Write request metadata to stderr.") var verbose = false

  public init() {}

  public mutating func run() async throws {
    var environment = CLIEnvironment.current
    let mode: ExplainMode = doc ? .document : .quick
    let limit: CommandInput.Limit = doc ? .explainDocument : .explainQuick
    if doc && !deep.isEmpty {
      try CommandInput.fail("--doc and --deep cannot be used together.", environment)
    }
    if doc && session != nil && !text.isEmpty {
      try CommandInput.fail(
        "--doc with --session only supports reply mode. Omit TEXT to explain the latest reply.",
        environment)
    }
    let sections = try deep.map { value in
      guard let section = ExplainDeepSection(rawValue: value) else {
        try CommandInput.fail(
          "unknown deep section. Choose --deep vocab or --deep domain.", environment)
      }
      return section
    }
    if session != nil && context != nil {
      try CommandInput.fail("--session and --context cannot be used together.", environment)
    }
    if context == "-" && (text.isEmpty || text == ["-"]) {
      try CommandInput.fail(
        "input and context cannot both read stdin. Pass TEXT or a context file.", environment)
    }
    let config = try CLIConfiguration.load(environment)
    let prepared: PreparedSubject
    if let session {
      prepared = try SessionInput.prepare(
        session, text: text, environment: environment, replyLimit: limit)
    } else {
      let input = try CommandInput.read(
        text, command: "explain", environment: environment, limit: limit)
      let background = try CommandInput.context(context, environment: environment)
      prepared = PreparedSubject(
        subject: ExplainSubject(
          input: input, context: background.map(ExplainContext.tail), inputRedaction: .redact))
    }
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
      try ExplainOutput(environment: environment, json: json, noColor: noColor, mode: mode)
        .complete(
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
    RequestReporter.noteUnknownModel(resolved, environment: environment)
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
      output: ExplainOutput(environment: environment, json: json, noColor: noColor, mode: mode),
      interrupts: interrupts, showSent: showSent, reporter: reporter)
    try await execution.run(
      prepared: prepared,
      sections: sections,
      settings: ExplainSettings(
        targetLanguage: target ?? config.targetLanguage ?? "en",
        nativeLanguage: native ?? config.nativeLanguage ?? "zh-Hans",
        glossaryEnabled: !noGlossary && (config.glossary ?? true)),
      resolved: resolved)
  }
}

private struct ExplainFailure: Error {
  let diagnostic: RewriteDiagnostic
}

struct ExplainExecution {
  var output: ExplainOutput
  let interrupts: CLIInterruptHandler
  let showSent: Bool
  let reporter: RequestReporter
  var completesCommand = true
  var reportsAbort = true
  var reportGlossaryWarning: (@Sendable (String) -> Void)?
  let started = ContinuousClock.now
  var firstToken: Duration?
  var retried = false

  mutating func run(
    prepared: PreparedSubject, sections: [ExplainDeepSection], settings: ExplainSettings,
    resolved: ResolvedProvider
  ) async throws {
    var quick: ExplainQuick?
    var document: ExplainDocument?
    var deep: [ExplainDeep] = []
    var activeSection: ExplainDeepSection?
    var diagnostic: RewriteDiagnostic?
    do {
      let cancellation = try interrupts.beginOperation()
      let provider = output.environment.makeProvider(resolved)
      if output.mode == .document {
        reporter.begin(.document)
        let result = try await consume(
          ExplainRunner.document(
            prepared: prepared, settings: settings, provider: provider, cancellation: cancellation,
            glossaryStore: output.environment.glossaryStore))
        document = result
        try finishOperation(result.snapshot, eligibility: result.eligibility)
      } else {
        reporter.begin(.quick)
        let quickResult = try await consume(
          ExplainRunner.quick(
            prepared: prepared, settings: settings, provider: provider, cancellation: cancellation,
            glossaryStore: output.environment.glossaryStore))
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
      }
    } catch let failure as ExplainFailure {
      diagnostic = failure.diagnostic
    } catch let error as LLMError {
      // Finalize the request first so the metadata matches its outcome.
      reporter.finish(error: finishRequest() ? .aborted : error)
      diagnostic = RewriteDiagnostic.forError(error)
    }
    if finishRequest() { diagnostic = RewriteDiagnostic.forError(.aborted) }
    let timing: [String: JSONValue] = [
      "first_token_ms": firstToken.map { .number(milliseconds($0)) } ?? .null,
      "total_ms": .number(milliseconds(started.duration(to: .now))),
      "retried": .bool(retried), "strict_retry": .bool(false),
    ]
    try output.complete(
      quick: quick, deep: deep, diagnostic: diagnostic, section: activeSection,
      provider: resolved, timing: timing, document: document)
    if let diagnostic {
      if reportsAbort || diagnostic.exitCode != 130 {
        output.environment.stderr(diagnostic.line)
      }
      throw ExitCode(diagnostic.exitCode)
    }
  }

  private func finishRequest() -> Bool {
    if completesCommand { return interrupts.complete() }
    interrupts.endOperation()
    return interrupts.isCancelled
  }

  mutating func consume<Result>(
    _ stream: AsyncThrowingStream<ExplainUpdate<Result>, any Error>
  ) async throws -> Result {
    for try await update in stream {
      switch update {
      case .prepared(let subject):
        output.input = subject.input
        output.glossary = subject.glossary
        for warning in subject.glossaryWarnings {
          if let reportGlossaryWarning {
            reportGlossaryWarning(warning)
          } else {
            output.environment.stderr("pl: \(warning)\n")
          }
        }
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
        guard !interrupts.isCancelled else { continue }
        if !snapshot.rawText.isEmpty { reporter.firstToken() }
        if firstToken == nil && !snapshot.rawText.isEmpty {
          firstToken = started.duration(to: .now)
        }
        output.render(snapshot)
      case .retrying(let after, let cause):
        guard !interrupts.isCancelled else { continue }
        retried = true
        reporter.retry(after: after, cause: cause)
      case .completed(let result): return result
      }
    }
    throw LLMError.emptyResponse
  }

  mutating func finishOperation(_ snapshot: SectionsSnapshot, eligibility: Eligibility) throws {
    interrupts.endOperation()
    if interrupts.isCancelled { throw LLMError.aborted }
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
