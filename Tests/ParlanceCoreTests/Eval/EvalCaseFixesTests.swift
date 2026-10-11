import Foundation
import Testing

@testable import ParlanceCore

struct EvalCaseFixesTests {
  private let reply =
    "<best>Check it.</best><gloss>看看</gloss>"
    + "<alts><alt><text>Review it.</text><note>正式</note></alt></alts>"
  private let fixes = "<fixes><fix>This is Case A.</fix></fixes>"

  @Test(arguments: ["帮我看看", "please check this"])
  func countsReplyAndFilteredResult(_ input: String) async throws {
    let run = try await EvalHarness.run(
      kind: .rewrite, testCase: EvalCase(id: "case", input: input), preset: "mock", model: "mock",
      provider: MockProvider(scripts: [
        [
          .event(.text(reply + "<fix")), .event(.text("es><fix>This is Case A.</fix></fixes>")),
          .event(.finished(.stop)),
        ]
      ]))
    let expected = input == "帮我看看" ? 1 : 0
    #expect(run.recording.metrics.caseAFixesInReply == expected)
    #expect(run.recording.metrics.caseAFixesInResult == 0)
    let replay = try await EvalHarness.replay(run.recording)
    #expect(replay.recording.metrics == run.recording.metrics)
    let report = EvalReport(timestamp: "test", runs: [run, replay])
    #expect(report.aggregates.first?.caseAFixesInReply == expected * 2)
    #expect(report.aggregates.first?.caseAFixesInResult == 0)
    #expect(report.markdown.contains("Case A fixes reply | Case A fixes result"))
  }

  @Test func anyAttemptCountsAndResidualFixesAreDetected() {
    var parser = SectionStreamParser()
    parser.feed(reply + fixes)
    let snapshot = parser.finish()
    var result = RewriteResult(
      snapshot: snapshot, sections: FixSections(snapshot: snapshot), bestEligibility: .eligible,
      altEligibility: [.eligible])
    let present = Recording(events: [.text(reply + fixes), .finished(.stop)])
    let absent = Recording(events: [.text(reply), .finished(.stop)])
    for (attempts, expected) in [
      ([present, absent], 1), ([absent, present], 1), ([present, present], 1), ([absent], 0),
      ([], 0),
    ] {
      let metrics = EvalMetrics.rewrite(result, input: "帮我看看", attempts: attempts)
      #expect(metrics.caseAFixesInReply == expected)
      #expect(metrics.caseAFixesInResult == 1)
    }
    result.snapshot.sections.removeAll { $0.name == "fixes" }
    #expect(EvalMetrics.rewrite(result, input: "帮我看看", attempts: []).caseAFixesInResult == 1)
    result.sections?.fixes = []
    result.fallback = .firstBest
    let fallback = EvalMetrics.rewrite(result, input: "帮我看看", attempts: [present])
    #expect(fallback.caseAFixesInReply == 1)
    #expect(fallback.caseAFixesInResult == 0)
    let japanese = EvalMetrics.rewrite(
      result, input: "東京", attempts: [present],
      settings: RewriteSettings(targetLanguage: "ja", nativeLanguage: "zh-Hans"))
    #expect(japanese.caseAFixesInReply == 0)
  }

  @Test func legacyReportsDecodeWithoutNewCounters() throws {
    let recording = EvalRecording(
      preset: "mock", model: "mock", kind: .rewrite, testCase: EvalCase(id: "old", input: "看看"),
      attempts: [], metrics: EvalMetrics())
    let report = EvalReport(
      timestamp: "test", runs: [EvalRun(recording: recording, totalSeconds: 1)])
    func legacy(_ value: Any) -> Any {
      if let object = value as? [String: Any] {
        return object.filter { !["caseAFixesInReply", "caseAFixesInResult"].contains($0.key) }
          .mapValues(legacy)
      }
      if let array = value as? [Any] { return array.map(legacy) }
      return value
    }
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))
    let data = try JSONSerialization.data(withJSONObject: legacy(object))
    let decoded = try JSONDecoder().decode(EvalReport.self, from: data)
    #expect(decoded.runs.first?.recording.metrics.caseAFixesInReply == nil)
    #expect(decoded.runs.first?.recording.metrics.caseAFixesInResult == nil)
    #expect(decoded.aggregates.first?.caseAFixesInReply == nil)
    #expect(decoded.aggregates.first?.caseAFixesInResult == nil)
    let aggregate = EvalAggregate(preset: "mock", group: "all", values: decoded.runs)
    #expect(aggregate.caseAFixesInReply == 0)
    #expect(aggregate.caseAFixesInResult == 0)
  }
}
