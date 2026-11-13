import Foundation

/// The BCP 47 tags the app offers as target and native languages. The glossary keys a language pair
/// by the tag string, so an entry is never rewritten to an equivalent spelling (`en`, not `en-US`).
public enum LanguageCatalog {
  /// Regional or script variants only where spelling or vocabulary differ.
  public static let tags = [
    "en", "en-GB", "zh-Hans", "zh-Hant", "ja", "ko", "es", "es-419", "fr", "fr-CA", "de", "it",
    "pt-BR", "pt-PT", "nl", "sv", "nb", "da", "fi", "pl", "cs", "sk", "hu", "ro", "bg", "hr", "el",
    "ru", "uk", "tr", "ar", "he", "fa", "ur", "hi", "bn", "ta", "te", "th", "vi", "id", "ms", "fil",
    "ca",
  ]

  /// Entries whose grammar makes an everyday sentence pick one of two registers (du / Sie, tu /
  /// vous, plain / polite endings). Languages with three levels of address or kinship-based
  /// address stay out: docs/designs/2026-11-12-rewrite-formality.md.
  private static let formalityTags: Set<String> = [
    "de", "fr", "fr-CA", "es", "es-419", "it", "pt-BR", "pt-PT", "ca", "nl", "pl", "cs", "sk", "hu",
    "ro", "bg", "hr", "el", "ru", "uk", "tr", "ja", "ko",
  ]

  /// Whether the tag's catalog entry marks formality. A regional tag reads its entry's mark
  /// (`de-DE` → `de`); a tag with no entry is false.
  public static func marksFormality(_ tag: String) -> Bool {
    entry(forPreferred: tag).map(formalityTags.contains) ?? false
  }

  /// The tag's name in `locale`, or nil when Foundation has none.
  public static func displayName(_ tag: String, in locale: String) -> String? {
    nonempty(Locale(identifier: locale).localizedString(forIdentifier: tag))
  }

  /// The language's name for itself, or nil when Foundation has none.
  public static func autonym(_ tag: String) -> String? { displayName(tag, in: tag) }

  /// "日语 — 日本語"; one name when both are the same; the tag itself when Foundation has no name.
  public static func title(_ tag: String, in locale: String) -> String {
    guard let name = displayName(tag, in: locale) else { return tag }
    guard let own = autonym(tag), own != name else { return name }
    return "\(name) — \(own)"
  }

  /// How prompts name a language: its English name and the tag, "Portuguese (Brazil) (pt-BR)".
  /// A tag Foundation cannot name stays as written.
  public static func promptName(_ tag: String) -> String {
    guard let name = displayName(tag, in: "en_US_POSIX") else { return tag }
    return "\(name) (\(tag))"
  }

  /// Whether the tag's language is `code`, whatever its script or region.
  public static func isLanguage(_ tag: String, _ code: String) -> Bool {
    Locale.Language(identifier: tag).languageCode?.identifier == code
  }

  public static func sorted(in locale: String) -> [String] {
    let collation = Locale(identifier: locale)
    let names = Dictionary(
      uniqueKeysWithValues: tags.map { ($0, displayName($0, in: locale) ?? $0) })
    return tags.sorted {
      names[$0]!.compare(names[$1]!, locale: collation) == .orderedAscending
    }
  }

  /// The language code alone for the catalog's unmarked entry of a language (`zh-Hans` → ZH), the
  /// whole tag for a variant (`zh-Hant` → ZH-HANT). A tag outside the catalog keeps the language
  /// code alone, as the header showed before the catalog existed.
  public static func badge(_ tag: String) -> String {
    let code = String(tag.prefix { $0 != "-" }).uppercased()
    guard let entry = tags.first(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else {
      return code
    }
    return entry.contains("-") && entry != "zh-Hans" ? entry.uppercased() : code
  }

  /// The first-launch native language: the first system preferred language the catalog covers
  /// that is not English, else the first covered English variant, else `zh-Hans`.
  public static func nativeLanguage(preferred: [String]) -> String {
    let covered = preferred.compactMap(entry(forPreferred:))
    return covered.first { !["en", "en-GB"].contains($0) } ?? covered.first ?? "zh-Hans"
  }

  static func entry(forPreferred identifier: String) -> String? {
    let language = Locale.Language(identifier: identifier)
    guard let code = language.languageCode?.identifier else { return nil }
    let region = language.region?.identifier
    switch code {
    case "zh": return language.script == .hanTraditional ? "zh-Hant" : "zh-Hans"
    case "pt": return region == "BR" ? "pt-BR" : "pt-PT"
    case "es": return region == nil || region == "ES" ? "es" : "es-419"
    case "fr": return region == "CA" ? "fr-CA" : "fr"
    case "en":
      return ["GB", "IE", "AU", "NZ", "ZA", "IN"].contains(region ?? "") ? "en-GB" : "en"
    default: return tags.contains(code) ? code : nil
    }
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return value
  }
}
