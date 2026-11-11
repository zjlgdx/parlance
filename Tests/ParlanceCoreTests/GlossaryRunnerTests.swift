import Foundation
import Testing
import os

@testable import ParlanceCore

struct GlossaryRunnerTests {
  @Test func inputOnlyAndSavedPreparation() async throws {
    let directory = glossaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GlossaryStore(directory: directory)
    let entry = glossaryEntry(note: "我的译法")
    try store.add(entry)
    try store.add(glossaryEntry("backpressure", "背压"))
    let provider = MockProvider(scripts: [[.event(.text(explainReply)), .event(.finished(.stop))]])
    var result: ExplainQuick?
    for try await update in ExplainRunner.quick(
      subject: ExplainSubject(
        input: "rate limits", context: .tail("backpressure"), inputRedaction: .redact),
      settings: ExplainSettings(), provider: provider, cancellation: LLMCancellation(),
      glossaryStore: store)
    {
      if case .prepared(let prepared) = update {
        #expect(prepared.glossary == [entry])
      }
      if case .completed(let quick) = update { result = quick }
    }
    let quick = try #require(result)
    let request = try #require(provider.recordedRequests.first)
    #expect(
      request.messages.last?.content
        == "Input:\nrate limits\n\nBackground context:\nbackpressure\n\nGlossary: the user's own translations. Use them for these terms where they carry this meaning.\n- rate limit = 速率限制 (我的译法)\nUse these translations in <translation> and <plain>. Do not produce <term> cards for these terms."
    )
    let ordinary = PreparedSubject(
      subject: ExplainSubject(input: "rate limits", inputRedaction: .redact))
    #expect(
      request.messages[0]
        == ExplainPrompt.quick(subject: ordinary, settings: ExplainSettings()).messages[0])
    try store.add(glossaryEntry("rate limit", "已经改过"))
    let reuse = MockProvider(scripts: [[.error(.auth(status: 401))]])
    for try await update in ExplainRunner.quick(
      prepared: quick.subject, settings: ExplainSettings(), provider: reuse,
      cancellation: LLMCancellation(), glossaryStore: store)
    {
      if case .prepared(let prepared) = update { #expect(prepared == quick.subject) }
    }
    #expect(reuse.recordedRequests.first == request)
    for section in ExplainDeepSection.allCases {
      let deeper = MockProvider(scripts: [[.error(.auth(status: 401))]])
      for try await _ in ExplainRunner.deep(
        section, from: quick, settings: ExplainSettings(), provider: deeper,
        cancellation: LLMCancellation())
      {}
      #expect(
        deeper.recordedRequests.first?.messages.last?.content == request.messages.last?.content)
    }
    let follow = MockProvider(scripts: [[.error(.auth(status: 401))]])
    for try await _ in ExplainRunner.followUp(
      question: "why?",
      conversation: ExplainConversation(
        subject: quick.subject, quickResult: quick.snapshot.rawText),
      settings: ExplainSettings(), provider: follow, cancellation: LLMCancellation())
    {}
    #expect(follow.recordedRequests.first?.messages[1] == request.messages[1])
    #expect(quick.subject.forDocument().glossary == [entry])
    let attached = ordinary.attaching(ExplainAttachment(name: "backpressure", text: "backpressure"))
    #expect(
      attached.withGlossary(store, settings: ExplainSettings()).glossary.map(\.target) == [
        "rate limit"
      ])
    var unsafe = ordinary
    unsafe.glossary = [glossaryEntry("api_key=\"fake-test-secret\"", "safe")]
    #expect(!ExplainPrompt.user(subject: unsafe).contains("fake-test-secret"))
  }

  @Test(arguments: [false, true]) func filtersStreamingAndFinalTerms(document: Bool) async throws {
    let directory = glossaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GlossaryStore(directory: directory)
    try store.add(glossaryEntry())
    try store.add(glossaryEntry("split-flap", "翻页显示"))
    let terms =
      "<terms>"
      + ["rate limits", "split flap", "速率限制", "other", "unrelated rate limit"].map {
        "<term><word>\($0)</word><meaning>释义</meaning><here>这里</here></term>"
      }.joined() + "</terms>"
    let prefix =
      document
      ? "<gist>概要</gist><decisions></decisions><parts><part><heading>标题</heading><plain>正文</plain></part></parts>"
      : "<translation>译文</translation><plain>说明</plain>"
    let provider = MockProvider(scripts: [
      [.event(.text(prefix)), .event(.text(terms)), .event(.finished(.stop))]
    ])
    let subject = ExplainSubject(input: "rate limits and split flap", inputRedaction: .redact)
    func check(_ snapshot: SectionsSnapshot) {
      guard snapshot.sections.contains(where: { $0.name == "terms" }) else { return }
      #expect(ExplainSections.terms(in: snapshot).map(\.word) == ["other", "unrelated rate limit"])
    }
    if document {
      for try await update in ExplainRunner.document(
        subject: subject, settings: ExplainSettings(), provider: provider,
        cancellation: LLMCancellation(), glossaryStore: store)
      {
        if case .sections(let snapshot) = update { check(snapshot) }
        if case .completed(let result) = update {
          check(result.snapshot)
          #expect(result.sections?.terms.map(\.word) == ["other", "unrelated rate limit"])
          #expect(result.eligibility == .eligible)
        }
      }
    } else {
      for try await update in ExplainRunner.quick(
        subject: subject, settings: ExplainSettings(), provider: provider,
        cancellation: LLMCancellation(), glossaryStore: store)
      {
        if case .sections(let snapshot) = update { check(snapshot) }
        if case .completed(let result) = update {
          check(result.snapshot)
          #expect(result.eligibility == .eligible)
        }
      }
    }
  }

  @Test func rewritePreparationFailureAndStrictReuse() async throws {
    let directory = glossaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GlossaryStore(directory: directory)
    try store.add(glossaryEntry())
    try store.add(glossaryEntry("hidden", "隐藏"))
    let bad =
      "<best>Rate limits.</best><gloss>说明</gloss><alts><alt><text>Rate limits.</text><note>说明</note></alt></alts>"
    let provider = MockProvider(scripts: [
      [.event(.text(bad)), .event(.finished(.stop))], [.error(.auth(status: 401))],
    ])
    var updates: [RewriteUpdate] = []
    for try await update in RewriteRunner.run(
      input: "rate limits `hidden`", settings: RewriteSettings(), provider: provider,
      cancellation: LLMCancellation(), glossaryStore: store)
    {
      updates.append(update)
      if case .prepared = update { try store.add(glossaryEntry("rate limit", "后来改过")) }
    }
    guard case .prepared(let prepared) = updates.first, case .completed(let result) = updates.last
    else {
      Issue.record("Expected preparation before completion")
      return
    }
    #expect(prepared.glossary == [glossaryEntry()])
    #expect(prepared.message.hasPrefix("rate limits ⟦0⟧\n\nGlossary:"))
    #expect(prepared.message.contains("Keep terms already in the target language"))
    #expect(result.glossary == prepared.glossary)
    #expect(result.strictRetried)
    #expect(provider.recordedRequests.count == 2)
    #expect(provider.recordedRequests.allSatisfy { $0.messages.last?.content == prepared.message })
    let protection = TermProtection.protect("rate limits `hidden`")
    #expect(
      provider.recordedRequests[0].messages[0].content
        == RewritePrompt.system(settings: RewriteSettings(), protection: protection))
    let failed = MockProvider(scripts: [[.error(.auth(status: 401))]])
    var failureUpdates: [RewriteUpdate] = []
    for try await update in RewriteRunner.run(
      input: "rate limit", settings: RewriteSettings(), provider: failed,
      cancellation: LLMCancellation(), glossaryStore: store)
    { failureUpdates.append(update) }
    guard case .prepared = failureUpdates.first else {
      Issue.record("Preparation missing on failure")
      return
    }
  }

  @Test func delimiterSelectionAndDisabledStorage() async throws {
    var entry = glossaryEntry()
    entry.note = "⟦"
    #expect(TermProtection.protect("`code`", glossary: [entry]).text == "⟪0⟫")
    entry.native = "⟪"
    entry.target = "〖"
    #expect(TermProtection.protect("`code`", glossary: [entry]).delimiters == nil)
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let files = GlossaryStore.Files(
      read: { _, _ in
        reads.withLock { $0 += 1 }
        throw CocoaError(.fileReadUnknown)
      },
      locked: { _, _ in Issue.record("Unexpected write") },
      replace: { _, _ in Issue.record("Unexpected write") })
    let store = GlossaryStore(directory: glossaryDirectory(), files: files)
    let provider = MockProvider(scripts: [[.error(.auth(status: 401))]])
    for try await _ in ExplainRunner.quick(
      subject: ExplainSubject(input: "rate limit", inputRedaction: .redact),
      settings: ExplainSettings(glossaryEnabled: false), provider: provider,
      cancellation: LLMCancellation(), glossaryStore: store)
    {}
    for try await _ in RewriteRunner.run(
      input: "rate limit", settings: RewriteSettings(glossaryEnabled: false), provider: provider,
      cancellation: LLMCancellation(), glossaryStore: store)
    {}
    #expect(reads.withLock { $0 } == 0)
    for try await update in RewriteRunner.run(
      input: "rate limit", settings: RewriteSettings(), provider: provider,
      cancellation: LLMCancellation(), glossaryStore: store)
    {
      if case .prepared(let prepared) = update { #expect(prepared.warnings.count == 1) }
    }
    #expect(reads.withLock { $0 } == 1)
    var settings = ParlanceSettings()
    #expect(settings.glossaryEnabled)
    settings.glossaryEnabled = false
    #expect(
      try JSONDecoder().decode(ParlanceSettings.self, from: JSONEncoder().encode(settings))
        .glossaryEnabled == false)
    var old = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
    old.removeValue(forKey: "glossaryEnabled")
    #expect(
      try JSONDecoder().decode(
        ParlanceSettings.self, from: JSONSerialization.data(withJSONObject: old)
      ).glossaryEnabled)
  }
}
