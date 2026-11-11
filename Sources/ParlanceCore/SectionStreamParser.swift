import Foundation

public struct SectionSchema: Sendable, Equatable {
  public struct Tag: Sendable, Equatable {
    public var name: String
    public var children: [Tag]
    public var minimum: Int
    public var maximum: Int?
    public var retainedLimit: Int?
    /// A closed leaf with only whitespace makes the whole response malformed.
    public var nonEmpty: Bool

    public init(
      _ name: String, children: [Tag] = [], minimum: Int = 1, maximum: Int? = 1,
      retainedLimit: Int? = nil, nonEmpty: Bool = false
    ) {
      self.name = name
      self.children = children
      self.minimum = minimum
      self.maximum = maximum
      self.retainedLimit = retainedLimit
      self.nonEmpty = nonEmpty
    }
  }
  public var tags: [Tag]
  public init(tags: [Tag]) { self.tags = tags }

  public static let explainQuick = SectionSchema(tags: [
    Tag("translation", nonEmpty: true), Tag("plain", nonEmpty: true),
    Tag(
      "terms",
      children: [
        Tag(
          "term",
          children: [
            Tag("word", nonEmpty: true), Tag("ipa", minimum: 0), Tag("meaning", nonEmpty: true),
            Tag("here"),
          ],
          minimum: 0, maximum: nil)
      ]),
  ])
  public static let explainCommand: SectionSchema = {
    var tags = explainQuick.tags
    tags.insert(
      Tag(
        "command",
        children: [
          Tag(
            "part",
            children: [
              Tag("code", nonEmpty: true), Tag("does", nonEmpty: true), Tag("effects", minimum: 0),
            ], maximum: nil)
        ]), at: 2)
    return SectionSchema(tags: tags)
  }()
  public static let explainDocument = SectionSchema(tags: [
    Tag("gist", nonEmpty: true),
    Tag("decisions", children: [Tag("decision", minimum: 0, maximum: nil, nonEmpty: true)]),
    Tag(
      "parts",
      children: [
        Tag(
          "part", children: [Tag("heading", nonEmpty: true), Tag("plain", nonEmpty: true)],
          maximum: nil)
      ]),
    explainQuick.tags[2],
  ])
  public static let explainVocab = SectionSchema(tags: [Tag("vocab", nonEmpty: true)])
  public static let explainDomain = SectionSchema(tags: [Tag("domain", nonEmpty: true)])

  public static let fix = SectionSchema(tags: [
    Tag("best"), Tag("gloss"),
    Tag(
      "alts",
      children: [
        Tag("alt", children: [Tag("text"), Tag("note")], maximum: nil, retainedLimit: 2)
      ]),
    Tag("fixes", children: [Tag("fix", maximum: nil)], minimum: 0),
  ])
}

public struct SectionNode: Sendable, Equatable {
  public var name: String
  public var text: String
  public var children: [SectionNode]
  public var isClosed: Bool
}

public struct SectionsSnapshot: Sendable, Equatable {
  public var sections: [SectionNode]
  public var rawText: String
  public var isFinished: Bool
  public var isMalformed: Bool
}

/// Recognises only the current container's children and the current section's closing tag.
/// An undecidable tag prefix stays buffered; unknown markup is ordinary text.
public struct SectionStreamParser: Sendable, Equatable {
  private struct Frame: Sendable, Equatable {
    var tag: SectionSchema.Tag
    var text = ""
    var children: [SectionNode] = []
    var counts: [String: Int] = [:]
    var node: SectionNode {
      SectionNode(
        name: tag.name, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
        children: children, isClosed: false)
    }
  }
  private let schema: SectionSchema
  private var stack: [Frame] = []
  private var roots: [SectionNode] = []
  private var counts: [String: Int] = [:]
  private var raw = ""
  private var pending = ""
  private var ended = false
  private var invalid = false

  public init(schema: SectionSchema = .fix) { self.schema = schema }

  public var snapshot: SectionsSnapshot {
    var nodes = roots
    var open: SectionNode?
    for frame in stack.reversed() {
      var node = frame.node
      if let child = open {
        let rule = frame.tag.children.first { $0.name == child.name }
        if rule?.retainedLimit == nil
          || node.children.filter({ $0.name == child.name }).count < rule!.retainedLimit!
        {
          node.children.append(child)
        }
      }
      open = node
    }
    if let open { nodes.append(open) }
    return SectionsSnapshot(
      sections: nodes, rawText: raw, isFinished: ended, isMalformed: ended && invalid)
  }

  public mutating func feed(_ chunk: String) {
    guard !ended else { return }
    raw += chunk
    pending += chunk
    consume(final: false)
  }

  @discardableResult
  public mutating func finish() -> SectionsSnapshot {
    guard !ended else { return snapshot }
    consume(final: true)
    invalid = invalid || !stack.isEmpty || !validCounts(counts, rules: schema.tags)
    ended = true
    return snapshot
  }

  private func validCounts(_ counts: [String: Int], rules: [SectionSchema.Tag]) -> Bool {
    rules.allSatisfy { rule in
      let count = counts[rule.name, default: 0]
      return count >= rule.minimum && (rule.maximum == nil || count <= rule.maximum!)
    }
  }

  private mutating func consume(final: Bool) {
    while !pending.isEmpty {
      let rules = stack.last?.tag.children ?? schema.tags
      let closing = stack.last.map { "</\($0.tag.name)>" }
      if let closing, pending.unicodeScalars.starts(with: closing.unicodeScalars) {
        pending.unicodeScalars.removeFirst(closing.unicodeScalars.count)
        closeSection()
        continue
      }
      if let rule = rules.first(where: {
        pending.unicodeScalars.starts(with: "<\($0.name)>".unicodeScalars)
      }) {
        pending.unicodeScalars.removeFirst(rule.name.unicodeScalars.count + 2)
        if stack.isEmpty {
          counts[rule.name, default: 0] += 1
        } else {
          stack[stack.count - 1].counts[rule.name, default: 0] += 1
        }
        stack.append(Frame(tag: rule))
        continue
      }
      let tokens = rules.map { "<\($0.name)>" } + (closing.map { [$0] } ?? [])
      if !final
        && tokens.contains(where: { $0.unicodeScalars.starts(with: pending.unicodeScalars) })
      {
        return
      }
      let scalar = pending.unicodeScalars.removeFirst()
      if let frame = stack.last, frame.tag.children.isEmpty {
        stack[stack.count - 1].text.unicodeScalars.append(scalar)
      }
    }
  }

  private mutating func closeSection() {
    let frame = stack.removeLast()
    invalid = invalid || !validCounts(frame.counts, rules: frame.tag.children)
    var node = frame.node
    invalid = invalid || (frame.tag.nonEmpty && node.text.isEmpty)
    node.isClosed = true
    if stack.isEmpty {
      roots.append(node)
    } else {
      let count = stack[stack.count - 1].counts[frame.tag.name, default: 0]
      if frame.tag.retainedLimit == nil || count <= frame.tag.retainedLimit! {
        stack[stack.count - 1].children.append(node)
      }
    }
  }
}
