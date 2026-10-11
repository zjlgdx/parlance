import Testing

@testable import ParlanceCore

let rewriteFixture =
  "<best> Ship it. </best><gloss>发布。</gloss><alts><alt><text>Release it.</text><note>正式</note></alt></alts>"

func parsedSections(_ text: String) -> SectionsSnapshot {
  var parser = SectionStreamParser(schema: .fix)
  parser.feed(text)
  return parser.finish()
}

struct SectionStreamParserTests {
  @Test func wellFormedAndEveryCutPoint() {
    let text = rewriteFixture + "<fixes><fix>Use an imperative.</fix></fixes>"
    let expected = parsedSections(text)
    #expect(!expected.isMalformed)
    #expect(expected.rawText == text)
    #expect(expected.sections.first?.text == "Ship it.")
    #expect(expected.sections.allSatisfy { $0.isClosed })
    for index in text.indices + [text.endIndex] {
      var parser = SectionStreamParser(schema: .fix)
      parser.feed(String(text[..<index]))
      parser.feed(String(text[index...]))
      #expect(parser.finish() == expected)
    }
    var parser = SectionStreamParser(schema: .fix)
    for character in text { parser.feed(String(character)) }
    #expect(parser.finish() == expected)
  }

  @Test func unicodeScalarCutsPreserveText() {
    let content = "\u{301}Cafe\u{301} 👩‍💻"
    let text = rewriteFixture.replacingOccurrences(of: " Ship it. ", with: content)
    let expected = parsedSections(text)
    #expect(expected.sections.first?.text == content)
    for index in text.unicodeScalars.indices {
      var parser = SectionStreamParser()
      parser.feed(String(text.unicodeScalars[..<index]))
      parser.feed(String(text.unicodeScalars[index...]))
      #expect(parser.finish() == expected)
    }
  }

  @Test func partialTagsAndSnapshots() {
    var parser = SectionStreamParser(schema: .fix)
    parser.feed("<be")
    #expect(parser.snapshot.sections.isEmpty)
    parser.feed("st>hello<")
    #expect(parser.snapshot.sections.first?.text == "hello")
    #expect(parser.snapshot.sections.first?.isClosed == false)
    #expect(parser.snapshot.rawText == "<best>hello<")
    parser.feed("/best>")
    #expect(parser.snapshot.sections.first?.isClosed == true)
    #expect(parser.finish().isMalformed)
    var tail = SectionStreamParser(schema: .fix)
    tail.feed("<best>hello<")
    #expect(tail.finish().sections.first?.text == "hello<")
  }

  @Test func nestedOpenSectionsSnapshot() {
    var parser = SectionStreamParser(schema: .fix)
    parser.feed("<alts><alt><text>a</text></alt><alt><text>b</te")
    let open = parser.snapshot
    #expect(!open.isMalformed)
    #expect(!open.isFinished)
    let alts = open.sections.first
    #expect(alts?.name == "alts")
    #expect(alts?.isClosed == false)
    #expect(alts?.children.map(\.isClosed) == [true, false])
    #expect(alts?.children.last?.children.first?.text == "b")
    #expect(alts?.children.last?.children.first?.isClosed == false)
    parser.feed("xt></alt><alt><text>c</text></alt><alt><text>d")
    #expect(parser.snapshot.sections.first?.children.count == 2)
    #expect(parser.snapshot.sections.first?.children.last?.children.first?.text == "b")
    #expect(parser.finish().isMalformed)
  }

  @Test func contextRestrictsTags() {
    let content =
      "<T>x</T><div>html</div><best x>attr</best x><text>child</text><gloss>nested</gloss>"
    let text = rewriteFixture.replacingOccurrences(of: " Ship it. ", with: content)
    #expect(parsedSections(text).sections.first?.text == content)
    #expect(!parsedSections(text).isMalformed)
    #expect(!parsedSections("<text>outside</text>preamble" + text + "epilogue").isMalformed)
  }

  @Test func structureValidation() {
    let malformed = [
      rewriteFixture.replacingOccurrences(of: "</best>", with: ""),
      rewriteFixture.replacingOccurrences(of: "</alts>", with: ""),
      rewriteFixture.replacingOccurrences(of: "<gloss>发布。</gloss>", with: ""),
      rewriteFixture + "<best>again</best>",
      rewriteFixture + "<gloss>again</gloss>",
      rewriteFixture + "<alts><alt><text>x</text><note>n</note></alt></alts>",
      rewriteFixture + "<fixes></fixes>",
      rewriteFixture + "<fixes><fix>x</fix></fixes><fixes><fix>y</fix></fixes>",
      rewriteFixture.replacingOccurrences(of: "<text>Release it.</text>", with: ""),
      rewriteFixture.replacingOccurrences(of: "<note>正式</note>", with: ""),
      "<best>x</best><gloss>g</gloss><alts></alts>",
    ]
    for text in malformed {
      let result = parsedSections(text)
      #expect(result.isMalformed)
      #expect(result.rawText == text)
    }
    #expect(!parsedSections(rewriteFixture).isMalformed)
  }

  @Test func capsAlternativesAndDropsContainerProse() {
    let text = rewriteFixture.replacingOccurrences(
      of: "</alts>",
      with:
        "prose<alt><text>Second</text><note>n</note></alt><alt><text>Third</text><note>n</note></alt></alts>"
    )
    let result = parsedSections(text)
    #expect(!result.isMalformed)
    #expect(result.sections.first { $0.name == "alts" }?.children.count == 2)
  }
}
