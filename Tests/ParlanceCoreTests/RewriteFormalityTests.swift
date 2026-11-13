import Foundation
import Testing

@testable import ParlanceCore

/// #357, docs/designs/2026-11-12-rewrite-formality.md.
struct RewriteFormalityTests {
  private let caseA = "(case A), use the "
  private let formal = """
    formal register in best and in every alt: the polite everyday forms of
    address, verb forms and sentence endings, without moving up to honorific or business
    language.
    """
  private let informal =
    "informal register in best and in every alt: the forms used between friends."
  private let caseB = """
    When the input is already in the target language (case B), keep the register the user wrote
    in, in best and in every alt; do not change it to match the setting. There the tone preset
    changes the choice of words only, never the register: input written in the polite forms
    (such as Sie, vous, usted, です/ます or 해요) gives a best and alts in the polite forms, and
    input written in the familiar forms gives a best and alts in the familiar forms.
    """
  private let formalCue = """
    In case A the setting alone decides the register, never the input: input that addresses the reader
    familiarly, with a pronoun or only a verb form (such as 你, ты or tu), is still
    written in the polite forms (such as Sie, vous, usted, です/ます or 해요), in best and in
    every alt.
    """
  private let informalCue = """
    In case A the setting alone decides the register, never the input: input that addresses the reader
    politely, with a pronoun or only a verb form (such as 您, вы or vous), is still
    written in the familiar forms (such as du, tu, tú, Japanese plain forms or Korean 반말), in
    best and in every alt.
    """
  private let check = """
    Before you answer, check the register of every sentence of best and of each alt. In case B
    it is the register of the input, whatever the setting is. In case A it is in the

    """
  private let formalCheck =
    "polite forms (such as Sie, vous, usted, です/ます or 해요), whatever form of address the input uses."
  private let informalCheck =
    "familiar forms (such as du, tu, tú, Japanese plain forms or Korean 반말), whatever form of address the input uses."
  private let noFix = "The user's register is a choice, not a mistake: write no fix about it."
  private let correctRule = """
    The forms of address and the register (formal or informal) are not mistakes: keep them
    as the user wrote them.
    """

  private func prompts(
    target: String, tone: RewriteSettings.Tone, _ body: (String, String, String) -> Void
  ) {
    for native in ["zh-Hans", "en"] {
      for mode in RewriteSettings.Mode.allCases {
        for fixes in [true, false] {
          for protection in [nil, TermProtection.protect("use fooBar with --flag")] {
            for strict in [true, false] {
              func prompt(_ settings: RewriteSettings) -> String {
                RewritePrompt.system(settings: settings, protection: protection, strict: strict)
              }
              var settings = RewriteSettings(
                targetLanguage: target, nativeLanguage: native, tone: tone, includeFixes: fixes,
                mode: mode)
              let unset = prompt(settings)
              settings.formality = .formal
              let formal = prompt(settings)
              settings.formality = .informal
              body(unset, formal, prompt(settings))
            }
          }
        }
      }
    }
  }

  @Test func formalIsTheDefault() {
    #expect(RewriteSettings().formality == .formal)
    #expect(RewriteSettings.Formality.allCases.map(\.rawValue) == ["formal", "informal"])
  }

  /// The setting leaves no trace unless the tone is casual and the target marks formality.
  @Test(arguments: [
    ("en", RewriteSettings.Tone.casual), ("en-GB", .casual), ("zh-Hant", .casual), ("sv", .casual),
    ("hi", .casual), ("vi", .casual), ("xx", .casual), ("tlh", .casual), ("en", .agent),
    ("de", .agent), ("de-DE", .agent), ("ja", .agent), ("ko", .agent), ("es-MX", .agent),
    ("xx", .agent),
  ])
  func promptIsUnchangedWhenTheConditionFails(_ target: String, _ tone: RewriteSettings.Tone) {
    prompts(target: target, tone: tone) { unset, formal, informal in
      #expect(Array(formal.utf8) == Array(unset.utf8))
      #expect(Array(informal.utf8) == Array(unset.utf8))
      for fragment in ["Register:", "register", "forms of address", "form of address"] {
        #expect(!unset.contains(fragment), "\(fragment)")
      }
    }
  }

  @Test(arguments: [
    "de", "de-DE", "fr", "fr-BE", "es", "es-MX", "pt", "pt-BR", "ja", "ja-JP", "ko",
  ])
  func casualToneNamesTheRegisterForAMarkedTarget(_ target: String) {
    prompts(target: target, tone: .casual) { unset, formal, informal in
      #expect(Array(unset.utf8) == Array(formal.utf8))
      #expect(formal.contains(caseA + self.formal))
      #expect(!formal.contains("informal register in best"))
      #expect(informal.contains(caseA + self.informal))
      #expect(!informal.contains("polite everyday forms"))
      // #367: the setting, not a form of address in native-language input, decides case A; the
      // rule sits between the case A and case B sentences and is restated as the prompt's last
      // paragraph.
      #expect(formal.contains(self.formal + "\n" + formalCue + "\nWhen the input is already"))
      #expect(informal.contains(self.informal + "\n" + informalCue + "\nWhen the input is already"))
      #expect(formal.hasSuffix("\n\n" + check + formalCheck))
      #expect(informal.hasSuffix("\n\n" + check + informalCheck))
      for prompt in [formal, informal] {
        #expect(prompt.contains("\n\nRegister: when you write target-language text from input"))
        #expect(prompt.contains(caseB))
        #expect(!prompt.contains("Agent tone:"))
      }
    }
  }

  @Test func fixesSentenceFollowsTheFixesSection() {
    for mode in RewriteSettings.Mode.allCases {
      for formality in RewriteSettings.Formality.allCases {
        for fixes in [true, false] {
          let prompt = RewritePrompt.system(
            settings: RewriteSettings(
              targetLanguage: "ja", nativeLanguage: "en", tone: .casual, includeFixes: fixes,
              mode: mode, formality: formality))
          #expect(prompt.contains(noFix) == fixes, "\(mode) \(formality) \(fixes)")
          #expect(prompt.contains("<fixes>") == fixes)
          #expect(prompt.contains(caseB + (fixes ? "\n" + noFix : "") + "\n\n"))
        }
      }
    }
  }

  @Test func correctModeKeepsTheUsersRegister() {
    for formality in RewriteSettings.Formality.allCases {
      for fixes in [true, false] {
        func prompt(_ target: String, _ tone: RewriteSettings.Tone, _ mode: RewriteSettings.Mode)
          -> String
        {
          RewritePrompt.system(
            settings: RewriteSettings(
              targetLanguage: target, nativeLanguage: "en", tone: tone, includeFixes: fixes,
              mode: mode, formality: formality))
        }
        let correct = prompt("de", .casual, .correct)
        #expect(
          correct.contains(
            "a request keeps its wording and a question stays a question.\n" + correctRule
              + "\nWhen nothing is wrong, best is the input unchanged."))
        let altRule = "That <text> keeps the register of the input"
        #expect(correct.contains("input with its mistakes fixed. " + altRule))
        #expect(!prompt("de", .agent, .correct).contains(altRule))
        #expect(!prompt("en", .casual, .correct).contains(altRule))
        #expect(!prompt("de", .casual, .polish).contains(correctRule))
        #expect(!prompt("de", .agent, .correct).contains(correctRule))
        #expect(!prompt("en", .casual, .correct).contains(correctRule))
        #expect(!prompt("xx", .casual, .correct).contains(correctRule))
      }
    }
  }

  /// The paragraph takes the agent block's place: after the case and fixes rules, ahead of the
  /// correct-mode scope, the naming rule and the token rules.
  @Test func registerParagraphPosition() throws {
    let prompt = RewritePrompt.system(
      settings: RewriteSettings(
        targetLanguage: "ko", nativeLanguage: "en", tone: .casual, mode: .correct),
      protection: TermProtection.protect("use fooBar with --flag"))
    func offset(_ text: String) throws -> String.Index {
      try #require(prompt.range(of: text)).lowerBound
    }
    #expect(try offset("Never output a fixes section") < offset("Register:"))
    #expect(try offset(noFix) < offset("Correct mode, case B:"))
    #expect(try offset("Correct mode, case B:") < offset("Some inputs describe"))
    #expect(try offset("Some inputs describe") < offset("Tokens like"))
    #expect(try offset("Tokens like") < offset("Before you answer, check the register"))
  }

  /// #358: the App's stored setting defaults to formal, round-trips, and older data without the
  /// key decodes as formal with every other value kept.
  @Test func storedFormalityDefaultsRoundTripsAndMigrates() throws {
    #expect(ParlanceSettings().formality == .formal)
    var settings = ParlanceSettings()
    settings.formality = .informal
    settings.targetLanguage = "de"
    settings.tone = .casual
    let encoded = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(ParlanceSettings.self, from: encoded) == settings)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(legacy.removeValue(forKey: "formality") as? String == "informal")
    settings.formality = .formal
    let decoded = try JSONDecoder().decode(
      ParlanceSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded == settings)
  }
}
