import Foundation

struct EvalAggregate: Codable, Sendable {
  var preset: String
  var group: String
  var runs: Int
  var firstTokenSamples: Int
  var firstTokenP50: Double?
  var firstTokenP95: Double?
  var totalP50: Double?
  var totalP95: Double?
  var sectionsComplete: Int
  var sectionCompleteness: Double
  var termPasses: Int
  var termVersions: Int
  var termProtectionRate: Double?
  var residueCount: Int
  var strictRetries: Int
  var fallbacks: Int
  var caseAFixesInReply: Int?
  var caseAFixesInResult: Int?
  var failures: [String: Int]

  /// Nearest-rank percentile; missing first-token observations are omitted, never treated as zero.
  static func percentile(_ values: [Double], _ quantile: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[max(0, Int(ceil(Double(sorted.count) * quantile)) - 1)]
  }

  init(preset: String, group: String, values: [EvalRun]) {
    self.preset = preset
    self.group = group
    runs = values.count
    let first = values.compactMap(\.firstTokenSeconds)
    firstTokenSamples = first.count
    firstTokenP50 = Self.percentile(first, 0.5)
    firstTokenP95 = Self.percentile(first, 0.95)
    totalP50 = Self.percentile(values.map(\.totalSeconds), 0.5)
    totalP95 = Self.percentile(values.map(\.totalSeconds), 0.95)
    let metrics = values.map(\.recording.metrics)
    sectionsComplete = metrics.filter(\.sectionsComplete).count
    sectionCompleteness = runs == 0 ? 0 : Double(sectionsComplete) / Double(runs)
    termPasses = metrics.reduce(0) { $0 + $1.termPasses }
    termVersions = metrics.reduce(0) { $0 + $1.termVersions }
    termProtectionRate = termVersions == 0 ? nil : Double(termPasses) / Double(termVersions)
    residueCount = metrics.filter(\.bestHasResidue).count
    strictRetries = metrics.filter(\.strictRetryUsed).count
    fallbacks = metrics.filter(\.fallback).count
    caseAFixesInReply = metrics.reduce(0) { $0 + ($1.caseAFixesInReply ?? 0) }
    caseAFixesInResult = metrics.reduce(0) { $0 + ($1.caseAFixesInResult ?? 0) }
    failures = [:]
    for metric in metrics {
      for (code, count) in metric.failures { failures[code, default: 0] += count }
    }
  }
}

struct EvalReport: Codable, Sendable {
  var schemaVersion = 1
  var timestamp: String
  var runs: [EvalRun]
  var aggregates: [EvalAggregate]

  init(timestamp: String, runs: [EvalRun]) {
    self.timestamp = timestamp
    self.runs = runs
    aggregates = []
    for preset in Set(runs.map(\.recording.preset)).sorted() {
      let providerRuns = runs.filter { $0.recording.preset == preset }
      aggregates.append(EvalAggregate(preset: preset, group: "all", values: providerRuns))
      let groups = Dictionary(grouping: providerRuns) {
        "\($0.recording.kind.rawValue)/\($0.recording.testCase.group)"
      }
      for group in groups.keys.sorted() {
        aggregates.append(EvalAggregate(preset: preset, group: group, values: groups[group]!))
      }
    }
  }

  var markdown: String {
    func number(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "N/A" }
    var lines = [
      "# Prompt eval report",
      "",
      "UTC：\(timestamp)。首字为首个非空 text 事件；总时延含严格重试。单位：秒。",
      "分位数采用 nearest-rank；未收到文本的 run 不进入首字分位数，样本数单列。",
      "术语统计覆盖所有尝试中实际出现的 best 与全部 alt/text（含未闭合版本）；解释为 N/A。",
      "Case A fixes 按核心输入分类：Reply 统计任一次尝试含 <fixes> 的 run，Result 统计最终结果仍含该节或纠错条目的 run；旧报告缺项按 0 汇总。",
      "failure 按失败版本或尝试计数，同一 run 可贡献多项。人工评分尚未完成。",
      "",
      "| Preset | Category | Runs | First samples | First p50 | First p95 | Total p50 | Total p95 | Sections | Terms | Residue | Strict retry | Fallback | Case A fixes reply | Case A fixes result | Failures by code |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for value in aggregates {
      let failures = value.failures.keys.sorted().map { "\($0): \(value.failures[$0]!)" }.joined(
        separator: ", ")
      lines.append(
        "| \(value.preset) | \(value.group) | \(value.runs) | \(value.firstTokenSamples) | "
          + "\(number(value.firstTokenP50)) | \(number(value.firstTokenP95)) | "
          + "\(number(value.totalP50)) | \(number(value.totalP95)) | "
          + "\(value.sectionsComplete)/\(value.runs) (\(number(value.sectionCompleteness))) | "
          + "\(value.termPasses)/\(value.termVersions) (\(number(value.termProtectionRate))) | "
          + "\(value.residueCount) | \(value.strictRetries) | \(value.fallbacks) | "
          + "\(value.caseAFixesInReply ?? 0) | \(value.caseAFixesInResult ?? 0) | \(failures.isEmpty ? "none" : failures) |"
      )
    }
    return lines.joined(separator: "\n") + "\n"
  }
}
