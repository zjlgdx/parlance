import Testing

@testable import ParlanceCore

struct ExplainParserTests {
  @Test func everyTagAcrossEverySplit() {
    for (schema, text, names) in [
      (SectionSchema.explainQuick, explainReply, ["translation", "plain", "terms"]),
      (.explainVocab, "<vocab>usage <T> --flag /path</vocab>", ["vocab"]),
      (.explainDomain, "<domain>background <div></domain>", ["domain"]),
    ] {
      for split in 0...text.count {
        var parser = SectionStreamParser(schema: schema)
        parser.feed(String(text.prefix(split)))
        parser.feed(String(text.dropFirst(split)))
        let result = parser.finish()
        #expect(!result.isMalformed)
        #expect(result.sections.map(\.name) == names)
        #expect(result.rawText == text)
      }
    }
  }

  @Test func quickRequiredTagsAndTermChildren() {
    let prefix = "<translation>t</translation><plain>p</plain>"
    for terms in [
      "<terms></terms>",
      "<terms><term><word>w</word><meaning>m</meaning><here>h</here></term></terms>",
      "<terms><term><word>w</word><ipa>i</ipa><meaning>m</meaning><here>h</here></term><term><word>x</word><meaning>m</meaning><here>h</here></term></terms>",
    ] {
      var parser = SectionStreamParser(schema: .explainQuick)
      parser.feed(prefix + terms)
      #expect(!parser.finish().isMalformed)
    }
    for text in [
      prefix, "<plain>p</plain><terms></terms>", "<translation>t</translation><terms></terms>",
      prefix + "<terms>", prefix + "<terms></terms><terms></terms>",
      prefix + "<translation>again</translation><terms></terms>",
      prefix + "<plain>again</plain><terms></terms>",
      prefix + "<terms><term><meaning>m</meaning><here>h</here></term></terms>",
      prefix + "<terms><term><word>w</word><here>h</here></term></terms>",
      prefix + "<terms><term><word>w</word><meaning>m</meaning></term></terms>",
      prefix
        + "<terms><term><word>w</word><word>x</word><meaning>m</meaning><here>h</here></term></terms>",
      prefix
        + "<terms><term><word>w</word><ipa>i</ipa><ipa>j</ipa><meaning>m</meaning><here>h</here></term></terms>",
    ] {
      var parser = SectionStreamParser(schema: .explainQuick)
      parser.feed(text)
      #expect(parser.finish().isMalformed, "\(text)")
    }
  }

  @Test func childTagsOutsideParentStayText() {
    var parser = SectionStreamParser(schema: .explainQuick)
    let text = "<word>w</word><term>x</term><ipa>i</ipa><meaning>m</meaning><here>h</here><T>"
    parser.feed(
      "preamble <translation>\(text)</translation><plain>p</plain><terms></terms> epilogue")
    let result = parser.finish()
    #expect(!result.isMalformed)
    #expect(result.sections.first?.text == text)
  }

  @Test func deepOnlyRequiresItsOwnTag() {
    for (schema, tag) in [(SectionSchema.explainVocab, "vocab"), (.explainDomain, "domain")] {
      for (text, malformed) in [
        ("<\(tag)>only</\(tag)>", false),
        ("<\(tag)>unclosed", true),
        ("<\(tag)>first</\(tag)><\(tag)>second</\(tag)>", true),
        ("<translation>t</translation><plain>p</plain><terms></terms>", true),
      ] {
        var parser = SectionStreamParser(schema: schema)
        parser.feed(text)
        #expect(parser.finish().isMalformed == malformed)
      }
    }
  }
}
