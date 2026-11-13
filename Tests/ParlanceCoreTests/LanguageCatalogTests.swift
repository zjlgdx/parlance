import Foundation
import Testing

@testable import ParlanceCore

struct LanguageCatalogTests {
  @Test(arguments: LanguageCatalog.tags)
  func foundationNamesEveryEntry(_ tag: String) {
    for locale in ["zh-Hans", "en"] {
      #expect(LanguageCatalog.displayName(tag, in: locale)?.isEmpty == false)
    }
    #expect(LanguageCatalog.autonym(tag)?.isEmpty == false)
  }

  @Test func entriesAreUniqueAndKeepTheDefaultTags() {
    #expect(Set(LanguageCatalog.tags).count == LanguageCatalog.tags.count)
    #expect(LanguageCatalog.tags.contains("en"))
    #expect(LanguageCatalog.tags.contains("zh-Hans"))
    #expect(Set(LanguageCatalog.sorted(in: "zh-Hans")) == Set(LanguageCatalog.tags))
  }

  @Test func titlesPairTheInterfaceNameWithTheAutonym() {
    #expect(LanguageCatalog.title("ja", in: "zh-Hans") == "日语 — 日本語")
    #expect(LanguageCatalog.title("zh-Hans", in: "zh-Hans") == "简体中文")
    #expect(LanguageCatalog.title("xx", in: "zh-Hans") == "xx")
  }

  @Test func sortsByDisplayNameInTheGivenLocale() {
    let names = LanguageCatalog.sorted(in: "en").map { LanguageCatalog.displayName($0, in: "en")! }
    #expect(names.first == "Arabic")
    #expect(
      names
        == names.sorted { $0.compare($1, locale: Locale(identifier: "en")) == .orderedAscending })
  }

  @Test func badgesAreDistinct() {
    let badges = LanguageCatalog.tags.map(LanguageCatalog.badge)
    #expect(Set(badges).count == badges.count)
  }

  @Test func badgesMarkOnlyVariants() {
    let expected = [
      "en": "EN", "zh-Hans": "ZH", "es": "ES", "fr": "FR", "ja": "JA", "en-GB": "EN-GB",
      "zh-Hant": "ZH-HANT", "pt-BR": "PT-BR", "pt-PT": "PT-PT", "es-419": "ES-419",
      "fr-CA": "FR-CA",
      "zh-hant": "ZH-HANT", "de-CH": "DE",
    ]
    for (tag, badge) in expected { #expect(LanguageCatalog.badge(tag) == badge, "\(tag)") }
  }

  @Test(arguments: [
    (["zh-Hant-TW"], "zh-Hant"), (["zh-HK"], "zh-Hant"), (["zh-Hans-CN"], "zh-Hans"),
    (["pt-BR"], "pt-BR"), (["pt-AO"], "pt-PT"), (["es-ES"], "es"), (["es-MX"], "es-419"),
    (["fr-CA"], "fr-CA"), (["fr-BE"], "fr"), (["en-TW", "zh-Hant-TW"], "zh-Hant"),
    (["en-US"], "en"), (["en-AU", "xx"], "en-GB"), (["xx", "en-US", "de-DE"], "de"),
    (["xx"], "zh-Hans"), ([], "zh-Hans"),
  ])
  func infersTheNativeLanguage(_ preferred: [String], _ expected: String) {
    #expect(LanguageCatalog.nativeLanguage(preferred: preferred) == expected)
  }

  /// #357: the formality mark, read through the entry a regional tag maps to.
  @Test func marksFormalityForTheListedEntries() {
    let marked: Set<String> = [
      "de", "fr", "fr-CA", "es", "es-419", "it", "pt-BR", "pt-PT", "ca", "nl", "pl", "cs", "sk",
      "hu", "ro", "bg", "hr", "el", "ru", "uk", "tr", "ja", "ko",
    ]
    #expect(marked.isSubset(of: LanguageCatalog.tags))
    for tag in LanguageCatalog.tags {
      #expect(LanguageCatalog.marksFormality(tag) == marked.contains(tag), "\(tag)")
    }
    for tag in ["de-DE", "de-CH", "ja-JP", "ko-KR", "fr-BE", "pt", "pt-AO", "es-MX", "es-ES", "DE"]
    {
      #expect(LanguageCatalog.marksFormality(tag), "\(tag)")
    }
    for tag in ["en-US", "en-AU", "zh-Hans-CN", "zh-HK", "sv-SE", "hi-IN", "xx", "tlh", "", "eo"] {
      #expect(!LanguageCatalog.marksFormality(tag), "\(tag)")
    }
  }
}
