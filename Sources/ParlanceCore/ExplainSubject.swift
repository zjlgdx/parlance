public enum ExplainContext: Sendable, Equatable {
  case around(before: String, after: String)
  case tail(String)
}

public struct ExplainSubject: Sendable, Equatable {
  public enum InputRedaction: Sendable, Equatable { case redact, keep }
  public var input: String
  public var context: ExplainContext?
  public var inputRedaction: InputRedaction

  public init(input: String, context: ExplainContext? = nil, inputRedaction: InputRedaction) {
    self.input = input
    self.context = context
    self.inputRedaction = inputRedaction
  }
}

public struct PreparedSubject: Sendable, Equatable {
  public let input: String
  /// Actual redacted send windows, preserving which side of the selection they came from.
  public let context: ExplainContext?
  public let pemRedacted: Bool

  init(subject: ExplainSubject) {
    let input =
      subject.inputRedaction == .redact
      ? Redactor.redact(subject.input) : Redacted(text: subject.input, pemRedacted: false)
    self.input = input.text
    var pem = input.pemRedacted
    switch subject.context {
    case .around(let before, let after):
      let before = Self.window(before, limit: 1500, suffix: true)
      let after = Self.window(after, limit: 1500, suffix: false)
      context = .around(before: before.text, after: after.text)
      pem = pem || before.pemRedacted || after.pemRedacted
    case .tail(let text):
      let tail = Self.window(text, limit: 3000, suffix: true)
      context = .tail(tail.text)
      pem = pem || tail.pemRedacted
    case nil: context = nil
    }
    pemRedacted = pem
  }

  /// Windows use Unicode scalars, matching Redactor's coordinates (not bytes or graphemes).
  /// Find matches on the whole margin; clip replacements to original positions, never reflow.
  private static func window(_ text: String, limit: Int, suffix: Bool) -> Redacted {
    let replacements = Redactor.ranges(in: text)
    let scalars = Array(text.unicodeScalars)
    let window =
      suffix ? max(0, scalars.count - limit)..<scalars.count : 0..<min(limit, scalars.count)
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
