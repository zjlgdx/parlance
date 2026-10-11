import Foundation
import ParlanceCore

struct FixOutput {
  let environment: CLIEnvironment
  let json: Bool
  let color: Bool
  private var rendered = Set<Int>()

  init(environment: CLIEnvironment, json: Bool, noColor: Bool) {
    self.environment = environment
    self.json = json
    color =
      environment.stdoutIsTTY && !noColor
      && (environment.variables["NO_COLOR"] ?? "").isEmpty
      && environment.variables["TERM"] != "dumb"
  }

  mutating func render(_ snapshot: SectionsSnapshot) {
    guard environment.stdoutIsTTY && !json else { return }
    for (index, section) in snapshot.sections.enumerated()
    where section.isClosed && !rendered.contains(index) {
      rendered.insert(index)
      switch section.name {
      case "best": write(section.text, style: "1")
      case "gloss": write(section.text, style: "2")
      case "alts":
        for (offset, alt) in section.children.enumerated() {
          write("\(offset + 1). \(alt.children.first { $0.name == "text" }?.text ?? "")")
          if let note = alt.children.first(where: { $0.name == "note" }) {
            write(note.text, style: "2")
          }
        }
      case "fixes":
        for fix in section.children { write("- \(fix.text)") }
      default: break
      }
    }
  }

  mutating func startNewBlock() {
    guard environment.stdoutIsTTY && !json else { return }
    write("---", style: "2")
    rendered.removeAll()
  }

  private func write(_ text: String, style: String? = nil) {
    let safe = TerminalText.display(text)
    if color, let style {
      environment.stdout("\u{1B}[\(style)m\(safe)\u{1B}[0m\n")
    } else {
      environment.stdout(safe + "\n")
    }
  }

  mutating func complete(
    _ result: RewriteResult, provider: ResolvedProvider, timing: [String: JSONValue]
  ) throws -> RewriteDiagnostic? {
    let diagnostic = RewriteDiagnostic.forEligibility(result.bestEligibility)
    if json {
      try writeJSON(result, diagnostic: diagnostic, provider: provider, timing: timing)
    } else if environment.stdoutIsTTY {
      if diagnostic?.code == "aborted" { return diagnostic }
      if result.fallback == .firstBest, let sections = result.sections {
        startNewBlock()
        write("retry failed; using first result", style: "2")
        write(sections.best, style: "1")
      } else if diagnostic == nil || result.sections != nil {
        render(result.snapshot)
      } else if !result.snapshot.rawText.isEmpty, rendered.isEmpty || result.snapshot.isMalformed {
        // Output whose structure is not valid (including a section left open by an interruption) is
        // shown whole; a truncated reply whose sections were all rendered while streaming is not
        // repeated.
        write(result.snapshot.rawText)
      }
      let versions =
        [("best", result.bestEligibility)]
        + result.altEligibility.enumerated().map { ("alt \($0.offset + 1)", $0.element) }
      for (name, eligibility) in versions {
        if eligibility == .placeholdersChanged {
          write("\(name): identifiers changed; not eligible")
        } else if eligibility == .placeholdersUnavailable {
          write("\(name): no free placeholder delimiters; not eligible")
        }
      }
    } else if diagnostic == nil, let sections = result.sections {
      write(sections.best)
    }
    return diagnostic
  }

  func failure(
    _ error: LLMError, provider: ResolvedProvider, timing: [String: JSONValue]
  ) throws -> RewriteDiagnostic {
    let diagnostic = RewriteDiagnostic.forError(error)
    if json { try writeJSON(nil, diagnostic: diagnostic, provider: provider, timing: timing) }
    return diagnostic
  }

  /// A failure before any request, such as key lookup ending with exit 3.
  func failure(
    _ diagnostic: RewriteDiagnostic, provider: ResolvedProvider, timing: [String: JSONValue]
  ) throws {
    if json { try writeJSON(nil, diagnostic: diagnostic, provider: provider, timing: timing) }
  }

  private func writeJSON(
    _ result: RewriteResult?, diagnostic: RewriteDiagnostic?, provider: ResolvedProvider,
    timing: [String: JSONValue]
  ) throws {
    var body: JSONValue = .null
    if diagnostic == nil, let result, let sections = result.sections {
      let alternatives: [JSONValue] = sections.alts.enumerated().map { index, alt in
        let eligibility = result.altEligibility[index]
        if let error = RewriteDiagnostic.forEligibility(eligibility) {
          return .object(["eligible": .bool(false), "reason": .string(error.code)])
        }
        return .object([
          "eligible": .bool(true), "text": .string(TerminalText.display(alt.text)),
          "note": alt.note.map { .string(TerminalText.display($0)) } ?? .null,
        ])
      }
      body = .object([
        "best": .object([
          "eligible": .bool(true), "text": .string(TerminalText.display(sections.best)),
        ]),
        "gloss": sections.gloss.map { .string(TerminalText.display($0)) } ?? .null,
        "alts": .array(alternatives),
        "fixes": .array(sections.fixes.map { .string(TerminalText.display($0)) }),
      ])
    }
    let error: JSONValue =
      diagnostic.map {
        .object([
          "code": .string($0.code), "section": .null, "message": .string($0.message),
          "http_status": $0.httpStatus.map { .integer($0) } ?? .null,
          "provider_code": $0.providerCode.map { .string($0.rawValue) } ?? .null,
        ])
      } ?? .null
    let usage: JSONValue =
      result?.usage.map {
        .object([
          "prompt_tokens": .integer($0.promptTokens),
          "completion_tokens": .integer($0.completionTokens),
        ])
      } ?? .null
    let object = JSONValue.object([
      "schema": .integer(1), "command": .string("fix"),
      "status": .string(diagnostic == nil ? "ok" : "error"),
      "provider": .string(provider.preset.id),
      "model": .string(safeConfigValue(provider.model)),
      "result": body, "fallback": result?.fallback == .firstBest ? .string("first_best") : .null,
      "usage": usage, "timing": .object(timing),
      "error": error,
    ])
    let data = try JSONEncoder().encode(object)
    environment.stdout(String(decoding: data, as: UTF8.self) + "\n")
  }
}
