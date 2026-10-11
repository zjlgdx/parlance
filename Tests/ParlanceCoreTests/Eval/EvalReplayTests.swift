import Foundation
import Testing

@testable import ParlanceCore

struct EvalReplayTests {
  @Test func caseInventory() throws {
    let rewrites = try EvalFiles.cases(.rewrite)
    let explanations = try EvalFiles.cases(.explain)
    #expect(rewrites.count >= 30)
    #expect(explanations.count >= 20)
    #expect(Set(rewrites.map(\.id)).count == rewrites.count)
    #expect(Set(explanations.map(\.id)).count == explanations.count)
    #expect(Set(rewrites.compactMap(\.category)) == ["zh", "mixed-code", "broken-en"])
    #expect(Set(explanations.compactMap(\.source)) == ["claude-code", "codex"])
    #expect((rewrites + explanations).allSatisfy { !$0.input.isEmpty })
  }

  @Test func recordedReplays() async throws {
    let files = try EvalFiles.recordings(in: EvalFiles.fixtures.appendingPathComponent("recorded"))
    if files.isEmpty { print("EvalReplay: recorded/ is empty; no live recordings to replay.") }
    for file in files {
      let recording = try EvalFiles.read(EvalRecording.self, from: file)
      #expect(file.lastPathComponent == "\(recording.kind.rawValue)-\(recording.testCase.id).json")
      #expect(file.deletingLastPathComponent().lastPathComponent == recording.preset)
      let sourceCase = try #require(
        EvalFiles.cases(recording.kind).first { $0.id == recording.testCase.id })
      #expect(sourceCase == recording.testCase)
      try await check(recording)
    }
  }

  @Test func handwrittenReplays() async throws {
    let files = try EvalFiles.recordings(
      in: EvalFiles.fixtures.appendingPathComponent("handwritten"))
    #expect(files.count == 3)
    for file in files {
      let recording = try EvalFiles.read(EvalRecording.self, from: file)
      try await check(recording)
      switch recording.testCase.id {
      case "clean":
        #expect(recording.metrics.sectionsComplete)
        #expect(recording.metrics.termPasses == 2)
      case "strict-retry":
        #expect(recording.attempts.count == 2)
        #expect(recording.metrics.strictRetryUsed)
        #expect(recording.metrics.termPasses == 3)
        #expect(recording.metrics.termVersions == 4)
      case "missing-plain": #expect(!recording.metrics.sectionsComplete)
      default: Issue.record("Unexpected handwritten fixture")
      }
    }
  }

  private func check(_ recording: EvalRecording) async throws {
    #expect(recording.schemaVersion == 1)
    #expect(!recording.attempts.isEmpty)
    let replay = try await EvalHarness.replay(recording)
    if recording.kind == .rewrite {
      let id = recording.testCase.id
      if id.hasPrefix("zh-") || id.hasPrefix("mix-") {
        #expect(
          RewriteCase.classify(recording.testCase.input, settings: RewriteSettings()) == .translate,
          "\(id)")
        #expect(replay.recording.metrics.caseAFixesInResult == 0, "\(recording.preset)/\(id)")
      }
      if recording.testCase.id.hasPrefix("en-") { try await checkRetainedFixes(recording) }
    }
    var metrics = replay.recording.metrics
    // Legacy recordings have no baseline for the new counters; retain every existing check.
    if recording.metrics.caseAFixesInReply == nil { metrics.caseAFixesInReply = nil }
    if recording.metrics.caseAFixesInResult == nil { metrics.caseAFixesInResult = nil }
    #expect(
      metrics == recording.metrics, "\(recording.preset)/\(recording.testCase.id)")
    // Also catches missing/extra attempts and any loss of usage, errors or chunk boundaries.
    #expect(replay.recording.attempts == recording.attempts)
    #expect(!replay.recording.metrics.bestEligible || !replay.recording.metrics.bestHasResidue)
  }

  private func checkRetainedFixes(_ recording: EvalRecording) async throws {
    #expect(RewriteCase.classify(recording.testCase.input, settings: RewriteSettings()) == .polish)
    var parser = SectionStreamParser()
    for event in try #require(recording.attempts.last).events {
      if case .text(let chunk) = event { parser.feed(chunk) }
    }
    let protection = TermProtection.protect(recording.testCase.input)
    let expected = (parser.finish().sections.first { $0.name == "fixes" }?.children ?? [])
      .map { protection.restore($0.text) }
      .filter { !protection.containsUnknownToken($0) }
    let result = try await bounded {
      let provider = MockProvider(scripts: recording.attempts.map { $0.events.map(\.step) })
      for try await update in RewriteRunner.run(
        input: recording.testCase.input, settings: RewriteSettings(), provider: provider,
        cancellation: LLMCancellation())
      {
        if case .completed(let result) = update { return result }
      }
      throw TestDeadline()
    }
    #expect(result.sections?.fixes == expected, "\(recording.preset)/\(recording.testCase.id)")
  }

  @Test func residueRejectsKnownUnknownAndForeignTokens() async throws {
    let input = "修复 `fetchUser()`"
    for text in ["⟦0⟧", "⟦999⟧", "⟦oops⟧", "dangling ⟧", "⟪77⟫", "〖2〗"] {
      #expect(EvalMetrics.hasResidue(text, input: input), "\(text)")
    }
    #expect(!EvalMetrics.hasResidue("Fix `fetchUser()`.", input: input))
    #expect(!EvalMetrics.hasResidue("Keep `⟦0⟧`.", input: "保留 `⟦0⟧`"))
    // A foreign delimiter token is not rejected by the runner's chosen-pair validation.
    // The independent eval check must still reject an otherwise eligible best.
    let text =
      "<best>Fix ⟦0⟧ ⟪999⟫.</best><gloss>修复</gloss>"
      + "<alts><alt><text>Repair ⟦0⟧.</text><note>简短</note></alt></alts>"
    let run = try await EvalHarness.run(
      kind: .rewrite, testCase: EvalCase(id: "residue", category: "mixed-code", input: input),
      preset: "handwritten", model: "test",
      provider: MockProvider(scripts: [
        [.event(.text(text)), .event(.finished(.stop))]
      ]))
    #expect(run.recording.metrics.bestEligible)
    #expect(run.recording.metrics.bestHasResidue)
    #expect(run.recording.metrics.failures["placeholder_residue"] == 1)
  }

  @Test func recordingRoundTripsAllEventsAndErrors() throws {
    let errors: [LLMError] = [
      .auth(status: nil), .auth(status: 401), .quota(status: 402),
      .invalidRequest(status: 400, providerCode: nil),
      .invalidRequest(status: 404, providerCode: .modelNotFound),
      .rateLimit(retryAfter: nil), .rateLimit(retryAfter: .milliseconds(125)),
      .server(status: 503), .transport, .timeout(.firstToken), .timeout(.idle), .timeout(.total),
      .aborted, .emptyResponse, .malformedResponse,
    ]
    for error in errors {
      let decoded = try JSONDecoder().decode(
        RecordedError.self, from: JSONEncoder().encode(RecordedError(error)))
      #expect(decoded.value == error)
    }
    let events: [LLMEvent] = [
      .text(""), .text("<be"), .text("st>⟦0⟧"),
      .retrying(after: .nanoseconds(123), cause: .rateLimit),
      .usage(.init(promptTokens: 7, completionTokens: 8, reasoningTokens: 9)),
      .usage(.init(promptTokens: 7, completionTokens: 8)),
      .finished(.stop), .finished(.length), .finished(.contentFilter), .finished(.other),
    ]
    for event in events {
      let decoded = try JSONDecoder().decode(
        RecordedEvent.self, from: JSONEncoder().encode(RecordedEvent(event)))
      if case .event(let restored) = decoded.step {
        #expect(restored == event)
      } else {
        Issue.record("Event decoded as a failure")
      }
    }
  }

  @Test func recordsHTTPEventsAndReplaysThemOffline() async throws {
    let text =
      "<best>Fix ⟦0⟧.</best><gloss>修复</gloss>"
      + "<alts><alt><text>Repair ⟦0⟧.</text><note>简短</note></alt></alts>"
    for preset in [ProviderPreset.deepseek, .gemini, .openai, .claude] {
      // URLProtocol intercepts every request; these are synthetic SSE bytes, never live traffic.
      var script: [Harness.Step] = []
      if preset.wire == .anthropicMessages {
        script.append(
          .data(sse(#"{"type":"message_start","message":{"usage":{"input_tokens":2}}}"#)))
      }
      script += [
        .data(textChunk(String(text.prefix(4)), preset: preset)),
        .data(textChunk(String(text.dropFirst(4)), preset: preset)),
        .data(finishChunk("stop", preset: preset)),
      ]
      if preset.wire == .anthropicMessages {
        script.append(.data(sse(#"{"type":"message_stop"}"#)))
      } else {
        script.append(
          .data(sse(#"{"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":3}}"#)))
      }
      script += [.data(sse("[DONE]")), .end]
      let fixture = Fixture(preset, scripts: [script], apiKey: "fake-eval-key")
      let run = try await EvalHarness.run(
        kind: .rewrite,
        testCase: EvalCase(id: "wire", category: "mixed-code", input: "修复 `fetchUser()`"),
        preset: preset.id, model: preset.defaultModel!, provider: fixture.provider)
      #expect(run.recording.metrics.sectionsComplete)
      let first = try #require(run.firstTokenSeconds)
      #expect(first >= 0 && first <= run.totalSeconds)
      #expect(run.recording.attempts.count == 1)
      #expect(
        run.recording.attempts[0].events == [
          .text(String(text.prefix(4))), .text(String(text.dropFirst(4))),
          .usage(promptTokens: 2, completionTokens: 3, reasoningTokens: nil), .finished(.stop),
        ])
      try await check(run.recording)
    }
  }

  @Test func fallbackAndErrorReplay() async throws {
    let goodBestBadAlt =
      "<best>Fix ⟦0⟧.</best><gloss>修复</gloss>"
      + "<alts><alt><text>Fix it.</text><note>简短</note></alt></alts>"
    let input = EvalCase(id: "fallback", category: "mixed-code", input: "修复 `fetchUser()`")
    let run = try await EvalHarness.run(
      kind: .rewrite, testCase: input, preset: "handwritten", model: "test",
      provider: MockProvider(scripts: [
        [.event(.text(goodBestBadAlt)), .event(.finished(.stop))],
        [
          .event(.retrying(after: .milliseconds(25), cause: .server)), .error(.server(status: 503)),
        ],
      ]))
    #expect(run.recording.metrics.fallback)
    #expect(run.recording.metrics.bestEligible)
    #expect(!run.recording.metrics.sectionsComplete)
    #expect(run.recording.metrics.termPasses == 1)
    #expect(run.recording.metrics.termVersions == 2)
    #expect(run.recording.metrics.failures["server"] == 1)
    try await check(run.recording)
  }

  @Test func everyAlternativeCounts() async throws {
    let text =
      "<best>⟦0⟧</best><gloss>修复</gloss><alts>"
      + "<alt><text>⟦0⟧</text><note>一</note></alt>"
      + "<alt><text>⟦0⟧</text><note>二</note></alt>"
      + "<alt><text>lost</text><note>三</note></alt></alts>"
    let run = try await EvalHarness.run(
      kind: .rewrite,
      testCase: EvalCase(id: "all-alts", category: "mixed-code", input: "修复 `fetchUser()`"),
      preset: "handwritten", model: "test",
      provider: MockProvider(scripts: [[.event(.text(text)), .event(.finished(.stop))]]))
    #expect(run.recording.metrics.termVersions == 4)
    #expect(run.recording.metrics.termPasses == 3)
  }

  @Test func hangingReplayIsBoundedAndCancelled() async throws {
    let cancellation = LLMCancellation()
    defer { cancellation.cancel() }
    do {
      try await bounded(timeout: .milliseconds(20)) {
        for try await _ in RewriteRunner.run(
          input: "input", settings: RewriteSettings(),
          provider: MockProvider(scripts: [[.hang]]), cancellation: cancellation)
        {}
      }
      Issue.record("A hanging provider must hit the deadline")
    } catch is TestDeadline {}  // A deadline timer, not a sleep used to synchronize work.
  }

  @Test func liveSwitchAndKeyAreBothRequired() {
    let key = ["GEMINI_API_KEY": "fake-eval-key"]
    #expect(LiveEvalTests.enabledPresets(key).isEmpty)
    #expect(LiveEvalTests.enabledPresets(["PARLANCE_LIVE_EVAL": "1"]).isEmpty)
    var environment = key.merging(["PARLANCE_LIVE_EVAL": "1"]) { _, new in new }
    #expect(LiveEvalTests.enabledPresets(environment).map(\.id) == ["gemini"])
    environment["CI"] = ""
    #expect(LiveEvalTests.enabledPresets(environment).isEmpty)
    environment["CI"] = "false"
    #expect(LiveEvalTests.enabledPresets(environment).isEmpty)
  }

  @Test func modelOverrideRunsOnlyThePresetsThatListIt() {
    let environment = [
      "PARLANCE_LIVE_EVAL": "1", "DEEPSEEK_API_KEY": "fake-eval-key",
      "ANTHROPIC_API_KEY": "fake-eval-key", "PARLANCE_EVAL_MODEL": "claude-sonnet-5-5",
    ]
    #expect(LiveEvalTests.enabledPresets(environment).map(\.id) == ["claude"])
    var unknown = environment
    unknown["PARLANCE_EVAL_MODEL"] = "not-a-model"
    #expect(LiveEvalTests.enabledPresets(unknown).isEmpty)
  }

  @Test func aggregatesUseVersionDenominatorsAndNearestRank() throws {
    let clean = try EvalFiles.read(
      EvalRecording.self,
      from: EvalFiles.fixtures.appendingPathComponent("handwritten/rewrite-clean.json"))
    var failed = clean
    failed.testCase.category = "zh"
    failed.metrics.termPasses = 0
    failed.metrics.sectionsComplete = false
    failed.metrics.bestHasResidue = true
    failed.metrics.failures = ["placeholder_residue": 1]
    let report = EvalReport(
      timestamp: "test",
      runs: [
        EvalRun(recording: clean, firstTokenSeconds: 1, totalSeconds: 2),
        EvalRun(recording: failed, firstTokenSeconds: nil, totalSeconds: 4),
      ])
    let aggregate = try #require(report.aggregates.first)
    #expect(aggregate.firstTokenSamples == 1)
    #expect(aggregate.firstTokenP50 == 1)
    #expect(aggregate.totalP50 == 2)
    #expect(aggregate.totalP95 == 4)
    #expect(aggregate.termProtectionRate == 0.5)
    #expect(aggregate.sectionCompleteness == 0.5)
    #expect(aggregate.residueCount == 1)
    #expect(aggregate.failures == ["placeholder_residue": 1])
    #expect(Set(report.aggregates.map(\.group)) == ["all", "rewrite/mixed-code", "rewrite/zh"])
    #expect(EvalAggregate.percentile([], 0.95) == nil)
    #expect(EvalAggregate.percentile(Array(1...20).map(Double.init), 0.95) == 19)
    #expect(report.markdown.contains("placeholder_residue: 1"))
  }
}
