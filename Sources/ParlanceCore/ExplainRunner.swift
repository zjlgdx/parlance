public struct ExplainSections: Sendable, Equatable {
  public struct Term: Sendable, Equatable {
    public let word: String
    public let ipa: String?
    public let meaning: String
    public let here: String
  }
  public let translation: String
  public let plain: String
  public let terms: [Term]

  init(snapshot: SectionsSnapshot) {
    translation = snapshot.sections.first { $0.name == "translation" }?.text ?? ""
    plain = snapshot.sections.first { $0.name == "plain" }?.text ?? ""
    terms = (snapshot.sections.first { $0.name == "terms" }?.children ?? []).map { term in
      Term(
        word: term.children.first { $0.name == "word" }?.text ?? "",
        ipa: term.children.first { $0.name == "ipa" }?.text,
        meaning: term.children.first { $0.name == "meaning" }?.text ?? "",
        here: term.children.first { $0.name == "here" }?.text ?? "")
    }
  }
}

public struct ExplainQuick: Sendable, Equatable {
  /// Streaming/raw text remains available for display; only eligible results may be exported.
  public let snapshot: SectionsSnapshot
  public let eligibility: Eligibility
  public let subject: PreparedSubject
  public let usage: LLMUsage?
  /// Available only after normal completion and structural validation.
  public var sections: ExplainSections? {
    eligibility == .eligible ? ExplainSections(snapshot: snapshot) : nil
  }
}

public enum ExplainDeepSection: String, Sendable, Equatable, CaseIterable {
  case vocab, domain
  var schema: SectionSchema { self == .vocab ? .explainVocab : .explainDomain }
}

public struct ExplainDeep: Sendable, Equatable {
  public let section: ExplainDeepSection
  public let snapshot: SectionsSnapshot
  public let eligibility: Eligibility
  public let subject: PreparedSubject
  public let usage: LLMUsage?
}

public struct ExplainAnswer: Sendable, Equatable {
  public let text: String
  public let eligibility: Eligibility
  public let usage: LLMUsage?
}

public struct ExplainConversation: Sendable, Equatable {
  public struct Round: Sendable, Equatable {
    public var question: String
    public var answer: String
    public init(question: String, answer: String) {
      self.question = question
      self.answer = answer
    }
  }
  public let subject: PreparedSubject
  public let quickResult: String
  public var rounds: [Round]

  public init(subject: PreparedSubject, quickResult: String, rounds: [Round] = []) {
    self.subject = subject
    self.quickResult = quickResult
    self.rounds = rounds
  }
}

public enum ExplainUpdate<Result: Sendable & Equatable>: Sendable, Equatable {
  case prepared(PreparedSubject)
  /// Follow-up uses rawText, with no parsed sections.
  case sections(SectionsSnapshot)
  case retrying(after: Duration, cause: LLMErrorCode)
  case completed(Result)
}

public enum ExplainError: Error, Sendable, Equatable {
  case ineligibleQuick
}

public enum ExplainRunner {
  /// Preparation is yielded before calling the provider, including on failures or cancellation.
  /// As in RewriteRunner, provider errors complete with an incomplete result.
  public static func quick(
    subject: ExplainSubject, settings: ExplainSettings, provider: any LLMProvider,
    cancellation: LLMCancellation
  ) -> AsyncThrowingStream<ExplainUpdate<ExplainQuick>, any Error> {
    let prepared = PreparedSubject(subject: subject)
    return run(
      request: ExplainPrompt.quick(subject: prepared, settings: settings), schema: .explainQuick,
      prepared: prepared, provider: provider, cancellation: cancellation
    ) {
      ExplainQuick(
        snapshot: $0.snapshot, eligibility: $0.eligibility, subject: prepared, usage: $0.usage)
    }
  }

  /// An ineligible quick result throws ExplainError.ineligibleQuick without a provider call.
  public static func deep(
    _ section: ExplainDeepSection, from quick: ExplainQuick, settings: ExplainSettings,
    provider: any LLMProvider, cancellation: LLMCancellation
  ) -> AsyncThrowingStream<ExplainUpdate<ExplainDeep>, any Error> {
    guard quick.eligibility == .eligible else {
      return AsyncThrowingStream { $0.finish(throwing: ExplainError.ineligibleQuick) }
    }
    return run(
      request: ExplainPrompt.deep(section, subject: quick.subject, settings: settings),
      schema: section.schema, provider: provider, cancellation: cancellation
    ) {
      ExplainDeep(
        section: section, snapshot: $0.snapshot, eligibility: $0.eligibility,
        subject: quick.subject, usage: $0.usage)
    }
  }

  /// Reads but never modifies caller-owned history. Questions and prior answers are kept verbatim.
  public static func followUp(
    question: String, conversation: ExplainConversation, settings: ExplainSettings,
    provider: any LLMProvider, cancellation: LLMCancellation
  ) -> AsyncThrowingStream<ExplainUpdate<ExplainAnswer>, any Error> {
    run(
      request: ExplainPrompt.followUp(
        question: question, conversation: conversation, settings: settings),
      schema: nil, provider: provider, cancellation: cancellation
    ) {
      ExplainAnswer(text: $0.snapshot.rawText, eligibility: $0.eligibility, usage: $0.usage)
    }
  }

  private static func run<Result: Sendable & Equatable>(
    request: LLMRequest, schema: SectionSchema?, prepared: PreparedSubject? = nil,
    provider: any LLMProvider, cancellation: LLMCancellation,
    result: @escaping @Sendable (RunnerAttempt) -> Result
  ) -> AsyncThrowingStream<ExplainUpdate<Result>, any Error> {
    let (stream, continuation) = AsyncThrowingStream<ExplainUpdate<Result>, any Error>.makeStream()
    if let prepared { continuation.yield(.prepared(prepared)) }
    let task = Task {
      let attempt = await RunnerAttempt.run(
        request: request, schema: schema, provider: provider, cancellation: cancellation,
        sections: { continuation.yield(.sections($0)) },
        retrying: { continuation.yield(.retrying(after: $0, cause: $1)) })
      continuation.yield(.completed(result(attempt)))
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
}
