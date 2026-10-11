public struct ProtectedInput: Sendable, Equatable {
  public struct Delimiters: Sendable, Equatable {
    public let open: Unicode.Scalar
    public let close: Unicode.Scalar
  }
  /// What a fragment is, so the prompt can tell the model which token is the flag and which the
  /// path without sending the fragment itself. A backticked fragment takes the kind of its content
  /// when the content is exactly one recognized fragment. Two names joined by one slash
  /// (`src/Makefile`, but also `async/await` or `CI/CD`) are a `slashTerm`, not a `path`.
  public enum Kind: String, Sendable, Equatable {
    case path, slashTerm, flag, url, identifier, code
  }
  public let text: String
  public let fragments: [String]
  public let delimiters: Delimiters?
  public let counts: [Int]
  public let kinds: [Kind]

  public func token(_ index: Int) -> String {
    guard let delimiters else { return "" }
    return "\(delimiters.open)\(index)\(delimiters.close)"
  }

  public func validate(_ text: String) -> Bool {
    guard delimiters != nil else { return false }
    var actual = Array(repeating: 0, count: fragments.count)
    for token in tokens(in: text) {
      guard let index = token.index else { return false }
      actual[index] += 1
    }
    return actual == counts
  }

  public func containsUnknownToken(_ text: String) -> Bool {
    tokens(in: text).contains { $0.index == nil }
  }

  public func restore(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    var result = ""
    var start = 0
    for token in tokens(in: text) {
      guard let index = token.index else { continue }
      result += String(String.UnicodeScalarView(scalars[start..<token.range.lowerBound]))
      result += fragments[index]
      start = token.range.upperBound
    }
    result += String(String.UnicodeScalarView(scalars[start...]))
    return result
  }

  private func tokens(in text: String) -> [(range: Range<Int>, index: Int?)] {
    guard let delimiters else { return [] }
    let scalars = Array(text.unicodeScalars)
    var result: [(Range<Int>, Int?)] = []
    var start = 0
    // The chosen pair is absent from the input, so a delimiter scalar that is not part of a
    // numbered token can only come from the model; it is reported as an unknown token.
    while start < scalars.count {
      guard scalars[start] == delimiters.open else {
        if scalars[start] == delimiters.close { result.append((start..<(start + 1), nil)) }
        start += 1
        continue
      }
      var end = start + 1
      while end < scalars.count && TermProtection.isDigit(scalars[end]) { end += 1 }
      if end > start + 1 && end < scalars.count && scalars[end] == delimiters.close {
        let digits = String(String.UnicodeScalarView(scalars[(start + 1)..<end]))
        let number = Int(digits)
        let index = number.flatMap { value in
          String(value) == digits && fragments.indices.contains(value) ? value : nil
        }
        result.append((start..<(end + 1), index))
        start = end + 1
      } else {
        result.append((start..<(start + 1), nil))
        start += 1
      }
    }
    return result
  }
}

public enum TermProtection {
  public static func protect(_ input: String) -> ProtectedInput {
    let candidates: [ProtectedInput.Delimiters] = [
      .init(open: "⟦", close: "⟧"), .init(open: "⟪", close: "⟫"), .init(open: "〖", close: "〗"),
    ]
    let scalars = Array(input.unicodeScalars)
    guard
      let delimiters = candidates.first(where: {
        !scalars.contains($0.open) && !scalars.contains($0.close)
      })
    else {
      return ProtectedInput(text: input, fragments: [], delimiters: nil, counts: [], kinds: [])
    }
    let scanner = Scanner(scalars: scalars)
    var text = ""
    var fragments: [String] = []
    var counts: [Int] = []
    var kinds: [ProtectedInput.Kind] = []
    var indices: [[UInt8]: Int] = [:]
    var position = 0
    while position < scalars.count {
      if let (end, kind) = scanner.match(at: position) {
        let fragment = scanner.text(position..<end)
        let identity = Array(fragment.utf8)
        let index: Int
        if let existing = indices[identity] {
          index = existing
          counts[index] += 1
        } else {
          index = fragments.count
          indices[identity] = index
          fragments.append(fragment)
          counts.append(1)
          kinds.append(kind)
        }
        text += "\(delimiters.open)\(index)\(delimiters.close)"
        position = end
      } else {
        text.unicodeScalars.append(scalars[position])
        position += 1
      }
    }
    return ProtectedInput(
      text: text, fragments: fragments, delimiters: delimiters, counts: counts, kinds: kinds)
  }

  fileprivate static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
    ("0"..."9").contains(scalar)
  }
  private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
  }
  private static func isIdentifier(_ scalar: Unicode.Scalar) -> Bool {
    isLetter(scalar) || isDigit(scalar) || scalar == "_"
  }
  private static func isPath(_ scalar: Unicode.Scalar) -> Bool {
    isIdentifier(scalar) || ".~/-+@%".unicodeScalars.contains(scalar)
  }

  private struct Scanner {
    let scalars: [Unicode.Scalar]
    /// A URL or flag value runs to whitespace, a curly quote or CJK text (prose that follows
    /// without a space; raw CJK inside a URL is not supported) and then sheds trailing ASCII
    /// sentence punctuation and closing quotes.
    let asciiPunctuation = ".,;:!?)]}>\"'"
    func isValueScalar(_ scalar: Unicode.Scalar) -> Bool {
      !scalar.properties.isWhitespace && !"“”‘’—…·".unicodeScalars.contains(scalar)
        && !isCJK(scalar)
    }
    func isCJK(_ scalar: Unicode.Scalar) -> Bool {
      // Ideographs, CJK symbols and punctuation, kana, Hangul syllables and fullwidth forms.
      scalar.properties.isIdeographic || (0x3000...0x30FF).contains(scalar.value)
        || (0xAC00...0xD7AF).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value)
    }
    func text(_ range: Range<Int>) -> String {
      String(String.UnicodeScalarView(scalars[range]))
    }
    func end(from start: Int, while matches: (Unicode.Scalar) -> Bool) -> Int {
      var end = start
      while end < scalars.count && matches(scalars[end]) { end += 1 }
      return end
    }
    /// Sheds trailing punctuation; a closing bracket stays when the fragment opens it
    /// (`https://en.wikipedia.org/wiki/Function_(mathematics)`).
    func trimmed(_ end: Int, from start: Int, punctuation: String) -> Int {
      var end = end
      while end > start && punctuation.unicodeScalars.contains(scalars[end - 1]) {
        let closer = scalars[end - 1]
        let pairs: [Unicode.Scalar: Unicode.Scalar] = [")": "(", "]": "[", "}": "{"]
        if let opener = pairs[closer] {
          let range = scalars[start..<(end - 1)]
          if range.filter({ $0 == opener }).count > range.filter({ $0 == closer }).count { break }
        }
        end -= 1
      }
      return end
    }
    func match(at start: Int) -> (end: Int, kind: ProtectedInput.Kind)? {
      if let end = backticks(at: start) {
        let inner = Scanner(scalars: Array(scalars[(start + 1)..<(end - 1)]))
        if let (innerEnd, kind) = inner.match(at: 0), innerEnd == inner.scalars.count {
          return (end, kind)
        }
        return (end, .code)
      }
      if let end = url(at: start) { return (end, .url) }
      if let (end, isPath) = path(at: start) { return (end, isPath ? .path : .slashTerm) }
      if let end = flag(at: start) { return (end, .flag) }
      if let end = dotted(at: start) ?? bare(at: start) { return (end, .identifier) }
      return nil
    }
    func backticks(at start: Int) -> Int? {
      guard scalars[start] == "`" else { return nil }
      let end = end(from: start + 1) {
        $0 != "`" && !"\n\r\u{B}\u{C}\u{85}\u{2028}\u{2029}".unicodeScalars.contains($0)
      }
      return end > start + 1 && end < scalars.count && scalars[end] == "`" ? end + 1 : nil
    }
    func url(at start: Int) -> Int? {
      guard isLetter(scalars[start]), start == 0 || !isIdentifier(scalars[start - 1])
      else { return nil }
      let schemeEnd = end(from: start + 1) {
        isLetter($0) || isDigit($0) || "+.-".unicodeScalars.contains($0)
      }
      guard schemeEnd + 3 <= scalars.count, text(schemeEnd..<(schemeEnd + 3)) == "://"
      else { return nil }
      let body = schemeEnd + 3
      let end = trimmed(
        end(from: body, while: isValueScalar), from: body, punctuation: asciiPunctuation)
      return end > body ? end : nil
    }
    func path(at start: Int) -> (end: Int, isPath: Bool)? {
      guard isPath(scalars[start]), !"+@%".unicodeScalars.contains(scalars[start]),
        start == 0 || !isPath(scalars[start - 1])
      else { return nil }
      let end = trimmed(end(from: start, while: isPath), from: start, punctuation: ".,:;)")
      let value = text(start..<end)
      guard value.contains("/"),
        scalars[start..<end].contains(where: { isLetter($0) || isDigit($0) })
      else { return nil }
      let absolute = ["/", "./", "../", "~/"].contains { value.hasPrefix($0) }
      let segments = value.split(separator: "/", omittingEmptySubsequences: false)
      let nested = segments.count >= 3
      let last = Array((segments.last.map(String.init) ?? "").unicodeScalars)
      let extensionExists = last.indices.contains { index in
        last[index] == "." && index + 1 < last.count
          && (isLetter(last[index + 1]) || isDigit(last[index + 1]))
      }
      // `src/Makefile`, `bin/tool`: a single slash between two names is a relative path unless it
      // reads as prose (`and/or`, `he/she`, `km/h`, `yes/no`): both sides plain lowercase letters
      // with one side shorter than three.
      let relative =
        segments.count == 2
        && segments.allSatisfy { segment in
          segment.unicodeScalars.contains { isLetter($0) || isDigit($0) }
        }
        && segments.contains { segment in
          segment.unicodeScalars.count >= 3 && segments.allSatisfy { $0.unicodeScalars.count >= 3 }
            || segment.unicodeScalars.contains { !("a"..."z").contains($0) }
        }
      if absolute || nested || extensionExists { return (end, true) }
      return relative ? (end, false) : nil
    }
    func flag(at start: Int) -> Int? {
      guard start + 2 < scalars.count, scalars[start] == "-", scalars[start + 1] == "-",
        isLetter(scalars[start + 2]) || isDigit(scalars[start + 2]),
        start == 0 || !(isIdentifier(scalars[start - 1]) || scalars[start - 1] == "-")
      else { return nil }
      var end = end(from: start + 3) { isIdentifier($0) || $0 == "-" }
      if end < scalars.count && scalars[end] == "=" {
        let valueEnd = trimmed(
          self.end(from: end + 1, while: isValueScalar), from: end + 1,
          punctuation: asciiPunctuation)
        if valueEnd > end + 1 { end = valueEnd }
      }
      return end
    }
    func dotted(at start: Int) -> Int? {
      guard start == 0 || !isIdentifier(scalars[start - 1]) else { return nil }
      var position = start
      var segments = 0
      var longSegment = false
      while position < scalars.count {
        guard isLetter(scalars[position]) || scalars[position] == "_" else { break }
        let segmentEnd = end(from: position, while: isIdentifier)
        segments += 1
        longSegment = longSegment || segmentEnd - position >= 2
        position = segmentEnd
        guard position + 1 < scalars.count && scalars[position] == ".",
          isLetter(scalars[position + 1]) || scalars[position + 1] == "_",
          !startsSentence(at: position + 1)
        else { break }
        position += 1
      }
      let call = position + 1 < scalars.count && text(position..<(position + 2)) == "()"
      // Abbreviations such as `e.g.` and `i.e.` are chains of single letters; a member name of one
      // letter is kept once the chain has a longer member or ends in a call (`a.b()`).
      guard segments >= 2, longSegment || call else { return nil }
      if call { position += 2 }
      return position == scalars.count || !isIdentifier(scalars[position]) ? position : nil
    }
    /// `late.I missed` is a missing space before a sentence, not a member access: a single
    /// uppercase letter that is not a call ends the chain.
    func startsSentence(at index: Int) -> Bool {
      let segmentEnd = end(from: index, while: isIdentifier)
      guard segmentEnd - index == 1, ("A"..."Z").contains(scalars[index]) else { return false }
      return !(segmentEnd + 1 < scalars.count && text(segmentEnd..<(segmentEnd + 2)) == "()")
    }
    func bare(at start: Int) -> Int? {
      guard isIdentifier(scalars[start]), start == 0 || !isIdentifier(scalars[start - 1])
      else { return nil }
      let end = end(from: start, while: isIdentifier)
      let word = scalars[start..<end]
      let snake = word.contains("_") && word.contains { isLetter($0) || isDigit($0) }
      let camel =
        !word.contains("_") && word.contains { ("a"..."z").contains($0) }
        && word.dropFirst().contains { ("A"..."Z").contains($0) }
      return snake || camel ? end : nil
    }
  }
}
