import Foundation

public enum ContextScope: Sendable, Equatable {
  case focusedText, visibleWindow, none
}

public struct ExplainSource: Sendable, Equatable {
  public var app: String
  public var title: String?
  public var scope: ContextScope

  public init(app: String, title: String? = nil, scope: ContextScope) {
    self.app = app
    self.title = title
    self.scope = scope
  }
}

public enum ExplainContext: Sendable, Equatable {
  case around(before: String, after: String)
  case tail(String)

  /// The most UTF-8 bytes the app and the CLI keep on each side of the selection.
  public static let marginBytes = 16 * 1024
}

public struct ExplainSubject: Sendable, Equatable {
  public enum InputRedaction: Sendable, Equatable { case redact, keep }
  public var input: String
  public var context: ExplainContext?
  public var source: ExplainSource?
  public var inputRedaction: InputRedaction

  public init(
    input: String, context: ExplainContext? = nil, inputRedaction: InputRedaction,
    source: ExplainSource? = nil
  ) {
    self.input = input
    self.context = context
    self.source = source
    self.inputRedaction = inputRedaction
  }
}

/// A file or clipboard text the user chose to send with an explanation. `name` is a file name
/// without its path, or 剪贴板 for the clipboard.
public struct ExplainAttachment: Sendable, Equatable {
  public var name: String
  public var text: String

  public init(name: String, text: String) {
    self.name = name
    self.text = text
  }
}

/// The redacted part of an attachment that is sent; `name` is redacted and on one line.
public enum PreparedAttachment: Sendable, Equatable {
  /// The whole attachment.
  case whole(name: String, text: String)
  /// Lines that mention the input.
  case snippets(name: String, lines: [String])
  /// Searched, without a match.
  case noMatch(name: String)
  /// The beginning only, when the input is not searchable.
  case head(name: String, text: String)

  public var name: String {
    switch self {
    case .whole(let name, _), .snippets(let name, _), .noMatch(let name), .head(let name, _): name
    }
  }

  /// The attachment text that is sent, without its name.
  public var texts: [String] {
    switch self {
    case .whole(_, let text), .head(_, let text): [text]
    case .snippets(_, let lines): lines
    case .noMatch: []
    }
  }
}

public struct PreparedSubject: Sendable, Equatable {
  public let input: String
  /// Actual redacted send windows, preserving which side of the selection they came from.
  public let context: ExplainContext?
  public let elsewhere: [String]
  public let source: ExplainSource?
  public internal(set) var attachment: PreparedAttachment?
  public var pemRedacted: Bool { partsPEM || attachmentPEM }
  /// Kept apart so that replacing or removing an attachment never leaves its PEM state behind.
  private let partsPEM: Bool
  private var attachmentPEM = false

  public init(subject: ExplainSubject) {
    let input =
      subject.inputRedaction == .redact
      ? Redactor.redact(subject.input) : Redacted(text: subject.input, pemRedacted: false)
    self.input = input.text
    var pem = input.pemRedacted
    var margins: [(text: String, searchable: Range<Int>)] = []
    switch subject.context {
    case .around(let before, let after):
      margins = [
        (before, Self.skippingCutLine(before, 0..<max(0, before.unicodeScalars.count - 1500))),
        (
          after,
          Self.skippingCutLine(
            after, min(1500, after.unicodeScalars.count)..<after.unicodeScalars.count, atEnd: true)
        ),
      ]
      let before = Self.window(before, limit: 1500, suffix: true)
      let after = Self.window(after, limit: 1500, suffix: false)
      context = .around(before: before.text, after: after.text)
      pem = pem || before.pemRedacted || after.pemRedacted
    case .tail(let text):
      margins = [(text, Self.skippingCutLine(text, 0..<max(0, text.unicodeScalars.count - 3000)))]
      let tail = Self.window(text, limit: 3000, suffix: true)
      context = .tail(tail.text)
      pem = pem || tail.pemRedacted
    case nil: context = nil
    }
    var snippets: [String] = []
    if subject.source?.scope != ContextScope.none {
      let candidates = margins.enumerated().flatMap { index, margin in
        TextMatching.snippetRanges(
          input: subject.input, in: margin.text, searchableRanges: [margin.searchable]
        ).map { (margin: index, snippet: $0) }
      }
      let ranked =
        candidates.filter { $0.snippet.isDefinition }
        + candidates.filter { !$0.snippet.isDefinition }
      // Like the send windows, the limits count original scalars; a placeholder may lengthen a
      // snippet slightly, and clipping on original positions is what keeps it whole.
      var total = 0
      for candidate in ranked {
        guard snippets.count < 3 else { break }
        let range = candidate.snippet.range
        guard total + range.count <= 900 else { continue }
        let clipped = Self.clip(margins[candidate.margin].text, range: range)
        snippets.append(clipped.text)
        total += range.count
        pem = pem || clipped.pemRedacted
      }
    }
    elsewhere = snippets
    if let source = subject.source {
      let app = Redactor.redact(source.app)
      let title = source.title.map(Redactor.redact)
      self.source = ExplainSource(
        app: Self.sourceLine(app.text), title: title.map { Self.sourceLine($0.text) },
        scope: source.scope)
      pem = pem || app.pemRedacted || title?.pemRedacted == true
    } else {
      source = nil
    }
    partsPEM = pem
  }

  private init(input: String, preserving subject: PreparedSubject, partsPEM: Bool) {
    self.input = input
    context = subject.context
    elsewhere = subject.elsewhere
    source = subject.source
    self.partsPEM = partsPEM
  }

  /// Redacts the whole input and removes the attachment, preserving the prepared background.
  public func forDocument() -> PreparedSubject {
    let redacted = Redactor.redact(input)
    return PreparedSubject(
      input: redacted.text, preserving: self, partsPEM: partsPEM || redacted.pemRedacted)
  }

  /// A copy with only the attachment replaced (`nil` removes it). It is prepared from the saved
  /// input and the attachment's original text, so the session never keeps unredacted margins.
  public func attaching(_ attachment: ExplainAttachment?) -> PreparedSubject {
    var copy = self
    copy.attachment = nil
    copy.attachmentPEM = false
    guard let attachment else { return copy }
    let redactedName = Redactor.redact(attachment.name)
    let name = Self.sourceLine(redactedName.text)
    let text = attachment.text
    let replacements = Redactor.ranges(in: text)
    let count = text.unicodeScalars.count
    let whole = Self.clip(text, range: 0..<count, replacements: replacements)
    var pem = redactedName.pemRedacted
    if whole.text.unicodeScalars.count <= 12_000 {
      copy.attachment = .whole(name: name, text: whole.text)
      pem = pem || whole.pemRedacted
    } else if !TextMatching.isSearchable(input) {
      let head = Self.clip(text, range: 0..<min(2_400, count), replacements: replacements)
      copy.attachment = .head(name: name, text: head.text)
      pem = pem || head.pemRedacted
    } else {
      // The attachment was not cut by capture, so all of it is searchable. As with the snippets
      // elsewhere in the text, the limits count original scalars.
      var lines: [String] = []
      var total = 0
      for snippet in TextMatching.snippetRanges(
        input: input, in: text, searchableRanges: [0..<count])
      {
        guard lines.count < 8 else { break }
        guard total + snippet.range.count <= 2_400 else { continue }
        let clipped = Self.clip(text, range: snippet.range, replacements: replacements)
        lines.append(clipped.text)
        total += snippet.range.count
        pem = pem || clipped.pemRedacted
      }
      copy.attachment = lines.isEmpty ? .noMatch(name: name) : .snippets(name: name, lines: lines)
    }
    copy.attachmentPEM = pem
    return copy
  }

  /// Keeps the source on one line of the prompt: line breaks and control characters (category Cc;
  /// joiners stay) become spaces. The field is clipped after redaction, before any placeholder
  /// that would straddle the limit, so every placeholder sent is whole and counted.
  private static func sourceLine(_ text: String, limit: Int = 200) -> String {
    let scalars = text.unicodeScalars.map {
      $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0) ? " " : $0
    }
    guard scalars.count > limit else { return String(String.UnicodeScalarView(scalars)) }
    let placeholder = Array(Redactor.placeholder.unicodeScalars)
    let straddling = (max(0, limit - placeholder.count + 1)..<limit).first {
      $0 + placeholder.count <= scalars.count
        && Array(scalars[$0..<$0 + placeholder.count]) == placeholder
    }
    return String(String.UnicodeScalarView(Array(scalars.prefix(straddling ?? limit)) + ["…"]))
  }

  /// A margin that reaches `marginBytes` (less one long Character, or a few stripped bytes) was
  /// probably cut at its outer edge (the start of `before` or `.tail`, the end of `after`),
  /// possibly inside a secret that the redactor can no longer recognise, so the search range stops
  /// short of the line touching that edge. A shorter margin is the whole text and keeps its edges;
  /// the side next to the selection is never cut.
  private static func skippingCutLine(_ text: String, _ range: Range<Int>, atEnd: Bool = false)
    -> Range<Int>
  {
    guard text.utf8.count > ExplainContext.marginBytes - 64 else { return range }
    let scalars = Array(text.unicodeScalars)
    if atEnd {
      let upper = min(
        range.upperBound, scalars.lastIndex { CharacterSet.newlines.contains($0) } ?? 0)
      return min(range.lowerBound, upper)..<upper
    }
    let lower = max(
      range.lowerBound,
      (scalars.firstIndex { CharacterSet.newlines.contains($0) } ?? scalars.count) + 1)
    return lower..<max(lower, range.upperBound)
  }

  /// Windows use Unicode scalars, matching Redactor's coordinates (not bytes or graphemes).
  private static func window(_ text: String, limit: Int, suffix: Bool) -> Redacted {
    let count = text.unicodeScalars.count
    let window =
      suffix ? max(0, count - limit)..<count : 0..<min(limit, count)
    return clip(text, range: window)
  }

  /// Find matches on the whole margin; clip replacements to original positions, never reflow.
  private static func clip(
    _ text: String, range window: Range<Int>, replacements: [Redaction]? = nil
  ) -> Redacted {
    let replacements = replacements ?? Redactor.ranges(in: text)
    let scalars = Array(text.unicodeScalars)
    var cursor = window.lowerBound
    var output = ""
    var pem = false
    for replacement in replacements where replacement.range.overlaps(window) {
      let start = max(window.lowerBound, replacement.range.lowerBound)
      let end = min(window.upperBound, replacement.range.upperBound)
      output += String(String.UnicodeScalarView(scalars[cursor..<start]))
      output += Redactor.placeholder
      cursor = end
      pem = pem || replacement.pemRanges.contains { $0.overlaps(window) }
    }
    output += String(String.UnicodeScalarView(scalars[cursor..<window.upperBound]))
    return Redacted(text: output, pemRedacted: pem)
  }
}
