import Foundation
import Testing

@testable import ParlanceCore

// Split so the source holds no contiguous PEM marker for the secret scanner; the text is fictional.
private let pemBegin = "-----BEGIN " + "PRIVATE KEY-----"
private let pemEnd = "-----END " + "PRIVATE KEY-----"

struct ExplainAttachmentTests {
  private let filler = String(repeating: "Fictional filler prose.\n", count: 600)

  private func prepared(
    _ input: String = "rollout gate", context: ExplainContext? = nil,
    source: ExplainSource? = nil, inputRedaction: ExplainSubject.InputRedaction = .keep
  ) -> PreparedSubject {
    PreparedSubject(
      subject: ExplainSubject(
        input: input, context: context, inputRedaction: inputRedaction, source: source))
  }

  @Test func wholeUpToTwelveThousandRedactedScalars() {
    let subject = prepared()
    let exact = String(repeating: "a", count: 12_000)
    #expect(
      subject.attaching(ExplainAttachment(name: "notes.md", text: exact)).attachment
        == .whole(name: "notes.md", text: exact))
    let over = String(repeating: "a", count: 12_001)
    #expect(
      subject.attaching(ExplainAttachment(name: "notes.md", text: over)).attachment
        == .noMatch(name: "notes.md"))
    // The limit counts the redacted text: a long secret shrinks to its placeholder.
    let secret = "sk-test-FAKE-" + String(repeating: "0", count: 20)
    let shrinking = secret + " " + String(repeating: "a", count: 11_979)
    #expect(shrinking.unicodeScalars.count > 12_000)
    #expect(
      subject.attaching(ExplainAttachment(name: "notes.md", text: shrinking)).attachment
        == .whole(name: "notes.md", text: "[REDACTED] " + String(repeating: "a", count: 11_979)))
  }

  @Test func headWhenTheInputIsNotSearchable() throws {
    let text = String(repeating: "b", count: 2_393) + " KEY=FAKE-value" + filler
    for input in ["a", "rollout\ngate", String(repeating: "x", count: 201)] {
      let attached = prepared(input).attaching(ExplainAttachment(name: "notes.md", text: text))
      guard case .head(let name, let head) = attached.attachment else {
        Issue.record("expected .head for \(input.count) characters")
        continue
      }
      #expect(name == "notes.md")
      // The secret straddles the 2,400-scalar edge; it is replaced, never cut in half.
      #expect(head == String(repeating: "b", count: 2_393) + " KEY=[REDACTED]")
      #expect(!head.contains("FAKE"))
    }
  }

  @Test func snippetsAreCappedAtEightAndTwentyFourHundredScalars() throws {
    let line = "rollout gate " + String(repeating: "fictional ", count: 40)
    let text = filler + Array(repeating: line, count: 10).joined(separator: "\n")
    let attached = prepared().attaching(ExplainAttachment(name: "notes.md", text: text))
    guard case .snippets(let name, let lines) = attached.attachment else {
      Issue.record("expected .snippets")
      return
    }
    #expect(name == "notes.md")
    #expect(lines.count == 8)
    #expect(lines.allSatisfy { $0.unicodeScalars.count == 300 })
    #expect(lines.reduce(0) { $0 + $1.unicodeScalars.count } <= 2_400)
    // Short lines stay far under the total, so only the count cap applies.
    let short = filler + Array(repeating: "rollout gate: short", count: 10).joined(separator: "\n")
    let shortAttached = prepared().attaching(ExplainAttachment(name: "notes.md", text: short))
    guard case .snippets(_, let shortLines) = shortAttached.attachment else {
      Issue.record("expected .snippets")
      return
    }
    #expect(shortLines.count == 8)
  }

  @Test func snippetsPutDefinitionsFirstAndRedactWholeLines() {
    let text =
      filler + "We changed the rollout gate today.\n" + filler
      + "| rollout gate | the fictional check, KEY=FAKE-value |\n"
    let attached = prepared().attaching(ExplainAttachment(name: "notes.md", text: text))
    #expect(
      attached.attachment
        == .snippets(
          name: "notes.md",
          lines: [
            "| rollout gate | the fictional check, KEY=[REDACTED] |",
            "We changed the rollout gate today.",
          ]))
  }

  @Test func secretCrossingASnippetEdgeIsRedacted() throws {
    let secret = "sk-test-FAKE-" + String(repeating: "0", count: 200)
    let line = secret + " rollout gate " + String(repeating: "fictional filler ", count: 30)
    let attached = prepared().attaching(ExplainAttachment(name: "notes.md", text: filler + line))
    guard case .snippets(_, let lines) = attached.attachment else {
      Issue.record("expected .snippets")
      return
    }
    let snippet = try #require(lines.first)
    #expect(snippet.hasPrefix("[REDACTED] rollout gate "))
    #expect(!snippet.contains("FAKE") && !snippet.contains("000"))
  }

  @Test func noMatchWhenTheSearchFindsNothing() {
    let attached = prepared().attaching(ExplainAttachment(name: "notes.md", text: filler))
    #expect(attached.attachment == .noMatch(name: "notes.md"))
    #expect(!attached.pemRedacted)
  }

  @Test func attachingChangesOnlyTheAttachmentAndRestoresPEMState() {
    let pem =
      pemBegin + "\nfictional body FAKE-TEST-NOT-A-KEY\n" + pemEnd
    let plain = prepared(
      context: .tail("Fictional first line.\nrollout gate: a check\n" + filler),
      source: ExplainSource(app: "Example", title: "Doc", scope: .focusedText))
    let withPEM = plain.attaching(ExplainAttachment(name: "notes.md", text: pem))
    #expect(withPEM.pemRedacted)
    #expect(withPEM.attachment == .whole(name: "notes.md", text: "[REDACTED]"))
    #expect(withPEM.input == plain.input)
    #expect(withPEM.context == plain.context)
    #expect(withPEM.elsewhere == plain.elsewhere)
    #expect(withPEM.source == plain.source)
    // Replacing or removing the attachment drops its PEM state.
    let replaced = withPEM.attaching(ExplainAttachment(name: "other.md", text: "plain text"))
    #expect(!replaced.pemRedacted)
    #expect(replaced.attachment == .whole(name: "other.md", text: "plain text"))
    #expect(withPEM.attaching(nil) == plain)
    #expect(replaced.attaching(nil) == plain)
    // The parts' own PEM state survives an attachment that has none.
    let partsPEM = prepared(context: .around(before: pem, after: ""))
    #expect(partsPEM.pemRedacted)
    #expect(partsPEM.attaching(ExplainAttachment(name: "a.md", text: "plain")).pemRedacted)
    #expect(partsPEM.attaching(nil) == partsPEM)
  }

  @Test func pemInNameOrSnippetSetsTheFlag() {
    let pem =
      pemBegin + "\nrollout gate FAKE-TEST-NOT-A-KEY\n" + pemEnd
    let snippet = prepared().attaching(ExplainAttachment(name: "notes.md", text: filler + pem))
    #expect(snippet.attachment == .snippets(name: "notes.md", lines: ["[REDACTED]"]))
    #expect(snippet.pemRedacted)
    let named = prepared().attaching(
      ExplainAttachment(name: pemBegin + "\nFAKE", text: "plain"))
    #expect(named.attachment == .whole(name: "[REDACTED]", text: "plain"))
    #expect(named.pemRedacted)
  }

  @Test func nameIsRedactedAndKeptToOneLine() throws {
    let attached = prepared().attaching(
      ExplainAttachment(
        name: "KEY=FAKE-value\nnotes\t" + String(repeating: "n", count: 250), text: "plain"))
    let name = try #require(attached.attachment?.name)
    #expect(name.hasPrefix("KEY=[REDACTED] notes "))
    #expect(!name.contains("\n") && !name.contains("\t"))
    #expect(name.unicodeScalars.count == 201)
    #expect(name.hasSuffix("…"))
  }

  @Test func promptSnapshotForEachForm() {
    let subject = prepared()
    let cases: [(PreparedAttachment, String)] = [
      (.whole(name: "notes.md", text: "whole text"), "\n\nAttached notes.md:\nwhole text"),
      (
        .snippets(name: "notes.md", lines: ["one", "two"]),
        "\n\nAttached notes.md (lines that mention the input):\none\n---\ntwo"
      ),
      (
        .head(name: "notes.md", text: "head text"),
        "\n\nAttached notes.md (beginning only, not searched):\nhead text"
      ),
      (
        .noMatch(name: "notes.md"),
        "\n\nAttached notes.md: no exact match for the input was found; it may still be described in other words."
      ),
    ]
    let base = ExplainPrompt.user(subject: subject)
    #expect(base == "Input:\nrollout gate")
    for (attachment, suffix) in cases {
      #expect(ExplainPrompt.user(subject: subject.with(attachment)) == base + suffix)
    }
  }

  @Test func attachmentFollowsElsewhereAndIsSentWithScopeNone() {
    let context = ExplainContext.tail(
      "Fictional first line.\nrollout gate: a check\n" + String(repeating: " ", count: 3000))
    let focused = prepared(
      context: context, source: ExplainSource(app: "Example", scope: .focusedText)
    ).attaching(ExplainAttachment(name: "剪贴板", text: "attached text"))
    #expect(
      ExplainPrompt.user(subject: focused).hasSuffix(
        "\n\nBackground elsewhere in the same text:\nrollout gate: a check"
          + "\n\nAttached 剪贴板:\nattached text"))
    let none = prepared(context: context, source: ExplainSource(app: "Example", scope: .none))
      .attaching(ExplainAttachment(name: "剪贴板", text: "attached text"))
    #expect(
      ExplainPrompt.user(subject: none)
        == "Source: Example\n\nInput:\nrollout gate\n\nAttached 剪贴板:\nattached text")
  }

  @Test func attachedPromptReachesQuickDeepAndFollowUp() {
    let subject = prepared().attaching(ExplainAttachment(name: "notes.md", text: "attached"))
    let user = ExplainPrompt.user(subject: subject)
    #expect(user.hasSuffix("Attached notes.md:\nattached"))
    #expect(
      ExplainPrompt.quick(subject: subject, settings: ExplainSettings()).messages.last?.content
        == user)
    #expect(
      ExplainPrompt.deep(.vocab, subject: subject, settings: ExplainSettings()).messages.last?
        .content == user)
    let followUp = ExplainPrompt.followUp(
      question: "fictional question",
      conversation: ExplainConversation(subject: subject, quickResult: "fictional answer"),
      settings: ExplainSettings())
    #expect(followUp.messages[1].content == user)
  }

  @Test func systemPromptCoversAttachmentsInTheHonestyClause() {
    let system = ExplainPrompt.quick(subject: prepared(), settings: ExplainSettings()).messages[0]
      .content
    #expect(system.contains("Context and attached documents are background only"))
    #expect(system.contains("an\nattachment nor the input defines a term"))
  }
}

extension PreparedSubject {
  /// Tests build a specific attachment form without going through the thresholds.
  fileprivate func with(_ attachment: PreparedAttachment) -> PreparedSubject {
    var copy = attaching(nil)
    copy.attachment = attachment
    return copy
  }
}
