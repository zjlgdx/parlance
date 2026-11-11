public enum CommandEffect: String, Sendable, Equatable, CaseIterable {
  case writes, deletes, network, privilege
}

public struct CommandPart: Sendable, Equatable {
  public let code: String
  public let does: String
  public let effects: [CommandEffect]

  public init(code: String, does: String, effects: [CommandEffect]) {
    self.code = code
    self.does = does
    self.effects = effects
  }

  /// `input` is the prepared input that was sent; `<code>` is checked against it (see `verbatim`).
  public init(section: SectionNode, input: String) {
    code = Self.verbatim(section.children.first { $0.name == "code" }?.text ?? "", in: input)
    does = section.children.first { $0.name == "does" }?.text ?? ""
    let words = (section.children.first { $0.name == "effects" }?.text ?? "")
      .lowercased().split { $0 == "," || $0.isWhitespace }
    effects = CommandEffect.allCases.filter { words.contains(Substring($0.rawValue)) }
  }

  /// Some models write `&`, `<`, `>` and quotes in `<code>` as XML entities although the prompt
  /// forbids it (`2&gt;&amp;1`, #307). The decoded text replaces the code only when the code is
  /// not a verbatim substring of the input and the decoded text is; a code that is already
  /// verbatim (including an input that itself contains `&amp;`) or that differs from the input in
  /// any other way is kept as the model wrote it.
  static func verbatim(_ code: String, in input: String) -> String {
    guard !input.contains(code) else { return code }
    let decoded = decodingXMLEntities(code)
    return decoded != code && input.contains(decoded) ? decoded : code
  }

  static let xmlEntities = [
    ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
  ]

  /// One left-to-right pass over the five predefined XML entities, so `&amp;lt;` becomes `&lt;`.
  static func decodingXMLEntities(_ text: String) -> String {
    var result = ""
    var rest = Substring(text)
    while let ampersand = rest.firstIndex(of: "&") {
      result += rest[..<ampersand]
      rest = rest[ampersand...]
      if let (entity, character) = xmlEntities.first(where: { rest.hasPrefix($0.0) }) {
        result += character
        rest = rest.dropFirst(entity.count)
      } else {
        result += "&"
        rest = rest.dropFirst()
      }
    }
    return result + rest
  }
}

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
  public let command: [CommandPart]?

  init(snapshot: SectionsSnapshot, input: String) {
    command = snapshot.sections.first { $0.name == "command" }?.children.map {
      CommandPart(section: $0, input: input)
    }
    translation = snapshot.sections.first { $0.name == "translation" }?.text ?? ""
    plain = snapshot.sections.first { $0.name == "plain" }?.text ?? ""
    terms = Self.terms(in: snapshot)
  }

  /// The quick layer and document mode share the `<terms>` structure.
  static func terms(in snapshot: SectionsSnapshot) -> [Term] {
    (snapshot.sections.first { $0.name == "terms" }?.children ?? []).map { term in
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
    eligibility == .eligible ? ExplainSections(snapshot: snapshot, input: subject.input) : nil
  }
}

public enum ExplainMode: String, Sendable, Equatable {
  case quick, document
}

public struct ExplainDocumentSections: Sendable, Equatable {
  public struct Part: Sendable, Equatable {
    public let heading: String
    public let plain: String
  }
  public let gist: String
  public let decisions: [String]
  public let parts: [Part]
  public let terms: [ExplainSections.Term]

  /// `input` is the document as sent. Models write `&`, `<`, `>` and quotes in every field as XML
  /// entities (#303 eval). When the document contains no entity text, every field is decoded;
  /// when it does, the model may be quoting it, so only headings and term words, which are copied
  /// from the document, are decoded, and only when that makes them verbatim (the `<code>` rule).
  /// Known limit: an answer that deliberately writes an entity about a document without any is
  /// decoded too. Public so streaming renderers can decode an in-progress snapshot the same way;
  /// part `i` here is child `i` of the snapshot's `<parts>`.
  public init(snapshot: SectionsSnapshot, input: String) {
    let decodesAll = !CommandPart.xmlEntities.contains { input.contains($0.0) }
    let prose = { decodesAll ? CommandPart.decodingXMLEntities($0) : $0 }
    let copied = {
      decodesAll ? CommandPart.decodingXMLEntities($0) : CommandPart.verbatim($0, in: input)
    }
    gist = prose(snapshot.sections.first { $0.name == "gist" }?.text ?? "")
    decisions =
      snapshot.sections.first { $0.name == "decisions" }?.children.map { prose($0.text) } ?? []
    parts = (snapshot.sections.first { $0.name == "parts" }?.children ?? []).map { part in
      Part(
        heading: copied(part.children.first { $0.name == "heading" }?.text ?? ""),
        plain: prose(part.children.first { $0.name == "plain" }?.text ?? ""))
    }
    terms = ExplainSections.terms(in: snapshot).map {
      ExplainSections.Term(
        word: copied($0.word), ipa: $0.ipa.map(prose), meaning: prose($0.meaning),
        here: prose($0.here))
    }
  }
}

public struct ExplainDocument: Sendable, Equatable {
  /// Global maximum in Swift Characters (`String.count`), matching the CLI input check.
  /// The per-preset effective limit is set by the platform verification note.
  public static let maximumCharacters = 60_000

  /// Streaming/raw text remains available for display; only eligible results may be exported.
  public let snapshot: SectionsSnapshot
  public let eligibility: Eligibility
  public let subject: PreparedSubject
  public let usage: LLMUsage?
  /// Available only after normal completion and structural validation.
  public var sections: ExplainDocumentSections? {
    eligibility == .eligible
      ? ExplainDocumentSections(snapshot: snapshot, input: subject.input) : nil
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
  /// Raw text of the initial result, either quick or document mode.
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
    cancellation: LLMCancellation, glossaryStore: GlossaryStore? = nil
  ) -> AsyncThrowingStream<ExplainUpdate<ExplainQuick>, any Error> {
    quick(
      prepared: PreparedSubject(subject: subject), settings: settings, provider: provider,
      cancellation: cancellation, glossaryStore: glossaryStore)
  }

  /// Reuses the exact redacted windows; preparing them again could clip a boundary placeholder.
  public static func quick(
    prepared: PreparedSubject, settings: ExplainSettings, provider: any LLMProvider,
    cancellation: LLMCancellation, glossaryStore: GlossaryStore? = nil
  ) -> AsyncThrowingStream<ExplainUpdate<ExplainQuick>, any Error> {
    let prepared = prepared.withGlossary(glossaryStore, settings: settings)
    return run(
      request: ExplainPrompt.quick(subject: prepared, settings: settings),
      schema: ShellCommandDetector.isCommand(prepared.input) ? .explainCommand : .explainQuick,
      prepared: prepared, provider: provider, cancellation: cancellation
    ) {
      ExplainQuick(
        snapshot: $0.snapshot, eligibility: $0.eligibility, subject: prepared, usage: $0.usage)
    }
  }

  public static func document(
    subject: ExplainSubject, settings: ExplainSettings, provider: any LLMProvider,
    cancellation: LLMCancellation, glossaryStore: GlossaryStore? = nil
  ) -> AsyncThrowingStream<ExplainUpdate<ExplainDocument>, any Error> {
    document(
      prepared: PreparedSubject(subject: subject), settings: settings, provider: provider,
      cancellation: cancellation, glossaryStore: glossaryStore)
  }

  /// Yields and sends the same redacted, attachment-free subject, including when switching modes.
  public static func document(
    prepared: PreparedSubject, settings: ExplainSettings, provider: any LLMProvider,
    cancellation: LLMCancellation, glossaryStore: GlossaryStore? = nil
  ) -> AsyncThrowingStream<ExplainUpdate<ExplainDocument>, any Error> {
    let subject = prepared.forDocument().withGlossary(glossaryStore, settings: settings)
    return run(
      request: ExplainPrompt.document(subject: subject, settings: settings),
      schema: .explainDocument, prepared: subject, provider: provider, cancellation: cancellation
    ) {
      ExplainDocument(
        snapshot: $0.snapshot, eligibility: $0.eligibility, subject: subject, usage: $0.usage)
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
    mode: ExplainMode = .quick,
    provider: any LLMProvider, cancellation: LLMCancellation
  ) -> AsyncThrowingStream<ExplainUpdate<ExplainAnswer>, any Error> {
    run(
      request: ExplainPrompt.followUp(
        question: question, conversation: conversation, settings: settings, mode: mode),
      schema: nil, provider: provider, cancellation: cancellation
    ) {
      ExplainAnswer(text: $0.snapshot.rawText, eligibility: $0.eligibility, usage: $0.usage)
    }
  }

  private static func filterTerms(
    _ snapshot: SectionsSnapshot, prepared: PreparedSubject?,
    schema: SectionSchema?
  ) -> SectionsSnapshot {
    guard let prepared, !prepared.glossary.isEmpty else { return snapshot }
    var copy = snapshot
    let document = schema == .explainDocument
    for index in copy.sections.indices where copy.sections[index].name == "terms" {
      copy.sections[index].children.removeAll { term in
        var word = term.children.first { $0.name == "word" }?.text ?? ""
        if document {
          word =
            CommandPart.xmlEntities.contains { prepared.input.contains($0.0) }
            ? CommandPart.verbatim(word, in: prepared.input) : CommandPart.decodingXMLEntities(word)
        }
        return prepared.glossary.contains { Glossary.isSameTerm(word, entry: $0) }
      }
    }
    return copy
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
        sections: {
          continuation.yield(.sections(filterTerms($0, prepared: prepared, schema: schema)))
        },
        retrying: { continuation.yield(.retrying(after: $0, cause: $1)) })
      let filtered = RunnerAttempt(
        snapshot: filterTerms(attempt.snapshot, prepared: prepared, schema: schema),
        eligibility: attempt.eligibility, usage: attempt.usage)
      continuation.yield(.completed(result(filtered)))
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
