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
    if let targetScripts = scripts(for: target.script?.identifier),
      let nativeScripts = scripts(for: native.script?.identifier),
      nativeScripts != targetScripts, !nativeScripts.contains("Latn")
    {
      // A lone letter such as a kaomoji's katakana or a Greek symbol is not prose, so case A
      // needs two adjacent letters from a script only the native language uses.
      let evidence = nativeScripts.subtracting(targetScripts)
      func isEvidence(_ scalar: Unicode.Scalar) -> Bool {
        isLetter(scalar) && script(of: scalar).map(evidence.contains) == true
      }
      let scalars = Array(protection.text.unicodeScalars)
      return zip(scalars, scalars.dropFirst()).contains { isEvidence($0) && isEvidence($1) }
        ? .translate : .polish
    }
    // Latin letters appear in every language as product names and acronyms, and the recognizer
    // weighs them over CJK text, so any letter in a non-Latin target's script keeps case B; only
    // an all-Latin draft is left to the recognizer.
    if let targetScripts = scripts(for: target.script?.identifier), !targetScripts.contains("Latn"),
      letters.contains(where: { script(of: $0).map(targetScripts.contains) ?? false })
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

  private static func scripts(for identifier: String?) -> Set<String>? {
    switch identifier {
    case "Hans", "Hant", "Hani": ["Hani"]
    case "Jpan": ["Hani", "Kana"]
    case "Kore": ["Hani", "Hang"]
    case "Latn", "Cyrl", "Arab", "Hebr", "Grek", "Thai", "Deva", "Hang": [identifier!]
    default: nil
    }
  }

  /// A deliberately limited block table: unlisted letters do not establish a script mismatch.
  private static func script(of scalar: Unicode.Scalar) -> String? {
    switch scalar.value {
    case 0x0041...0x024F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF,
      0xAB30...0xAB6F, 0xFF21...0xFF5A:
      "Latn"
    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F,
      0x30000...0x323AF, 0x3005...0x3007, 0x303B:
      "Hani"
    case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D, 0x1AFF0...0x1AFFF,
      0x1B000...0x1B16F:
      "Kana"
    case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF,
      0xFFA0...0xFFDC:
      "Hang"
    case 0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F,
      0x1E030...0x1E08F:
      "Cyrl"
    case 0x0600...0x06FF, 0x0750...0x077F, 0x0870...0x08FF, 0xFB50...0xFDFF,
      0xFE70...0xFEFF, 0x1EE00...0x1EEFF:
      "Arab"
    case 0x0590...0x05FF, 0xFB1D...0xFB4F: "Hebr"
    case 0x0370...0x03FF, 0x1F00...0x1FFF: "Grek"
    case 0x0E00...0x0E7F: "Thai"
    case 0x0900...0x097F, 0xA8E0...0xA8FF, 0x11B00...0x11B5F: "Deva"
    default: nil
    }
  }
}
