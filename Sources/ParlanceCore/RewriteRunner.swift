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
  /// Consumers must check each version's eligibility before copying its restored text.
  public var sections: FixSections?
  public var usage: LLMUsage?
  public var bestEligibility: Eligibility
  public var altEligibility: [Eligibility]
  public var fallback: Fallback? = nil
  public var strictRetried = false
}

public enum RewriteUpdate: Sendable, Equatable {
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
    cancellation: LLMCancellation
  ) -> AsyncThrowingStream<RewriteUpdate, any Error> {
    let (stream, continuation) = AsyncThrowingStream<RewriteUpdate, any Error>.makeStream()
    let task = Task {
      let protection = TermProtection.protect(input)
      let inputCase = RewriteCase.classify(protection, settings: settings)
      let first = await attempt(
        settings: settings, protection: protection, inputCase: inputCase, strict: false,
        provider: provider,
        cancellation: cancellation, continuation: continuation)
      var result = first
      if first.bestEligibility == .placeholdersChanged
        || first.altEligibility.contains(.placeholdersChanged)
      {
        continuation.yield(.strictRetry)
        result = await attempt(
          settings: settings, protection: protection, inputCase: inputCase, strict: true,
          provider: provider,
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
    strict: Bool, provider: any LLMProvider,
    cancellation: LLMCancellation,
    continuation: AsyncThrowingStream<RewriteUpdate, any Error>.Continuation
  ) async -> RewriteResult {
    let request = LLMRequest(
      messages: [
        LLMMessage(
          role: .system,
          content: RewritePrompt.system(
            settings: settings, protection: protection, strict: strict)),
        LLMMessage(role: .user, content: protection.text),
      ], maxOutputTokens: 4096)
    let attempt = await RunnerAttempt.run(
      request: request, schema: .fix, provider: provider, cancellation: cancellation,
      sections: {
        continuation.yield(.sections(restored($0, protection: protection, inputCase: inputCase)))
      },
      retrying: { continuation.yield(.retrying(after: $0, cause: $1)) })
    let snapshot = attempt.snapshot
    let eligibility = attempt.eligibility
    let display = restored(snapshot, protection: protection, inputCase: inputCase)
    let altCount = snapshot.sections.first { $0.name == "alts" }?.children.count ?? 0
    var result = RewriteResult(
      snapshot: display, sections: nil, usage: attempt.usage, bestEligibility: eligibility,
      altEligibility: Array(repeating: eligibility, count: altCount))
    guard eligibility == .eligible else { return result }
    let original = FixSections(snapshot: snapshot)
    func validate(_ text: String) -> Eligibility {
      guard protection.delimiters != nil else { return .placeholdersUnavailable }
      return protection.validate(text) ? .eligible : .placeholdersChanged
    }
    result.bestEligibility = validate(original.best)
    result.altEligibility = original.alts.map { validate($0.text) }
    result.sections = FixSections(snapshot: display)
    return result
  }

  private static func restored(
    _ snapshot: SectionsSnapshot, protection: ProtectedInput, inputCase: RewriteCase
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
