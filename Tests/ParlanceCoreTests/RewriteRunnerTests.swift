import Testing
import os

@testable import ParlanceCore

/// Yields its events and then ends the stream normally, without `.finished` and without an error.
struct FinishingProvider: LLMProvider {
  var events: [LLMEvent]
  func stream(_ request: LLMRequest, cancellation: LLMCancellation) -> AsyncThrowingStream<
    LLMEvent, any Error
  > {
    AsyncThrowingStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }
}

func runRewrite(_ steps: [MockProvider.Step]) async throws -> RewriteResult {
  try await runRewrite(MockProvider(scripts: [steps]))
}

func runRewrite(_ provider: any LLMProvider) async throws -> RewriteResult {
  return try await bounded {
    for try await update in RewriteRunner.run(
      input: "input", settings: RewriteSettings(), provider: provider,
      cancellation: LLMCancellation())
    {
      if case .completed(let result) = update { return result }
    }
    throw TestDeadline()
  }
}

struct RewriteRunnerTests {
  @Test(arguments: ["帮我看看", "please fix the bug"])
  func fixesFollowInputCase(_ input: String) async throws {
    let chunks = [
      protectedReply("Fix the bug."), "<fixes><fix>Use the imperative.",
      "</fix><fix>Keep the article.</fix></fixes>",
    ]
    let provider = MockProvider(scripts: [
      chunks.map { .event(.text($0)) } + [.event(.finished(.stop))]
    ])
    let (result, updates) = try await protectedRun(provider, input: input)
    let snapshots = updates.compactMap { update -> SectionsSnapshot? in
      if case .sections(let snapshot) = update { return snapshot }
      return nil
    }
    #expect(snapshots.count == chunks.count)
    let expected = input == "帮我看看" ? [] : ["Use the imperative.", "Keep the article."]
    if expected.isEmpty {
      #expect(snapshots.allSatisfy { !$0.sections.contains { $0.name == "fixes" } })
      #expect(!result.snapshot.sections.contains { $0.name == "fixes" })
    } else {
      #expect(snapshots.last?.sections.last?.children.map(\.text) == expected)
    }
    #expect(result.sections?.fixes == expected)
    #expect(result.snapshot.rawText == chunks.joined())
    #expect(result.bestEligibility == .eligible)
    #expect(result.altEligibility == [.eligible])
    #expect(!result.strictRetried)
  }

  @Test func successAndUsage() async throws {
    let result = try await runRewrite([
      .event(.text(rewriteFixture)),
      .event(.usage(LLMUsage(promptTokens: 2, completionTokens: 3))), .event(.finished(.stop)),
    ])
    #expect(result.bestEligibility == .eligible)
    #expect(result.altEligibility == [.eligible])
    #expect(result.sections?.best == "Ship it.")
    #expect(result.sections?.alts.first?.note == "正式")
    #expect(result.usage == LLMUsage(promptTokens: 2, completionTokens: 3))
  }

  @Test func terminalReasons() async throws {
    for (reason, expected) in [
      (LLMFinishReason.length, IncompleteReason.length), (.contentFilter, .contentFilter),
      (.other, .other),
    ] {
      let result = try await runRewrite([.event(.text(rewriteFixture)), .event(.finished(reason))])
      #expect(result.bestEligibility == .incomplete(expected))
      #expect(result.altEligibility == [.incomplete(expected)])
      #expect(result.sections == nil)
    }
    let partial = try await runRewrite([.event(.text("<best>partial")), .error(.transport)])
    #expect(partial.bestEligibility == .incomplete(.error(.transport)))
    #expect(partial.snapshot.rawText == "<best>partial")
    let mockNoFinish = try await runRewrite([.event(.text(rewriteFixture))])
    #expect(mockNoFinish.bestEligibility == .incomplete(.error(.transport)))
    let noFinish = try await runRewrite(FinishingProvider(events: [.text(rewriteFixture)]))
    #expect(noFinish.bestEligibility == .incomplete(.error(.transport)))
    #expect(noFinish.sections == nil)
    let empty = try await runRewrite(FinishingProvider(events: []))
    #expect(empty.bestEligibility == .incomplete(.error(.emptyResponse)))
    let usageOnly = try await runRewrite(
      FinishingProvider(events: [.usage(LLMUsage(promptTokens: 1, completionTokens: 0))]))
    #expect(usageOnly.bestEligibility == .incomplete(.error(.emptyResponse)))
    let auth = try await runRewrite([.error(.auth(status: 401))])
    #expect(auth.bestEligibility == .incomplete(.error(.auth(status: 401))))
    let malformed = try await runRewrite([.event(.text("raw")), .event(.finished(.stop))])
    #expect(malformed.bestEligibility == .malformed)
    #expect(malformed.sections == nil)
    #expect(malformed.snapshot.rawText == "raw")
  }

  @Test func streamingSnapshotAndCancellation() async throws {
    let token = LLMCancellation()
    let provider = MockProvider(scripts: [[.event(.text("<best>partial")), .hang]])
    let result = try await bounded {
      var snapshots = 0
      for try await update in RewriteRunner.run(
        input: "x", settings: RewriteSettings(),
        provider: provider, cancellation: token)
      {
        switch update {
        case .sections(let snapshot):
          snapshots += 1
          #expect(snapshot.sections.first?.text == "partial")
          #expect(!snapshot.isFinished)
          token.cancel()
        case .completed(let result):
          #expect(snapshots == 1)
          return result
        case .retrying, .strictRetry: Issue.record("Unexpected retry")
        }
      }
      throw TestDeadline()
    }
    #expect(result.bestEligibility == .incomplete(.error(.aborted)))
    #expect(result.snapshot.rawText == "<best>partial")
  }

  @Test func consumerCancellationCancelsProviderToken() async throws {
    let token = LLMCancellation()
    let provider = MockProvider(scripts: [[.event(.text("<best>partial")), .hang]])
    let (firstSection, signal) = AsyncStream<Void>.makeStream()
    let consumer = Task {
      for try await update in RewriteRunner.run(
        input: "x", settings: RewriteSettings(), provider: provider, cancellation: token)
      {
        if case .sections = update { signal.yield() }
      }
    }
    try await bounded {
      for await _ in firstSection { return }
      throw TestDeadline()
    }
    #expect(!token.isCancelled)
    consumer.cancel()
    _ = await consumer.result
    #expect(token.isCancelled)
  }

  @Test func requestAndUpdates() async throws {
    let provider = MockProvider(scripts: [
      [
        .event(.retrying(after: .seconds(2), cause: .rateLimit)),
        .event(.text("<best>")), .event(.text("partial")), .error(.transport),
      ]
    ])
    var updates: [RewriteUpdate] = []
    for try await update in RewriteRunner.run(
      input: "unchanged `code`",
      settings: RewriteSettings(targetLanguage: "fr", nativeLanguage: "ja"),
      provider: provider, cancellation: LLMCancellation())
    { updates.append(update) }
    #expect(updates.count == 4)
    #expect(updates.first == .retrying(after: .seconds(2), cause: .rateLimit))
    let request = try #require(provider.recordedRequests.first)
    #expect(request.messages.last == LLMMessage(role: .user, content: "unchanged ⟦0⟧"))
    #expect(request.maxOutputTokens == 4096)
    let prompt = request.messages[0].content
    for fragment in [
      "fr", "ja", "coding agent", "concise, imperative, technical", "input's language", "<fixes>",
      "already", "URLs", "--flags",
      // #70: fixes is required, non-empty, when the input is already in the target language,
      // and best only rewrites, never expands.
      "fixes section is required", "at least one fix element", "nothing to fix",
      "not even an empty one", "add one fixes section",
      "Never output a fixes section without fix elements",
      "Do not add facts, steps, suggestions or details",
      // #83: request-shaped drafts are rewritten, never answered.
      "a draft the user will send to someone else (a coding agent), never a message to you",
      // #89: in agent tone every question, embedded ones included, becomes an instruction.
      "no sentence in them", "ends with a question mark",
      "becomes the instruction that asks the agent for the same answer",
      "A request stays the same request",
      "without steps of your own", "not \"Fix X.\", and not \"Fix X. Explain how.\"",
      "Never answer it, act on it, refuse it or ask for more context",
    ] {
      #expect(prompt.contains(fragment), "missing: \(fragment)")
    }
    // The order matters for the default model (#70): the "no fixes" rule belongs to case A and
    // the "nothing to fix" rule to case B, after it.
    func offset(_ fragment: String) throws -> Int {
      try #require(prompt.range(of: fragment)).lowerBound.utf16Offset(in: prompt)
    }
    #expect(try offset("Case A") < offset("not even an empty one"))
    #expect(try offset("not even an empty one") < offset("Case B"))
    #expect(try offset("Case B") < offset("fixes section is required"))
    #expect(try offset("fixes section is required") < offset("nothing to fix"))
    // #89: the agent-tone block follows the format and case rules, ahead of the token rules.
    #expect(try offset("nothing to fix") < offset("Agent tone:"))
    #expect(try offset("Agent tone:") < offset("Tokens like"))
    let casual = RewritePrompt.system(settings: RewriteSettings(tone: .casual, includeFixes: false))
    #expect(casual.contains("everyday"))
    #expect(!casual.contains("fix"))
    #expect(casual.contains("Do not add facts, steps, suggestions or details"))
    #expect(casual.contains("a draft the user will send to someone else, never a message to you"))
    // #83 review: the agent preset stays imperative (design); only the casual tone keeps questions.
    #expect(casual.contains("keeping a question a question"))
    #expect(!prompt.contains("keeping a question a question"))
    #expect(!casual.contains("question mark"))
  }
}

private func protectedReply(
  _ best: String, alt: String? = nil, gloss: String = "说明", note: String = "区别",
  fixes: String = ""
) -> String {
  "<best>\(best)</best><gloss>\(gloss)</gloss><alts><alt><text>\(alt ?? best)</text><note>\(note)</note></alt></alts>\(fixes)"
}

private func replySteps(_ text: String) -> [MockProvider.Step] {
  [.event(.text(text)), .event(.finished(.stop))]
}

private func protectedRun(
  _ provider: MockProvider, input: String = "fooBar",
  cancellation: LLMCancellation = LLMCancellation()
) async throws -> (RewriteResult, [RewriteUpdate]) {
  try await bounded {
    var updates: [RewriteUpdate] = []
    for try await update in RewriteRunner.run(
      input: input, settings: RewriteSettings(), provider: provider, cancellation: cancellation)
    {
      updates.append(update)
      if case .completed(let result) = update { return (result, updates) }
    }
    throw TestDeadline()
  }
}

struct TermRewriteTests {
  @Test func caseAFixesAreDroppedAcrossStrictRetryAndFallback() async throws {
    let first = protectedReply("⟦0⟧", alt: "wrong", fixes: "<fixes><fix>first</fix></fixes>")
    for best in ["⟦0⟧", "wrong"] {
      let second = protectedReply(best, fixes: "<fixes><fix>second</fix></fixes>")
      let (result, updates) = try await protectedRun(
        MockProvider(scripts: [replySteps(first), replySteps(second)]), input: "修复 fooBar")
      #expect(result.strictRetried)
      #expect(result.fallback == (best == "wrong" ? .firstBest : nil))
      #expect(result.bestEligibility == .eligible)
      #expect(result.sections?.fixes == [])
      #expect(!result.snapshot.sections.contains { $0.name == "fixes" })
      #expect(result.snapshot.rawText.contains("<fixes><fix>second</fix></fixes>"))
      for case .sections(let snapshot) in updates {
        #expect(!snapshot.sections.contains { $0.name == "fixes" })
      }
    }
  }

  @Test func caseAFilteringPreservesFailureEligibility() async throws {
    for (suffix, finish, expected) in [
      ("<fixes></fixes>", LLMFinishReason.stop, Eligibility.malformed),
      ("<fixes><fix>partial", .length, .incomplete(.length)),
    ] {
      let reply = protectedReply("Check it.") + suffix
      let (result, updates) = try await protectedRun(
        MockProvider(scripts: [[.event(.text(reply)), .event(.finished(finish))]]), input: "帮我看看")
      #expect(result.bestEligibility == expected)
      #expect(result.sections == nil)
      #expect(!result.snapshot.sections.contains { $0.name == "fixes" })
      #expect(result.snapshot.rawText == reply)
      for case .sections(let snapshot) in updates {
        #expect(!snapshot.sections.contains { $0.name == "fixes" })
      }
    }
  }

  @Test func strictRetryRegeneratesAndRestores() async throws {
    let good = "use ⟦0⟧ and ⟦0⟧ with ⟦1⟧"
    let provider = MockProvider(scripts: [
      replySteps(protectedReply("use ⟦0⟧ with ⟦1⟧", alt: good)),
      replySteps(protectedReply(good)),
    ])
    let (result, updates) = try await protectedRun(
      provider, input: "use fooBar and fooBar with --flag")
    #expect(result.bestEligibility == .eligible)
    #expect(result.altEligibility == [.eligible])
    #expect(result.sections?.best == "use fooBar and fooBar with --flag")
    #expect(result.sections?.alts.first?.text == result.sections?.best)
    #expect(result.strictRetried)
    #expect(result.fallback == nil)
    #expect(updates.filter { $0 == .strictRetry }.count == 1)
    #expect(provider.recordedRequests.count == 2)
    #expect(provider.recordedRequests[0].messages.last?.content == good)
    #expect(provider.recordedRequests[1].messages.last?.content == good)
    let first = provider.recordedRequests[0].messages[0].content
    let second = provider.recordedRequests[1].messages[0].content
    #expect(first.contains("Copy each token exactly"))
    // The legend names each token's kind, aligned with the reused numbers, and never the fragment.
    #expect(
      first.contains(
        "What each token stands for: ⟦0⟧ is a code identifier, ⟦1⟧ is a command-line flag."))
    #expect(!first.contains("fooBar"))
    #expect(!first.replacingOccurrences(of: "--flags", with: "").contains("--flag"))
    let kinds = TermProtection.protect(
      "用 `--dry-run` 跑 scripts/migrate.sh，见 https://example.com/a 与 fooBar、`x = 1`、async/await")
    #expect(
      RewritePrompt.system(settings: RewriteSettings(), protection: kinds).contains(
        "⟦0⟧ is a command-line flag, ⟦1⟧ is a file path, ⟦2⟧ is a URL, ⟦3⟧ is a code identifier,"
          + " ⟦4⟧ is a code fragment, ⟦5⟧ is a slash-separated term."))
    #expect(second.hasPrefix(first))
    #expect(second.contains("previous answer"))
    #expect(second.contains("⟦0⟧ ×2, ⟦1⟧ ×1"))
  }

  @Test(arguments: [false, true]) func versionsFailSeparately(bestFails: Bool) async throws {
    let reply = protectedReply(bestFails ? "wrong" : "⟦0⟧", alt: bestFails ? "⟦0⟧" : "wrong")
    let provider = MockProvider(scripts: [replySteps(reply)])
    let (result, _) = try await protectedRun(provider)
    #expect(result.bestEligibility == (bestFails ? .placeholdersChanged : .eligible))
    #expect(result.altEligibility == [bestFails ? .eligible : .placeholdersChanged])
    #expect(result.sections != nil)
    #expect(result.fallback == nil)
    #expect(result.strictRetried)
    #expect(provider.recordedRequests.count == 2)
  }

  @Test func eachAlternativeHasItsOwnEligibility() async throws {
    let reply = protectedReply("⟦0⟧").replacingOccurrences(
      of: "</alts>", with: "<alt><text>wrong</text><note>second</note></alt></alts>")
    let (result, _) = try await protectedRun(MockProvider(scripts: [replySteps(reply)]))
    #expect(result.bestEligibility == .eligible)
    #expect(result.altEligibility == [.eligible, .placeholdersChanged])
    #expect(result.sections?.alts.map(\.text) == ["fooBar", "wrong"])
    #expect(result.strictRetried)
  }

  @Test func allVersionsFail() async throws {
    let (result, _) = try await protectedRun(
      MockProvider(scripts: [replySteps(protectedReply("⟦7⟧ ⟦0⟧"))]))
    #expect(result.bestEligibility == .placeholdersChanged)
    #expect(result.altEligibility == [.placeholdersChanged])
    #expect(result.sections?.best == "⟦7⟧ fooBar")
    #expect(result.strictRetried)
    #expect(result.fallback == nil)
  }

  @Test func firstBestFallback() async throws {
    let first = replySteps(protectedReply("first ⟦0⟧", alt: "wrong"))
    let secondAttempts: [[MockProvider.Step]] = [
      [.error(.transport)], replySteps(protectedReply("wrong")),
      [.event(.text(protectedReply("⟦0⟧"))), .event(.finished(.length))],
      [.event(.text(protectedReply("⟦0⟧"))), .event(.finished(.contentFilter))],
      [.event(.text(protectedReply("⟦0⟧"))), .event(.finished(.other))],
      replySteps("malformed"),
    ]
    for second in secondAttempts {
      let (result, _) = try await protectedRun(MockProvider(scripts: [first, second]))
      #expect(result.fallback == .firstBest)
      #expect(result.bestEligibility == .eligible)
      #expect(result.altEligibility.isEmpty)
      #expect(result.sections == FixSections(best: "first fooBar", gloss: nil, alts: [], fixes: []))
      #expect(result.strictRetried)
      #expect(!result.snapshot.rawText.contains("first"))
    }
    let (failed, _) = try await protectedRun(
      MockProvider(scripts: [
        replySteps(protectedReply("wrong")), [.error(.transport)],
      ]))
    #expect(failed.bestEligibility == .incomplete(.error(.transport)))
    #expect(failed.fallback == nil)
    #expect(failed.sections == nil)
  }

  @Test func retryCancellationDoesNotFallback() async throws {
    let token = LLMCancellation()
    defer { token.cancel() }
    let provider = MockProvider(scripts: [
      replySteps(protectedReply("⟦0⟧", alt: "wrong")), [.hang],
    ])
    let result = try await bounded {
      for try await update in RewriteRunner.run(
        input: "fooBar", settings: RewriteSettings(), provider: provider, cancellation: token)
      {
        if case .strictRetry = update { token.cancel() }
        if case .completed(let result) = update { return result }
      }
      throw TestDeadline()
    }
    #expect(result.bestEligibility == .incomplete(.error(.aborted)))
    #expect(result.fallback == nil)
    #expect(result.sections == nil)
    #expect(result.strictRetried)
    #expect(provider.recordedRequests.count == 2)
  }

  /// Serves the first request from `first`; on the second request yields `partial` and, once the
  /// token is cancelled, ends the stream the way `ending` says: normally (no `.finished`, no
  /// error), with a `.transport` error, or with `.finished(.stop)`.
  struct QuietCancelProvider: LLMProvider {
    enum Ending: Sendable { case quiet, transport, stop }
    var first: String
    var partial: String
    var ending = Ending.quiet
    let count = OSAllocatedUnfairLock(initialState: 0)
    func stream(_ request: LLMRequest, cancellation: LLMCancellation) -> AsyncThrowingStream<
      LLMEvent, any Error
    > {
      let index = count.withLock { count in
        count += 1
        return count
      }
      return AsyncThrowingStream { continuation in
        if index == 1 {
          continuation.yield(.text(first))
          continuation.yield(.finished(.stop))
          continuation.finish()
        } else {
          continuation.yield(.text(partial))
          cancellation.onCancel {
            switch ending {
            case .quiet: continuation.finish()
            case .transport: continuation.finish(throwing: LLMError.transport)
            case .stop:
              continuation.yield(
                .text(
                  "</best><gloss>g</gloss><alts><alt><text>⟦0⟧</text><note>n</note></alt></alts>"))
              continuation.yield(.finished(.stop))
              continuation.finish()
            }
          }
        }
      }
    }
  }

  @Test(arguments: [QuietCancelProvider.Ending.quiet, .transport, .stop])
  func retryEndedAfterCancelIsAbortedNotFallback(_ ending: QuietCancelProvider.Ending) async throws
  {
    let token = LLMCancellation()
    defer { token.cancel() }
    let provider = QuietCancelProvider(
      first: protectedReply("⟦0⟧", alt: "wrong"), partial: "<best>second ⟦0⟧", ending: ending)
    let result = try await bounded {
      for try await update in RewriteRunner.run(
        input: "fooBar", settings: RewriteSettings(), provider: provider, cancellation: token)
      {
        if case .strictRetry = update { token.cancel() }
        if case .completed(let result) = update { return result }
      }
      throw TestDeadline()
    }
    #expect(result.bestEligibility == .incomplete(.error(.aborted)))
    #expect(result.fallback == nil)
    #expect(result.sections == nil)
  }

  @Test func incompleteDoesNotRetry() async throws {
    let provider = MockProvider(scripts: [
      [
        .event(.text(protectedReply("wrong"))), .event(.finished(.length)),
      ]
    ])
    let (result, updates) = try await protectedRun(provider)
    #expect(result.bestEligibility == .incomplete(.length))
    #expect(!result.strictRetried)
    #expect(!updates.contains(.strictRetry))
    #expect(provider.recordedRequests.count == 1)
  }

  @Test func auxiliaryFieldsDropUnknownTokens() async throws {
    let text = protectedReply(
      "⟦0⟧", gloss: "⟦7⟧", note: "⟦8⟧", fixes: "<fixes><fix>⟦9⟧</fix><fix>keep ⟦0⟧</fix></fixes>")
    let (result, _) = try await protectedRun(MockProvider(scripts: [replySteps(text)]))
    #expect(result.bestEligibility == .eligible)
    #expect(result.altEligibility == [.eligible])
    #expect(result.sections?.gloss == nil)
    #expect(result.sections?.alts.first?.note == nil)
    #expect(result.sections?.fixes == ["keep fooBar"])
    #expect(!result.strictRetried)
    let (restored, _) = try await protectedRun(
      MockProvider(scripts: [
        replySteps(protectedReply("⟦0⟧", gloss: "⟦0⟧ ⟦0⟧", note: "⟦0⟧"))
      ]))
    #expect(restored.sections?.gloss == "fooBar fooBar")
    #expect(restored.sections?.alts.first?.note == "fooBar")
  }

  @Test func streamingRestoration() async throws {
    let provider = MockProvider(scripts: [
      [
        .event(.text("<best>use ⟦")),
        .event(
          .text(
            "0⟧ now</best><gloss>⟦0⟧</gloss><alts><alt><text>⟦0⟧</text><note>⟦0⟧</note></alt></alts>"
          )),
        .event(.finished(.stop)),
      ]
    ])
    let (result, updates) = try await protectedRun(provider)
    let snapshots = updates.compactMap { update -> SectionsSnapshot? in
      if case .sections(let snapshot) = update { return snapshot }
      return nil
    }
    #expect(snapshots[0].sections.first?.text == "use ⟦")
    #expect(snapshots[1].sections.first?.text == "use fooBar now")
    #expect(snapshots[1].rawText.contains("<best>use fooBar now</best>"))
    #expect(snapshots[1].sections.last?.children.first?.children.last?.text == "fooBar")
    #expect(result.bestEligibility == .eligible)
  }

  @Test func literalAndUnavailableDelimiters() async throws {
    for stray in [false, true] {
      let provider = MockProvider(scripts: [
        replySteps(protectedReply("⟦0⟧ ⟪0⟫" + (stray ? " ⟪1⟫" : "")))
      ])
      let (result, _) = try await protectedRun(provider, input: "⟦0⟧ fooBar")
      #expect(provider.recordedRequests[0].messages.last?.content == "⟦0⟧ ⟪0⟫")
      #expect(result.bestEligibility == (stray ? .placeholdersChanged : .eligible))
      #expect(result.sections?.best.contains("⟦0⟧ fooBar") == true)
    }
    let input = "⟦ ⟫ 〖 fooBar"
    let provider = MockProvider(scripts: [replySteps(protectedReply(input))])
    let (result, _) = try await protectedRun(provider, input: input)
    #expect(provider.recordedRequests[0].messages.last?.content == input)
    #expect(provider.recordedRequests.count == 1)
    #expect(result.bestEligibility == .placeholdersUnavailable)
    #expect(result.altEligibility == [.placeholdersUnavailable])
    #expect(result.sections != nil)
    #expect(!result.strictRetried)
  }

  @Test func inventedTokenWithoutFragments() async throws {
    let provider = MockProvider(scripts: [
      replySteps(protectedReply("⟦3⟧")), replySteps(protectedReply("plain")),
    ])
    let (result, _) = try await protectedRun(provider, input: "plain")
    #expect(result.bestEligibility == .eligible)
    #expect(result.strictRetried)
    #expect(!provider.recordedRequests[0].messages[0].content.contains("Tokens like"))
    #expect(provider.recordedRequests[1].messages[0].content.contains("previous answer"))
  }

  @Test func usageAcrossAttempts() async throws {
    for usages in [
      [
        LLMUsage(promptTokens: 2, completionTokens: 3, reasoningTokens: 1),
        LLMUsage(promptTokens: 5, completionTokens: 7, reasoningTokens: 2),
      ], [nil, LLMUsage(promptTokens: 5, completionTokens: 7)],
      [LLMUsage(promptTokens: 2, completionTokens: 3), nil],
    ] as [[LLMUsage?]] {
      let scripts = usages.map { usage -> [MockProvider.Step] in
        [.event(.text(protectedReply("wrong")))] + (usage.map { [.event(.usage($0))] } ?? []) + [
          .event(.finished(.stop))
        ]
      }
      let (result, _) = try await protectedRun(MockProvider(scripts: scripts))
      #expect(result.usage?.promptTokens == usages.compactMap { $0?.promptTokens }.reduce(0, +))
      #expect(
        result.usage?.completionTokens == usages.compactMap { $0?.completionTokens }.reduce(0, +))
      #expect(result.usage?.reasoningTokens == (usages[0]?.reasoningTokens == nil ? nil : 3))
    }
  }
}
