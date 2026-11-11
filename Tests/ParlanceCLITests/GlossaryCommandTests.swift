import Foundation
import Testing
import os

@testable import ParlanceCLI
@testable import ParlanceCore

private final class GlossaryCLI: Sendable {
  struct Output {
    var out = ""
    var err = ""
  }
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(
    "parlance-glossary-cli-\(UUID().uuidString)")
  let output = OSAllocatedUnfairLock(initialState: Output())
  let provider: MockProvider
  var store: GlossaryStore {
    GlossaryStore(directory: home.appendingPathComponent(".config/parlance"))
  }

  init(
    reply: String =
      "<translation>译文</translation><plain>说明</plain><terms><term><word>rate limits</word><meaning>模型的释义</meaning><here>说明</here></term></terms>",
    fail: Bool = false
  ) {
    provider = MockProvider(scripts: [
      fail ? [.error(.auth(status: 401))] : [.event(.text(reply)), .event(.finished(.stop))]
    ])
  }
  deinit { try? FileManager.default.removeItem(at: home) }
  func run(
    _ arguments: [String], config: String? = nil, tty: Bool = false, store: GlossaryStore? = nil,
    timeZone: TimeZone = .current, date: Date = Date(timeIntervalSince1970: 1_794_355_200)
  ) async -> Int32 {
    output.withLock { $0 = Output() }
    var environment = CLIEnvironment(
      variables: ["OPENAI_API_KEY": "fake-test-key", "XDG_CONFIG_HOME": "/fictional-config"],
      stdinIsTTY: true, stdoutIsTTY: tty, stderrIsTTY: false,
      readStdin: {
        Issue.record("Unexpected stdin read")
        return Data()
      },
      stdout: { text in self.output.withLock { $0.out += text } },
      stderr: { text in self.output.withLock { $0.err += text } },
      makeProvider: { _ in self.provider },
      homeDirectory: home.path, readConfig: { _ in config.map { Data($0.utf8) } },
      wallDate: { date })
    environment.timeZone = timeZone
    environment.glossaryStoreOverride = store
    return await CLIEnvironment.$override.withValue(environment) {
      await PL.execute(arguments: arguments).rawValue
    }
  }
  var out: String { output.withLock { $0.out } }
  var err: String { output.withLock { $0.err } }
}

@Suite(.timeLimit(.minutes(1)))
struct GlossaryCommandTests {
  @Test func commandsUseHomeAndConfiguredPair() async throws {
    let cli = GlossaryCLI()
    #expect(await cli.run(["glossary", "path"]) == 0)
    #expect(cli.out == cli.store.path.path + "\n")
    #expect(!FileManager.default.fileExists(atPath: cli.home.path))
    #expect(await cli.run(["glossary", "list", "--json"]) == 0)
    #expect(cli.out == "[]\n")
    #expect(!FileManager.default.fileExists(atPath: cli.home.path))
    #expect(await cli.run(["glossary", "add", "Rate Limit", "速率限制", "--note", "我的译法"]) == 0)
    #expect(cli.err == "added\n")
    #expect(await cli.run(["glossary", "add", "rate limit", "限速"]) == 0)
    #expect(cli.err == "updated\n")
    #expect(
      await cli.run(
        ["glossary", "add", "rate limit", "limite"], config: "native_language = \"fr\"") == 0)
    #expect(cli.err == "added\n")
    #expect(await cli.run(["glossary", "list"]) == 0)
    #expect(cli.out == "rate limit = 限速\n")
    #expect(await cli.run(["glossary", "list", "--json"]) == 0)
    let entries = try JSONDecoder().decode([GlossaryEntry].self, from: Data(cli.out.utf8))
    #expect(entries.count == 1)
    #expect(entries.first?.native == "限速")
    #expect(await cli.run(["glossary", "export", "--anki"]) == 0)
    #expect(cli.out == Glossary.anki(entries, targetLanguage: "en", nativeLanguage: "zh-Hans"))
    #expect(!cli.out.contains("limite"))
    #expect(await cli.run(["glossary", "export"]) == 64)
    #expect(await cli.run(["glossary", "remove", " RATE LIMIT "]) == 0)
    #expect(cli.err == "removed\n")
    #expect(cli.store.read().entries.map(\.native) == ["limite"])
    #expect(await cli.run(["glossary", "remove", "missing"]) == 0)
    #expect(cli.err == "not found\n")
    #expect(cli.provider.recordedRequests.isEmpty)
  }

  @Test func admissionExitNamesFieldAndDoesNotWrite() async {
    let cli = GlossaryCLI()
    for (arguments, field) in [
      (["glossary", "add", "⟦bad", "正常"], "target"),
      (["glossary", "add", "safe", "api_key=\"fake-test-secret\""], "native"),
      (["glossary", "add", "safe", "正常", "--note", String(repeating: "a", count: 201)], "note"),
    ] {
      #expect(await cli.run(arguments) == 64)
      #expect(cli.err.contains("field \(field)"))
      #expect(!cli.err.contains("fake-test-secret"))
      #expect(cli.out.isEmpty)
    }
    #expect(!FileManager.default.fileExists(atPath: cli.home.path))
  }

  @Test(arguments: [false, true], [false, true])
  func explainOutput(tty: Bool, json: Bool) async throws {
    let cli = GlossaryCLI()
    #expect(await cli.run(["glossary", "add", "rate limit", "限速", "--note", "原样显示"]) == 0)
    let original = try Data(contentsOf: cli.store.path)
    #expect(
      await cli.run(
        ["explain", "rate limits", "--show-sent", "--no-color"] + (json ? ["--json"] : []), tty: tty
      ) == 0)
    #expect(cli.err.contains("- rate limit = 限速 (原样显示)"))
    #expect(!cli.out.contains("模型的释义"))
    if json {
      let object = try #require(
        JSONSerialization.jsonObject(with: Data(cli.out.utf8)) as? [String: Any])
      let result = try #require(object["result"] as? [String: Any])
      let entries = try #require(result["glossary"] as? [[String: Any]])
      #expect(entries.count == 1)
      #expect(entries.first?["native"] as? String == "限速")
      #expect(entries.first?["note"] as? String == "原样显示")
      #expect((result["terms"] as? [Any])?.isEmpty == true)
    } else {
      #expect(cli.out == "译文\nPlain: 说明\nTerms:\nGlossary:\n- rate limit: 限速 (原样显示)\n")
    }
    #expect(try Data(contentsOf: cli.store.path) == original)
  }

  @Test func documentAndFixJSONAndFailureShowSent() async throws {
    let document = GlossaryCLI(
      reply:
        "<gist>摘要</gist><decisions></decisions><parts><part><heading>标题</heading><plain>正文</plain></part></parts><terms></terms>"
    )
    #expect(await document.run(["glossary", "add", "rate limit", "限速"]) == 0)
    for flags in [[], ["--json"], ["--no-color"]] {
      #expect(
        await document.run(
          ["explain", "rate limit", "--doc"] + flags, tty: flags == ["--no-color"]) == 0)
      #expect(
        document.out.contains(
          flags == ["--json"] ? "\"glossary\"" : "Terms:\nGlossary:\n- rate limit: 限速\n"))
    }
    let fix = GlossaryCLI(
      reply:
        "<best>Rate limits.</best><gloss>限速。</gloss><alts><alt><text>Rate limits!</text><note>说明</note></alt></alts>"
    )
    #expect(await fix.run(["glossary", "add", "rate limit", "限速"]) == 0)
    let original = try Data(contentsOf: fix.store.path)
    #expect(await fix.run(["fix", "rate limit", "--json", "--show-sent"]) == 0)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(fix.out.utf8)) as? [String: Any])
    #expect(
      ((object["result"] as? [String: Any])?["glossary"] as? [[String: Any]])?.first?["native"]
        as? String == "限速")
    #expect(fix.err.hasPrefix(fix.provider.recordedRequests[0].messages[1].content + "\n"))
    #expect(await fix.run(["fix", "rate limit"]) == 0)
    #expect(fix.out == "Rate limits.\n")
    #expect(try Data(contentsOf: fix.store.path) == original)
    let failure = GlossaryCLI(fail: true)
    #expect(await failure.run(["glossary", "add", "rate limit", "限速"]) == 0)
    #expect(await failure.run(["fix", "rate limit", "--show-sent"]) == 3)
    #expect(failure.err.hasPrefix(failure.provider.recordedRequests[0].messages[1].content + "\n"))
    #expect(failure.err.contains("authentication"))
    #expect(failure.out.isEmpty)
  }

  @Test(arguments: ["fix", "explain"])
  func badLinesAndReadLimitWarnOnceWithoutBlocking(_ command: String) async throws {
    let reply =
      command == "fix"
      ? "<best>Rate limits.</best><gloss>限速</gloss><alts><alt><text>Rate limits!</text><note>说明</note></alt></alts>"
      : "<translation>译文</translation><plain>说明</plain><terms></terms>"
    let cli = GlossaryCLI(reply: reply)
    #expect(await cli.run(["glossary", "add", "rate limit", "限速"]) == 0)
    let head = try Data(contentsOf: cli.store.path) + Data("broken\n{}\n".utf8)
    let original = head + Data(repeating: 120, count: GlossaryStore.readLimit - head.count + 10)
    try original.write(to: cli.store.path)
    #expect(await cli.run([command, "rate limit", "--show-sent"]) == 0)
    #expect(cli.err.components(separatedBy: "skipped 2 invalid lines").count == 2)
    #expect(cli.err.components(separatedBy: "ignored content beyond 1 MiB").count == 2)
    #expect(
      cli.provider.recordedRequests.first?.messages.last?.content.contains("- rate limit = 限速")
        == true)
    #expect(try Data(contentsOf: cli.store.path) == original)
  }

  @Test func disabledMeansNoReadAndConfigIsTyped() async throws {
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let files = GlossaryStore.Files(
      read: { _, _ in
        reads.withLock { $0 += 1 }
        throw CocoaError(.fileReadUnknown)
      },
      locked: { _, _ in Issue.record("Unexpected write") },
      replace: { _, _ in Issue.record("Unexpected write") })
    let cli = GlossaryCLI(fail: true)
    let store = GlossaryStore(directory: cli.home, files: files)
    for command in ["fix", "explain"] {
      #expect(await cli.run([command, "rate limit", "--no-glossary"], store: store) == 3)
      #expect(
        await cli.run([command, "rate limit"], config: "glossary = false", store: store) == 3)
      #expect(
        await cli.run(
          [command, "rate limit", "--no-glossary"], config: "glossary = true", store: store) == 3)
    }
    #expect(reads.withLock { $0 } == 0)
    #expect(
      await cli.run(["explain", "rate limit"], config: "glossary = \"false\"", store: store) == 78)
    #expect(cli.err.contains("glossary"))
    #expect(await cli.run(["explain", "rate limit"], store: store) == 3)
    #expect(reads.withLock { $0 } == 1)
    #expect(cli.err.contains("could not read"))
    #expect(await cli.run(["config", "show"], config: "glossary = false") == 0)
    #expect(cli.out.contains("glossary = false"))
  }

  @Test(arguments: [false, true]) func watchDisableDoesNotRead(useFlag: Bool) async throws {
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let files = GlossaryStore.Files(
      read: { _, _ in
        reads.withLock { $0 += 1 }
        return (Data(), false)
      },
      locked: { _, _ in Issue.record("Unexpected write") },
      replace: { _, _ in Issue.record("Unexpected write") })
    let fixture = try SessionWatchFixture()
    try fixture.append(fixture.records(1, reply: "rate limit"))
    var environment = fixture.environment(config: useFlag ? nil : "glossary = false")
    environment.glossaryStoreOverride = GlossaryStore(
      directory: FileManager.default.temporaryDirectory, files: files)
    let saved = environment
    let task = Task { await fixture.run(saved, options: useFlag ? ["--no-glossary"] : []) }
    defer { fixture.stop(task) }
    try await fixture.requestsFinished.wait()
    fixture.signal()
    #expect(await fixture.result(task) == 130)
    #expect(reads.withLock { $0 } == 0)
  }
}

extension GlossaryCommandTests {
  @Test func missingRemoveAndLocalAddedDate() async throws {
    let cli = GlossaryCLI()
    #expect(await cli.run(["glossary", "remove", "missing"]) == 0)
    #expect(!FileManager.default.fileExists(atPath: cli.home.path))
    // The injected clock is November 10 at 17:00 UTC, or November 11 at 01:00 in UTC+8.
    #expect(
      await cli.run(
        ["glossary", "add", "term", "词语"], timeZone: TimeZone(secondsFromGMT: 8 * 3600)!,
        date: Date(timeIntervalSince1970: 1_794_330_000)) == 0)
    #expect(cli.store.read().entries.first?.added == "2026-11-11")
  }

  @Test func glossaryIOFailuresExit74() async throws {
    let cli = GlossaryCLI()
    let failingRead = GlossaryStore.Files(
      read: { _, _ in throw CocoaError(.fileReadNoPermission) },
      locked: { _, body in try body() }, replace: { _, _ in Issue.record("Unexpected write") },
      exists: { _ in true })
    let readStore = GlossaryStore(directory: cli.home, files: failingRead)
    for arguments in [
      ["list"], ["list", "--json"], ["export", "--anki"], ["add", "term", "词语"],
      ["remove", "term"],
    ] {
      #expect(await cli.run(["glossary"] + arguments, store: readStore) == 74)
      #expect(cli.out.isEmpty)
    }
    let bytes =
      try JSONEncoder().encode(GlossaryEntry(target: "term", native: "词语", added: "2026-11-11"))
      + Data([10])
    let failingWrite = GlossaryStore.Files(
      read: { _, _ in (bytes, false) },
      locked: { _, body in try body() },
      replace: { _, _ in throw CocoaError(.fileWriteNoPermission) }, exists: { _ in true })
    let writeStore = GlossaryStore(directory: cli.home, files: failingWrite)
    for arguments in [["add", "term", "新词"], ["remove", "term"]] {
      #expect(await cli.run(["glossary"] + arguments, store: writeStore) == 74)
    }
  }

  @Test func watchSendsMatchesAndWarnsOncePerRun() async throws {
    let bytes =
      try JSONEncoder().encode(
        GlossaryEntry(target: "rate limit", native: "限速", added: "2026-11-11"))
      + Data("\nbroken\n".utf8)
    let files = GlossaryStore.Files(
      read: { _, _ in (bytes, true) },
      locked: { _, _ in Issue.record("Unexpected write") },
      replace: { _, _ in Issue.record("Unexpected write") })
    for _ in 0..<2 {
      let fixture = try SessionWatchFixture()
      try fixture.append(fixture.records(1, reply: "rate limit"))
      var environment = fixture.environment()
      environment.glossaryStoreOverride = GlossaryStore(
        directory: FileManager.default.temporaryDirectory, files: files)
      let saved = environment
      let task = Task { await fixture.run(saved) }
      defer { fixture.stop(task) }
      try await fixture.handledCompletions.wait()
      try fixture.append(fixture.records(2, reply: "rate limits"))
      try await fixture.tick()
      try await fixture.handledCompletions.wait(2)
      fixture.signal()
      #expect(await fixture.result(task) == 130)
      #expect(fixture.provider.recordedRequests.count == 2)
      #expect(
        fixture.provider.recordedRequests.allSatisfy {
          $0.messages[1].content.contains("\n\nGlossary:")
            && $0.messages[1].content.contains("- rate limit = 限速")
        })
      #expect(fixture.error.components(separatedBy: "skipped 1 invalid lines").count == 2)
      #expect(fixture.error.components(separatedBy: "ignored content beyond 1 MiB").count == 2)
    }
  }
}
