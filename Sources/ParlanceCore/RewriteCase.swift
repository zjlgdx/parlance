import Foundation
import NaturalLanguage

public enum RewriteCase: Sendable, Equatable {
  case translate, polish

  public static func classify(_ text: String, settings: RewriteSettings) -> Self {
    classify(TermProtection.protect(text), settings: settings)
  }

  static func classify(_ protection: ProtectedInput, settings: RewriteSettings) -> Self {
    let target = Locale.Language(identifier: settings.targetLanguage)
    let native = Locale.Language(identifier: settings.nativeLanguage)
    guard target.languageCode != native.languageCode || target.script != native.script else {
      return .polish
    }
    // Protection tokens contain only delimiters and digits. Replacing nonletters with spaces
    // excludes them and preserves word boundaries for language recognition.
    let letters = protection.text.unicodeScalars.filter(isLetter)
    guard !letters.isEmpty else { return .polish }
    let targetScripts = LanguageScripts.codes(script: target.script?.identifier)
    if let evidence = evidenceScripts(target: target, native: native), let targetScripts {
      // A lone letter such as a kaomoji's katakana or a Greek symbol is not prose, so case A
      // needs two adjacent letters from a script only the native language uses. Swift's regex
      // search counts by Character, so a letter with its combining marks (Devanagari or Khmer
      // vowel signs, Arabic harakat) is one letter here.
      guard !evidence.isEmpty else { return .polish }
      let pattern =
        "[" + LanguageScripts.letters(evidence) + "--" + LanguageScripts.letters(targetScripts)
        + "]{2}"
      return protection.text.range(of: pattern, options: .regularExpression) != nil
        ? .translate : .polish
    }
    // Latin letters appear in every language as product names and acronyms, and the recognizer
    // weighs them over CJK text, so any letter in a non-Latin target's script keeps case B; only
    // an all-Latin draft is left to the recognizer.
    if let targetScripts, !targetScripts.contains("Latn"),
      LanguageScripts.containsLetter(protection.text, in: targetScripts)
    {
      return .polish
    }
    let prose = String(
      String.UnicodeScalarView(protection.text.unicodeScalars.map { isLetter($0) ? $0 : " " }))
    guard letters.count >= 15, prose.split(whereSeparator: { $0.isWhitespace }).count >= 3,
      let targetLanguage = recognizerLanguage(target),
      let nativeLanguage = recognizerLanguage(native), targetLanguage != nativeLanguage
    else { return .polish }
    let recognizer = NLLanguageRecognizer()
    // An unsupported target constraint can collapse the pair to native with probability 1.
    // Probe target support before interpreting the two-language confidence.
    recognizer.languageConstraints = [targetLanguage]
    recognizer.processString(prose)
    guard recognizer.languageHypotheses(withMaximum: 1)[targetLanguage] != nil else {
      return .polish
    }
    recognizer.reset()
    recognizer.languageConstraints = [targetLanguage, nativeLanguage]
    recognizer.processString(prose)
    return (recognizer.languageHypotheses(withMaximum: 2)[nativeLanguage] ?? 0) >= 0.9
      ? .translate : .polish
  }

  private static func recognizerLanguage(_ language: Locale.Language) -> NLLanguage? {
    guard let code = language.languageCode?.identifier else { return nil }
    if code == "zh" {
      switch language.script?.identifier {
      case "Hans": return .simplifiedChinese
      case "Hant": return .traditionalChinese
      default: return nil
      }
    }
    return NLLanguage(rawValue: code)
  }

  private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
    default: false
    }
  }

  /// The scripts only the native language uses, when scripts decide the case: both script sets
  /// are known and differ, and the native one is not Latin. Empty when the native scripts are all
  /// shared with the target. Nil leaves the pair to the recognizer.
  private static func evidenceScripts(target: Locale.Language, native: Locale.Language)
    -> Set<String>?
  {
    guard let targetScripts = LanguageScripts.codes(script: target.script?.identifier),
      let nativeScripts = LanguageScripts.codes(script: native.script?.identifier),
      nativeScripts != targetScripts, !nativeScripts.contains("Latn")
    else { return nil }
    return nativeScripts.subtracting(targetScripts)
  }

  /// Whether `classify` can ever answer `.translate` for this pair: native-only scripts exist, or
  /// the recognizer knows both languages. When false every input is case B (design §4), which
  /// says nothing about the input.
  public static func canDistinguish(_ settings: RewriteSettings) -> Bool {
    let target = Locale.Language(identifier: settings.targetLanguage)
    let native = Locale.Language(identifier: settings.nativeLanguage)
    guard target.languageCode != native.languageCode || target.script != native.script else {
      return false
    }
    if let evidence = evidenceScripts(target: target, native: native) { return !evidence.isEmpty }
    guard let targetLanguage = recognizerLanguage(target),
      let nativeLanguage = recognizerLanguage(native), targetLanguage != nativeLanguage
    else { return false }
    return [targetLanguage, nativeLanguage].allSatisfy { language in
      // A constraint the recognizer does not support yields no hypothesis, whatever the text.
      let recognizer = NLLanguageRecognizer()
      recognizer.languageConstraints = [language]
      recognizer.processString("a")
      return recognizer.languageHypotheses(withMaximum: 1)[language] != nil
    }
  }
}
