import Foundation

@testable import ParlanceCore

enum EvalKind: String, Codable, Sendable { case rewrite, explain }
struct EvalCase: Codable, Sendable, Equatable {
  var id: String
  var category: String?
  var source: String?
  var input: String
  var group: String { category ?? source ?? "unknown" }
}

enum EvalFiles {
  static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent()
  static let fixtures = tests.appendingPathComponent("Fixtures/eval")
  static let root = tests.deletingLastPathComponent().deletingLastPathComponent()
  static func cases(_ kind: EvalKind) throws -> [EvalCase] {
    try read([EvalCase].self, from: fixtures.appendingPathComponent("\(kind.rawValue).json"))
  }
  static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: url))
  }
  static func write<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(value).write(to: url, options: .atomic)
  }
  static func recordings(in directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    var failure: (any Error)?
    let enumerator = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey],
      errorHandler: { _, error in
        failure = error
        return false
      })
    var files: [URL] = []
    while let url = enumerator?.nextObject() as? URL {
      if url.pathExtension == "json",
        try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
      {
        files.append(url)
      }
    }
    if let failure { throw failure }
    return files.sorted { $0.path < $1.path }
  }
}

struct EvalRecording: Codable, Sendable, Equatable {
  var schemaVersion = 1
  var preset: String
  var model: String
  var kind: EvalKind
  var testCase: EvalCase
  var attempts: [Recording]
  var metrics: EvalMetrics
}

struct EvalMetrics: Codable, Sendable, Equatable {
  var sectionsComplete = false
  var termPasses = 0
  var termVersions = 0
  var bestEligible = false
  var bestHasResidue = false
  var strictRetryUsed = false
  var fallback = false
  /// Missing in older recordings; new runs always populate both counters.
  var caseAFixesInReply: Int? = 0
  var caseAFixesInResult: Int? = 0
  /// Counts failing versions/attempts by code; a run can contribute more than one failure.
  var failures: [String: Int] = [:]

  static func hasResidue(_ text: String, input: String) -> Bool {
    let protection = TermProtection.protect(input)
    if let pair = protection.delimiters,
      text.unicodeScalars.contains(pair.open) || text.unicodeScalars.contains(pair.close)
    {
      return true
    }
    // Also catch invented tokens from another supported delimiter pair. Literal input tokens
    // restored as part of a protected fragment are user text, not leaked protection tokens.
    let pattern = #"⟦[0-9]+⟧|⟪[0-9]+⟫|〖[0-9]+〗"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let value = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: value.length)).contains {
      !input.contains(value.substring(with: $0.range))
    }
  }

  static func failureCode(_ eligibility: Eligibility) -> String? {
    switch eligibility {
    case .eligible: nil
    case .malformed: "malformed_sections"
    case .placeholdersChanged: "placeholders_changed"
    case .placeholdersUnavailable: "placeholders_unavailable"
    case .incomplete(let reason):
      switch reason {
      case .error(let error): error.code.rawValue
      case .length: "length"
      case .contentFilter: "content_filter"
      case .other: "other_finish"
      }
    }
  }

  static func rewrite(
    _ result: RewriteResult, input: String, attempts: [Recording],
    settings: RewriteSettings = RewriteSettings()
  ) -> Self {
    var metrics = Self()
    let isCaseA = RewriteCase.classify(input, settings: settings) == .translate
    if isCaseA {
      metrics.caseAFixesInResult =
        result.snapshot.sections.contains { $0.name == "fixes" }
          || !(result.sections?.fixes.isEmpty ?? true) ? 1 : 0
    }
    metrics.bestEligible = result.bestEligibility == .eligible
    metrics.sectionsComplete =
      metrics.bestEligible && !result.snapshot.isMalformed
      && result.snapshot.isFinished && result.fallback == nil
    metrics.strictRetryUsed = result.strictRetried
    metrics.fallback = result.fallback != nil
    let best =
      result.sections?.best
      ?? result.snapshot.sections.first { $0.name == "best" }?.text ?? ""
    metrics.bestHasResidue = hasResidue(best, input: input)
    if metrics.bestHasResidue { metrics.failures["placeholder_residue", default: 0] += 1 }
    let protection = TermProtection.protect(input)
    // Preserve every alternative for eval, including versions the UI intentionally does not retain.
    var schema = SectionSchema.fix
    for index in schema.tags.indices where schema.tags[index].name == "alts" {
      schema.tags[index].children[0].retainedLimit = nil
    }
    for attempt in attempts {
      var parser = SectionStreamParser(schema: schema)
      for event in attempt.events {
        if case .text(let chunk) = event { parser.feed(chunk) }
      }
      let snapshot = parser.finish()
      if isCaseA, snapshot.rawText.contains("<fixes>") {
        metrics.caseAFixesInReply = 1
      }
      var versions = snapshot.sections.filter { $0.name == "best" }
      versions += (snapshot.sections.first { $0.name == "alts" }?.children ?? []).flatMap {
        $0.children.filter { $0.name == "text" }
      }
      for version in versions {
        metrics.termVersions += 1
        if version.isClosed && protection.validate(version.text) {
          metrics.termPasses += 1
        } else {
          metrics.failures["placeholders_changed", default: 0] += 1
        }
      }
      if snapshot.isMalformed { metrics.failures["malformed_sections", default: 0] += 1 }
      metrics.recordTerminalFailures(attempt)
    }
    if let code = failureCode(result.bestEligibility), metrics.failures[code] == nil {
      metrics.failures[code] = 1
    }
    return metrics
  }

  static func explain(_ result: ExplainQuick, attempts: [Recording]) -> Self {
    var metrics = Self()
    metrics.sectionsComplete = result.eligibility == .eligible
    for attempt in attempts { metrics.recordTerminalFailures(attempt) }
    if let code = failureCode(result.eligibility), metrics.failures[code] == nil {
      metrics.failures[code] = 1
    }
    return metrics
  }

  private mutating func recordTerminalFailures(_ attempt: Recording) {
    for event in attempt.events {
      switch event {
      case .failure(let error): failures[error.value.code.rawValue, default: 0] += 1
      case .finished(let reason) where reason != .stop:
        let code =
          reason == .contentFilter
          ? "content_filter" : reason.rawValue + (reason == .other ? "_finish" : "")
        failures[code, default: 0] += 1
      default: break
      }
    }
  }
}

struct EvalRun: Codable, Sendable {
  var recording: EvalRecording
  var firstTokenSeconds: Double?
  var totalSeconds: Double
}

enum EvalHarness {
  static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }

  static func run(
    kind: EvalKind, testCase: EvalCase, preset: String, model: String,
    provider: any LLMProvider, timeout: Duration = .seconds(30)
  ) async throws -> EvalRun {
    let recorder = RecordingProvider(provider)
    let cancellation = LLMCancellation()
    defer { cancellation.cancel() }
    let (metrics, elapsed) = try await bounded(timeout: timeout) {
      switch kind {
      case .rewrite:
        for try await update in RewriteRunner.run(
          input: testCase.input, settings: RewriteSettings(), provider: recorder,
          cancellation: cancellation)
        {
          if case .completed(let result) = update {
            let elapsed = recorder.elapsed
            return (
              EvalMetrics.rewrite(result, input: testCase.input, attempts: recorder.attempts),
              elapsed
            )
          }
        }
      case .explain:
        for try await update in ExplainRunner.quick(
          subject: ExplainSubject(input: testCase.input, inputRedaction: .redact),
          settings: ExplainSettings(), provider: recorder, cancellation: cancellation)
        {
          if case .completed(let result) = update {
            let elapsed = recorder.elapsed
            return (EvalMetrics.explain(result, attempts: recorder.attempts), elapsed)
          }
        }
      }
      throw TestDeadline()
    }
    return EvalRun(
      recording: EvalRecording(
        preset: preset, model: model, kind: kind, testCase: testCase,
        attempts: recorder.attempts, metrics: metrics),
      firstTokenSeconds: recorder.firstToken.map(seconds), totalSeconds: seconds(elapsed))
  }

  static func replay(_ recording: EvalRecording) async throws -> EvalRun {
    let provider = MockProvider(scripts: recording.attempts.map { $0.events.map(\.step) })
    return try await run(
      kind: recording.kind, testCase: recording.testCase, preset: recording.preset,
      model: recording.model, provider: provider)
  }
}
