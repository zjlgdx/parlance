import Foundation

public enum IncompleteReason: Sendable, Equatable {
  case error(LLMError)
  case length, contentFilter, other
}

public enum Eligibility: Sendable, Equatable {
  case eligible
  case incomplete(IncompleteReason)
  case malformed
  case placeholdersChanged, placeholdersUnavailable
}

public struct FixSections: Sendable, Equatable {
  public struct Alternative: Sendable, Equatable {
    public var text: String
    public var note: String?
  }
  public var best: String
  public var gloss: String?
  public var alts: [Alternative]
  public var fixes: [String]

  public init(best: String, gloss: String?, alts: [Alternative], fixes: [String]) {
    self.best = best
    self.gloss = gloss
    self.alts = alts
    self.fixes = fixes
  }

  init(snapshot: SectionsSnapshot) {
    func section(_ name: String) -> SectionNode? {
      snapshot.sections.first { $0.name == name }
    }
    best = section("best")?.text ?? ""
    gloss = section("gloss")?.text
    alts = (section("alts")?.children ?? []).map { alt in
      Alternative(
        text: alt.children.first { $0.name == "text" }?.text ?? "",
        note: alt.children.first { $0.name == "note" }?.text)
    }
    fixes = section("fixes")?.children.map(\.text) ?? []
  }
}

public enum Fallback: Sendable, Equatable { case firstBest }

public struct RewriteResult: Sendable, Equatable {
  public var snapshot: SectionsSnapshot
  /// Present for a complete, structurally valid reply, including placeholder failures.
  /// Empty alternatives are dropped; an empty best is `.malformed` with sections still present.
  /// Consumers must check each version's eligibility before copying its restored text.
  public var sections: FixSections?
  public var usage: LLMUsage?
  public var bestEligibility: Eligibility
  public var altEligibility: [Eligibility]
  public var fallback: Fallback? = nil
  public var strictRetried = false
  public var glossary: [GlossaryEntry] = []
}

public struct PreparedRewrite: Sendable, Equatable {
  public let glossary: [GlossaryEntry]
  public let message: String
  public let warnings: [String]
}

public enum RewriteUpdate: Sendable, Equatable {
  case prepared(PreparedRewrite)
  case sections(SectionsSnapshot)
  case retrying(after: Duration, cause: LLMErrorCode)
  case strictRetry
  case completed(RewriteResult)
}

public enum RewriteRunner {
  /// Provider failures, including failures before any text, complete with an incomplete result.
  /// The stream does not throw provider errors; its throwing shape matches other core streams.
  /// Cancelling consumption cancels the supplied provider token and the forwarding task.
  public static func run(
    input: String, settings: RewriteSettings, provider: any LLMProvider,
    cancellation: LLMCancellation, glossaryStore: GlossaryStore? = nil
  ) -> AsyncThrowingStream<RewriteUpdate, any Error> {
    let (stream, continuation) = AsyncThrowingStream<RewriteUpdate, any Error>.makeStream()
    let task = Task {
      var protection = TermProtection.protect(input)
      let read = settings.glossaryEnabled ? glossaryStore?.read() ?? GlossaryRead() : GlossaryRead()
      let glossary = Glossary.match(
        read.entries, in: protection.text,
        targetLanguage: settings.targetLanguage, nativeLanguage: settings.nativeLanguage)
      if !glossary.isEmpty { protection = TermProtection.protect(input, glossary: glossary) }
      let message = protection.text + Glossary.paragraph(glossary, explain: false)
      continuation.yield(
        .prepared(PreparedRewrite(glossary: glossary, message: message, warnings: read.warnings)))
      let inputCase = RewriteCase.classify(protection, settings: settings)
      let first = await attempt(
        settings: settings, protection: protection, inputCase: inputCase, strict: false,
        provider: provider, message: message,
        cancellation: cancellation, continuation: continuation)
      var result = first
      // A malformed best is not retried, like any other malformed reply.
      if first.bestEligibility != .malformed,
        first.bestEligibility == .placeholdersChanged
          || first.altEligibility.contains(.placeholdersChanged)
      {
        continuation.yield(.strictRetry)
        result = await attempt(
          settings: settings, protection: protection, inputCase: inputCase, strict: true,
          provider: provider, message: message,
          cancellation: cancellation, continuation: continuation)
        result.strictRetried = true
        result.usage = combinedUsage(first.usage, result.usage)
        if result.bestEligibility != .eligible,
          result.bestEligibility != .incomplete(.error(.aborted)),
          first.bestEligibility == .eligible, let sections = first.sections
        {
          result.sections = FixSections(best: sections.best, gloss: nil, alts: [], fixes: [])
          result.bestEligibility = .eligible
          result.altEligibility = []
          result.fallback = .firstBest
        }
      }
      result.glossary = glossary
      continuation.yield(.completed(result))
      continuation.finish()
    }
    continuation.onTermination = { reason in
      if case .cancelled = reason {
        cancellation.cancel()
        task.cancel()
      }
    }
    return stream
  }

  private static func attempt(
    settings: RewriteSettings, protection: ProtectedInput, inputCase: RewriteCase,
    strict: Bool, provider: any LLMProvider, message: String,
    cancellation: LLMCancellation,
    continuation: AsyncThrowingStream<RewriteUpdate, any Error>.Continuation
  ) async -> RewriteResult {
    // A back-translation into the language the versions are written in only repeats the best
    // version, so it is left out of every view when the two settings name one written language.
    let gloss = !sameWrittenLanguage(settings.targetLanguage, settings.nativeLanguage)
    let request = LLMRequest(
      messages: [
        LLMMessage(
          role: .system,
          content: RewritePrompt.system(
            settings: settings, protection: protection, strict: strict)),
        LLMMessage(role: .user, content: message),
      ], maxOutputTokens: 4096)
    // Apply the alternative limit after dropping empty text, so an empty slot does not
    // displace a later usable alternative.
    var schema = SectionSchema.fix
    for index in schema.tags.indices where schema.tags[index].name == "alts" {
      schema.tags[index].children[0].retainedLimit = nil
    }
    let attempt = await RunnerAttempt.run(
      request: request, schema: schema, provider: provider, cancellation: cancellation,
      sections: {
        continuation.yield(
          .sections(
            restored(
              retainingAlternatives($0), protection: protection, inputCase: inputCase,
              gloss: gloss)))
      },
      retrying: { continuation.yield(.retrying(after: $0, cause: $1)) })
    let snapshot = retainingAlternatives(attempt.snapshot)
    let eligibility = attempt.eligibility
    let display = restored(
      snapshot, protection: protection, inputCase: inputCase, gloss: gloss)
    let altCount = snapshot.sections.first { $0.name == "alts" }?.children.count ?? 0
    var result = RewriteResult(
      snapshot: display, sections: nil, usage: attempt.usage, bestEligibility: eligibility,
      altEligibility: Array(repeating: eligibility, count: altCount))
    guard eligibility == .eligible else { return result }
    let original = FixSections(snapshot: snapshot)
    func validate(_ text: String) -> Eligibility {
      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .malformed }
      guard protection.delimiters != nil else { return .placeholdersUnavailable }
      return protection.validate(text) ? .eligible : .placeholdersChanged
    }
    result.bestEligibility = validate(original.best)
    result.altEligibility = original.alts.map { validate($0.text) }
    result.sections = FixSections(snapshot: display)
    return result
  }

  /// True when both tags name the same language in the same script: `en` and `en-GB`, but not
  /// `zh-Hans` and `zh-Hant`.
  private static func sameWrittenLanguage(_ a: String, _ b: String) -> Bool {
    let (a, b) = (Locale.Language(identifier: a), Locale.Language(identifier: b))
    guard let code = a.languageCode, code == b.languageCode else { return false }
    return a.script == b.script
  }

  private static func retainingAlternatives(_ snapshot: SectionsSnapshot) -> SectionsSnapshot {
    var snapshot = snapshot
    let limit = SectionSchema.fix.tags.first { $0.name == "alts" }!.children[0].retainedLimit!
    for index in snapshot.sections.indices where snapshot.sections[index].name == "alts" {
      snapshot.sections[index].children = Array(
        snapshot.sections[index].children.filter { alt in
          let text = alt.children.first { $0.name == "text" }?.text ?? ""
          return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.prefix(limit))
    }
    return snapshot
  }

  private static func restored(
    _ snapshot: SectionsSnapshot, protection: ProtectedInput, inputCase: RewriteCase, gloss: Bool
  ) -> SectionsSnapshot {
    func restore(_ node: SectionNode) -> SectionNode? {
      var node = node
      node.text = protection.restore(node.text)
      // Auxiliary fields are display-only; omit invented tokens from streaming views too.
      if ["gloss", "note", "fix"].contains(node.name), protection.containsUnknownToken(node.text) {
        return nil
      }
      node.children = node.children.compactMap(restore)
      return node
    }
    var snapshot = snapshot
    if inputCase == .translate { snapshot.sections.removeAll { $0.name == "fixes" } }
    if !gloss { snapshot.sections.removeAll { $0.name == "gloss" } }
    snapshot.sections = snapshot.sections.compactMap(restore)
    snapshot.rawText = protection.restore(snapshot.rawText)
    return snapshot
  }

  private static func combinedUsage(_ first: LLMUsage?, _ second: LLMUsage?) -> LLMUsage? {
    guard let first else { return second }
    guard let second else { return first }
    let reasoning =
      first.reasoningTokens == nil && second.reasoningTokens == nil
      ? nil : (first.reasoningTokens ?? 0) + (second.reasoningTokens ?? 0)
    return LLMUsage(
      promptTokens: first.promptTokens + second.promptTokens,
      completionTokens: first.completionTokens + second.completionTokens, reasoningTokens: reasoning
    )
  }
}
