import Foundation
import Testing

@testable import ParlanceCore

struct LiveEvalTests {
  static func enabled(_ environment: [String: String]) -> Bool {
    environment["CI"] == nil && environment["PARLANCE_LIVE_EVAL"] == "1"
  }
  static func enabledPresets(_ environment: [String: String]) -> [ProviderPreset] {
    guard enabled(environment) else { return [] }
    let override = modelOverride(environment)
    return ProviderPreset.all.filter {
      $0.defaultModel != nil && $0.baseURL != nil
        && !(environment[$0.apiKeyEnvironmentVariable] ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (override.map($0.alternateModels.contains) ?? true)
    }
  }
  /// An alternate model to compare; only the presets that list it run.
  static func modelOverride(_ environment: [String: String]) -> String? {
    environment["PARLANCE_EVAL_MODEL"].flatMap {
      let model = $0.trimmingCharacters(in: .whitespacesAndNewlines)
      return model.isEmpty ? nil : model
    }
  }

  // One test keeps enabled providers and their cases sequential, even with parallel Swift Testing.
  // A set override keeps the test enabled, so a mistyped model fails instead of skipping silently.
  @Test(
    .enabled(
      if: !enabledPresets(ProcessInfo.processInfo.environment).isEmpty
        || (enabled(ProcessInfo.processInfo.environment)
          && modelOverride(ProcessInfo.processInfo.environment) != nil)
    ))
  func liveEval() async throws {
    let environment = ProcessInfo.processInfo.environment
    let presets = Self.enabledPresets(environment)
    if let override = Self.modelOverride(environment) {
      try #require(!presets.isEmpty, "no keyed preset lists \(override) as an alternate model")
    }
    guard !presets.isEmpty else {
      print("LiveEval: no enabled preset has a non-empty key; no requests made.")
      return
    }
    for preset in presets {
      // An override run compares an alternate model and is never recorded over the fixtures.
      let override = Self.modelOverride(environment)
      if override != nil {
        try #require(environment["PARLANCE_EVAL_RECORD"] != "1", "do not record an override run")
      }
      let model = try #require(override ?? preset.defaultModel)
      let baseURL = try #require(preset.baseURL)
      let session = URLSession(configuration: .ephemeral)
      defer { session.invalidateAndCancel() }
      let provider = HTTPProvider(
        provider: ResolvedProvider(
          preset: preset, baseURL: baseURL, model: model,
          apiKey: environment[preset.apiKeyEnvironmentVariable]), session: session)
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
      let timestamp = formatter.string(from: Date())
      let directory = EvalFiles.root.appendingPathComponent(
        "build/eval/\(preset.id)-\(model)-\(timestamp)")
      var runs: [EvalRun] = []
      // Optional pacing between cases for providers whose quota is per minute (free tiers);
      // waiting on a provider quota, not synchronising anything.
      let interval = Double(environment["PARLANCE_EVAL_INTERVAL"] ?? "") ?? 0
      for kind in [EvalKind.rewrite, .explain] {
        for testCase in try EvalFiles.cases(kind) {
          if interval > 0 && !runs.isEmpty { try await Task.sleep(for: .seconds(interval)) }
          // HTTPProvider bounds each attempt at 120 s; allow both strict attempts plus teardown.
          let run = try await EvalHarness.run(
            kind: kind, testCase: testCase, preset: preset.id, model: model,
            provider: provider, timeout: .seconds(250))
          runs.append(run)
          if environment["PARLANCE_EVAL_RECORD"] == "1" {
            try EvalFiles.write(
              run.recording,
              to: EvalFiles.fixtures.appendingPathComponent(
                "recorded/\(preset.id)/\(kind.rawValue)-\(testCase.id).json"))
          }
          // Checkpoint after each case so interrupted runs still have an honest partial report.
          let report = EvalReport(timestamp: timestamp, runs: runs)
          try EvalFiles.write(report, to: directory.appendingPathComponent("report.json"))
          try report.markdown.write(
            to: directory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        }
      }
      print("LiveEval: \(preset.id), \(runs.count) cases; report: \(directory.path)")
    }
  }
}
