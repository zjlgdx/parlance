import Foundation

/// The one place that says which writing systems a language uses. Scripts are ICU script codes;
/// letters are matched with ICU's `\p{scx=…}`, so every script Foundation infers for a language
/// tag is covered without a block table.
public enum LanguageScripts {
  /// The scripts of a BCP 47 tag, written or inferred by Foundation; nil when it names none or
  /// ICU does not know the script.
  public static func codes(for language: String) -> Set<String>? {
    codes(script: Locale.Language(identifier: language).script?.identifier)
  }

  static func codes(script: String?) -> Set<String>? {
    guard let script else { return nil }
    let codes: Set<String> =
      switch script {
      case "Hans", "Hant", "Hani": ["Hani"]
      case "Jpan": ["Hani", "Hira", "Kana"]
      case "Kore": ["Hang", "Hani"]
      // Foundation infers Nastaliq for Urdu; ICU has no characters under that code.
      case "Aran": ["Arab"]
      default: [script]
      }
    return (try? NSRegularExpression(pattern: letters(codes))) == nil ? nil : codes
  }

  /// An ICU set of the letters written in any of `codes`. Script extensions keep marks shared by
  /// a few scripts, such as the kana prolonged sound mark, with the scripts that use them. The
  /// ideographic zero 〇 is a letter-number to ICU but is written as a Han character (二〇二四).
  static func letters(_ codes: Set<String>) -> String {
    "[[" + codes.sorted().map { "\\p{scx=\($0)}" }.joined() + "]&&[\\p{L}\\x{3007}]]"
  }

  public static func containsLetter(_ text: String, in codes: Set<String>) -> Bool {
    !codes.isEmpty && text.range(of: letters(codes), options: .regularExpression) != nil
  }
}
