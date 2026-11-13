import CryptoKit
import Darwin
import Foundation

public struct GlossaryEntry: Codable, Sendable, Equatable {
  public var target: String
  public var native: String
  public var note: String?
  public var targetLanguage: String
  public var nativeLanguage: String
  public var added: String

  enum CodingKeys: String, CodingKey {
    case target, native, note, added
    case targetLanguage = "target_lang"
    case nativeLanguage = "native_lang"
  }

  public init(
    target: String, native: String, note: String? = nil, targetLanguage: String = "en",
    nativeLanguage: String = "zh-Hans", added: String
  ) {
    self.target = target
    self.native = native
    self.note = note
    self.targetLanguage = targetLanguage
    self.nativeLanguage = nativeLanguage
    self.added = added
  }

  public static func normalize(_ target: String) -> String {
    target.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .precomposedStringWithCanonicalMapping
  }

  /// NUL separates identity components unambiguously; it is not permitted in stored fields.
  public var identity: String {
    targetLanguage + "\0" + nativeLanguage + "\0" + Self.normalize(target)
  }

  public var guid: String {
    "parlance-"
      + SHA256.hash(data: Data(identity.utf8)).prefix(8)
      .map { String(format: "%02x", $0) }.joined()
  }

  public struct AdmissionError: Error, Sendable, Equatable {
    public let field: String
  }

  public func admitted() throws -> Self {
    func check(_ value: String, field: String, limit: Int) throws -> String {
      let clean = String(
        String.UnicodeScalarView(
          value.unicodeScalars.filter {
            $0.properties.generalCategory != .control && !CharacterSet.newlines.contains($0)
          }))
      guard clean.count <= limit,
        field == "note" || !clean.trimmingCharacters(in: .whitespaces).isEmpty,
        Redactor.redact(clean).text == clean,
        !clean.contains(where: { "⟦⟧⟪⟫〖〗".contains($0) })
      else { throw AdmissionError(field: field) }
      return clean
    }
    var copy = self
    copy.target = try check(target, field: "target", limit: 80)
    copy.native = try check(native, field: "native", limit: 200)
    copy.note = try note.map { try check($0, field: "note", limit: 200) }
    for (field, language) in [("target_lang", targetLanguage), ("native_lang", nativeLanguage)] {
      guard
        language.range(of: #"^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$"#, options: .regularExpression)
          != nil
      else { throw AdmissionError(field: field) }
    }
    guard Self.validDate(added) else { throw AdmissionError(field: "added") }
    return copy
  }

  /// Validate a Gregorian YYYY-MM-DD without mutable formatter state or per-line formatter construction.
  private static func validDate(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
      bytes.enumerated().allSatisfy({
        $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element)
      })
    else { return false }
    func number(_ range: Range<Int>) -> Int {
      range.reduce(0) { $0 * 10 + Int(bytes[$1] - 48) }
    }
    let year = number(0..<4)
    let month = number(5..<7)
    let day = number(8..<10)
    guard year > 0, (1...12).contains(month) else { return false }
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return (1...days[month - 1]).contains(day)
  }

  /// Recheck at the send boundary, including prepared subjects retained across requests.
  var redacted: Self {
    var copy = self
    copy.target = Redactor.redact(target).text
    copy.native = Redactor.redact(native).text
    copy.note = note.map { Redactor.redact($0).text }
    return copy
  }
}

public struct GlossaryRead: Sendable, Equatable {
  public var entries: [GlossaryEntry] = []
  public var invalidLines = 0
  public var truncated = false
  public var unreadable = false

  public var warnings: [String] {
    var result: [String] = []
    if invalidLines > 0 { result.append("glossary: skipped \(invalidLines) invalid lines.") }
    if truncated { result.append("glossary: ignored content beyond 1 MiB.") }
    if unreadable { result.append("glossary: could not read the file. Check file permissions.") }
    return result
  }
}

public struct GlossaryStore: Sendable {
  public static let readLimit = 1_048_576
  public let directory: URL
  public var path: URL { directory.appendingPathComponent("glossary.jsonl") }
  private let files: Files

  /// File operations are injected together so tests can interleave writers at lock acquisition.
  struct Files: Sendable {
    var read: @Sendable (URL, Int?) throws -> (Data, Bool)
    var locked: @Sendable (URL, () throws -> Void) throws -> Void
    var replace: @Sendable (URL, Data) throws -> Void
    var exists: @Sendable (URL) throws -> Bool = { url in
      do {
        _ = try FileManager.default.attributesOfItem(atPath: url.path)
        return true
      } catch let error as CocoaError
        where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
      {
        return false
      }
    }

    static let local = Files(
      read: { url, limit in
        let file: FileHandle
        do { file = try FileHandle(forReadingFrom: url) } catch let error as CocoaError
          where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
        { return (Data(), false) }
        defer { try? file.close() }
        let size = try file.seekToEnd()
        try file.seek(toOffset: 0)
        if let limit { return (try file.read(upToCount: limit) ?? Data(), size > limit) }
        return (try file.readToEnd() ?? Data(), false)
      },
      locked: { directory, body in
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        let lockPath = directory.appendingPathComponent("glossary.jsonl.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
          guard errno == EINTR else { throw POSIXError(.EIO) }
        }
        defer { flock(descriptor, LOCK_UN) }
        try body()
      },
      replace: { url, data in
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
          ".glossary-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
          try? file.close()
          try? FileManager.default.removeItem(at: temporary)
        }
        try file.write(contentsOf: data)
        try file.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
      })
  }

  public init(
    directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".config/parlance")
  ) {
    self.init(directory: directory, files: .local)
  }

  init(directory: URL, files: Files) {
    self.directory = directory
    self.files = files
  }

  private static func lines(_ data: Data) -> [Data] {
    var result: [Data] = []
    var start = data.startIndex
    for index in data.indices where data[index] == 10 {
      result.append(data[start...index])
      start = data.index(after: index)
    }
    if start < data.endIndex { result.append(data[start...]) }
    return result
  }

  private static func entry(_ line: Data) -> GlossaryEntry? {
    guard let entry = try? JSONDecoder().decode(GlossaryEntry.self, from: line),
      let admitted = try? entry.admitted(), admitted == entry
    else { return nil }
    return entry
  }

  public func read() -> GlossaryRead {
    do {
      let (data, truncated) = try files.read(path, Self.readLimit)
      var result = GlossaryRead(truncated: truncated)
      var lines = Self.lines(data)
      if truncated, data.last != 10 { _ = lines.popLast() }
      var positions: [String: Int] = [:]
      var entries: [GlossaryEntry?] = []
      for line in lines {
        guard let entry = Self.entry(line) else {
          result.invalidLines += 1
          continue
        }
        let identity = entry.identity
        if let previous = positions.updateValue(entries.count, forKey: identity) {
          entries[previous] = nil
        }
        entries.append(entry)
      }
      result.entries = entries.compactMap { $0 }
      return result
    } catch { return GlossaryRead(unreadable: true) }
  }

  /// Returns true when replacing an existing identity. Unchanged lines retain their bytes.
  @discardableResult public func add(_ entry: GlossaryEntry) throws -> Bool {
    let entry = try entry.admitted()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try modify(identity: entry.identity, replacement: encoder.encode(entry) + Data([10]))
  }

  @discardableResult public func remove(
    target: String, targetLanguage: String, nativeLanguage: String
  ) throws -> Bool {
    guard try files.exists(path) else { return false }
    let identity = GlossaryEntry(
      target: target, native: "", targetLanguage: targetLanguage,
      nativeLanguage: nativeLanguage, added: ""
    ).identity
    return try modify(identity: identity, replacement: nil)
  }

  private func modify(identity: String, replacement: Data?) throws -> Bool {
    var found = false
    try files.locked(directory) {
      let (data, _) = try files.read(path, nil)
      var output = Data()
      for line in Self.lines(data) {
        if Self.entry(line)?.identity == identity {
          if !found, let replacement { output.append(replacement) }
          found = true
        } else {
          output.append(line)
        }
      }
      if !found, let replacement {
        if !output.isEmpty, output.last != 10 { output.append(10) }
        output.append(replacement)
      }
      if found || replacement != nil { try files.replace(path, output) }
    }
    return found
  }
}

public enum Glossary {
  public static func match(
    _ entries: [GlossaryEntry], in text: String,
    targetLanguage: String, nativeLanguage: String
  ) -> [GlossaryEntry] {
    let text = text.precomposedStringWithCanonicalMapping
    let whole = NSRange(text.startIndex..., in: text)
    var candidates: [(entry: GlossaryEntry, ranges: [NSRange], length: Int, identity: String)] = []
    let targetScripts = LanguageScripts.codes(for: targetLanguage)
    let nativeScripts = LanguageScripts.codes(for: nativeLanguage)
    for entry in entries
    where entry.targetLanguage == targetLanguage && entry.nativeLanguage == nativeLanguage {
      var ranges = targetPattern(entry)?.matches(in: text, range: whole).map(\.range) ?? []
      let native = entry.native.precomposedStringWithCanonicalMapping
      if native.count >= 2, let targetScripts, let nativeScripts, targetScripts != nativeScripts,
        LanguageScripts.containsLetter(native, in: nativeScripts)
      {
        let pattern = try! NSRegularExpression(
          pattern: NSRegularExpression.escapedPattern(for: native))
        ranges += pattern.matches(in: text, range: whole).map(\.range)
      }
      let length = ranges.compactMap { Range($0, in: text).map { text[$0].count } }.max() ?? 0
      if length > 0 { candidates.append((entry, ranges, length, entry.identity)) }
    }
    candidates.sort {
      if $0.length != $1.length { return $0.length > $1.length }
      if $0.entry.added != $1.entry.added { return $0.entry.added > $1.entry.added }
      return $0.identity < $1.identity
    }
    var occupied: [NSRange] = []
    var result: [GlossaryEntry] = []
    for candidate in candidates {
      let uncovered = candidate.ranges.filter { range in
        !occupied.contains {
          $0.length > range.length && $0.location <= range.location
            && NSMaxRange($0) >= NSMaxRange(range)
        }
      }
      guard !uncovered.isEmpty else { continue }
      result.append(candidate.entry.redacted)
      occupied += uncovered
      if result.count == 20 { break }
    }
    return result
  }

  /// Expressions with Latin, Cyrillic or Greek letters match whole words; English targets also
  /// accept the endings s, es, ed and ing. Other scripts match as substrings.
  private static func targetPattern(_ entry: GlossaryEntry) -> NSRegularExpression? {
    let target = entry.target.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard !target.isEmpty else { return nil }
    let pieces = target.components(separatedBy: CharacterSet(charactersIn: "- "))
    let pattern = pieces.map(NSRegularExpression.escapedPattern).joined(separator: "[- ]")
    let words = LanguageScripts.containsLetter(target, in: ["Latn", "Cyrl", "Grek"])
    let english =
      Locale.Language(identifier: entry.targetLanguage).languageCode?.identifier == "en"
    return try? NSRegularExpression(
      pattern: (words ? #"(?<![\p{L}\p{N}_])"# : "") + pattern
        + (words && english ? "(?:s|es|ed|ing)?" : "")
        + (words ? #"(?![\p{L}\p{N}_])"# : ""), options: .caseInsensitive)
  }

  public static func isSameTerm(_ word: String, entry: GlossaryEntry) -> Bool {
    if word == entry.native { return true }
    let word = word.precomposedStringWithCanonicalMapping
    let whole = NSRange(word.startIndex..., in: word)
    return targetPattern(entry)?.firstMatch(in: word, range: whole)?.range == whole
  }

  public static func paragraph(_ entries: [GlossaryEntry], explain: Bool) -> String {
    guard !entries.isEmpty else { return "" }
    let lines = entries.map { original in
      let entry = original.redacted
      return "- \(entry.target) = \(entry.native)" + (entry.note.map { " (\($0))" } ?? "")
    }
    let rules =
      explain
      ? "Use these translations in <translation> and <plain>. Do not produce <term> cards for these terms."
      : "When a native-language expression matches, use its target-language expression. Keep terms already in the target language instead of replacing them with synonyms; inflect them when grammar requires it."
    return
      "\n\nGlossary: the user's own translations. Use them for these terms where they carry this meaning.\n"
      + lines.joined(separator: "\n") + "\n" + rules
  }

  public static func anki(
    _ entries: [GlossaryEntry], targetLanguage: String, nativeLanguage: String
  ) -> String {
    func quote(_ text: String) -> String {
      text.contains("\"") ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }
    let header =
      "#separator:Tab\n#html:false\n#notetype:Basic\n#tags:parlance\n#guid column:1\n#columns:GUID\tFront\tBack\n"
    return header
      + entries.filter {
        $0.targetLanguage == targetLanguage && $0.nativeLanguage == nativeLanguage
      }
      .map { entry in
        [entry.guid, entry.target, entry.native + (entry.note.map { " — " + $0 } ?? "")]
          .map(quote).joined(separator: "\t") + "\n"
      }.joined()
  }
}
