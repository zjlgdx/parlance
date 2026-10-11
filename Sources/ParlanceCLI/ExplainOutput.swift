import Foundation
import ParlanceCore

struct ExplainOutput {
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

  mutating func startOperation() { rendered.removeAll() }

  mutating func render(_ snapshot: SectionsSnapshot) {
    guard environment.stdoutIsTTY && !json else { return }
    for (index, section) in snapshot.sections.enumerated()
    where section.isClosed && !rendered.contains(index) {
      rendered.insert(index)
      writeSection(section)
    }
  }

  private func writeSection(_ section: SectionNode) {
    switch section.name {
    case "translation": write(section.text, style: "1")
    case "plain": write("Plain: \(section.text)", style: "2")
    case "terms":
      write("Terms:")
      for term in section.children {
        let value = { (name: String) in term.children.first { $0.name == name }?.text ?? "" }
        let ipa = value("ipa")
        write(
          "- \(value("word"))\(ipa.isEmpty ? "" : " (\(ipa))"): \(value("meaning")); \(value("here"))"
        )
      }
    case "vocab": write("Vocab: \(section.text)")
    case "domain": write("Domain: \(section.text)")
    default: break
    }
  }

  mutating func finishOperation(_ snapshot: SectionsSnapshot, eligibility: Eligibility) {
    guard environment.stdoutIsTTY && !json, eligibility != .incomplete(.error(.aborted)) else {
      return
    }
    if eligibility == .eligible {
      render(snapshot)
    } else if !snapshot.rawText.isEmpty, rendered.isEmpty || snapshot.isMalformed {
      write(snapshot.rawText)
    }
  }

  private func write(_ text: String, style: String? = nil) {
    let safe = TerminalText.display(text)
    if color, let style {
      environment.stdout("\u{1B}[\(style)m\(safe)\u{1B}[0m\n")
    } else {
      environment.stdout(safe + "\n")
    }
  }

  func complete(
    quick: ExplainQuick?, deep: [ExplainDeep], diagnostic: RewriteDiagnostic?,
    section: ExplainDeepSection?, provider: ResolvedProvider, timing: [String: JSONValue]
  ) throws {
    if json {
      try writeJSON(
        quick: quick, deep: deep, diagnostic: diagnostic, section: section,
        provider: provider, timing: timing)
    } else if environment.stdoutIsTTY {
      if let diagnostic, let section {
        write("\(section.rawValue): \(diagnostic.message)")
      }
    } else if diagnostic == nil, let quick {
      for section in quick.snapshot.sections { writeSection(section) }
      for result in deep {
        for section in result.snapshot.sections { writeSection(section) }
      }
    }
  }

  private func writeJSON(
    quick: ExplainQuick?, deep: [ExplainDeep], diagnostic: RewriteDiagnostic?,
    section: ExplainDeepSection?, provider: ResolvedProvider, timing: [String: JSONValue]
  ) throws {
    func safe(_ text: String) -> JSONValue { .string(TerminalText.display(text)) }
    var body: JSONValue = .null
    if diagnostic == nil, let sections = quick?.sections {
      // Every repeat is executed and printed in plain text; the fixed JSON shape keeps the last one.
      func deepText(_ name: ExplainDeepSection) -> JSONValue {
        deep.last { $0.section == name }?.snapshot.sections.first.map { safe($0.text) } ?? .null
      }
      body = .object([
        "translation": safe(sections.translation), "plain": safe(sections.plain),
        "terms": .array(
          sections.terms.map {
            .object([
              "word": safe($0.word), "ipa": $0.ipa.map(safe) ?? .null,
              "meaning": safe($0.meaning), "here": safe($0.here),
            ])
          }),
        "vocab": deepText(.vocab), "domain": deepText(.domain),
      ])
    }
    let error: JSONValue =
      diagnostic.map {
        var fields: [String: JSONValue] = [
          "code": .string($0.code), "message": .string($0.message),
          "http_status": $0.httpStatus.map { .integer($0) } ?? .null,
          "provider_code": $0.providerCode.map { .string($0.rawValue) } ?? .null,
        ]
        if let section { fields["section"] = .string(section.rawValue) }
        return .object(fields)
      } ?? .null
    let usages = ([quick?.usage] + deep.map(\.usage)).compactMap { $0 }
    let usage: JSONValue =
      usages.isEmpty
      ? .null
      : .object([
        "prompt_tokens": .integer(usages.reduce(0) { $0 + $1.promptTokens }),
        "completion_tokens": .integer(usages.reduce(0) { $0 + $1.completionTokens }),
      ])
    let object = JSONValue.object([
      "schema": .integer(1), "command": .string("explain"),
      "status": .string(diagnostic == nil ? "ok" : "error"),
      "provider": .string(provider.preset.id), "model": .string(safeConfigValue(provider.model)),
      "result": body, "fallback": .null, "usage": usage, "timing": .object(timing), "error": error,
    ])
    environment.stdout(String(decoding: try JSONEncoder().encode(object), as: UTF8.self) + "\n")
  }
}
