import Foundation
import Testing

@testable import ParlanceCore

let explainReply = """
  <translation>译文</translation><plain>简单说</plain><terms><term><word>word</word>
  <ipa>/wɜːd/</ipa><meaning>词</meaning><here>此处含义</here></term></terms>
  """

private func explainSteps(_ text: String = explainReply) -> [MockProvider.Step] {
  [.event(.text(text)), .event(.finished(.stop))]
}

func quickResult(
  subject: ExplainSubject = ExplainSubject(input: "subject", inputRedaction: .redact),
  provider: any LLMProvider = MockProvider(scripts: [explainSteps()])
) async throws -> ExplainQuick {
  try await bounded {
    for try await update in ExplainRunner.quick(
      subject: subject, settings: ExplainSettings(), provider: provider,
      cancellation: LLMCancellation())
    {
      if case .completed(let result) = update { return result }
    }
    throw TestDeadline()
  }
}

struct ExplainWindowTests {
  struct Fixture: Decodable {
    let name: String
    let input: String
    let expectedInput: String
    let kind: String?
    let before: String?
    let after: String?
    let expectedBefore: String?
    let expectedAfter: String?
    let pem: Bool

    var context: ExplainContext? {
      if kind == "around" { return .around(before: before!, after: after!) }
      if kind == "tail" { return .tail(before!) }
      return nil
    }
    var expectedContext: ExplainContext? {
      if kind == "around" { return .around(before: expectedBefore!, after: expectedAfter!) }
      if kind == "tail" { return .tail(expectedBefore!) }
      return nil
    }
  }

  static func fixtures() throws -> [Fixture] {
    struct RedactorFixture: Decodable {
      let name: String
      let input: String
      let expected: String
      let pem: Bool
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/redaction")
    func existing(_ group: String) throws -> [RedactorFixture] {
      try JSONDecoder().decode(
        [RedactorFixture].self, from: Data(contentsOf: root.appendingPathComponent("\(group).json"))
      )
    }
    var fixtures = try JSONDecoder().decode(
      [Fixture].self, from: Data(contentsOf: root.appendingPathComponent("explain.json")))
    let pem = try existing("pem")
    let ordinary = try existing("ordinary").filter { $0.input == $0.expected }
    for item in pem + ordinary {
      fixtures.append(
        Fixture(
          name: "input " + item.name, input: item.input, expectedInput: item.expected, kind: nil,
          before: nil, after: nil, expectedBefore: nil, expectedAfter: nil, pem: item.pem))
      fixtures.append(
        Fixture(
          name: "around " + item.name, input: "subject", expectedInput: "subject", kind: "around",
          before: item.input, after: item.input, expectedBefore: item.expected,
          expectedAfter: item.expected, pem: item.pem))
    }
    let random = try #require(existing("random").first)
    fixtures.append(
      Fixture(
        name: "non PEM input", input: random.input, expectedInput: random.expected, kind: nil,
        before: nil, after: nil, expectedBefore: nil, expectedAfter: nil, pem: false))
    return fixtures
  }

  @Test(arguments: [ExplainSubject.InputRedaction.redact, .keep])
  func originalWindowsAndPEMMatrix(_ policy: ExplainSubject.InputRedaction) async throws {
    for fixture in try Self.fixtures() {
      let provider = MockProvider(scripts: [explainSteps()])
      let result = try await quickResult(
        subject: ExplainSubject(
          input: fixture.input, context: fixture.context, inputRedaction: policy),
        provider: provider)
      #expect(
        result.subject.input == (policy == .keep ? fixture.input : fixture.expectedInput),
        "\(fixture.name)")
      #expect(result.subject.context == fixture.expectedContext, "\(fixture.name)")
      #expect(
        result.subject.pemRedacted == (fixture.pem && (fixture.kind != nil || policy == .redact)),
        "\(fixture.name)")
      #expect(result.eligibility == .eligible)
      #expect(provider.recordedRequests.count == 1)
      var sent = "Input:\n\(policy == .keep ? fixture.input : fixture.expectedInput)"
      if fixture.kind == "around" {
        sent += "\n\nBackground before input:\n\(fixture.expectedBefore!)"
        sent += "\n\nBackground after input:\n\(fixture.expectedAfter!)"
      } else if fixture.kind == "tail" {
        sent += "\n\nBackground context:\n\(fixture.expectedBefore!)"
      }
      #expect(provider.recordedRequests[0].messages.last == LLMMessage(role: .user, content: sent))
    }
  }

  @Test func scalarWindowsAndOrdinaryOutput() async throws {
    let listing = (1...4).map { "/workspace/services/payments/production/region\($0)" }.joined(
      separator: "\n")
    let path = "/" + String(repeating: "directory/", count: 24) + "file.swift"
    let classes = (1...4).map { "PaymentProductionRegion\($0)TransactionCoordinator" }.joined(
      separator: "\n")
    for text in [listing, path, classes] {
      let result = try await quickResult(
        subject: ExplainSubject(
          input: text, context: .around(before: text, after: text), inputRedaction: .redact))
      #expect(result.subject.input == text)
      #expect(result.subject.context == .around(before: text, after: text))
      #expect(!result.subject.pemRedacted)
    }
    let text = String(repeating: "😀e\u{301}", count: 1100)
    let result = try await quickResult(
      subject: ExplainSubject(
        input: text, context: .around(before: text, after: text), inputRedaction: .redact))
    #expect(
      result.subject.context
        == .around(
          before: String(String.UnicodeScalarView(text.unicodeScalars.suffix(1500))),
          after: String(String.UnicodeScalarView(text.unicodeScalars.prefix(1500)))))
    let tail = try await quickResult(
      subject: ExplainSubject(input: "", context: .tail(text), inputRedaction: .keep))
    #expect(
      tail.subject.context
        == .tail(String(String.UnicodeScalarView(text.unicodeScalars.suffix(3000)))))
  }
}

struct ExplainRunnerTests {
  @Test func preparedBeforeHangingProvider() async throws {
    let token = LLMCancellation()
    defer { token.cancel() }
    let provider = MockProvider(scripts: [[.hang]])
    let first = try await bounded {
      var iterator = ExplainRunner.quick(
        subject: ExplainSubject(input: "subject", inputRedaction: .redact),
        settings: ExplainSettings(), provider: provider, cancellation: token
      ).makeAsyncIterator()
      return try await iterator.next()
    }
    guard case .prepared(let subject) = first else {
      Issue.record("The first update must be prepared without waiting for a provider event")
      return
    }
    #expect(subject.input == "subject")
  }

  @Test func updatesUsageAndFailure() async throws {
    let usage = LLMUsage(promptTokens: 2, completionTokens: 3)
    let provider = MockProvider(scripts: [
      [
        .event(.retrying(after: .seconds(1), cause: .rateLimit)),
        .event(.text("<translation>译")),
        .event(.text(String(explainReply.dropFirst("<translation>译".count)))),
        .event(.usage(usage)), .event(.finished(.stop)),
      ]
    ])
    let updates = try await bounded {
      var updates: [ExplainUpdate<ExplainQuick>] = []
      for try await update in ExplainRunner.quick(
        subject: ExplainSubject(input: "subject", inputRedaction: .keep),
        settings: ExplainSettings(),
        provider: provider, cancellation: LLMCancellation())
      { updates.append(update) }
      return updates
    }
    #expect(updates.count == 5)
    guard case .prepared = updates[0], case .sections(let snapshot) = updates[2],
      case .completed(let result) = updates.last
    else {
      Issue.record("Missing prepared, streaming or completed update")
      return
    }
    #expect(updates[1] == .retrying(after: .seconds(1), cause: .rateLimit))
    #expect(!snapshot.isFinished)
    #expect(snapshot.sections.first?.text == "译")
    #expect(result.eligibility == .eligible)
    #expect(result.usage == usage)
    #expect(result.sections?.translation == "译文")
    #expect(result.sections?.plain == "简单说")
    #expect(
      result.sections?.terms == [
        ExplainSections.Term(word: "word", ipa: "/wɜːd/", meaning: "词", here: "此处含义")
      ])
    #expect(result.snapshot.rawText == explainReply)
    #expect(result.snapshot.sections.map(\.name) == ["translation", "plain", "terms"])
    for (reason, expected) in [
      (LLMFinishReason.length, IncompleteReason.length), (.contentFilter, .contentFilter),
      (.other, .other),
    ] {
      let result = try await quickResult(
        provider: MockProvider(scripts: [
          [.event(.text(explainReply)), .event(.finished(reason))]
        ]))
      #expect(result.eligibility == .incomplete(expected))
      #expect(result.sections == nil)
    }
    let malformedProvider = MockProvider(scripts: [explainSteps("<translation>only</translation>")])
    #expect(try await quickResult(provider: malformedProvider).eligibility == .malformed)
    #expect(malformedProvider.recordedRequests.count == 1)
    #expect(
      try await quickResult(provider: FinishingProvider(events: [])).eligibility
        == .incomplete(.error(.emptyResponse)))
    #expect(
      try await quickResult(provider: FinishingProvider(events: [.text(explainReply)])).eligibility
        == .incomplete(.error(.transport)))
    #expect(
      try await quickResult(provider: MockProvider(scripts: [[.error(.auth(status: 401))]]))
        .eligibility == .incomplete(.error(.auth(status: 401))))
  }

  @Test func cancellationAndConsumerTermination() async throws {
    let token = LLMCancellation()
    defer { token.cancel() }
    let result = try await bounded {
      for try await update in ExplainRunner.quick(
        subject: ExplainSubject(input: "subject", inputRedaction: .keep),
        settings: ExplainSettings(),
        provider: MockProvider(scripts: [[.event(.text("<translation>partial")), .hang]]),
        cancellation: token)
      {
        if case .sections = update { token.cancel() }
        if case .completed(let result) = update { return result }
      }
      throw TestDeadline()
    }
    #expect(result.eligibility == .incomplete(.error(.aborted)))

    let consumerToken = LLMCancellation()
    defer { consumerToken.cancel() }
    let (ready, signal) = AsyncStream<Void>.makeStream()
    let consumer = Task {
      for try await update in ExplainRunner.quick(
        subject: ExplainSubject(input: "subject", inputRedaction: .keep),
        settings: ExplainSettings(),
        provider: MockProvider(scripts: [[.hang]]), cancellation: consumerToken)
      { if case .prepared = update { signal.yield() } }
    }
    defer { consumer.cancel() }
    try await bounded { for await _ in ready { return } }
    consumer.cancel()
    try await bounded { _ = await consumer.result }
    #expect(consumerToken.isCancelled)
  }

  @Test(arguments: ExplainDeepSection.allCases)
  func deepReusesSubjectAndOnlyRequestsItsTag(_ section: ExplainDeepSection) async throws {
    let fixture = try #require(ExplainWindowTests.fixtures().first { $0.name == "split block" })
    let quick = try await quickResult(
      subject: ExplainSubject(
        input: fixture.input, context: fixture.context, inputRedaction: .redact))
    let provider = MockProvider(scripts: [
      explainSteps("<\(section.rawValue)>deeper</\(section.rawValue)>")
    ])
    let result = try await bounded {
      for try await update in ExplainRunner.deep(
        section, from: quick, settings: ExplainSettings(), provider: provider,
        cancellation: LLMCancellation())
      {
        if case .prepared = update { Issue.record("Deep must reuse preparation") }
        if case .completed(let result) = update { return result }
      }
      throw TestDeadline()
    }
    #expect(result.eligibility == .eligible)
    #expect(result.subject == quick.subject)
    #expect(result.snapshot.sections.map(\.name) == [section.rawValue])
    #expect(provider.recordedRequests.count == 1)
    let request = try #require(provider.recordedRequests.first)
    #expect(request.messages.last?.content == ExplainPrompt.user(subject: quick.subject))
    #expect(request.messages.first?.content.contains("<\(section.rawValue)>") == true)
    for tag in ["translation", "plain", "terms", section == .vocab ? "domain" : "vocab"] {
      #expect(request.messages.first?.content.contains("<\(tag)>") == false)
    }
    for eligibility in [
      Eligibility.malformed, .incomplete(.length), .incomplete(.error(.auth(status: 401))),
      .placeholdersChanged, .placeholdersUnavailable,
    ] {
      let invalid = ExplainQuick(
        snapshot: quick.snapshot, eligibility: eligibility, subject: quick.subject, usage: nil)
      do {
        for try await _ in ExplainRunner.deep(
          section, from: invalid, settings: ExplainSettings(), provider: provider,
          cancellation: LLMCancellation())
        {}
        Issue.record("Ineligible quick must be rejected")
      } catch { #expect(error as? ExplainError == .ineligibleQuick) }
    }
    #expect(provider.recordedRequests.count == 1)
  }

  @Test func followUpKeepsHistoryAndPlainText() async throws {
    let quick = try await quickResult()
    let fake = try #require(ExplainWindowTests.fixtures().first { $0.name == "non PEM input" })
      .input
    let rounds = (0..<12).map {
      ExplainConversation.Round(question: "question \($0)", answer: "answer \($0) \(fake)")
    }
    let conversation = ExplainConversation(
      subject: quick.subject, quickResult: quick.snapshot.rawText, rounds: rounds)
    let provider = MockProvider(scripts: [explainSteps("Plain <T> answer")])
    let result = try await bounded {
      for try await update in ExplainRunner.followUp(
        question: fake, conversation: conversation, settings: ExplainSettings(), provider: provider,
        cancellation: LLMCancellation())
      {
        if case .completed(let result) = update { return result }
      }
      throw TestDeadline()
    }
    #expect(result.text == "Plain <T> answer")
    #expect(result.eligibility == .eligible)
    #expect(conversation.rounds == rounds)
    let messages = try #require(provider.recordedRequests.first).messages
    #expect(messages.count == 24)
    #expect(
      messages[1] == LLMMessage(role: .user, content: ExplainPrompt.user(subject: quick.subject)))
    #expect(messages[2] == LLMMessage(role: .assistant, content: quick.snapshot.rawText))
    for (index, round) in rounds.suffix(10).enumerated() {
      #expect(messages[3 + index * 2] == LLMMessage(role: .user, content: round.question))
      #expect(messages[4 + index * 2] == LLMMessage(role: .assistant, content: round.answer))
    }
    #expect(messages.last == LLMMessage(role: .user, content: fake))
    for (events, expected) in [
      ([LLMEvent.text("partial"), .finished(.length)], Eligibility.incomplete(.length)),
      ([.text("partial"), .finished(.contentFilter)], .incomplete(.contentFilter)),
      ([.text("partial"), .finished(.other)], .incomplete(.other)),
      ([.text("partial")], .incomplete(.error(.transport))),
      ([], .incomplete(.error(.emptyResponse))),
    ] {
      let eligibility = try await bounded {
        for try await update in ExplainRunner.followUp(
          question: "question", conversation: conversation, settings: ExplainSettings(),
          provider: FinishingProvider(events: events), cancellation: LLMCancellation())
        { if case .completed(let result) = update { return result.eligibility } }
        throw TestDeadline()
      }
      #expect(eligibility == expected)
    }
  }

  @Test func promptsDescribeDirectionAndContent() async throws {
    let subject = try await quickResult().subject
    let settings = ExplainSettings(targetLanguage: "fr", nativeLanguage: "ja")
    let quick = ExplainPrompt.quick(subject: subject, settings: settings).messages[0].content
    for fragment in [
      "Target language: fr.", "Native language: ja.", "Judge the input's language",
      "target-language input", "native-language input",
      "code", "paths", "--flags", "parameters", "identifiers", "[REDACTED]", "background only",
      "<translation>", "<plain>", "one simple sentence", "<terms>", "<word>", "<ipa>", "<meaning>",
      "<here>",
    ] {
      #expect(quick.contains(fragment), "missing \(fragment)")
    }
    let vocab = ExplainPrompt.deep(.vocab, subject: subject, settings: settings).messages[0].content
    #expect(vocab.contains("synonyms, collocations and usage"))
    let domain = ExplainPrompt.deep(.domain, subject: subject, settings: settings).messages[0]
      .content
    #expect(domain.contains("background knowledge and related concepts"))
  }
}
