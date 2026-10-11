import ArgumentParser
import Testing

@testable import ParlanceCLI

struct RootCommandTests {
  @Test func versionFlagPrintsTheVersionConstantAndExitsCleanly() {
    #expect {
      _ = try PL.parseAsRoot(["--version"])
    } throws: { error in
      PL.message(for: error) == Version.current && PL.exitCode(for: error) == .success
    }
  }

  @Test func commandIsNamedPl() {
    let usage = PL.helpMessage().split(separator: "\n").first { $0.hasPrefix("USAGE:") }
    #expect(usage?.split(separator: " ").dropFirst().first == "pl")
  }

  @Test func bareCommandPrintsHelpAndExitsCleanly() async throws {
    var command = try PL.parseAsRoot([]) as! any AsyncParsableCommand
    await #expect {
      try await command.run()
    } throws: { error in
      PL.message(for: error) == PL.helpMessage() && PL.exitCode(for: error) == .success
    }
  }
}
