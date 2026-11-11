import Foundation
import Testing

@testable import ParlanceCore

struct RewriteModeTests {
  @Test func polishRemainsDefault() {
    for tone in RewriteSettings.Tone.allCases {
      for fixes in [true, false] {
        for protection in [nil, TermProtection.protect("use fooBar with --flag")] {
          for strict in [true, false] {
            let implicit = RewritePrompt.system(
              settings: RewriteSettings(tone: tone, includeFixes: fixes),
              protection: protection, strict: strict)
            let explicit = RewritePrompt.system(
              settings: RewriteSettings(tone: tone, includeFixes: fixes, mode: .polish),
              protection: protection, strict: strict)
            #expect(Array(implicit.utf8) == Array(explicit.utf8))
            #expect(
              explicit.contains(
                "Case B, the whole input is already in the target language: polish it."))
            #expect(explicit.contains("word-for-word translation") == fixes)
            #expect(explicit.contains("Agent tone: best and every alt text") == (tone == .agent))
          }
        }
      }
    }
  }

  @Test func correctPromptChangesOnlyTheTask() {
    for tone in RewriteSettings.Tone.allCases {
      for mode in RewriteSettings.Mode.allCases {
        let prompt = RewritePrompt.system(settings: RewriteSettings(tone: tone, mode: mode))
        #expect(prompt.contains("translate it into idiomatic target language"))
        #expect(prompt.contains("No fixes section, not even an empty one"))
        #expect(prompt.contains("Agent tone:") == (tone == .agent))
        if mode == .correct {
          for fragment in [
            "correct it", "fixing\nevery spelling", "keep every other word",
            "alts holds\nexactly one <alt>",
            "one change you made in best", "Write no fix for anything best leaves unchanged",
            "the capitalization, the",
            "Correct mode, case B: the tone preset applies only to the <text> of the <alt>",
            "its <text> is the input polished",
            "a request keeps its wording and a question stays a",
          ] {
            #expect(prompt.contains(fragment))
          }
          #expect(!prompt.contains("polish it."))
          #expect(!prompt.contains("word-for-word translation"))
          if tone == .agent {
            #expect(prompt.contains("in case B best keeps the user's own\nsentences."))
          }
        }
      }
    }
    let noFixes = RewritePrompt.system(
      settings: RewriteSettings(tone: .casual, includeFixes: false, mode: .correct))
    #expect(!noFixes.contains("fixes"))
    #expect(!noFixes.contains("<fix>"))
    #expect(!noFixes.contains("one change you made in best"))
    #expect(noFixes.contains("fixing\nevery spelling"))
    #expect(!noFixes.contains("Agent tone:"))
    for fixes in [true, false] {
      let prompt = RewritePrompt.system(
        settings: RewriteSettings(includeFixes: fixes, mode: .correct))
      #expect(prompt.contains("abbreviations such as pls, u or dont"))
      #expect(prompt.contains("keep them unchanged in best"))
    }
  }

  @Test func correctSurvivesStrictRetryAndStillRejectsChangedTokens() async throws {
    let bad =
      "<best>use changed</best><gloss>使用</gloss>"
      + "<alts><alt><text>use changed</text><note>说明</note></alt></alts>"
    let steps: [MockProvider.Step] = [.event(.text(bad)), .event(.finished(.stop))]
    let provider = MockProvider(scripts: [steps, steps])
    let result = try await bounded {
      for try await update in RewriteRunner.run(
        input: "use fooBar", settings: RewriteSettings(mode: .correct), provider: provider,
        cancellation: LLMCancellation())
      {
        if case .completed(let result) = update { return result }
      }
      throw TestDeadline()
    }
    #expect(result.strictRetried)
    #expect(result.bestEligibility != .eligible)
    #expect(provider.recordedRequests.count == 2)
    for request in provider.recordedRequests {
      #expect(
        request.messages[0].content.contains(
          "Case B, the whole input is already in the target language: correct it."))
    }
    let retry = try #require(provider.recordedRequests.last)
    #expect(retry.messages[0].content.contains("The previous answer changed these tokens"))
  }

  @Test func storedModeDefaultsRoundTripsAndMigrates() throws {
    #expect(ParlanceSettings().rewriteMode == .polish)
    var settings = ParlanceSettings()
    settings.rewriteMode = .correct
    settings.targetLanguage = "ja"
    settings.tone = .casual
    settings.includeFixes = false
    let encoded = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(ParlanceSettings.self, from: encoded) == settings)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "rewriteMode")
    settings.rewriteMode = .polish
    let decoded = try JSONDecoder().decode(
      ParlanceSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded == settings)
  }
}
