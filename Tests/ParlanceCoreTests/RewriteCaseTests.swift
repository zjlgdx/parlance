import Testing

@testable import ParlanceCore

struct RewriteCaseTests {
  @Test(arguments: [
    ("en", "zh-Hans", #"lgtm ¯\_(ツ)_/¯ but pls fix the typo"#),
    ("en", "zh-Hans", "use a λ here, the μ value is wrong"),
    ("zh-Hans", "en", "登录页面在 Safari 上白屏"),
    ("ja", "zh-Hans", "iPhoneを買いました"),
    ("sr", "en", "Dobar dan, kako ste?"),
    ("en-US", "es-ES", "No idea"),
    ("en-US", "es-ES", "Final"),
    ("en-US", "es-ES", "Hola a todos"),
    ("en-US", "es-ES", "Necesito instrucciones"),
    // A draft in a third script gets no hypothesis from the two-language recognizer.
    ("ja", "en", "Пожалуйста, проверьте эту функцию и исправьте ошибку в ней"),
  ])
  func incidentalScriptsAndAmbiguousTextKeepFixes(
    _ target: String, _ native: String, _ input: String
  ) {
    #expect(
      RewriteCase.classify(
        input, settings: RewriteSettings(targetLanguage: target, nativeLanguage: native)) == .polish
    )
  }

  @Test(arguments: ["帮我看看", "把 `fetchUser()` 改成 async/await", "please 看看 this"])
  func translatesChinese(_ input: String) {
    #expect(RewriteCase.classify(input, settings: RewriteSettings()) == .translate)
  }

  @Test(arguments: [
    "please fix the bug in src/a.swift", "`帮我看看` `fetchUser()` async/await", "⟦0⟧",
    "`⟦0⟧` fetchUser src/a.swift", "123 ! 😀", "", "\u{301}",
  ])
  func preservesPolishOrProtectedInput(_ input: String) {
    #expect(RewriteCase.classify(input, settings: RewriteSettings()) == .polish)
  }

  @Test(arguments: ["東京", "帮我看看", "東京に行きます"])
  func japaneseAcceptsHanAndKana(_ input: String) {
    // Han belongs to both languages and therefore supplies no native-only script evidence.
    let settings = RewriteSettings(targetLanguage: "ja", nativeLanguage: "zh-Hans")
    #expect(RewriteCase.classify(input, settings: settings) == .polish)
  }

  @Test func recognizesSharedLatinScript() {
    let settings = RewriteSettings(targetLanguage: "en-US", nativeLanguage: "es-ES")
    #expect(
      RewriteCase.classify(
        "Por favor, revisa este documento y corrige los errores antes de enviarlo a mis compañeros.",
        settings: settings) == .translate)
    #expect(
      RewriteCase.classify(
        "Please review this document and correct the errors before sending it to my colleagues.",
        settings: settings) == .polish)
  }

  @Test(arguments: ["en", "zh-Hans", "hy"])
  func recognizesLongNativeTextWhenScriptEvidenceIsUnavailable(_ target: String) {
    #expect(
      RewriteCase.classify(
        "Por favor, revisa este documento y corrige los errores antes de enviarlo a mis compañeros.",
        settings: RewriteSettings(targetLanguage: target, nativeLanguage: "es-ES")) == .translate)
  }

  @Test func matchingLanguagesAndUnlistedScriptsAreConservative() {
    #expect(
      RewriteCase.classify(
        "帮我看看", settings: RewriteSettings(targetLanguage: "en-US", nativeLanguage: "en-GB"))
        == .polish)
    #expect(
      RewriteCase.classify(
        "帮我看看", settings: RewriteSettings(targetLanguage: "hy", nativeLanguage: "zh-Hans"))
        == .translate)  // #343: Armenian is no longer an unlisted script.
    #expect(
      RewriteCase.classify(
        "Բարև 帮", settings: RewriteSettings(targetLanguage: "hy", nativeLanguage: "zh-Hans"))
        == .polish)
    #expect(RewriteCase.classify("Հայերեն", settings: RewriteSettings()) == .polish)
  }

  @Test(arguments: [
    ("en", "hello"), ("zh-Hans", "汉字"), ("zh-Hant", "漢字"), ("ja", "カタカナ"),
    ("ko", "한글漢字"), ("ru", "Привет"), ("ar", "مرحبا"), ("he", "שלום"),
    ("el", "γειά"), ("th", "สวัสดี"), ("hi", "नमस्ते"),
  ])
  func commonScripts(_ language: String, _ input: String) {
    let native = language == "en" ? "zh-Hans" : "en"
    #expect(
      RewriteCase.classify(
        input, settings: RewriteSettings(targetLanguage: language, nativeLanguage: native))
        == .polish)
    let foreign = language == "en" ? "中文" : "ab"
    #expect(
      RewriteCase.classify(
        input + foreign, settings: RewriteSettings(targetLanguage: language, nativeLanguage: native)
      )
        == (language == "en" ? .translate : .polish))
    if language != "en" {
      let hasHan = ["zh-Hans", "zh-Hant", "ko"].contains(language)
      #expect(
        RewriteCase.classify(input, settings: RewriteSettings()) == (hasHan ? .translate : .polish))
    }
  }

  @Test(arguments: [
    ("zh-Hans", "我们的网站在 Safari 和 Firefox 上白屏了"), ("zh-Hans", "Safari 和 Firefox 上都白屏，Chrome 正常"),
    ("ja", "Google ChromeとMozilla Firefoxで表示が崩れます"),
    ("ko", "Visual Studio Code에서 Docker Compose를 사용하고 있습니다"),
  ])
  func keepsTargetTextWithLatinNames(_ target: String, _ input: String) {
    let settings = RewriteSettings(targetLanguage: target, nativeLanguage: "en")
    #expect(RewriteCase.classify(input, settings: settings) == .polish)
  }

  @Test(arguments: [
    ("el", "use a λ here, the μ value is wrong"), ("ja", "lgtm ¯\\_(ツ)_/¯ but pls fix the typo"),
    ("zh-Hans", "the 中 radical is drawn wrong"),
  ])
  func loneNativeLettersKeepCaseB(_ native: String, _ input: String) {
    let settings = RewriteSettings(targetLanguage: "en", nativeLanguage: native)
    #expect(RewriteCase.classify(input, settings: settings) == .polish)
  }

  @Test(arguments: [("el", "please γεια σου"), ("ja", "テストを直して"), ("zh-Hans", "fix 这个")])
  func nativeWordsMakeCaseA(_ native: String, _ input: String) {
    let settings = RewriteSettings(targetLanguage: "en", nativeLanguage: native)
    #expect(RewriteCase.classify(input, settings: settings) == .translate)
  }

  @Test(arguments: [
    ("bn", "আমি ভাত খাই"), ("ur", "میں ٹھیک ہوں"), ("ur-Aran", "میں ٹھیک ہوں"),
    ("ur-Arab", "میں ٹھیک ہوں"), ("ta", "வணக்கம்"), ("te", "నమస్కారం"), ("ka", "გამარჯობა"),
    ("hy", "Բարև ձեզ"), ("km", "សួស្តី"), ("my", "မင်္ဂလာပါ"), ("ja", "ユーザー"),
  ])
  func nativeScriptsFoundationInfersMakeCaseA(_ native: String, _ input: String) {
    let settings = RewriteSettings(targetLanguage: "en", nativeLanguage: native)
    #expect(RewriteCase.classify(input, settings: settings) == .translate)
    #expect(RewriteCase.classify("fix " + input, settings: settings) == .translate)
    #expect(RewriteCase.classify("please fix the flaky test", settings: settings) == .polish)
    #expect(RewriteCase.canDistinguish(settings))
  }

  @Test(arguments: ["ms", "fil", "sw", "sr-Latn"])
  func latinPairsTheRecognizerCannotJudgeStayCaseB(_ native: String) {
    // The recognizer does not know these languages; design §4 keeps such pairs in case B.
    let settings = RewriteSettings(targetLanguage: "en", nativeLanguage: native)
    #expect(
      RewriteCase.classify(
        "Tolong semak dokumen ini dan betulkan kesilapan sebelum menghantarnya kepada rakan saya.",
        settings: settings) == .polish)
    #expect(!RewriteCase.canDistinguish(settings))
  }

  @Test func pairsThatCanBeToldApartLocally() {
    for (target, native) in [
      ("en", "zh-Hans"), ("en-US", "es-ES"), ("zh-Hans", "en"), ("de", "fr"),
    ] {
      #expect(
        RewriteCase.canDistinguish(RewriteSettings(targetLanguage: target, nativeLanguage: native)))
    }
    // The same language, Han against Han plus kana, and an unknown tag leave nothing to go on.
    for (target, native) in [("en-US", "en-GB"), ("ja", "zh-Hans"), ("en", "xx")] {
      #expect(
        !RewriteCase.canDistinguish(
          RewriteSettings(targetLanguage: target, nativeLanguage: native)))
    }
  }
}
