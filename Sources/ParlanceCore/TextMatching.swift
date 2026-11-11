import Foundation

public enum TextMatching {
  public static func fold(_ character: Character) -> String {
    if character.isWhitespace { return "" }
    let folded = String(character).folding(
      options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    switch folded {
    case "“", "”", "„", "‟": return "\""
    case "‘", "’", "‚", "‛": return "'"
    case "‐", "‑", "‒", "–", "—", "−": return "-"
    case "…": return "..."
    default: return folded
    }
  }

  public struct SnippetRange: Sendable, Equatable {
    /// Unicode-scalar offsets in the original text, before folding or redaction.
    public let range: Range<Int>
    public let isDefinition: Bool
  }

  /// Only a single line of 2–200 Unicode scalars, after trimming, is searched for.
  public static func isSearchable(_ input: String) -> Bool {
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    return (2...200).contains(input.unicodeScalars.count) && !input.contains(where: \.isNewline)
  }

  /// One snippet per matching line, definitions first and otherwise in document order.
  /// Only whole matches inside one searchable range count; snippets may include nearby text.
  public static func snippetRanges(
    input: String, in text: String, searchableRanges: [Range<Int>]
  ) -> [SnippetRange] {
    guard isSearchable(input), !searchableRanges.isEmpty else { return [] }
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let needle = matchingView(Array(input)[...]).characters
    guard !needle.isEmpty else { return [] }
    let characters = Array(text)
    var offsets = [0]
    for character in characters {
      offsets.append(offsets.last! + character.unicodeScalars.count)
    }
    var candidates: [SnippetRange] = []
    var start = 0
    for end in 0...characters.count {
      guard end == characters.count || characters[end].isNewline else { continue }
      let line = characters[start..<end]
      if let candidate = snippet(
        line: line, offsets: offsets, needle: needle,
        leadingBoundary: input.first.map(isWord) == true,
        trailingBoundary: input.last.map(isWord) == true, searchableRanges: searchableRanges)
      {
        candidates.append(candidate)
      }
      start = end + 1
    }
    return candidates.filter(\.isDefinition) + candidates.filter { !$0.isDefinition }
  }

  private static func matchingView(_ characters: ArraySlice<Character>)
    -> (characters: [Character], origins: [Int])
  {
    var foldedCharacters: [Character] = []
    var origins: [Int] = []
    for index in characters.indices {
      if characters[index] == "\\", index + 1 < characters.endIndex,
        isASCIIPunctuation(characters[index + 1])
      {
        continue
      }
      let folded = fold(characters[index])
      foldedCharacters.append(contentsOf: folded)
      origins.append(contentsOf: repeatElement(index, count: folded.count))
    }
    return (foldedCharacters, origins)
  }

  private static func snippet(
    line: ArraySlice<Character>, offsets: [Int], needle: [Character],
    leadingBoundary: Bool, trailingBoundary: Bool, searchableRanges: [Range<Int>]
  ) -> SnippetRange? {
    let view = matchingView(line)
    guard view.characters.count >= needle.count else { return nil }
    var firstMatch: Range<Int>?
    var definition = false
    for start in 0...(view.characters.count - needle.count) {
      let end = start + needle.count
      guard view.characters[start..<end].elementsEqual(needle),
        start == 0 || view.origins[start - 1] != view.origins[start],
        end == view.origins.count || view.origins[end - 1] != view.origins[end]
      else { continue }
      let first = view.origins[start]
      let next = view.origins[end - 1] + 1
      // A Markdown escape right after the match is skipped: the boundary is the escaped character.
      var after = next
      if after + 1 < line.endIndex, line[after] == "\\", isASCIIPunctuation(line[after + 1]) {
        after += 1
      }
      // Likewise before the match: an escape there sits between the match and its neighbour.
      var before = first - 1
      if before > line.startIndex, line[before] == "\\", isASCIIPunctuation(line[first]) {
        before -= 1
      }
      guard !leadingBoundary || before < line.startIndex || !isWord(line[before]),
        !trailingBoundary || after == line.endIndex || !isWord(line[after])
      else { continue }
      let match = offsets[first]..<offsets[next]
      guard
        searchableRanges.contains(where: {
          $0.lowerBound <= match.lowerBound && match.upperBound <= $0.upperBound
        })
      else { continue }
      if firstMatch == nil { firstMatch = match }
      definition = definition || definitionFollows(line[next...])
    }
    guard let firstMatch else { return nil }
    definition = definition || line.filter { $0 == "|" }.count >= 2
    var first = line.startIndex
    var end = line.endIndex
    while first < end, line[first].isWhitespace { first += 1 }
    while end > first, line[end - 1].isWhitespace { end -= 1 }
    let lower = offsets[first]
    let upper = offsets[end]
    let start = max(
      lower, min((firstMatch.lowerBound + firstMatch.upperBound) / 2 - 150, upper - 300))
    return SnippetRange(range: start..<min(start + 300, upper), isDefinition: definition)
  }

  private static func definitionFollows(_ characters: ArraySlice<Character>) -> Bool {
    let rest = characters.drop { $0 == " " || $0 == "\t" || $0 == "*" || $0 == "`" }
    guard let first = rest.first else { return false }
    if [":", "：", "|", "=", "—"].contains(first) { return true }
    return first == "-" && rest.dropFirst().first == " "
  }

  private static func isWord(_ character: Character) -> Bool {
    guard character.unicodeScalars.count == 1, let value = character.unicodeScalars.first?.value
    else { return false }
    return (65...90).contains(value) || (97...122).contains(value)
      || (48...57).contains(value) || value == 95
  }

  private static func isASCIIPunctuation(_ character: Character) -> Bool {
    guard character.unicodeScalars.count == 1, let value = character.unicodeScalars.first?.value
    else { return false }
    return (33...47).contains(value) || (58...64).contains(value)
      || (91...96).contains(value) || (123...126).contains(value)
  }
}
