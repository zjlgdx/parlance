import Foundation
import Testing

@testable import ParlanceCore

/// #339: prompts name both languages and keep examples that belong to one language out of others.
struct PromptLanguagePairTests {
  private func hasHan(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
  }

  private var subject: PreparedSubject {
    PreparedSubject(subject: ExplainSubject(input: "a normal sentence", inputRedaction: .keep))
  }

  private var command: PreparedSubject {
    PreparedSubject(subject: ExplainSubject(input: "git rebase -i HEAD~3", inputRedaction: .keep))
  }

  @Test func rewriteNamesBothLanguagesAndAsksForTheNativeOne() {
    for tone in RewriteSettings.Tone.allCases {
      for mode in RewriteSettings.Mode.allCases {
        let prompt = RewritePrompt.system(
          settings: RewriteSettings(
            targetLanguage: "pt-BR", nativeLanguage: "en", tone: tone, mode: mode))
        #expect(prompt.contains("Target language: Portuguese (Brazil) (pt-BR)."))
        #expect(prompt.contains("Native language: English (en)."))
        #expect(prompt.contains("Write gloss, every note and every fix in the native language"))
      }
    }
    let noFixes = RewritePrompt.system(
      settings: RewriteSettings(targetLanguage: "de", nativeLanguage: "en", includeFixes: false))
    #expect(noFixes.contains("Write gloss and every note in the native language"))
    #expect(!noFixes.contains("every fix"))
  }

  @Test func englishExamplesGoOnlyToAnEnglishTarget() {
    for tone in RewriteSettings.Tone.allCases {
      for mode in RewriteSettings.Mode.allCases {
        for fixes in [true, false] {
          let other = RewritePrompt.system(
            settings: RewriteSettings(
              targetLanguage: "de", nativeLanguage: "en", tone: tone, includeFixes: fixes,
              mode: mode))
          for fragment in ["pls", "this test fail", "raise the speed", "English name"] {
            #expect(!other.contains(fragment), "\(fragment) in \(tone) \(mode) \(fixes)")
          }
          #expect(other.contains("the name established in the target language"))
          #expect(other.contains("is X broken? could Y do Z?") == (tone == .agent))
          let english = RewritePrompt.system(
            settings: RewriteSettings(
              targetLanguage: "en-GB", nativeLanguage: "de", tone: tone, includeFixes: fixes,
              mode: mode))
          #expect(english.contains("established English name"))
          #expect(english.contains("pls, u or dont") == (fixes || mode == .correct))
          #expect(english.contains("this test fail") == (fixes || mode == .correct))
          #expect(english.contains("raise the speed") == (fixes && mode == .polish))
        }
      }
    }
    let agent = RewritePrompt.system(
      settings: RewriteSettings(targetLanguage: "de", nativeLanguage: "en"))
    #expect(agent.contains("write the same kind of instruction in the\ntarget language"))
  }

  @Test func chineseExamplesGoOnlyToAChineseNativeLanguage() {
    for tone in RewriteSettings.Tone.allCases {
      for mode in RewriteSettings.Mode.allCases {
        #expect(
          !hasHan(
            RewritePrompt.system(
              settings: RewriteSettings(
                targetLanguage: "en", nativeLanguage: "ja", tone: tone, mode: mode))))
      }
    }
    for native in ["zh-Hans", "zh-Hant"] {
      let prompt = RewritePrompt.system(settings: RewriteSettings(nativeLanguage: native))
      #expect(prompt.contains("为什么 X"))
      #expect(prompt.contains("让数字从 0 滚到目标值"))
    }
    let japanese = ExplainSettings(nativeLanguage: "ja")
    #expect(!hasHan(ExplainPrompt.quick(subject: command, settings: japanese).messages[0].content))
    #expect(
      ExplainPrompt.quick(subject: command, settings: ExplainSettings()).messages[0].content
        .contains("不确定这个参数的含义"))
  }

  @Test func explainRequestsNameBothLanguagesAndKeepTheNativeOne() {
    let settings = ExplainSettings(targetLanguage: "en-GB", nativeLanguage: "zh-Hant")
    let conversation = ExplainConversation(subject: subject, quickResult: "reply")
    var prompts = [
      ExplainPrompt.quick(subject: subject, settings: settings),
      ExplainPrompt.quick(subject: command, settings: settings),
      ExplainPrompt.document(subject: subject, settings: settings),
    ]
    prompts += ExplainDeepSection.allCases.map {
      ExplainPrompt.deep($0, subject: subject, settings: settings)
    }
    for mode in [ExplainMode.quick, .document] {
      let followUp = ExplainPrompt.followUp(
        question: "why?", conversation: conversation, settings: settings, mode: mode)
      #expect(
        followUp.messages[0].content.hasSuffix(
          "Write the answer in Chinese, Traditional, the native language, even when the question is asked in another language."
        ))
      prompts.append(followUp)
    }
    for prompt in prompts.map({ $0.messages[0].content }) {
      #expect(prompt.contains("Target language: English (United Kingdom) (en-GB)."))
      #expect(prompt.contains("Native language: Chinese, Traditional (zh-Hant)."))
      #expect(prompt.contains("native language"))
    }
    // #368: each direction names its language, so a non-English pair does not fall back to
    // English: target-language input is translated into the native language.
    let quick = ExplainPrompt.quick(subject: subject, settings: settings).messages[0].content
    #expect(
      quick.contains(
        "for input in English (United Kingdom), the target language, translate it\n"
          + "into Chinese, Traditional and explain in Chinese, Traditional, the native "
          + "language"
      ))
    #expect(
      quick.contains(
        "<plain>one simple sentence explaining the meaning in Chinese, Traditional, the native "
          + "language</plain>"
      ))
    let commandPrompt = ExplainPrompt.quick(
      subject: PreparedSubject(
        subject: ExplainSubject(input: "git rebase -i HEAD~3", inputRedaction: .keep)),
      settings: settings
    ).messages[0].content
    #expect(
      commandPrompt.contains("one or two sentences in Chinese, Traditional, the native language"))
    #expect(commandPrompt.contains("the overall effect in Chinese, Traditional, naming"))
    // Input in a third language is translated for the reader, not into the target language.
    #expect(
      ExplainPrompt.quick(subject: subject, settings: settings).messages[0].content
        .contains(
          "translate it into Chinese, Traditional, not into English (United Kingdom), and"))
  }

  @Test func anUnknownTagStaysAsWritten() {
    #expect(LanguageCatalog.promptName("xx-custom") == "xx-custom")
    #expect(LanguageCatalog.promptName("zh-Hans") == "Chinese, Simplified (zh-Hans)")
  }
}
