import Foundation

public struct Redaction: Sendable, Equatable {
  /// Half-open offsets into the original text's unicodeScalars, not UTF-16 or Characters.
  public let range: Range<Int>
  /// True if any part of this merged range was matched by the PEM rule.
  public let isPEM: Bool
  /// Exact PEM portions before merging with other rules, in original scalar coordinates.
  public let pemRanges: [Range<Int>]
}

public struct Redacted: Sendable, Equatable {
  public let text: String
  public let pemRedacted: Bool
}

/// Best-effort context redaction for common secret formats; rare formats can be missed.
public enum Redactor {
  public static let placeholder = "[REDACTED]"

  /// Computes all matches on the whole original text, then merges overlapping or adjacent ranges.
  /// Callers can intersect these scalar ranges with a window in original-text coordinates.
  public static func ranges(in text: String) -> [Redaction] {
    let pemMatches = pemRanges(in: text)
    var matches = pemMatches
    for pattern in tokenPatterns {
      matches += find(pattern, in: text).map { Match(range: $0.range, isPEM: false) }
    }
    matches += assignmentRanges(in: text)
    let urls = find(urlPattern, in: text)
    // The part of each URL before its query or fragment: scheme, user info, host, port, path.
    let urlPaths = urls.map { url -> NSRange in
      let tail = (text as NSString).substring(with: url.range(at: 1))
      let pathLength =
        tail.utf16.firstIndex { $0 == 0x3F || $0 == 0x23 }
        .map { tail.utf16.distance(from: tail.utf16.startIndex, to: $0) } ?? tail.utf16.count
      return NSRange(
        location: url.range.location,
        length: url.range(at: 1).location - url.range.location + pathLength)
    }
    // Keep internal dots to protect filenames and dotted identifiers, but shed sentence dots.
    for candidate in find(randomPattern, in: text) {
      var range = candidate.range
      let original = (text as NSString).substring(with: range)
      range.length -= original.reversed().prefix { $0 == "." }.count
      let value = (text as NSString).substring(with: range)
      // A slash-joined run in a URL's path (with the host or port in front) is judged segment by
      // segment by the URL loop below. Query values, user info and fragments are judged here.
      if value.contains("/"),
        urlPaths.contains(where: { NSIntersectionRange($0, candidate.range).length > 0 })
      {
        continue
      }
      if isRandomToken(value) {
        matches.append(Match(range: range, isPEM: false))
      }
    }
    // A host's dots and word-like directories must not hide random tokens in URL path segments.
    // Inspect segments only inside explicit HTTP(S) URLs, leaving ordinary paths unchanged.
    for url in urls {
      for candidate in find(urlTokenPattern, in: text, range: url.range(at: 1)) {
        let value = (text as NSString).substring(with: candidate.range)
        if isRandomToken(value) {
          matches.append(Match(range: candidate.range, isPEM: false))
        }
      }
    }

    var merged: [Match] = []
    for match in matches.sorted(by: { $0.range.location < $1.range.location }) {
      if let last = merged.last, match.range.location <= NSMaxRange(last.range) {
        merged[merged.count - 1] = Match(
          range: NSRange(
            location: last.range.location,
            length: max(NSMaxRange(last.range), NSMaxRange(match.range)) - last.range.location),
          isPEM: last.isPEM || match.isPEM)
      } else {
        merged.append(match)
      }
    }

    // Regex ranges use UTF-16. Convert once, preserving scalar boundaries even beside emoji
    // and combining marks; String's grapheme-cluster indices are not the API's coordinate unit.
    var scalarOffsets = [0: 0]
    var utf16Offset = 0
    for (offset, scalar) in text.unicodeScalars.enumerated() {
      utf16Offset += scalar.value > 0xFFFF ? 2 : 1
      scalarOffsets[utf16Offset] = offset + 1
    }
    let pemScalars = pemMatches.map {
      scalarOffsets[$0.range.location]!..<scalarOffsets[NSMaxRange($0.range)]!
    }
    return merged.map { match in
      Redaction(
        range: scalarOffsets[match.range.location]!..<scalarOffsets[NSMaxRange(match.range)]!,
        isPEM: match.isPEM,
        pemRanges: pemScalars.filter { pem in
          pem.overlaps(
            scalarOffsets[match.range.location]!..<scalarOffsets[NSMaxRange(match.range)]!)
        })
    }
  }

  public static func redact(_ text: String) -> Redacted {
    let replacements = ranges(in: text)
    let scalars = Array(text.unicodeScalars)
    var output = ""
    var start = 0
    for replacement in replacements {
      output += String(String.UnicodeScalarView(scalars[start..<replacement.range.lowerBound]))
      output += placeholder
      start = replacement.range.upperBound
    }
    output += String(String.UnicodeScalarView(scalars[start...]))
    return Redacted(text: output, pemRedacted: replacements.contains { $0.isPEM })
  }

  // Prefix rules are case-sensitive, start outside ASCII identifiers, and consume the whole key.
  // ASCII boundaries allow a following combining mark or adjacent CJK prose to stay untouched.
  // JWT segments need at least eight base64url characters each; no signature validation occurs.
  // This heuristic misses valid JWTs with shorter payloads or signatures.
  private static let tokenPatterns = [
    #"(?<![A-Za-z0-9_])sk-[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])"#,
    #"(?<![A-Za-z0-9_])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9_-])"#,
    #"(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{30,}(?![A-Za-z0-9_-])"#,
    #"(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{40,}(?![A-Za-z0-9_-])"#,
    #"(?<![A-Za-z0-9_])AIza[A-Za-z0-9_-]{35}(?![A-Za-z0-9_-])"#,
    #"(?<![A-Za-z0-9_.-])eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-])(?!\.[A-Za-z0-9_-])"#,
  ].map(compile)

  private static let randomPattern = compile(#"[A-Za-z0-9+/_.\-]+={0,2}"#)
  private static let urlPattern = compile(#"(?i)\bhttps?://[^/\s"'<>]+(/[^\s"'<>]*)"#)
  private static let urlTokenPattern = compile(#"(?<=/)[A-Za-z0-9+_-]{32,}={0,2}"#)
  private static let pemPattern = compile(#"-----((?:BEGIN|END))[\t ]+[^\r\n]+?-----"#)
  private static let uuidPattern = compile(
    #"^[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"#)
  private static let assignmentPattern = compile(
    #"(?i)(?<![A-Za-z0-9_.-])(["']?)(?:[A-Za-z0-9_.-]*[_.-])?(?:KEY|TOKEN|SECRET|PASSWORD)\1[\t ]*(?:=(?!=)|:)[\t ]*"#
      + #"(?:"((?:\\[^\r\n]|[^"\\\r\n])*)"|'((?:\\[^\r\n]|[^'\\\r\n])*)'|((?!=)[!#-&(-;=?-~]+))"#)
  private static let referencePattern = compile(
    #"^(?:\$[A-Za-z_][A-Za-z0-9_]*|\$\{[A-Za-z_][A-Za-z0-9_]*\}|\{[A-Za-z_][A-Za-z0-9_.]*\}|<your-[A-Za-z0-9_.-]+>)$"#
  )

  /// Assignment names end in KEY, TOKEN, SECRET or PASSWORD, at the start or after _, - or .
  /// Names and values may be quoted; horizontal space is allowed around a single = or colon.
  /// Only the value is removed, excluding its outer quotes. Unquoted values are printable ASCII
  /// up to whitespace, a quote, `<` or `>` (so JSX `key={item.id}>` and CJK prose after the value
  /// stay), including internal #, commas and brackets. A whole `{identifier.path}` value is a
  /// template or JSX reference and stays. Trailing commas/semicolons and
  /// unmatched closing ), ] or } stay as syntax; balanced brackets remain part of the value.
  /// Empty values and exact $VAR, ${VAR}, <your-...> references are left alone by this rule.
  /// Other rules still inspect those values. This is a text heuristic, not a shell/JSON parser:
  /// `let token: String` also matches, an accepted false positive shared with YAML assignments.
  private static func assignmentRanges(in text: String) -> [Match] {
    let source = text as NSString
    return find(assignmentPattern, in: text).compactMap { match in
      var valueRange = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
      if match.range(at: 4).location != NSNotFound {
        let raw = source.substring(with: valueRange)
        if raw.hasPrefix("#"), valueRange.location > 0,
          " \t".utf16.contains(source.character(at: valueRange.location - 1))
        {
          return nil
        }
        valueRange.length -= trailingSyntaxLength(raw)
      }
      let value = source.substring(with: valueRange)
      guard !value.isEmpty, find(referencePattern, in: value).isEmpty else { return nil }
      return Match(range: valueRange, isPEM: false)
    }
  }

  private static func trailingSyntaxLength(_ value: String) -> Int {
    let pairs: [Unicode.Scalar: Unicode.Scalar] = [")": "(", "]": "[", "}": "{"]
    var counts: [Unicode.Scalar: Int] = [:]
    for scalar in value.unicodeScalars { counts[scalar, default: 0] += 1 }
    var length = 0
    for scalar in value.unicodeScalars.reversed() {
      if scalar == "," || scalar == ";" {
        length += 1
      } else if let opener = pairs[scalar], counts[scalar, default: 0] > counts[opener, default: 0]
      {
        counts[scalar, default: 0] -= 1
        length += 1
      } else {
        break
      }
    }
    return length
  }

  /// One left-to-right scan: BEGIN opens a block through the next END, ignoring nested BEGIN.
  /// An unpaired END starts at the previous PEM replacement's end (or the text's start).
  /// An open BEGIN extends to EOF. Markers count anywhere, including escaped JSON and diff lines.
  /// Accepted cost: a stray BEGIN in documentation, a log or a source string consumes the rest
  /// of the text if no END follows; a stray END consumes the preceding text since the last PEM.
  private static func pemRanges(in text: String) -> [Match] {
    let markers = find(pemPattern, in: text)
    var result: [Match] = []
    var open: Int?
    var previousEnd = 0
    for marker in markers {
      let kind = (text as NSString).substring(with: marker.range(at: 1))
      if kind == "BEGIN" {
        if open == nil { open = marker.range.location }
      } else {
        let start = open ?? previousEnd
        previousEnd = NSMaxRange(marker.range)
        result.append(
          Match(range: NSRange(location: start, length: previousEnd - start), isPEM: true))
        open = nil
      }
    }
    if let open {
      result.append(
        Match(range: NSRange(location: open, length: text.utf16.count - open), isPEM: true))
    }
    return result
  }

  /// A random candidate is >=32 ASCII key characters (alphanumerics, +, /, _, -, with up to
  /// two trailing = padding characters), contains uppercase, lowercase and at least one digit,
  /// and has character-class run density >=0.4. Classes are upper/lower/digit/other; runs are
  /// one plus adjacent class changes, divided by the full candidate length including padding.
  /// Dots, pure hex and dashed UUIDs are excluded. All-lowercase+digit tokens and low-density
  /// secrets are missed; identifiers with frequent class changes can be false positives.
  /// Leading/trailing and repeated slashes are ignored for segment checks. Segments of at
  /// least eight characters also need density >=0.4 to reject word-like paths. Short segments
  /// need no class/density check,
  /// and segments need not individually contain all three classes. This allows short base64
  /// fragments, but can miss base64 with word-like segments or flag random-looking paths.
  /// No consecutive-line inference is used.
  private static func isRandomToken(_ token: String) -> Bool {
    let bytes = Array(token.utf8)
    guard bytes.count >= 32, !bytes.contains(46) else { return false }
    let isHex: (UInt8) -> Bool = {
      (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
    }
    guard !bytes.allSatisfy(isHex) else { return false }
    if !find(uuidPattern, in: token).isEmpty {
      return false
    }
    // An absolute path with several segments (`/var/folders/x3/<hash>/T/`) is a path, even when
    // one directory name is a random-looking hash. Base64 that starts with `/` and contains
    // another `/` is missed as a result.
    if bytes.first == 47 && bytes.split(separator: 47).count >= 2 { return false }
    let classes = bytes.map(characterClass)
    guard classes.contains(0), classes.contains(1), classes.contains(2),
      hasRandomRunDensity(classes[...])
    else { return false }
    return bytes.split(separator: 47, omittingEmptySubsequences: true).allSatisfy {
      $0.count < 8 || hasRandomRunDensity($0.map(characterClass)[...])
    }
  }

  private static func characterClass(_ byte: UInt8) -> Int {
    switch byte {
    case 65...90: return 0
    case 97...122: return 1
    case 48...57: return 2
    default: return 3
    }
  }

  private static func hasRandomRunDensity(_ classes: ArraySlice<Int>) -> Bool {
    guard !classes.isEmpty else { return false }
    let runs = 1 + zip(classes, classes.dropFirst()).filter { $0 != $1 }.count
    return runs * 5 >= classes.count * 2
  }

  private struct Match {
    let range: NSRange
    let isPEM: Bool
  }

  private static func compile(_ pattern: String) -> NSRegularExpression {
    // Called only by static initializers for constant patterns owned by this file.
    try! NSRegularExpression(pattern: pattern)
  }

  private static func find(
    _ regex: NSRegularExpression, in text: String, range: NSRange? = nil
  ) -> [NSTextCheckingResult] {
    regex.matches(in: text, range: range ?? NSRange(location: 0, length: text.utf16.count))
  }
}
