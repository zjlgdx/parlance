import Testing

@testable import ParlanceCore

struct SSEParserTests {
  @Test(arguments: ["\n", "\r\n", "\r"])
  func everyBoundary(newline: String) {
    let bytes = Array(
      (": heartbeat" + newline + "event: answer" + newline + "id: 7" + newline + "retry: 42"
        + newline + "data: hé" + newline + "data: 世界" + newline + newline).utf8)
    let expected: [SSEParser.Item] = [
      .comment, .event(SSEEvent(event: "answer", data: "hé\n世界", id: "7", retry: 42)),
    ]
    for split in 0...bytes.count {
      var parser = SSEParser()
      let actual =
        parser.feed(bytes.prefix(split)) + parser.feed(bytes.dropFirst(split)) + parser.finish()
      #expect(actual == expected)
    }
    var parser = SSEParser()
    #expect(bytes.flatMap { parser.feed([$0]) } + parser.finish() == expected)
  }
  @Test func trailingAndEmptyData() {
    var parser = SSEParser()
    #expect(parser.feed(Array("data:\n\ndata: tail\n".utf8)) == [.event(SSEEvent(data: ""))])
    #expect(parser.finish() == [.event(SSEEvent(data: "tail"))])
    #expect(parser.finish().isEmpty)
  }
  @Test func unterminatedLineIsDropped() {
    var parser = SSEParser()
    #expect(parser.feed(Array("data: first\ndata: cut".utf8)).isEmpty)
    #expect(parser.finish().isEmpty)
    #expect(parser.feed(Array("data: next\n\n".utf8)) == [.event(SSEEvent(data: "next"))])
  }
}
extension SSEParserTests {
  @Test func fieldsAndByteOrderMark() {
    var parser = SSEParser()
    let bytes = Array(
      "\u{feff}:hi\r\nunknown: ignored\nevent: ignored\n\nid: kept\nretry: -2\ndata:  leading space\n\nid: bad\0value\ndata: next\n\n"
        .utf8)
    let actual = bytes.flatMap { parser.feed([$0]) } + parser.finish()
    #expect(
      actual == [
        .comment, .event(SSEEvent(data: " leading space", id: "kept")),
        .event(SSEEvent(data: "next", id: "kept")),
      ])
  }
}
