import ArgumentParser
import Foundation
import ParlanceCore
import Testing
import os

@testable import ParlanceCLI

private let validReply =
  "<best>Ship it.</best><gloss>发布。</gloss><alts><alt><text>Release it.</text><note>正式</note></alt></alts>"

private final class FixHarness: Sendable {
  struct State {
    var out = ""
    var err = ""
    var reads = 0
    var resolved: ResolvedProvider?
  }
  let state = OSAllocatedUnfairLock(initialState: State())
  let provider: MockProvider
  init(_ steps: [MockProvider.Step] = [.event(.text(validReply)), .event(.finished(.stop))]) {
    provider = MockProvider(scripts: [steps])
  }
  init(scripts: [[MockProvider.Step]]) {
    provider = MockProvider(scripts: scripts)
  }
  func run(
    _ arguments: [String] = ["fix", "input"], stdin: Data = Data(), inputTTY: Bool = false,
    outputTTY: Bool = false, errorTTY: Bool = false,
    variables: [String: String] = ["OPENAI_API_KEY": "fake-test-key"], config: String? = nil
  ) async -> Int32 {
    let environment = CLIEnvironment(
      variables: variables, stdinIsTTY: inputTTY, stdoutIsTTY: outputTTY, stderrIsTTY: errorTTY,
      readStdin: {
        self.state.withLock { $0.reads += 1 }
        return stdin
      },
      stdout: { text in self.state.withLock { $0.out += text } },
      stderr: { text in self.state.withLock { $0.err += text } },
      makeProvider: { resolved in
        self.state.withLock { $0.resolved = resolved }
        return self.provider
      }, readConfig: { _ in config.map { Data($0.utf8) } })
    return await CLIEnvironment.$override.withValue(environment) {
      await PL.execute(arguments: arguments).rawValue
    }
  }
  var output: String { state.withLock { $0.out } }
  var error: String { state.withLock { $0.err } }
}

struct FixCommandTests {
  @Test func entryPointHelpAndUsage() async {
    let root = FixHarness()
    #expect(await root.run([]) == 0)
    #expect(root.output.contains("USAGE: pl"))
    #expect(root.output.contains("fix"))
    #expect(root.error.isEmpty)
    #expect(root.provider.recordedRequests.isEmpty)
    for args in [
      ["fix", "x", "--tone", "invalid"], ["fix", "--model"],
      ["fix", "x", "--unknown\u{1B}[31m"],
    ] {
      let harness = FixHarness()
      #expect(await harness.run(args) == 64)
      #expect(harness.output.isEmpty)
      #expect(!harness.error.contains("\u{1B}"))
      #expect(harness.provider.recordedRequests.isEmpty)
    }
    let missingValue = FixHarness()
    #expect(await missingValue.run(["fix", "--model"]) == 64)
    #expect(missingValue.error.contains("--model"))
    #expect(missingValue.error.contains("Usage: pl fix"))
  }

  @Test func retryAndErrorJSON() async throws {
    for tty in [true, false] {
      let harness = FixHarness([
        .event(.retrying(after: .seconds(2), cause: .rateLimit)),
        .error(.invalidRequest(status: 404, providerCode: .modelNotFound)),
      ])
      #expect(await harness.run(["fix", "x", "--json"], errorTTY: tty) == 7)
      #expect(harness.error.contains("retrying in 2s (rate limited)") == tty)
      let object = try #require(
        JSONSerialization.jsonObject(with: Data(harness.output.utf8)) as? [String: Any])
      let error = try #require(object["error"] as? [String: Any])
      #expect(error["http_status"] as? Int == 404)
      #expect(error["provider_code"] as? String == "model_not_found")
      #expect(error["code"] as? String == "invalid_request")
      #expect(object["result"] is NSNull)
      #expect((object["timing"] as? [String: Any])?["retried"] as? Bool == true)
    }
    for (finish, code) in [
      (LLMFinishReason.length, "truncated"), (.contentFilter, "content_filtered"),
      (.other, "finish_other"),
    ] {
      let harness = FixHarness([.event(.text(validReply)), .event(.finished(finish))])
      #expect(await harness.run(["fix", "x", "--json"]) == 8)
      let object = try #require(
        JSONSerialization.jsonObject(with: Data(harness.output.utf8)) as? [String: Any])
      #expect((object["error"] as? [String: Any])?["code"] as? String == code)
      #expect(object["result"] is NSNull)
      #expect(!harness.output.contains("Ship it."))
    }
  }

  @Test func pipeGetsOnlyBest() async {
    let harness = FixHarness()
    #expect(await harness.run() == 0)
    #expect(harness.output == "Ship it.\n")
    #expect(harness.state.withLock { $0.reads } == 0)
  }

  @Test func malformedAndTruncated() async {
    for (text, reason) in [("raw <T>text", LLMFinishReason.stop), (validReply, .length)] {
      let harness = FixHarness([.event(.text(text)), .event(.finished(reason))])
      #expect(await harness.run() == 8)
      #expect(harness.output.isEmpty)
      #expect(!harness.error.isEmpty)
    }
    let tty = FixHarness([.event(.text("raw <T>text")), .event(.finished(.stop))])
    #expect(await tty.run(outputTTY: true) == 8)
    #expect(tty.output.contains("raw <T>text"))
    #expect(tty.error.contains("pl: could not recognise sections in the model output."))
    let partial = FixHarness([.event(.text("<best>unfinished")), .error(.transport)])
    #expect(await partial.run(outputTTY: true) == 4)
    #expect(partial.output.contains("unfinished"))
  }

  @Test func jsonObjects() async throws {
    for malformed in [false, true] {
      let harness = FixHarness([
        .event(.text(malformed ? "secret partial" : validReply)),
        .event(.usage(LLMUsage(promptTokens: 2, completionTokens: 3))), .event(.finished(.stop)),
      ])
      #expect(
        await harness.run(["fix", "input", "--json"], outputTTY: true) == (malformed ? 8 : 0))
      let object = try #require(
        JSONSerialization.jsonObject(with: Data(harness.output.utf8)) as? [String: Any])
      #expect(object["schema"] as? Int == 1)
      #expect(object["command"] as? String == "fix")
      #expect(object["provider"] as? String == "openai")
      #expect(object["model"] as? String == ProviderPreset.openai.defaultModel)
      #expect(object["fallback"] is NSNull)
      #expect((object["usage"] as? [String: Int])?["prompt_tokens"] == 2)
      let timing = try #require(object["timing"] as? [String: Any])
      #expect(timing["first_token_ms"] != nil)
      #expect(timing["total_ms"] != nil)
      #expect(timing["strict_retry"] as? Bool == false)
      #expect(timing["retried"] as? Bool == false)
      if malformed {
        #expect(object["status"] as? String == "error")
        #expect(object["result"] is NSNull)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "malformed_sections")
        for key in ["section", "http_status", "provider_code"] { #expect(error[key] is NSNull) }
        #expect(!harness.output.contains("secret partial"))
      } else {
        #expect(object["status"] as? String == "ok")
        #expect(object["error"] is NSNull)
        let result = try #require(object["result"] as? [String: Any])
        #expect((result["best"] as? [String: Any])?["text"] as? String == "Ship it.")
        #expect((result["best"] as? [String: Any])?["eligible"] as? Bool == true)
        #expect(result["gloss"] as? String == "发布。")
        #expect((result["alts"] as? [[String: Any]])?.count == 1)
        #expect((result["fixes"] as? [String]) == [])
      }
    }
  }

  @Test func usageAndInputRouting() async {
    for args in [
      ["fix"], ["fix", " \n"], ["fix", String(repeating: "x", count: 20_001)],
      ["fix", "x", "--provider", "unknown"],
    ] {
      let harness = FixHarness()
      #expect(await harness.run(args, inputTTY: true) == 64)
      #expect(harness.provider.recordedRequests.isEmpty)
      #expect(harness.state.withLock { $0.reads } == 0)
    }
    for args in [["fix"], ["fix", "-"]] {
      let harness = FixHarness()
      #expect(await harness.run(args, stdin: Data("from stdin".utf8)) == 0)
      #expect(harness.provider.recordedRequests.first?.messages.last?.content == "from stdin")
      #expect(harness.state.withLock { $0.reads } == 1)
    }
    let invalid = FixHarness()
    #expect(await invalid.run(["fix", "-"], stdin: Data([0xFF])) == 64)
    #expect(invalid.provider.recordedRequests.isEmpty)
    let joined = FixHarness()
    #expect(await joined.run(["fix", "hello", "world"]) == 0)
    #expect(joined.provider.recordedRequests.first?.messages.last?.content == "hello world")
  }

  @Test func providerSelection() async throws {
    for variables in [
      [:], ["PARLANCE_API_KEY": "fake"], ["OPENAI_API_KEY": "fake", "GEMINI_API_KEY": "fake"],
    ] {
      let harness = FixHarness()
      #expect(await harness.run(variables: variables) == 78)
      #expect(harness.provider.recordedRequests.isEmpty)
    }
    let missing = FixHarness()
    #expect(await missing.run(["fix", "x", "--provider", "openai"], variables: [:]) == 3)
    #expect(missing.error.contains("set OPENAI_API_KEY"))
    #expect(missing.output.isEmpty)
    let missingJSON = FixHarness()
    #expect(
      await missingJSON.run(["fix", "x", "--provider", "openai", "--json"], variables: [:]) == 3)
    #expect(missingJSON.provider.recordedRequests.isEmpty)
    let object = try jsonObject(missingJSON)
    #expect(object["status"] as? String == "error")
    #expect(object["result"] is NSNull)
    let error = try #require(object["error"] as? [String: Any])
    #expect(error["code"] as? String == "auth")
    #expect(error["http_status"] is NSNull)
    let usageJSON = FixHarness()
    #expect(await usageJSON.run(["fix", "x", "--json"], variables: [:]) == 78)
    #expect(usageJSON.output.isEmpty)
    for config in [
      "", "[providers.compatible]\nmodel = 'local'",
      "[providers.compatible]\nbase_url = 'http://localhost:11434/v1'",
    ] {
      let harness = FixHarness()
      #expect(
        await harness.run(["fix", "x", "--provider", "compatible"], variables: [:], config: config)
          == 78)
    }
    let compatible = FixHarness()
    #expect(
      await compatible.run(
        ["fix", "x", "--provider", "compatible", "--model", "override"],
        variables: [:],
        config: "[providers.compatible]\nbase_url = 'http://localhost:11434/v1'\nmodel = 'default'")
        == 0)
    #expect(compatible.state.withLock { $0.resolved?.model } == "override")
    #expect(compatible.state.withLock { $0.resolved?.apiKey } == nil)
  }

  @Test func compatibleBaseURLPolicy() async {
    let rejected = [
      "https://user:fake-secret@gateway.example/v1", "https://gateway.example/v1?key=fake",
      "https://gateway.example/v1#frag", "ftp://gateway.example/v1", "http:///v1",
      "http://gateway.example/v1",
    ]
    let unparseable = FixHarness()
    #expect(
      await unparseable.run(
        ["fix", "x", "--provider", "compatible", "--model", "m"],
        variables: [:], config: "[providers.compatible]\nbase_url = 'http://exa mple/v1'") == 78)
    #expect(unparseable.error.contains("not a valid URL"))
    #expect(!unparseable.error.contains("exa mple"))
    for base in rejected {
      let harness = FixHarness()
      let code = await harness.run(
        ["fix", "x", "--provider", "compatible", "--model", "m"],
        variables: ["PARLANCE_API_KEY": "fake-test-key"],
        config: "[providers.compatible]\nbase_url = '\(base)'")
      #expect(code == 78, "\(base)")
      #expect(harness.provider.recordedRequests.isEmpty)
      #expect(!harness.error.contains("gateway.example"))
      #expect(!harness.error.contains("fake"))
    }
    let accepted: [(String, String?)] = [
      ("http://gateway.example/v1", nil), ("http://localhost:11434/v1", "fake-key"),
      ("http://127.0.0.1:11434/v1", "fake-key"), ("http://[::1]:11434/v1", "fake-key"),
      ("https://gateway.example/v1", "fake-key"),
    ]
    for (base, key) in accepted {
      var variables: [String: String] = [:]
      if let key { variables["PARLANCE_API_KEY"] = key }
      let harness = FixHarness()
      #expect(
        await harness.run(
          ["fix", "x", "--provider", "compatible", "--model", "m"], variables: variables,
          config: "[providers.compatible]\nbase_url = '\(base)'")
          == 0, "\(base)")
      #expect(harness.state.withLock { $0.resolved?.apiKey } == key)
    }
  }

  @Test func ttyDiagnosticsDoNotPadOrRepeat() async {
    let failedEarly = FixHarness([.error(.auth(status: 401))])
    #expect(await failedEarly.run(outputTTY: true) == 3)
    #expect(failedEarly.output.isEmpty)
    let truncated = FixHarness([.event(.text(validReply)), .event(.finished(.length))])
    #expect(await truncated.run(outputTTY: true) == 8)
    #expect(truncated.output.components(separatedBy: "Ship it.").count == 2)
    #expect(!truncated.output.contains("<best>"))
    for steps in [
      [
        MockProvider.Step.event(.text("<best>Ship it.</best><gloss>open")),
        .event(.finished(.stop)),
      ],
      [.event(.text("<best>Ship it.</best><gloss>open")), .error(.transport)],
      [.event(.text("<best>Ship it.</best><gloss>open")), .event(.finished(.length))],
    ] {
      let openSection = FixHarness(steps)
      #expect(await openSection.run(outputTTY: true) != 0)
      #expect(openSection.output.contains("<best>Ship it.</best><gloss>open"))
    }
  }

  @Test func presetsAndRequestSettings() async throws {
    for preset in ProviderPreset.all where preset.id != "compatible" {
      let harness = FixHarness()
      #expect(
        await harness.run(
          ["fix", "x", "--target", "de", "--native", "fr", "--tone", "casual"],
          variables: [
            preset.apiKeyEnvironmentVariable: "fake-key", "PARLANCE_API_KEY": "fake-other-key",
          ]) == 0)
      #expect(harness.state.withLock { $0.resolved?.preset } == preset)
      #expect(harness.state.withLock { $0.resolved?.apiKey } == "fake-key")
      let prompt = try #require(harness.provider.recordedRequests.first?.messages.first?.content)
      #expect(prompt.contains("Target language: de"))
      #expect(prompt.contains("Native language: fr"))
      #expect(prompt.contains("everyday"))
    }
    let explicit = FixHarness()
    #expect(
      await explicit.run(
        ["fix", "x", "--provider", "openai", "--model", "custom"],
        variables: ["OPENAI_API_KEY": "fake", "GEMINI_API_KEY": "fake"]) == 0)
    #expect(explicit.state.withLock { $0.resolved?.model } == "custom")
    let boundary = FixHarness()
    let text = String(repeating: "界", count: 20_000)
    #expect(await boundary.run(["fix", "\u{1B}[31m" + text + "\u{1B}[0m"]) == 0)
    #expect(boundary.provider.recordedRequests.first?.messages.last?.content == text)
    let controls = FixHarness()
    #expect(await controls.run(["fix", " x\u{7}\t\n"]) == 0)
    #expect(controls.provider.recordedRequests.first?.messages.last?.content == " x\u{7}\t\n")
  }

  @Test func errorsMapToExitCodes() async {
    let cases: [(LLMError, Int32)] = [
      (.auth(status: 401), 3), (.transport, 4), (.timeout(.firstToken), 4),
      (.timeout(.idle), 4), (.timeout(.total), 4), (.quota(status: 402), 5),
      (.rateLimit(retryAfter: nil), 6), (.server(status: 503), 6),
      (.invalidRequest(status: 404, providerCode: .modelNotFound), 7),
      (.emptyResponse, 8), (.malformedResponse, 8), (.aborted, 130),
    ]
    for (error, code) in cases {
      let harness = FixHarness([.error(error)])
      #expect(await harness.run() == code)
      #expect(harness.output.isEmpty)
      #expect(harness.error.hasPrefix("pl: "))
    }
  }

  @Test func terminalSafetyAndColors() async {
    let harness = FixHarness()
    #expect(await harness.run(["fix", "\u{1B}[31mhello\u{1B}[0m\u{1B}]0;title\u{7}"]) == 0)
    #expect(harness.provider.recordedRequests.first?.messages.last?.content == "hello")
    let unsafe = validReply.replacingOccurrences(
      of: "Ship it.", with: "\u{1B}[31mShip\u{1B}]52;c;bad\u{1B}\\ it.\u{0}\u{85}\u{7}")
    let safe = FixHarness([.event(.text(unsafe)), .event(.finished(.stop))])
    #expect(await safe.run() == 0)
    #expect(safe.output == "Ship it.\n")
    for (args, variables) in [
      (["fix", "x", "--no-color"], ["OPENAI_API_KEY": "fake"]),
      (["fix", "x"], ["OPENAI_API_KEY": "fake", "NO_COLOR": "1"]),
      (["fix", "x"], ["OPENAI_API_KEY": "fake", "TERM": "dumb"]),
    ] {
      let plain = FixHarness()
      #expect(await plain.run(args, outputTTY: true, variables: variables) == 0)
      #expect(!plain.output.contains("\u{1B}"))
    }
    let color = FixHarness()
    #expect(
      await color.run(outputTTY: true, variables: ["OPENAI_API_KEY": "fake", "NO_COLOR": ""]) == 0)
    #expect(color.output.contains("\u{1B}[1m"))
  }
}

private func termReply(_ best: String, alt: String? = nil, note: String = "note") -> [MockProvider
  .Step]
{
  [
    .event(
      .text(
        "<best>\(best)</best><gloss>gloss</gloss><alts><alt><text>\(alt ?? best)</text><note>\(note)</note></alt></alts>"
      )), .event(.finished(.stop)),
  ]
}

private func jsonObject(_ harness: FixHarness) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: Data(harness.output.utf8)) as? [String: Any])
}

struct TermFixCommandTests {
  @Test func strictRetrySuccess() async throws {
    for json in [false, true] {
      let harness = FixHarness(scripts: [termReply("wrong"), termReply("second ⟦0⟧")])
      #expect(await harness.run(["fix", "fooBar"] + (json ? ["--json"] : [])) == 0)
      #expect(harness.error.contains("retrying with a stricter prompt"))
      #expect(harness.provider.recordedRequests.count == 2)
      if json {
        let object = try jsonObject(harness)
        #expect(object["status"] as? String == "ok")
        #expect(object["fallback"] is NSNull)
        #expect((object["timing"] as? [String: Any])?["strict_retry"] as? Bool == true)
        let result = try #require(object["result"] as? [String: Any])
        #expect((result["best"] as? [String: Any])?["text"] as? String == "second fooBar")
      } else {
        #expect(harness.output == "second fooBar\n")
      }
    }
  }

  @Test func invalidBestHasNoOutput() async throws {
    for json in [false, true] {
      let harness = FixHarness(scripts: [termReply("secret wrong", alt: "⟦0⟧")])
      #expect(await harness.run(["fix", "fooBar"] + (json ? ["--json"] : [])) == 8)
      #expect(harness.error.contains("the model changed identifiers, paths or flags."))
      if json {
        let object = try jsonObject(harness)
        #expect(object["status"] as? String == "error")
        #expect(object["result"] is NSNull)
        #expect((object["error"] as? [String: Any])?["code"] as? String == "placeholders_changed")
        #expect(!harness.output.contains("secret wrong"))
        #expect(!harness.output.contains("fooBar"))
      } else {
        #expect(harness.output.isEmpty)
      }
    }
  }

  @Test func fallbackOutput() async throws {
    for json in [false, true] {
      let harness = FixHarness(scripts: [
        termReply("first ⟦0⟧", alt: "wrong"), [.error(.transport)],
      ])
      #expect(await harness.run(["fix", "fooBar"] + (json ? ["--json"] : [])) == 0)
      #expect(harness.error.contains("using the first result"))
      if json {
        let object = try jsonObject(harness)
        #expect(object["fallback"] as? String == "first_best")
        #expect((object["timing"] as? [String: Any])?["strict_retry"] as? Bool == true)
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["gloss"] is NSNull)
        #expect((result["alts"] as? [Any])?.isEmpty == true)
        #expect((result["fixes"] as? [Any])?.isEmpty == true)
        #expect((result["best"] as? [String: Any])?["text"] as? String == "first fooBar")
      } else {
        #expect(harness.output == "first fooBar\n")
      }
    }
  }

  @Test func ttyRetryAndEligibility() async {
    let harness = FixHarness(scripts: [
      termReply("first ⟦0⟧", alt: "wrong"), termReply("second ⟦0⟧", alt: "wrong"),
    ])
    #expect(await harness.run(["fix", "fooBar", "--no-color"], outputTTY: true) == 0)
    #expect(harness.output.contains("---\nsecond fooBar\n"))
    #expect(harness.output.contains("alt 1: identifiers changed; not eligible\n"))
    let badBest = FixHarness(scripts: [termReply("wrong")])
    #expect(await badBest.run(["fix", "fooBar", "--no-color"], outputTTY: true) == 8)
    #expect(badBest.output.contains("best: identifiers changed; not eligible\n"))
    let fallback = FixHarness(scripts: [
      termReply("first ⟦0⟧", alt: "wrong"), termReply("second wrong"),
    ])
    #expect(await fallback.run(["fix", "fooBar", "--no-color"], outputTTY: true) == 0)
    #expect(fallback.output.hasSuffix("---\nretry failed; using first result\nfirst fooBar\n"))
    #expect(fallback.error.contains("using the first result"))
    let color = FixHarness(scripts: [termReply("first ⟦0⟧", alt: "wrong"), [.error(.transport)]])
    #expect(await color.run(["fix", "fooBar"], outputTTY: true) == 0)
    #expect(color.output.contains("\u{1B}[2m---\u{1B}[0m"))
    #expect(color.output.contains("\u{1B}[2mretry failed; using first result\u{1B}[0m\n"))
    #expect(color.output.hasSuffix("\u{1B}[1mfirst fooBar\u{1B}[0m\n"))
  }

  @Test func unavailableDelimiters() async throws {
    let input = "⟦⟧ ⟪⟫ 〖〗 fooBar"
    for json in [false, true] {
      let harness = FixHarness(scripts: [termReply(input)])
      #expect(await harness.run(["fix", input] + (json ? ["--json"] : [])) == 8)
      #expect(harness.provider.recordedRequests.first?.messages.last?.content == input)
      #expect(harness.provider.recordedRequests.count == 1)
      #expect(harness.error.contains("Remove the bracket characters"))
      if json {
        let object = try jsonObject(harness)
        #expect(
          (object["error"] as? [String: Any])?["code"] as? String == "placeholders_unavailable")
        #expect(object["result"] is NSNull)
      } else {
        #expect(harness.output.isEmpty)
      }
    }
  }

  @Test func ttyOmitsUnknownAuxiliaryFields() async {
    let reply =
      "<best>⟦0⟧</best><gloss>hidden gloss ⟦7⟧</gloss><alts><alt><text>⟦0⟧</text><note>hidden note ⟦8⟧</note></alt></alts><fixes><fix>hidden fix ⟦9⟧</fix><fix>keep ⟦0⟧</fix></fixes>"
    let harness = FixHarness([.event(.text(reply)), .event(.finished(.stop))])
    #expect(await harness.run(["fix", "fooBar", "--no-color"], outputTTY: true) == 0)
    #expect(!harness.output.contains("hidden"))
    #expect(harness.output.contains("keep fooBar"))
  }

  @Test func jsonAlternativeEligibilityAndNote() async throws {
    let harness = FixHarness(scripts: [termReply("⟦0⟧", alt: "secret alternative")])
    #expect(await harness.run(["fix", "fooBar", "--json"]) == 0)
    let result = try #require(try jsonObject(harness)["result"] as? [String: Any])
    let alt = try #require((result["alts"] as? [[String: Any]])?.first)
    #expect(alt["eligible"] as? Bool == false)
    #expect(alt["reason"] as? String == "placeholders_changed")
    #expect(alt.count == 2)
    #expect(!harness.output.contains("secret alternative"))
    let dropped = FixHarness(scripts: [termReply("⟦0⟧", note: "⟦7⟧")])
    #expect(await dropped.run(["fix", "fooBar", "--json"]) == 0)
    let droppedResult = try #require(try jsonObject(dropped)["result"] as? [String: Any])
    let eligible = try #require((droppedResult["alts"] as? [[String: Any]])?.first)
    #expect(eligible["eligible"] as? Bool == true)
    #expect(eligible["note"] is NSNull)
  }
}
