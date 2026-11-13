import Foundation
import Testing
import os

@testable import ParlanceCore

func glossaryEntry(
  _ target: String = "rate limit", _ native: String = "速率限制",
  note: String? = nil, nativeLanguage: String = "zh-Hans", added: String = "2026-11-11"
) -> GlossaryEntry {
  GlossaryEntry(
    target: target, native: native, note: note, nativeLanguage: nativeLanguage, added: added)
}

func glossaryDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "parlance-glossary-\(UUID().uuidString)")
}

struct GlossaryTests {
  @Test func roundTripPermissionsAndReadCreatesNothing() throws {
    let directory = glossaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GlossaryStore(directory: directory)
    #expect(store.read() == GlossaryRead())
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    let entry = glossaryEntry(note: "说明")
    #expect(try !store.add(entry))
    #expect(store.read().entries == [entry])
    let text = try String(contentsOf: store.path, encoding: .utf8)
    #expect(
      text
        == "{\"added\":\"2026-11-11\",\"native\":\"速率限制\",\"native_lang\":\"zh-Hans\",\"note\":\"说明\",\"target\":\"rate limit\",\"target_lang\":\"en\"}\n"
    )
    for (path, permissions) in [(directory, 0o700), (store.path, 0o600)] {
      let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == permissions)
    }
  }

  @Test func identityAndLanguages() throws {
    let directory = glossaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GlossaryStore(directory: directory)
    try store.add(glossaryEntry(" café "))
    #expect(try store.add(glossaryEntry("CAFE\u{301}", "咖啡")))
    #expect(try !store.add(glossaryEntry("café", "café", nativeLanguage: "fr")))
    let entries = store.read().entries
    #expect(entries.count == 2)
    #expect(entries[0].native == "咖啡")
    #expect(
      Glossary.match(entries, in: "CAFÉ", targetLanguage: "en", nativeLanguage: "zh-Hans") == [
        entries[0]
      ])
    #expect(try store.remove(target: "café", targetLanguage: "en", nativeLanguage: "zh-Hans"))
    #expect(store.read().entries == [entries[1]])
    #expect(try !store.remove(target: "absent", targetLanguage: "en", nativeLanguage: "fr"))
  }

  @Test func unchangedLinesAndUnknownFields() throws {
    let directory = glossaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GlossaryStore(directory: directory)
    try store.add(glossaryEntry())
    let original = Data(
      "invalid\n{\"target\":\"missing fields\"}\n{ \"target\":\"future\", \"native\":\"将来\", \"added\":\"2026-11-11\", \"target_lang\":\"en\", \"native_lang\":\"zh-Hans\", \"unknown\":42 }\r\n"
        .utf8)
    try original.write(to: store.path)
    #expect(store.read().invalidLines == 2)
    #expect(store.read().entries.map(\.target) == ["future"])
    try store.add(glossaryEntry())
    #expect(try Data(contentsOf: store.path).starts(with: original))
    try store.add(glossaryEntry("RATE LIMIT", "限速"))
    #expect(try Data(contentsOf: store.path).starts(with: original))
    try store.remove(target: "rate limit", targetLanguage: "en", nativeLanguage: "zh-Hans")
    #expect(try Data(contentsOf: store.path) == original)
  }

  @Test func admissionAndManualEdits() throws {
    let clean = try glossaryEntry("rate\nlimit\t", "限\u{0}速", note: "备\u{85}注").admitted()
    #expect(clean.target == "ratelimit")
    #expect(clean.native == "限速")
    #expect(clean.note == "备注")
    let secret = "api_key=\"fake-test-secret\""
    #expect(Redactor.redact(secret).text != secret)
    for field in ["target", "native", "note"] {
      for bad in [secret] + "⟦⟧⟪⟫〖〗".map(String.init) + [String(repeating: "a", count: 201)] {
        var entry = glossaryEntry()
        switch field {
        case "target": entry.target = bad
        case "native": entry.native = bad
        default: entry.note = bad
        }
        #expect(throws: GlossaryEntry.AdmissionError(field: field)) { try entry.admitted() }
      }
    }
    #expect(throws: GlossaryEntry.AdmissionError(field: "target")) {
      try glossaryEntry(String(repeating: "a", count: 81)).admitted()
    }
    let directory = glossaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GlossaryStore(directory: directory)
    try store.add(glossaryEntry())
    var invalid = [glossaryEntry("bad\nline"), glossaryEntry("⟦bad"), glossaryEntry(secret)]
    var invalidDate = glossaryEntry()
    invalidDate.added = "2026-02-30"
    invalid.append(invalidDate)
    var invalidLanguage = glossaryEntry()
    invalidLanguage.targetLanguage = ""
    invalid.append(invalidLanguage)
    let bytes = try invalid.reduce(into: Data()) { $0 += try JSONEncoder().encode($1) + Data([10]) }
    try bytes.write(to: store.path)
    #expect(store.read().entries.isEmpty)
    #expect(store.read().invalidLines == invalid.count)
  }

  @Test func interleavedWritersRereadUnderLock() throws {
    let directory = glossaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let second = GlossaryStore(directory: directory)
    let events = OSAllocatedUnfairLock(initialState: [String]())
    let files = GlossaryStore.Files(
      read: { url, limit in
        events.withLock { $0.append(limit == nil ? "reread" : "initial read") }
        return try GlossaryStore.Files.local.read(url, limit)
      },
      locked: { url, body in
        // Writer B commits while A is waiting to acquire the lock, after A's earlier read.
        try second.add(glossaryEntry("second", "第二"))
        events.withLock { $0.append("locked") }
        try GlossaryStore.Files.local.locked(url, body)
      },
      replace: { url, bytes in
        events.withLock { $0.append("replace") }
        try GlossaryStore.Files.local.replace(url, bytes)
      })
    let first = GlossaryStore(directory: directory, files: files)
    #expect(first.read().entries.isEmpty)
    try first.add(glossaryEntry("first", "第一"))
    #expect(events.withLock { $0 } == ["initial read", "locked", "reread", "replace"])
    #expect(second.read().entries.map(\.target) == ["second", "first"])
  }

  @Test func boundedReadAndUnboundedPreservingWrite() throws {
    let directory = glossaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GlossaryStore(directory: directory)
    try store.add(glossaryEntry())
    let first = try Data(contentsOf: store.path)
    let bytes =
      first + Data(repeating: 120, count: GlossaryStore.readLimit - first.count)
      + Data("\nignored\n".utf8)
    try bytes.write(to: store.path)
    let read = store.read()
    #expect(read.entries == [glossaryEntry()])
    #expect(read.truncated)
    #expect(read.warnings == ["glossary: ignored content beyond 1 MiB."])
    try store.add(glossaryEntry("new", "新词"))
    #expect(try Data(contentsOf: store.path).starts(with: bytes))
  }

  @Test func targetAndNativeMatching() {
    func matches(_ entry: GlossaryEntry, _ text: String) -> Bool {
      !Glossary.match(
        [entry], in: text, targetLanguage: entry.targetLanguage,
        nativeLanguage: entry.nativeLanguage
      ).isEmpty
    }
    for text in ["LIMIT", "limits", "limites", "limited", "limiting", "limits."] {
      #expect(matches(glossaryEntry("limit"), text))
    }
    for text in ["limitless", "unlimited", "limitation", "limit_name"] {
      #expect(!matches(glossaryEntry("limit"), text))
    }
    #expect(matches(glossaryEntry("split-flap"), "Split Flaps"))
    #expect(matches(glossaryEntry("rate limit"), "rate-limit"))
    #expect(!matches(glossaryEntry("coalesce"), "coalescing"))
    #expect(matches(glossaryEntry("load-bearing", "承重的；关键的"), "这是承重的；关键的"))
    #expect(!matches(glossaryEntry("load-bearing", "承重的；关键的"), "这是关键的"))
    #expect(!matches(glossaryEntry("one", "一"), "一"))
    for text in ["pain", "painting"] {
      #expect(!matches(glossaryEntry("bread", "pain", nativeLanguage: "fr"), text))
    }
    #expect(!matches(glossaryEntry("bread", "pain"), "pain"))
    #expect(matches(glossaryEntry("bread", "面包"), "买面包"))
    let protected = TermProtection.protect(
      "`rate limit` /rate/limit --limit rateLimit https://limit.test")
    #expect(
      Glossary.match(
        [glossaryEntry(), glossaryEntry("limit")], in: protected.text,
        targetLanguage: "en", nativeLanguage: "zh-Hans"
      ).isEmpty)
  }

  @Test func longestCoverageOrderAndLimit() {
    let entries = [
      glossaryEntry("limit"), glossaryEntry(), glossaryEntry("other", "另一个", added: "2026-11-10"),
    ]
    #expect(
      Glossary.match(entries, in: "rate limits", targetLanguage: "en", nativeLanguage: "zh-Hans")
        .map(\.target) == ["rate limit"])
    #expect(
      Glossary.match(
        entries, in: "rate limits; limit other", targetLanguage: "en", nativeLanguage: "zh-Hans"
      ).map(\.target) == ["rate limit", "limit", "other"])
    let many = (1...25).map {
      glossaryEntry(String(format: "word%02d", $0), added: String(format: "2026-11-%02d", $0))
    }
    let result = Glossary.match(
      many, in: many.map(\.target).joined(separator: " "), targetLanguage: "en",
      nativeLanguage: "zh-Hans")
    #expect(result.count == 20)
    #expect(result.map(\.added) == many.reversed().prefix(20).map(\.added))
  }

  @Test func ankiGoldenAndIdentityStability() throws {
    let entries = [
      glossaryEntry("say \"hello\"", "说“你好”", note: "a \"quote\""),
      glossaryEntry("ignored", "ignoré", nativeLanguage: "fr"),
    ]
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
      "Fixtures/glossary/anki.tsv")
    #expect(
      Glossary.anki(entries, targetLanguage: "en", nativeLanguage: "zh-Hans")
        == (try String(contentsOf: file, encoding: .utf8)))
    #expect(
      glossaryEntry("café").guid == glossaryEntry(" CAFE\u{301} ", "改变", added: "2026-11-01").guid)
    #expect(glossaryEntry().guid != glossaryEntry(nativeLanguage: "fr").guid)
  }
}

extension GlossaryTests {
  @Test func equalLengthMatchesRemainInOrder() {
    for (entries, input) in [
      (
        [
          glossaryEntry("rate limit", "限速", added: "2026-11-10"), glossaryEntry("throttling", "限速"),
        ], "限速"
      ),
      (
        [glossaryEntry("split-flap", added: "2026-11-10"), glossaryEntry("split flap")],
        "split flap"
      ),
    ] {
      #expect(
        Glossary.match(entries, in: input, targetLanguage: "en", nativeLanguage: "zh-Hans")
          == entries.reversed())
    }
    let entries = (1...25).map {
      glossaryEntry("term\($0)", "限速", added: String(format: "2026-11-%02d", $0))
    }
    #expect(
      Glossary.match(entries, in: "限速", targetLanguage: "en", nativeLanguage: "zh-Hans")
        == Array(entries.reversed().prefix(20)))
  }

  @Test func lastDuplicateWinsAtLastPosition() throws {
    let directory = glossaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GlossaryStore(directory: directory)
    try store.add(glossaryEntry())
    let entries = [
      glossaryEntry("a", "旧甲"), glossaryEntry("b", "旧乙"), glossaryEntry(" A ", "新甲"),
      glossaryEntry("c", "丙"), glossaryEntry("B", "新乙"),
    ]
    let bytes = try entries.reduce(into: Data()) { $0 += try JSONEncoder().encode($1) + Data([10]) }
    try bytes.write(to: store.path)
    #expect(store.read().entries == Array(entries.suffix(3)))
  }

  @Test func removeMissingCreatesNothing() throws {
    let directory = glossaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GlossaryStore(directory: directory)
    #expect(try !store.remove(target: "missing", targetLanguage: "en", nativeLanguage: "zh-Hans"))
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  @Test(arguments: ["2024-02-29", "2000-02-29", "2026-11-11"])
  func validCalendarDates(_ date: String) throws { _ = try glossaryEntry(added: date).admitted() }

  @Test(arguments: [
    "2025-02-29", "1900-02-29", "2026-04-31", "2026-00-01", "2026-01-00", "2026-1-01",
    "2026-01-01\n",
  ])
  func invalidCalendarDates(_ date: String) {
    #expect(throws: GlossaryEntry.AdmissionError(field: "added")) {
      try glossaryEntry(added: date).admitted()
    }
  }

  private func entry(
    _ target: String, _ native: String, _ targetLanguage: String, _ nativeLanguage: String
  ) -> GlossaryEntry {
    GlossaryEntry(
      target: target, native: native, targetLanguage: targetLanguage,
      nativeLanguage: nativeLanguage, added: "2026-11-12")
  }

  private func matches(_ entry: GlossaryEntry, _ text: String) -> Bool {
    !Glossary.match(
      [entry], in: text, targetLanguage: entry.targetLanguage,
      nativeLanguage: entry.nativeLanguage
    ).isEmpty
  }

  @Test func englishEndingsApplyOnlyToEnglishTargets() {
    let german = entry("Camp", "营地", "de", "zh-Hans")
    for text in ["Wir fahren zum Camping.", "Tested und gecamped", "Camped", "Camps", "Campes"] {
      #expect(!matches(german, text))
      #expect(!Glossary.isSameTerm(text, entry: german))
    }
    for text in ["Das Camp ist offen.", "CAMP", "camp"] { #expect(matches(german, text)) }
    #expect(Glossary.isSameTerm("camp", entry: german))
    #expect(!matches(german, "Campus"))
    for language in ["en", "en-GB"] {
      let english = entry("limit", "限制", language, "zh-Hans")
      for text in ["limits", "limites", "limited", "limiting"] {
        #expect(matches(english, text))
        #expect(Glossary.isSameTerm(text, entry: english))
      }
      #expect(!matches(english, "limitless"))
    }
  }

  @Test func cyrillicAndGreekTargetsMatchWholeWords() {
    let russian = entry("код", "代码", "ru", "zh-Hans")
    for text in ["кодировка файла", "штрихкод", "код_1", "коды"] {
      #expect(!matches(russian, text))
    }
    for text in ["этот код работает", "Код.", "КОД", "(код)"] { #expect(matches(russian, text)) }
    #expect(Glossary.isSameTerm("Код", entry: russian))
    #expect(!Glossary.isSameTerm("кодировка", entry: russian))
    #expect(!Glossary.isSameTerm("коды", entry: russian))
    let greek = entry("νέο", "新的", "el", "zh-Hans")
    #expect(!matches(greek, "νέοι άνθρωποι"))
    #expect(matches(greek, "ένα νέο σχέδιο"))
    #expect(!Glossary.isSameTerm("νέοι", entry: greek))
    #expect(Glossary.isSameTerm("νέο", entry: greek))
  }

  @Test func otherScriptsKeepSubstringMatching() {
    let chinese = entry("限流", "rate limiting", "zh-Hans", "en")
    #expect(matches(chinese, "这里需要限流策略"))
    #expect(Glossary.isSameTerm("限流", entry: chinese))
    #expect(!Glossary.isSameTerm("限流策略", entry: chinese))
    let japanese = entry("割り込み", "interrupt", "ja", "en")
    #expect(matches(japanese, "割り込み処理を追加します"))
    #expect(Glossary.isSameTerm("割り込み", entry: japanese))
    #expect(!Glossary.isSameTerm("割り込み処理", entry: japanese))
    for (target, text, language) in [
      ("서버", "서버에서 실행합니다", "ko"), ("خادم", "الخادم يعمل", "ar"), ("เซิร์ฟเวอร์", "ที่เซิร์ฟเวอร์นี้", "th"),
    ] {
      #expect(matches(entry(target, "server", language, "en"), text))
    }
    // The native side is unchanged: a whole native expression in a script the target lacks.
    #expect(matches(entry("код", "代码", "ru", "zh-Hans"), "看一下代码"))
    #expect(matches(entry("rate limit", "হার সীমা", "en", "bn"), "এখানে হার সীমা দরকার"))
  }

  @Test func ideographicZeroCountsAsHan() {
    #expect(LanguageScripts.containsLetter("〇〇", in: ["Hani"]))
    #expect(!LanguageScripts.containsLetter("〇〇", in: ["Latn"]))
    #expect(!LanguageScripts.containsLetter("2024", in: ["Hani"]))
  }
}
