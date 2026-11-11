import Foundation
import Testing

@testable import ParlanceCore

/// #26 performance baseline: one fixed rewrite and one fixed explain input, each run
/// `PARLANCE_PERF_RUNS` times (default 20) per keyed preset, sequentially. First token is measured
/// at the runner boundary: from `stream` to the first `.text` event, including any automatic retry
/// wait. The App's status-panel figure also covers the key lookup and the first parsed section, so
/// it reads slightly higher. Reports go to `build/perf/`: timings plus each run's recording (the
/// fixture input and the model's response text), never keys.
struct LivePerfTests {
  static let cases: [(EvalKind, String)] = [(.rewrite, "zh-01"), (.explain, "ex-05")]

  static func enabled(_ environment: [String: String]) -> Bool {
    environment["CI"] == nil && environment["PARLANCE_LIVE_PERF"] == "1"
  }

  static func presets(_ environment: [String: String]) -> [ProviderPreset] {
    guard enabled(environment) else { return [] }
    return ProviderPreset.all.filter {
      $0.defaultModel != nil && $0.baseURL != nil
        && !(environment[$0.apiKeyEnvironmentVariable] ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  @Test(.enabled(if: !presets(ProcessInfo.processInfo.environment).isEmpty))
  func livePerf() async throws {
    let environment = ProcessInfo.processInfo.environment
    let count = Int(environment["PARLANCE_PERF_RUNS"] ?? "") ?? 20
    try #require(count > 0)
    // Optional pacing for per-minute quotas (free tiers); waiting on a quota, not synchronising.
    let interval = Double(environment["PARLANCE_EVAL_INTERVAL"] ?? "") ?? 0
    let fixtures = try Self.cases.map { kind, id in
      (kind, try #require(try EvalFiles.cases(kind).first { $0.id == id }))
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
    let timestamp = formatter.string(from: Date())
    for preset in Self.presets(environment) {
      let model = try #require(preset.defaultModel)
      let session = URLSession(configuration: .ephemeral)
      defer { session.invalidateAndCancel() }
      let provider = HTTPProvider(
        provider: ResolvedProvider(
          preset: preset, baseURL: try #require(preset.baseURL), model: model,
          apiKey: environment[preset.apiKeyEnvironmentVariable]), session: session)
      let directory = EvalFiles.root.appendingPathComponent(
        "build/perf/\(preset.id)-\(model)-\(timestamp)")
      var runs: [EvalRun] = []
      for (kind, testCase) in fixtures {
        for _ in 0..<count {
          if interval > 0 && !runs.isEmpty { try await Task.sleep(for: .seconds(interval)) }
          runs.append(
            try await EvalHarness.run(
              kind: kind, testCase: testCase, preset: preset.id, model: model,
              provider: provider, timeout: .seconds(250)))
          // Checkpoint after each run so an interrupted baseline still has an honest report.
          let report = EvalReport(timestamp: timestamp, runs: runs)
          try EvalFiles.write(report, to: directory.appendingPathComponent("report.json"))
          try report.markdown.write(
            to: directory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        }
      }
      print("LivePerf: \(preset.id) \(model), \(runs.count) runs; report: \(directory.path)")
    }
  }
}
