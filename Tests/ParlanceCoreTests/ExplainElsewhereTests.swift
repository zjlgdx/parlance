import Foundation
import Testing

@testable import ParlanceCore

struct ExplainElsewhereTests {
  @Test func definitionBeyondTenKiBAppearsInPrompt() {
    let definition = "| rollout gate | 发布前必须通过的检查 |"
    let after =
      "\n" + String(repeating: "Fictional filler prose.\n", count: 500) + definition
      + "\nFictional closing line."
    #expect(after.utf8.count > 10 * 1024)
    let subject = PreparedSubject(
      subject: ExplainSubject(
        input: "rollout gate", context: .around(before: "", after: after),
        inputRedaction: .keep))
    #expect(subject.elsewhere == [definition])
    #expect(
      ExplainPrompt.user(subject: subject)
        .contains("\n\nBackground elsewhere in the same text:\n" + definition))
  }

  private func snippets(_ input: String, _ text: String, searchable: [Range<Int>]? = nil)
    -> [String]
  {
    let scalars = Array(text.unicodeScalars)
    return TextMatching.snippetRanges(
      input: input, in: text, searchableRanges: searchable ?? [0..<scalars.count]
    ).map { String(String.UnicodeScalarView(scalars[$0.range])) }
  }

  @Test func searchEligibilityUsesTrimmedScalarsAndSingleLines() {
    for input in ["a", String(repeating: "a", count: 201), "ab\ncd", "ab\r\ncd", "ab\u{2028}cd"] {
      #expect(snippets(input, input + ": definition").isEmpty)
    }
    for input in ["ab", String(repeating: "界", count: 200), "e\u{301}"] {
      #expect(snippets(" \t" + input + "\n", input + ": definition").count == 1)
    }
    #expect(snippets("ab cd", "ab\ncd").isEmpty)
    #expect(snippets("ab cd", "ab\rcd").isEmpty)
  }

  @Test func foldingEscapesAndOriginalWordBoundaries() {
    #expect(snippets("foo_bar", #"ＦＯＯ\_ＢＡＲ: definition"#).count == 1)
    #expect(snippets(#"foo\_bar"#, "foo_bar: definition").count == 1)
    #expect(snippets("ab", #"a\b"#).isEmpty)
    #expect(snippets("on", "long\nonly\n_on\non2\nturn on.") == ["turn on."])
    #expect(snippets("_x", "a_x\n_x!").count == 1)
    #expect(snippets("42", "142\n42a\n42.").count == 1)
    #expect(snippets("STRASSE", "Straße: road") == ["Straße: road"])
    #expect(snippets("as", "aß").isEmpty)
    #expect(snippets("éx", "e\u{301}x: definition") == ["e\u{301}x: definition"])
    #expect(snippets("“a”—…", "\"A\"-...") == ["\"A\"-..."])
  }

  @Test func onlyWholeMatchesInSearchableRangesCount() {
    let text = "term term"
    #expect(snippets("term", text, searchable: [1..<8]).isEmpty)
    #expect(snippets("term", text, searchable: [5..<9]) == [text])
    #expect(snippets("term", text, searchable: [0..<2, 2..<4]).isEmpty)
    let near = "term: nearby"
    for context in [
      ExplainContext.around(before: near, after: near), .tail(near),
      .around(before: "", after: String(repeating: " ", count: 1498) + "term"),
      .around(before: "term" + String(repeating: " ", count: 1498), after: ""),
      .tail("term" + String(repeating: " ", count: 2998)),
    ] {
      #expect(
        PreparedSubject(
          subject: ExplainSubject(input: "term", context: context, inputRedaction: .keep)
        )
        .elsewhere.isEmpty)
    }
  }

  @Test func definitionRankingThenDocumentOrder() {
    let plain = ["term appears first", "term-other", "term appears last"]
    let definitions = [
      "**term**: first", "`term`: second", "term ： third", "term | fourth",
      "term = fifth", "term — sixth", "term - seventh", "| term unrelated | eighth |",
      "term appears then term: ninth",
    ]
    #expect(
      snippets(
        "term", ([plain[0]] + definitions + Array(plain.dropFirst())).joined(separator: "\n"))
        == definitions + plain)
  }

  @Test func rankingAndLimitsApplyAcrossBothMargins() {
    let before = "term plain before\nterm: defined before\n" + String(repeating: " ", count: 1500)
    let after =
      String(repeating: " ", count: 1500)
      + "\nterm plain after\nterm: defined after\nterm: third definition\nterm: fourth"
    let subject = PreparedSubject(
      subject: ExplainSubject(
        input: "term", context: .around(before: before, after: after), inputRedaction: .keep))
    #expect(
      subject.elsewhere == [
        "term: defined before", "term: defined after", "term: third definition",
      ])
    #expect(
      ExplainPrompt.user(subject: subject).hasSuffix(
        "\n\nBackground elsewhere in the same text:\nterm: defined before\n---\nterm: defined after\n---\nterm: third definition"
      ))
    let longLine = "term " + String(repeating: "界", count: 400)
    let tail =
      Array(repeating: longLine, count: 4).joined(separator: "\n")
      + "\n" + String(repeating: " ", count: 3000)
    let limited = PreparedSubject(
      subject: ExplainSubject(input: "term", context: .tail(tail), inputRedaction: .keep))
    #expect(limited.elsewhere.count == 3)
    #expect(limited.elsewhere.reduce(0) { $0 + $1.unicodeScalars.count } == 900)
  }

  @Test func longLinesUseFirstCountedMatchAndScalarCentredClip() {
    let line = String(repeating: "界", count: 400) + " term " + String(repeating: "末", count: 400)
    let ranges = TextMatching.snippetRanges(
      input: "term", in: line, searchableRanges: [0..<line.unicodeScalars.count])
    #expect(ranges.map(\.range) == [253..<553])
    #expect(snippets("term", " \tterm short \t ") == ["term short"])
    let repeated = "term " + String(repeating: "界", count: 400) + " term"
    let later = TextMatching.snippetRanges(
      input: "term", in: repeated, searchableRanges: [5..<repeated.unicodeScalars.count])
    #expect(later.map(\.range) == [110..<410])
    let unicode = "👨‍💻 e\u{301} term"
    #expect(
      TextMatching.snippetRanges(
        input: "term", in: unicode, searchableRanges: [7..<11]
      ).map(\.range) == [0..<11])
  }

  @Test func snippetBudgetUsesOriginalRangesBeforeRedaction() {
    let line = "term KEY=FAKE " + String(repeating: "界", count: 286)
    #expect(line.unicodeScalars.count == 300)
    let context =
      Array(repeating: line, count: 4).joined(separator: "\n")
      + "\n" + String(repeating: " ", count: 3000)
    let subject = PreparedSubject(
      subject: ExplainSubject(input: "term", context: .tail(context), inputRedaction: .keep))
    #expect(subject.elsewhere == Array(repeating: Redactor.redact(line).text, count: 3))
    #expect(subject.elsewhere.reduce(0) { $0 + $1.unicodeScalars.count } > 900)
  }

  @Test func snippetsClipWholeMarginRedactionsAtBothEdges() {
    let key = "KEY=FAKE-value"
    let rightEdge =
      "term " + String(repeating: "界", count: 289) + key
      + String(repeating: " ", count: 20)
    let leftEdge =
      key + " " + String(repeating: "界", count: 144) + " term "
      + String(repeating: "末", count: 400)
    for line in [rightEdge, leftEdge] {
      let raw = "Fictional first line.\n" + line + "\n" + String(repeating: " ", count: 3000)
      let subject = PreparedSubject(
        subject: ExplainSubject(input: "term", context: .tail(raw), inputRedaction: .keep))
      #expect(subject.elsewhere.count == 1)
      #expect(subject.elsewhere[0].contains("[REDACTED]"))
      #expect(!subject.elsewhere[0].contains("FAKE"))
      #expect(!subject.elsewhere[0].contains("value"))
      #expect(!subject.pemRedacted)
    }
  }

  @Test func cutMarginEdgeLinesAreNotSearched() {
    // A margin at the capture limit may have been cut mid-secret at its outer edge.
    let cut = "ord=fictional term: a line cut at the margin edge"
    let inner = "term: an inner line"
    let filler = String(repeating: "x", count: ExplainContext.marginBytes)
    let around = PreparedSubject(
      subject: ExplainSubject(
        input: "term",
        context: .around(
          before: cut + "\n" + inner + "\n" + filler, after: filler + "\n" + inner + "\n" + cut),
        inputRedaction: .keep))
    #expect(around.elsewhere == [inner, inner])
    let tail = PreparedSubject(
      subject: ExplainSubject(
        input: "term", context: .tail(cut + "\n" + inner + "\n" + filler), inputRedaction: .keep))
    #expect(tail.elsewhere == [inner])
    let oneLine = PreparedSubject(
      subject: ExplainSubject(
        input: "term", context: .tail(cut + " " + filler), inputRedaction: .keep))
    #expect(oneLine.elsewhere.isEmpty)
  }

  @Test func shortMarginsKeepTheirFirstAndLastLines() {
    // Under the capture limit a margin is the whole text: its first and last lines are real.
    let first = "term: the document's first line"
    let last = "| term | the document's last row |"
    let filler = String(repeating: "x", count: 1600)
    let around = PreparedSubject(
      subject: ExplainSubject(
        input: "term",
        context: .around(before: first + "\n" + filler, after: filler + "\n" + last),
        inputRedaction: .keep))
    #expect(around.elsewhere == [first, last])
    let tail = PreparedSubject(
      subject: ExplainSubject(
        input: "term", context: .tail(first + "\n" + filler + filler), inputRedaction: .keep))
    #expect(tail.elsewhere == [first])
  }

  @Test func escapedCharacterAfterTheMatchIsTheBoundary() {
    let lines = "Fictional first line.\nfoo\\_bar: escaped word\nfoo\\.: escaped stop\n"
    let subject = PreparedSubject(
      subject: ExplainSubject(
        input: "foo", context: .tail(lines + String(repeating: " ", count: 3000)),
        inputRedaction: .keep))
    #expect(subject.elsewhere == ["foo\\.: escaped stop"])
  }

  @Test func pemOverlapAndRawSelectionAreUsedForSnippets() {
    let pem = "-----BEGIN PRIVATE KEY-----\nterm fictional body\n-----END PRIVATE KEY-----"
    let subject = PreparedSubject(
      subject: ExplainSubject(
        input: "term", context: .tail(pem + "\n" + String(repeating: " ", count: 3000)),
        inputRedaction: .keep))
    #expect(subject.elsewhere == ["[REDACTED]"])
    #expect(subject.pemRedacted)
    let raw = "KEY=FAKE-value"
    let redactedInput = PreparedSubject(
      subject: ExplainSubject(
        input: raw,
        context: .tail(
          "Fictional first line.\n" + raw + "\n" + String(repeating: " ", count: 3000)),
        inputRedaction: .redact))
    #expect(redactedInput.input == "KEY=[REDACTED]")
    #expect(redactedInput.elsewhere == ["KEY=[REDACTED]"])
  }

  @Test func noContextOrNoneScopeSuppressesSnippets() {
    let context = ExplainContext.tail(
      "Fictional first line.\nterm: definition\n" + String(repeating: " ", count: 3000))
    // The same context does yield a snippet when the scope allows it.
    let allowed = PreparedSubject(
      subject: ExplainSubject(
        input: "term", context: context, inputRedaction: .keep,
        source: ExplainSource(app: "Example", scope: .focusedText)))
    #expect(allowed.elsewhere == ["term: definition"])
    for context: ExplainContext? in [nil, context] {
      let subject = PreparedSubject(
        subject: ExplainSubject(
          input: "term", context: context, inputRedaction: .keep,
          source: ExplainSource(app: "Example", scope: .none)))
      #expect(subject.elsewhere.isEmpty)
      #expect(!ExplainPrompt.user(subject: subject).contains("Background"))
    }
  }

  @Test func onlyTheCutSideOfAMarginIsSkipped() {
    // A long inner line that reaches into the send window still counts outside it.
    let tail = PreparedSubject(
      subject: ExplainSubject(
        input: "term",
        context: .tail(
          "heading\nterm: definition " + String(repeating: "x", count: ExplainContext.marginBytes)),
        inputRedaction: .keep))
    #expect(tail.elsewhere.count == 1)
    #expect(tail.elsewhere.first?.hasPrefix("term: definition ") == true)
    let long = "term: inner " + String(repeating: "y", count: ExplainContext.marginBytes)
    let around = PreparedSubject(
      subject: ExplainSubject(
        input: "term",
        context: .around(
          before: "cut edge\n" + long,
          after: String(repeating: "y", count: ExplainContext.marginBytes)
            + " term: after\ncut edge"),
        inputRedaction: .keep))
    #expect(around.elsewhere.count == 2)
    #expect(around.elsewhere.first?.hasPrefix("term: inner ") == true)
    #expect(around.elsewhere.last?.hasSuffix(" term: after") == true)
  }

  @Test func escapeBeforeTheMatchIsSkippedForTheBoundary() {
    let lines = "Fictional first line.\na\\_foo: joined\n.\\_foo: apart\n"
    let subject = PreparedSubject(
      subject: ExplainSubject(
        input: "_foo", context: .tail(lines + String(repeating: " ", count: 3000)),
        inputRedaction: .keep))
    #expect(subject.elsewhere == [".\\_foo: apart"])
  }
}
