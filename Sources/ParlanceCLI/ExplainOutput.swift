import Foundation
import ParlanceCore

struct ExplainOutput {
  let environment: CLIEnvironment
  let json: Bool
  let color: Bool
  let mode: ExplainMode
  private var rendered = Set<[Int]>()
  /// The prepared input sent; command parts and document fields use it when decoding entities.
  var input = ""

  init(environment: CLIEnvironment, json: Bool, noColor: Bool, mode: ExplainMode = .quick) {
    self.environment = environment
    self.json = json
    self.mode = mode
    color =
      environment.stdoutIsTTY && !noColor
      && (environment.variables["NO_COLOR"] ?? "").isEmpty
      && environment.variables["TERM"] != "dumb"
  }

  mutating func startOperation() { rendered.removeAll() }

  mutating func render(_ snapshot: SectionsSnapshot) {
    guard environment.stdoutIsTTY && !json else { return }
    guard mode == .document else {
      for (index, section) in snapshot.sections.enumerated()
      where section.isClosed && rendered.insert([index]).inserted {
        writeSection(section, input: input)
      }
      return
    }
    // Decoded only when something new has closed: the entity check reads the whole document.
    var cached: ExplainDocumentSections?
    let input = self.input
    func decoded() -> ExplainDocumentSections {
      if let cached { return cached }
      let built = ExplainDocumentSections(snapshot: snapshot, input: input)
      cached = built
      return built
    }
    // Only the first section of each name is shown; it is the one the decoded view reads, and a
    // repeated section makes the reply malformed (its raw text is written at the end).
    var seen = Set<String>()
    for (index, section) in snapshot.sections.enumerated() where seen.insert(section.name).inserted
    {
      if section.name == "parts" {
        for (childIndex, part) in section.children.enumerated()
        where part.isClosed && !rendered.contains([index, childIndex]) {
          let parts = decoded().parts
          guard parts.indices.contains(childIndex) else { continue }
          rendered.insert([index, childIndex])
          writeDocumentPart(parts[childIndex])
        }
      } else if section.isClosed && rendered.insert([index]).inserted {
        writeDocumentSection(section.name, sections: decoded())
      }
    }
  }

  private func writeDocumentPart(_ part: ExplainDocumentSections.Part) {
    write("## \(part.heading)", style: "1")
    write(part.plain)
  }

  private func writeDocumentSection(_ name: String, sections: ExplainDocumentSections) {
    switch name {
    case "gist": write("Gist: \(sections.gist)", style: "1")
    case "decisions":
      if !sections.decisions.isEmpty {
        write("Decisions:")
        for decision in sections.decisions { write("- \(decision)") }
      }
    case "parts":
      for part in sections.parts { writeDocumentPart(part) }
    case "terms":
      write("Terms:")
      for term in sections.terms {
        let ipa = term.ipa ?? ""
        write("- \(term.word)\(ipa.isEmpty ? "" : " (\(ipa))"): \(term.meaning); \(term.here)")
      }
    default: break
    }
  }

  private func writeSection(_ section: SectionNode, input: String) {
    switch section.name {
    case "translation": write(section.text, style: "1")
    case "plain": write("Plain: \(section.text)", style: "2")
    case "command":
      write("Command:")
      for part in section.children.map({ CommandPart(section: $0, input: input) }) {
        let effects = part.effects.map(\.rawValue).joined(separator: ", ")
        write("- \(part.code): \(part.does)\(effects.isEmpty ? "" : " [\(effects)]")")
      }
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
    section: ExplainDeepSection?, provider: ResolvedProvider, timing: [String: JSONValue],
    document: ExplainDocument? = nil
  ) throws {
    if json {
      try writeJSON(
        quick: quick, deep: deep, diagnostic: diagnostic, section: section,
        provider: provider, timing: timing, document: document)
    } else if environment.stdoutIsTTY {
      if let diagnostic, let section {
        write("\(section.rawValue): \(diagnostic.message)")
      }
    } else if diagnostic == nil, let sections = document?.sections {
      for name in ["gist", "decisions", "parts", "terms"] {
        writeDocumentSection(name, sections: sections)
      }
    } else if diagnostic == nil, let quick {
      for section in quick.snapshot.sections { writeSection(section, input: quick.subject.input) }
      for result in deep {
        for section in result.snapshot.sections {
          writeSection(section, input: quick.subject.input)
        }
      }
    }
  }

  private func writeJSON(
    quick: ExplainQuick?, deep: [ExplainDeep], diagnostic: RewriteDiagnostic?,
    section: ExplainDeepSection?, provider: ResolvedProvider, timing: [String: JSONValue],
    document: ExplainDocument?
  ) throws {
    func safe(_ text: String) -> JSONValue { .string(TerminalText.display(text)) }
    var body: JSONValue = .null
    if diagnostic == nil, let sections = document?.sections {
      body = .object([
        "gist": safe(sections.gist), "decisions": .array(sections.decisions.map(safe)),
        "parts": .array(
          sections.parts.map {
            .object(["heading": safe($0.heading), "plain": safe($0.plain)])
          }),
        "terms": .array(
          sections.terms.map {
            .object([
              "word": safe($0.word), "ipa": $0.ipa.map(safe) ?? .null,
              "meaning": safe($0.meaning), "here": safe($0.here),
            ])
          }),
      ])
    } else if diagnostic == nil, let sections = quick?.sections {
      // Every repeat is executed and printed in plain text; the fixed JSON shape keeps the last one.
      func deepText(_ name: ExplainDeepSection) -> JSONValue {
        deep.last { $0.section == name }?.snapshot.sections.first.map { safe($0.text) } ?? .null
      }
      body = .object([
        "translation": safe(sections.translation), "plain": safe(sections.plain),
        "command": sections.command.map { parts in
          .array(
            parts.map {
              .object([
                "code": safe($0.code), "does": safe($0.does),
                "effects": .array($0.effects.map { .string($0.rawValue) }),
              ])
            })
        } ?? .null,
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
    let usages = ([quick?.usage, document?.usage] + deep.map(\.usage)).compactMap { $0 }
    let usage: JSONValue =
      usages.isEmpty
      ? .null
      : .object([
        "prompt_tokens": .integer(usages.reduce(0) { $0 + $1.promptTokens }),
        "completion_tokens": .integer(usages.reduce(0) { $0 + $1.completionTokens }),
      ])
    let object = JSONValue.object([
      "schema": .integer(1), "command": .string("explain"),
      "mode": .string(mode.rawValue),
      "status": .string(diagnostic == nil ? "ok" : "error"),
      "provider": .string(provider.preset.id), "model": .string(safeConfigValue(provider.model)),
      "result": body, "fallback": .null, "usage": usage, "timing": .object(timing), "error": error,
    ])
    environment.stdout(String(decoding: try JSONEncoder().encode(object), as: UTF8.self) + "\n")
  }
}
