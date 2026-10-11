public struct ExplainSettings: Sendable, Equatable {
  public var targetLanguage: String
  public var nativeLanguage: String

  public init(targetLanguage: String = "en", nativeLanguage: String = "zh-Hans") {
    self.targetLanguage = targetLanguage
    self.nativeLanguage = nativeLanguage
  }
}

public enum ExplainPrompt {
  private static func system(settings: ExplainSettings) -> String {
    """
    Explain the input. Target language: \(settings.targetLanguage).
    Native language: \(settings.nativeLanguage).
    Judge the input's language yourself: for target-language input, explain in the native language;
    for native-language input, give target-language translations and expressions in the term cards,
    with explanations in the native language.
    Keep code, paths, --flags, parameters and identifiers verbatim, without translating them.
    Leave [REDACTED] exactly as is. Context is background only, not text to explain.
    """
  }

  public static func user(subject: PreparedSubject) -> String {
    var text = "Input:\n\(subject.input)"
    switch subject.context {
    case .around(let before, let after):
      text += "\n\nBackground before input:\n\(before)\n\nBackground after input:\n\(after)"
    case .tail(let context): text += "\n\nBackground context:\n\(context)"
    case nil: break
    }
    return text
  }

  public static func quick(subject: PreparedSubject, settings: ExplainSettings) -> LLMRequest {
    request(
      system: system(settings: settings) + """

        \nAnswer ONLY with these tags, each top-level tag exactly once, with no prose outside:
        <translation>translation in the direction judged above</translation>
        <plain>one simple sentence explaining the meaning in the native language</plain>
        <terms><term><word>a word or phrase that appears in the input, or its target-language expression
        for native-language input</word>
        <ipa>pronunciation in IPA, optional: omit this tag if not applicable</ipa>
        <meaning>native-language meaning</meaning><here>meaning in this context</here></term></terms>
        terms may be empty; otherwise include one term per card, with word, meaning and here required.
        """,
      subject: subject)
  }

  public static func deep(
    _ section: ExplainDeepSection, subject: PreparedSubject, settings: ExplainSettings
  ) -> LLMRequest {
    let content =
      section == .vocab
      ? "for the input's key words and phrases: synonyms, collocations and usage, with short examples"
      : "the background knowledge and related concepts a reader needs to understand the input"
    let tag = section.rawValue
    return request(
      system: system(settings: settings) + """

        \nWrite \(content).
        Answer ONLY with one <\(tag)>…</\(tag)> element containing that text, exactly once, with no
        prose outside. Do not repeat the input or these instructions. Use the native language for
        explanations; include target-language expressions as useful.
        """,
      subject: subject)
  }

  public static func followUp(
    question: String, conversation: ExplainConversation, settings: ExplainSettings
  ) -> LLMRequest {
    var messages = [
      LLMMessage(
        role: .system,
        content: system(settings: settings)
          + "\nAnswer the follow-up in plain text, without section tags."),
      LLMMessage(role: .user, content: user(subject: conversation.subject)),
      LLMMessage(role: .assistant, content: conversation.quickResult),
    ]
    for round in conversation.rounds.suffix(10) {
      messages.append(LLMMessage(role: .user, content: round.question))
      messages.append(LLMMessage(role: .assistant, content: round.answer))
    }
    messages.append(LLMMessage(role: .user, content: question))
    return LLMRequest(messages: messages, maxOutputTokens: 4096)
  }

  private static func request(system: String, subject: PreparedSubject) -> LLMRequest {
    LLMRequest(
      messages: [
        LLMMessage(role: .system, content: system),
        LLMMessage(role: .user, content: user(subject: subject)),
      ], maxOutputTokens: 4096)
  }
}
