import ArgumentParser
import Foundation
import ParlanceCore

extension CLIEnvironment {
  var glossaryStore: GlossaryStore {
    glossaryStoreOverride
      ?? GlossaryStore(
        directory: URL(fileURLWithPath: homeDirectory).appendingPathComponent(".config/parlance"))
  }
}

func glossaryJSON(_ entries: [GlossaryEntry]) -> JSONValue {
  .array(
    entries.map { entry in
      .object([
        "target": .string(TerminalText.display(entry.target)),
        "native": .string(TerminalText.display(entry.native)),
        "note": entry.note.map { .string(TerminalText.display($0)) } ?? .null,
      ])
    })
}

public struct GlossaryCommand: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "glossary", abstract: "Manage your local terms and translations.",
    subcommands: [Add.self, List.self, Remove.self, Export.self, Path.self])
  public init() {}

  private static func pair(_ environment: CLIEnvironment) throws -> (String, String) {
    let config = try CLIConfiguration.load(environment)
    return (config.targetLanguage ?? "en", config.nativeLanguage ?? "zh-Hans")
  }

  private static func entries(_ environment: CLIEnvironment) throws -> [GlossaryEntry] {
    let (target, native) = try pair(environment)
    let read = environment.glossaryStore.read()
    if read.unreadable {
      try cliFail(74, "could not read the glossary. Check file permissions.", environment)
    }
    for warning in read.warnings { environment.stderr("pl: \(warning)\n") }
    return read.entries.filter { $0.targetLanguage == target && $0.nativeLanguage == native }
  }

  struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Save a term, replacing its previous translation.")
    @Argument var target: String
    @Argument var native: String
    @Option var note: String?

    mutating func run() async throws {
      let environment = CLIEnvironment.current
      let (targetLanguage, nativeLanguage) = try GlossaryCommand.pair(environment)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withFullDate]
      formatter.timeZone = environment.timeZone
      let entry = GlossaryEntry(
        target: target, native: native, note: note,
        targetLanguage: targetLanguage, nativeLanguage: nativeLanguage,
        added: formatter.string(from: environment.wallDate()))
      do {
        let updated = try environment.glossaryStore.add(entry)
        environment.stderr(updated ? "updated\n" : "added\n")
      } catch let error as GlossaryEntry.AdmissionError {
        try cliFail(
          64,
          "invalid glossary field \(error.field). Check its length and remove secrets or protection delimiters.",
          environment)
      } catch {
        try cliFail(
          74, "could not read or write the glossary. Check file permissions.", environment)
      }
    }
  }

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List entries for the configured language pair.")
    @Flag var json = false
    mutating func run() async throws {
      let environment = CLIEnvironment.current
      let entries = try GlossaryCommand.entries(environment)
      if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        environment.stdout(String(decoding: try encoder.encode(entries), as: UTF8.self) + "\n")
      } else {
        for entry in entries {
          environment.stdout(
            TerminalText.display(
              "\(entry.target) = \(entry.native)" + (entry.note.map { " (\($0))" } ?? "")) + "\n")
        }
      }
    }
  }

  struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Remove a term from the configured language pair.")
    @Argument var target: String
    mutating func run() async throws {
      let environment = CLIEnvironment.current
      let (targetLanguage, nativeLanguage) = try GlossaryCommand.pair(environment)
      do {
        let removed = try environment.glossaryStore.remove(
          target: target,
          targetLanguage: targetLanguage, nativeLanguage: nativeLanguage)
        environment.stderr(removed ? "removed\n" : "not found\n")
      } catch {
        try cliFail(
          74, "could not read or write the glossary. Check file permissions.", environment)
      }
    }
  }

  struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write an Anki TSV to stdout.")
    @Flag var anki = false
    mutating func run() async throws {
      let environment = CLIEnvironment.current
      guard anki else { try cliFail(64, "choose --anki for glossary export.", environment) }
      let (target, native) = try GlossaryCommand.pair(environment)
      environment.stdout(
        Glossary.anki(
          try GlossaryCommand.entries(environment), targetLanguage: target, nativeLanguage: native))
    }
  }

  struct Path: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Print the shared glossary file path.")
    mutating func run() async throws {
      let environment = CLIEnvironment.current
      environment.stdout(TerminalText.display(environment.glossaryStore.path.path) + "\n")
    }
  }
}
