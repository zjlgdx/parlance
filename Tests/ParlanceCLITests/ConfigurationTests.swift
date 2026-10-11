import Foundation
import ParlanceCore
import Testing
import os

@testable import ParlanceCLI

private final class ObservedKeychain: KeychainStoring {
  struct Calls: Sendable {
    var reads: [String] = []
    var probes: [String] = []
    var writes: [String] = []
    var deletes: [String] = []
  }
  let memory = MemoryKeychain()
  let calls = OSAllocatedUnfairLock(initialState: Calls())
  func read(account: String) throws -> String {
    calls.withLock { $0.reads.append(account) }
    return try memory.read(account: account)
  }
  func exists(account: String) throws -> Bool {
    calls.withLock { $0.probes.append(account) }
    return try memory.exists(account: account)
  }
  func write(account: String, secret: String) throws {
    calls.withLock { $0.writes.append(account) }
    try memory.write(account: account, secret: secret)
  }
  func delete(account: String) throws {
    calls.withLock { $0.deletes.append(account) }
    try memory.delete(account: account)
  }
}

private final class ConfigurationHarness: Sendable {
  struct State: Sendable {
    var out = ""
    var err = ""
    var configPaths: [String] = []
    var commands: [String] = []
    var timeouts: [TimeInterval] = []
    var interactions: [Bool] = []
    var passphraseReads = 0
    var stdinReads = 0
    var resolved: ResolvedProvider?
  }
  let state = OSAllocatedUnfairLock(initialState: State())
  let keychain = ObservedKeychain()
  let provider = MockProvider(scripts: [
    [
      .event(
        .text(
          "<best>Ship it.</best><gloss>发布。</gloss><alts><alt><text>Release it.</text><note>正式</note></alt></alts>"
        )),
      .event(.finished(.stop)),
    ]
  ])
  var snapshot: State { state.withLock { $0 } }

  func run(
    _ arguments: [String] = ["fix", "input"], config: String? = nil,
    variables: [String: String] = ["OPENAI_API_KEY": "fake-test-key-env"],
    stderrTTY: Bool = true, stdinTTY: Bool = false, stdin: Data = Data(),
    passphrase: String = "fake-test-key-tty",
    result: APIKeyCommandResult = .init(
      termination: .exit(0), stdout: Data("fake-test-key-cmd\n".utf8)),
    configReadFails: Bool = false
  ) async -> Int32 {
    let environment = CLIEnvironment(
      variables: variables, stdinIsTTY: stdinTTY, stdoutIsTTY: false, stderrIsTTY: stderrTTY,
      readStdin: {
        self.state.withLock { $0.stdinReads += 1 }
        return stdin
      },
      stdout: { value in self.state.withLock { $0.out += value } },
      stderr: { value in self.state.withLock { $0.err += value } },
      makeProvider: { resolved in
        self.state.withLock { $0.resolved = resolved }
        return self.provider
      },
      homeDirectory: "/fake/home",
      readConfig: { path in
        self.state.withLock { $0.configPaths.append(path) }
        if configReadFails { throw CocoaError(.fileReadNoPermission) }
        return config.map { Data($0.utf8) }
      },
      makeKeychain: { allowed in
        self.state.withLock { $0.interactions.append(allowed) }
        return self.keychain
      },
      runKeyCommand: { command, timeout in
        self.state.withLock {
          $0.commands.append(command)
          $0.timeouts.append(timeout)
        }
        return result
      },
      readPassphrase: {
        self.state.withLock { $0.passphraseReads += 1 }
        return passphrase
      })
    return await CLIEnvironment.$override.withValue(environment) {
      await PL.execute(arguments: arguments).rawValue
    }
  }
}

struct ConfigurationTests {
  @Test func pathAndDefaults() async {
    for (xdg, expected) in [
      (nil, "/fake/home/.config/parlance/config.toml"),
      ("relative", "/fake/home/.config/parlance/config.toml"),
      ("", "/fake/home/.config/parlance/config.toml"),
      ("/fake/xdg", "/fake/xdg/parlance/config.toml"),
    ] as [(String?, String)] {
      let harness = ConfigurationHarness()
      var variables = ["OPENAI_API_KEY": "fake-test-key"]
      variables["XDG_CONFIG_HOME"] = xdg
      #expect(await harness.run(variables: variables) == 0)
      #expect(harness.snapshot.configPaths == [expected])
      let path = ConfigurationHarness()
      #expect(await path.run(["config", "path"], config: "broken = [", variables: variables) == 0)
      #expect(path.snapshot.out == expected + "\n")
      #expect(path.snapshot.configPaths.isEmpty)
      #expect(harness.snapshot.resolved?.model == ProviderPreset.openai.defaultModel)
    }
    let unreadable = ConfigurationHarness()
    #expect(await unreadable.run(configReadFails: true) == 78)
    #expect(unreadable.snapshot.out.isEmpty)
  }

  @Test func precedenceAndModelOverride() async throws {
    let config = """
      provider = "deepseek"
      target_language = "de"
      native_language = "fr"
      tone = "casual"
      fixes = false
      [providers.deepseek]
      model = "configured"
      [models.configured]
      extra_body = { think = false, nested = { count = 2 }, stops = [1, 2] }
      max_output_field = "max_completion_tokens"
      system_role = "developer"
      """
    let harness = ConfigurationHarness()
    #expect(
      await harness.run(config: config, variables: ["DEEPSEEK_API_KEY": "fake-test-key"]) == 0)
    let resolved = try #require(harness.snapshot.resolved)
    #expect(resolved.preset == .deepseek)
    #expect(resolved.model == "configured")
    #expect(resolved.override?.extraBody?["think"] == .bool(false))
    #expect(resolved.override?.extraBody?["nested"] == .object(["count": .integer(2)]))
    #expect(resolved.override?.maxOutputField == .maxCompletionTokens)
    #expect(resolved.override?.systemRole == .developer)
    let prompt = try #require(harness.provider.recordedRequests.first?.messages.first?.content)
    #expect(prompt.contains("Target language: de"))
    #expect(prompt.contains("Native language: fr"))
    #expect(prompt.contains("everyday"))
    #expect(!prompt.contains("<fixes>"))
    let cli = ConfigurationHarness()
    #expect(
      await cli.run(
        [
          "fix", "input", "--provider", "openai", "--model", "cli-model", "--tone", "agent",
          "--target", "ja", "--native", "en",
        ],
        config: config) == 0)
    #expect(cli.snapshot.resolved?.preset == .openai)
    #expect(cli.snapshot.resolved?.model == "cli-model")
    let cliPrompt = try #require(cli.provider.recordedRequests.first?.messages.first?.content)
    #expect(cliPrompt.contains("Target language: ja"))
    #expect(cliPrompt.contains("Native language: en"))
    #expect(!cliPrompt.contains("everyday"))
  }

  @Test func automaticSelectionCountsNonemptyVariablesOnly() async {
    for preset in ProviderPreset.all where preset.id != "compatible" {
      let harness = ConfigurationHarness()
      var variables = Dictionary(
        uniqueKeysWithValues: ProviderPreset.all.map { ($0.apiKeyEnvironmentVariable, "") })
      let ownKey = "fake-test-key-\(preset.id)"
      variables[preset.apiKeyEnvironmentVariable] = ownKey
      variables["PARLANCE_API_KEY"] = "fake-test-key-other"
      #expect(await harness.run(variables: variables) == 0)
      #expect(harness.snapshot.resolved?.preset == preset)
      #expect(harness.snapshot.resolved?.apiKey == ownKey)
    }
    let empty = ConfigurationHarness()
    #expect(await empty.run(variables: ["DEEPSEEK_API_KEY": ""]) == 78)
    let selected = ConfigurationHarness()
    #expect(
      await selected.run(variables: ["DEEPSEEK_API_KEY": "", "OPENAI_API_KEY": "fake-test-key"])
        == 0)
    #expect(selected.snapshot.resolved?.preset == .openai)
    #expect(selected.snapshot.resolved?.apiKey == "fake-test-key")
    let onlyCompatible = ConfigurationHarness()
    #expect(await onlyCompatible.run(variables: ["PARLANCE_API_KEY": "fake-test-key"]) == 78)
  }

  @Test(arguments: [
    "api_key", "Authorization", "foo_secret", "clientSecret", "apiKey", "x-api-key",
    "clientPassword", "db_password", "passphrase", "auth", "pwd", "APIToken", "key_value",
    "secretkey", "accesstoken", "refresh_token_value", "token_value", "ssh_keys", "key",
    "api_key.", "api key", "privatekey", "cookie", "client.credentials", "bearer", "pass",
  ])
  func forbiddenFieldsRecurse(field: String) async {
    // Nested arrays of inline tables exercise traversal beyond the immediate extra_body table.
    for config in [
      "'\(field)' = 'fake-test-key'",
      "[models.local]\nextra_body = { '\(field)' = 'fake-test-key' }",
      "[models.local]\nextra_body = { nested = [[{ '\(field)' = 'fake-test-key' }]] }",
      "[unknown.nested]\n'\(field)' = 'fake-test-key'",
    ] {
      let harness = ConfigurationHarness()
      #expect(await harness.run(config: config) == 78)
      #expect(
        harness.snapshot.err.contains("Use environment variables, pl auth set or api_key_cmd"))
      #expect(!harness.snapshot.err.contains("fake-test-key"))
      #expect(harness.snapshot.out.isEmpty)
    }
  }

  @Test func allowedTokenParametersAndExemptions() async {
    let config = """
      [providers.openai]
      model = "my-secret-model"
      api_key_cmd = "fake-test-helper"
      [models."my-secret-model"]
      extra_body = { stop_token_ids = [1], stopTokenIDs = [2], eos_token_id = 3, allowed_token_ids = [4], pad_token_id = 5, max_tokens = 6, max_output_tokens = 7, top_k = 8, prompt_cache_key = "fake-test-key-cache" }
      """
    let harness = ConfigurationHarness()
    #expect(await harness.run(config: config) == 0)
    #expect(harness.snapshot.resolved?.override?.extraBody?.count == 9)
    let outside = ConfigurationHarness()
    #expect(await outside.run(config: "prompt_cache_key = 'fake-test-key'") == 78)
  }

  @Test func unknownNamesAndSyntaxNeverEcho() async {
    let harness = ConfigurationHarness()
    #expect(
      await harness.run(
        config: """
          oddname = "fake-test-key-value"
          [providers.openai]
          oddname2 = "fake-test-key-value"
          [providers.oddprovider]
          strange = true
          [models."odd-model"]
          oddname3 = "fake-test-key-value"
          """) == 0)
    #expect(harness.snapshot.err.contains("root contains 1 unknown"))
    #expect(harness.snapshot.err.contains("providers contains 1 unknown"))
    #expect(harness.snapshot.err.contains("providers.openai contains 1 unknown"))
    #expect(harness.snapshot.err.contains("models contains 1 unknown"))
    #expect(!harness.snapshot.err.contains("odd"))
    #expect(!harness.snapshot.err.contains("fake-test-key"))
    for (config, location) in [
      ("tone = 'fake-test-marker' extra", " at line 1"),
      ("# first line\ntone = 'fake-test-marker' extra", " at line 2"),
      ("tone = \"\\qfake-test-marker\"", ""),
    ] {
      let invalid = ConfigurationHarness()
      #expect(await invalid.run(config: config) == 78)
      #expect(
        invalid.snapshot.err
          == "pl: config.toml has a syntax error\(location). Check the TOML syntax.\n")
    }
  }

  @Test func typesEnumsReservedFieldsAndSafePaths() async {
    let secretModel = "sk-" + String(repeating: "a", count: 40)
    for (config, path) in [
      ("tone = 12", "tone"), ("fixes = 'fake-test-value'", "fixes"),
      ("target_language = []", "target_language"), ("native_language = 1", "native_language"),
      ("provider = 'fake-test-value'", "provider"), ("tone = 'fake-test-value'", "tone"),
      ("[providers.openai]\nbase_url = false", "providers.openai.base_url"),
      ("[providers.openai]\napi_key_cmd = 1", "providers.openai.api_key_cmd"),
      ("[providers.openai]\nmodel = []", "providers.openai.model"),
      (
        "[models.'\(secretModel)']\nmax_output_field = []", "models.\"[REDACTED]\".max_output_field"
      ),
      ("[models.local]\nsystem_role = 'fake-test-value'", "models.\"local\".system_role"),
      ("[models.local]\nmax_output_field = 'fake-test-value'", "models.\"local\".max_output_field"),
      ("[models.local]\nextra_body = []", "models.\"local\".extra_body"),
      ("[models.local]\nextra_body = { date = 1979-05-27 }", "models.\"local\".extra_body"),
      ("tone = { fake-test-value = 1979-05-27 }", "invalid type at tone."),
      ("fixes = { fake-test-value = 1979-05-27 }", "invalid type at fixes."),
      (
        "[providers.openai]\nmodel = { fake-test-value = 1979-05-27 }",
        "invalid type at providers.openai.model."
      ),
      (
        "[models.local]\nsystem_role = { fake-test-value = 1979-05-27 }",
        "invalid type at models.\"local\".system_role."
      ),
    ] {
      let harness = ConfigurationHarness()
      #expect(await harness.run(["fix", "input", "--json"], config: config) == 78)
      #expect(harness.snapshot.err.contains(path), "\(config)")
      #expect(!harness.snapshot.err.contains(secretModel))
      #expect(!harness.snapshot.err.contains("fake-test-value"))
      #expect(harness.snapshot.out.isEmpty)
    }
    for reserved in ["model", "messages", "stream", "stream_options", "system"] {
      let harness = ConfigurationHarness()
      #expect(
        await harness.run(
          config: "[models.unused]\nextra_body = { \(reserved) = 'fake-test-value' }") == 78)
      #expect(harness.snapshot.err.contains("extra_body"))
      #expect(!harness.snapshot.err.contains("fake-test-value"))
    }
  }

  @Test func sourceOrderAndRecoverableKeychainFailures() async throws {
    let config = "provider = 'openai'\n[providers.openai]\napi_key_cmd = 'fake-test-helper'"
    let env = ConfigurationHarness()
    try env.keychain.memory.write(account: "openai", secret: "fake-test-key-keychain")
    #expect(await env.run(config: config) == 0)
    #expect(env.snapshot.resolved?.apiKey == "fake-test-key-env")
    #expect(env.keychain.calls.withLock { $0.reads.isEmpty && $0.probes.isEmpty })
    #expect(env.snapshot.commands.isEmpty)
    let keychain = ConfigurationHarness()
    try keychain.keychain.memory.write(account: "openai", secret: "fake-test-key-keychain")
    #expect(await keychain.run(config: config, variables: [:]) == 0)
    #expect(keychain.snapshot.resolved?.apiKey == "fake-test-key-keychain")
    #expect(keychain.snapshot.commands.isEmpty)
    for failure in [KeychainError.notFound, .denied, .locked] {
      let fallback = ConfigurationHarness()
      fallback.keychain.memory.fail(account: "openai", with: failure)
      #expect(await fallback.run(config: config, variables: [:]) == 0)
      #expect(fallback.snapshot.resolved?.apiKey == "fake-test-key-cmd")
      #expect(fallback.snapshot.commands == ["fake-test-helper"])
      #expect(fallback.snapshot.timeouts == [30])
      #expect(
        fallback.snapshot.err.split(separator: "\n").filter { $0.hasPrefix("pl: ") }.count
          == (failure == .notFound ? 0 : 1))
    }
    let unavailable = ConfigurationHarness()
    unavailable.keychain.memory.fail(account: "openai", with: .unavailable)
    #expect(await unavailable.run(config: config, variables: [:]) == 3)
    #expect(unavailable.snapshot.commands.isEmpty)
  }

  @Test func nonInteractiveNeverQueriesKeychain() async throws {
    for (tty, variables) in [(false, [:]), (true, ["SSH_CONNECTION": ""]), (true, ["SSH_TTY": ""])]
    {
      let harness = ConfigurationHarness()
      try harness.keychain.memory.write(account: "openai", secret: "fake-test-key-keychain")
      #expect(
        await harness.run(
          config: "provider = 'openai'\n[providers.openai]\napi_key_cmd = 'fake-test-helper'",
          variables: variables, stderrTTY: tty) == 0)
      #expect(harness.keychain.calls.withLock { $0.reads.isEmpty && $0.probes.isEmpty })
      #expect(harness.snapshot.interactions == [false])
      #expect(harness.snapshot.resolved?.apiKey == "fake-test-key-cmd")
      #expect(harness.snapshot.err.contains("Keychain skipped"))
    }
  }

  @Test func originOverridesDoNotLeakOfficialOrCompatibleKeys() async throws {
    for base in ["https://gateway.example/v1", "http://gateway.example/v1"] {
      for variables in [
        ["DEEPSEEK_API_KEY": "fake-test-key-official"],
        ["PARLANCE_API_KEY": "fake-test-key-compatible"],
      ] {
        let harness = ConfigurationHarness()
        #expect(
          await harness.run(
            config:
              "provider = 'deepseek'\n[providers.deepseek]\nbase_url = '\(base)'\napi_key_cmd = 'fake-test-helper'",
            variables: variables, stderrTTY: false) == 0)
        #expect(harness.snapshot.resolved?.apiKey == nil)
        #expect(harness.snapshot.commands.isEmpty)
        #expect(harness.snapshot.err.contains("api_key_cmd skipped"))
        #expect(harness.snapshot.err.contains("Use compatible"))
      }
    }
    let interactive = ConfigurationHarness()
    try interactive.keychain.memory.write(
      account: "deepseek@https://gateway.example", secret: "fake-test-key-custom")
    #expect(
      await interactive.run(
        config:
          "provider = 'deepseek'\n[providers.deepseek]\nbase_url = 'https://gateway.example/proxy'\napi_key_cmd = 'fake-test-helper'",
        variables: [
          "DEEPSEEK_API_KEY": "fake-test-key-official",
          "PARLANCE_API_KEY": "fake-test-key-compatible",
        ]) == 0)
    #expect(interactive.snapshot.resolved?.apiKey == "fake-test-key-custom")
    #expect(
      interactive.keychain.calls.withLock { $0.reads } == ["deepseek@https://gateway.example"])
    #expect(interactive.snapshot.commands.isEmpty)
    let sameOrigin = ConfigurationHarness()
    #expect(
      await sameOrigin.run(
        config:
          "provider = 'deepseek'\n[providers.deepseek]\nbase_url = 'https://API.DeepSeek.com:443/proxy/v1'",
        variables: ["DEEPSEEK_API_KEY": "fake-test-key"]) == 0)
    #expect(sameOrigin.snapshot.resolved?.apiKey == "fake-test-key")
    let sameOriginCommand = ConfigurationHarness()
    #expect(
      await sameOriginCommand.run(
        config:
          "provider = 'deepseek'\n[providers.deepseek]\nbase_url = 'https://api.deepseek.com/proxy'\napi_key_cmd = 'fake-test-helper'",
        variables: [:]) == 0)
    #expect(sameOriginCommand.snapshot.commands.count == 1)
  }

  @Test func plainHTTPRejectsBeforeAnySecretReadOrCommand() async throws {
    let config =
      "provider = 'compatible'\n[providers.compatible]\nbase_url = 'http://gateway.example:8080/v1'\nmodel = 'local'"
    for source in ["env", "keychain", "cmd"] {
      let harness = ConfigurationHarness()
      if source == "keychain" {
        try harness.keychain.memory.write(
          account: "compatible@http://gateway.example:8080", secret: "fake-test-key")
      }
      #expect(
        await harness.run(
          config: config + (source == "cmd" ? "\napi_key_cmd = 'fake-test-helper'" : ""),
          variables: source == "env" ? ["PARLANCE_API_KEY": "fake-test-key"] : [:]) == 78)
      #expect(harness.snapshot.err.contains("refusing to send an API key over plain HTTP"))
      #expect(harness.snapshot.commands.isEmpty)
      #expect(harness.keychain.calls.withLock { $0.reads.isEmpty })
    }
    let skipped = ConfigurationHarness()
    try skipped.keychain.memory.write(
      account: "compatible@http://gateway.example:8080", secret: "fake-test-key")
    #expect(await skipped.run(config: config, variables: [:], stderrTTY: false) == 0)
    #expect(skipped.keychain.calls.withLock { $0.probes.isEmpty && $0.reads.isEmpty })
    let named = ConfigurationHarness()
    let account = "deepseek@http://gateway.example:8080"
    try named.keychain.memory.write(account: account, secret: "fake-test-key")
    #expect(
      await named.run(
        config:
          "provider = 'deepseek'\n[providers.deepseek]\nbase_url = 'http://gateway.example:8080/prefix'",
        variables: [:]) == 78)
    #expect(named.keychain.calls.withLock { $0.probes } == [account])
    let local = ConfigurationHarness()
    let localAccount = "deepseek@http://localhost:8080"
    try local.keychain.memory.write(account: localAccount, secret: "fake-test-key")
    #expect(
      await local.run(
        config:
          "provider = 'deepseek'\n[providers.deepseek]\nbase_url = 'http://localhost:8080/prefix'",
        variables: [:]) == 0)
    #expect(local.keychain.calls.withLock { $0.reads } == [localAccount])
  }

  @Test func helperFailuresNeverExposeCapturedOutput() async throws {
    let results: [APIKeyCommandResult] = [
      .init(termination: .exit(9), stdout: Data("fake-test-key-stdout".utf8)),
      .init(termination: .signal(15)),
      .init(
        termination: .exit(0), stdout: Data("fake-test-key-stdout".utf8), stdoutOverflowed: true),
      .init(termination: .timeout, stdout: Data("fake-test-key-stdout".utf8)),
      .init(termination: .launchFailed), .init(termination: .exit(0)),
      .init(termination: .exit(0), stdout: Data(" \n\t".utf8)),
      .init(termination: .exit(0), stdout: Data("fake-test-key-a\nfake-test-key-b".utf8)),
      .init(termination: .exit(0), stdout: Data("fake-test-key-a\rfake-test-key-b".utf8)),
      .init(termination: .exit(0), stdout: Data([0xff])),
    ]
    let config = "provider = 'openai'\n[providers.openai]\napi_key_cmd = 'fake-test-helper'"
    for result in results {
      let harness = ConfigurationHarness()
      #expect(
        await harness.run(
          ["fix", "input"], config: config, variables: [:], result: result) == 3)
      #expect(harness.snapshot.out.isEmpty)
      #expect(harness.snapshot.err.contains("run the api_key_cmd yourself to see its output"))
      switch result.termination {
      case .exit(let status):
        #expect(harness.snapshot.err.contains("status \(status)"))
        if result.stdoutOverflowed { #expect(harness.snapshot.err.contains("too much output")) }
      case .signal(let signal): #expect(harness.snapshot.err.contains("signal \(signal)"))
      case .timeout: #expect(harness.snapshot.err.contains("timed out after 30s"))
      case .launchFailed: #expect(harness.snapshot.err.contains("could not start"))
      }
      #expect(!harness.snapshot.err.contains("fake-test-key"))
    }
    let failedJSON = ConfigurationHarness()
    #expect(
      await failedJSON.run(
        ["fix", "input", "--json"], config: config, variables: [:],
        result: .init(termination: .exit(9), stdout: Data("fake-test-key-stdout".utf8))) == 3)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(failedJSON.snapshot.out.utf8)) as? [String: Any])
    #expect((object["error"] as? [String: Any])?["code"] as? String == "auth")
    #expect(!failedJSON.snapshot.out.contains("fake-test-key"))
    let success = ConfigurationHarness()
    #expect(
      await success.run(
        ["fix", "input"], config: config, variables: [:],
        result: .init(
          termination: .exit(0), stdout: Data("  fake-test-key-success\r\n".utf8))) == 0)
    #expect(success.snapshot.resolved?.apiKey == "fake-test-key-success")
    #expect(!(success.snapshot.out + success.snapshot.err).contains("fake-test-key"))
  }

  @Test func authSetRemoveAndCompatibleAccounts() async throws {
    let config = "[providers.compatible]\nbase_url = 'https://Gateway.example:443/private/path'"
    let pipe = ConfigurationHarness()
    #expect(
      await pipe.run(
        ["auth", "set", "--provider", "compatible"], config: config,
        stdin: Data("fake-test-key-first\nfake-test-key-second".utf8)) == 0)
    #expect(
      pipe.keychain.memory.secrets == ["compatible@https://gateway.example": "fake-test-key-first"])
    #expect(pipe.snapshot.passphraseReads == 0)
    #expect(pipe.snapshot.out.isEmpty && pipe.snapshot.err.isEmpty)
    #expect(pipe.provider.recordedRequests.isEmpty)
    #expect(await pipe.run(["auth", "remove", "--provider", "compatible"], config: config) == 0)
    #expect(pipe.keychain.memory.secrets.isEmpty)
    let tty = ConfigurationHarness()
    #expect(await tty.run(["auth", "set", "--provider", "openai"], stdinTTY: true) == 0)
    #expect(tty.snapshot.passphraseReads == 1 && tty.snapshot.stdinReads == 0)
    #expect(tty.keychain.memory.secrets["openai"] == "fake-test-key-tty")
    for verb in ["set", "remove"] {
      let missing = ConfigurationHarness()
      #expect(await missing.run(["auth", verb, "--provider", "compatible"]) == 78)
      #expect(missing.snapshot.err.contains("providers.compatible.base_url"))
      #expect(missing.snapshot.stdinReads == 0)
      #expect(missing.keychain.calls.withLock { $0.writes.isEmpty && $0.deletes.isEmpty })
    }
    let newOrigin = ConfigurationHarness()
    #expect(
      await newOrigin.run(
        ["auth", "set", "--provider", "compatible"],
        config: "[providers.compatible]\nbase_url = 'http://gateway.example:8080/other'",
        stdin: Data("fake-test-key".utf8)) == 0)
    #expect(
      newOrigin.keychain.calls.withLock { $0.writes } == ["compatible@http://gateway.example:8080"])
    let argument = ConfigurationHarness()
    #expect(await argument.run(["auth", "set", "--provider", "openai", "fake-test-key"]) == 64)
    #expect(argument.keychain.memory.secrets.isEmpty)
  }

  @Test func authStatusAndConfigShowOnlyProbeAttributes() async throws {
    for (tty, variables) in [(false, [:]), (true, ["SSH_CONNECTION": ""]), (true, ["SSH_TTY": ""])]
    {
      for command in [["auth", "status"], ["config", "show"]] {
        let harness = ConfigurationHarness()
        try harness.keychain.memory.write(account: "openai", secret: "fake-test-key-keychain")
        #expect(
          await harness.run(
            command,
            config: "provider = 'openai'\n[providers.openai]\napi_key_cmd = 'fake-test-helper'",
            variables: variables, stderrTTY: tty) == 0)
        #expect(
          harness.keychain.calls.withLock { $0.probes.contains("openai") && $0.reads.isEmpty })
        #expect(harness.snapshot.commands.isEmpty)
        #expect(harness.snapshot.out.contains("keychain (not used in non-interactive mode)"))
        #expect(harness.snapshot.out.contains("cmd configured"))
        #expect(!harness.snapshot.out.contains("fake-test"))
      }
    }
  }

  @Test func statusUsesTheSameOriginAndEmptyEnvironmentRules() async {
    let empty = ConfigurationHarness()
    #expect(
      await empty.run(
        ["auth", "status", "--provider", "openai"],
        config: "[providers.openai]\napi_key_cmd = 'fake-test-helper'",
        variables: ["OPENAI_API_KEY": ""]) == 0)
    #expect(!empty.snapshot.out.contains("env"))
    #expect(empty.snapshot.out.contains("cmd configured (used)"))
    let changed = ConfigurationHarness()
    #expect(
      await changed.run(
        ["auth", "status", "--provider", "openai"],
        config:
          "[providers.openai]\nbase_url = 'https://gateway.example:8443/proxy'\napi_key_cmd = 'fake-test-helper'"
      ) == 0)
    #expect(!changed.snapshot.out.contains("env"))
    #expect(changed.snapshot.out.contains("cmd configured (not used: changed origin)"))
    #expect(
      changed.keychain.calls.withLock { $0.probes } == ["openai@https://gateway.example:8443"])
    #expect(changed.keychain.calls.withLock { $0.reads.isEmpty })
    #expect(changed.snapshot.commands.isEmpty)
  }

  @Test func configShowWhitelistAndJSONModelRedaction() async {
    let secretModel = "sk-" + String(repeating: "a", count: 40)
    let config = """
      provider = "compatible"
      target_language = "\\u001B[31men\\u0007"
      [providers.compatible]
      model = "\(secretModel)"
      base_url = "https://gateway.example:443/fake-test-key-path"
      api_key_cmd = "fake-test-key-command"
      [models."\(secretModel)"]
      extra_body = { oddname = "fake-test-key-value", nested = { other = true } }
      system_role = "developer"
      max_output_field = "none"
      """
    for args in [["config"], ["config", "show"]] {
      let harness = ConfigurationHarness()
      #expect(await harness.run(args, config: config) == 0)
      let out = harness.snapshot.out
      #expect(out.contains("model = [REDACTED] [config]"))
      #expect(out.contains("base_url = https://gateway.example <path set> [config]"))
      #expect(out.contains("extra_body = <set> (2 fields) [config]"))
      #expect(out.contains("api_key_cmd = <set> [config]"))
      #expect(out.contains("target_language = en [config]"))
      #expect(out.contains("native_language = zh-Hans [default]"))
      for forbidden in [secretModel, "fake-test-key", "oddname", "nested", "\u{1B}", "\u{7}"] {
        #expect(!out.contains(forbidden))
      }
      #expect(harness.snapshot.commands.isEmpty)
      #expect(harness.keychain.calls.withLock { $0.reads.isEmpty })
    }
    let json = ConfigurationHarness()
    #expect(await json.run(["fix", "input", "--json", "--model", secretModel]) == 0)
    #expect(!json.snapshot.out.contains(secretModel))
    #expect(json.snapshot.out.contains("[REDACTED]"))
  }

  @Test func emptyCompatibleKeyDoesNotRefuseHTTP() async {
    let harness = ConfigurationHarness()
    #expect(
      await harness.run(
        config:
          "provider = 'compatible'\n[providers.compatible]\nbase_url = 'http://gateway.example/v1'\nmodel = 'local'",
        variables: ["PARLANCE_API_KEY": ""]) == 0)
    #expect(harness.snapshot.resolved?.apiKey == nil)
    #expect(harness.provider.recordedRequests.count == 1)
  }

  @Test func sameOriginOverridesStillRequireKey() async {
    for base in [
      "https://api.deepseek.com/proxy", "https://api.deepseek.com:443", "https://API.DEEPSEEK.COM",
      "https://API.DEEPSEEK.COM:443/proxy",
    ] {
      let harness = ConfigurationHarness()
      #expect(
        await harness.run(
          config: "provider = 'deepseek'\n[providers.deepseek]\nbase_url = '\(base)'",
          variables: [:]) == 3)
      #expect(harness.provider.recordedRequests.isEmpty)
      #expect(harness.keychain.calls.withLock { $0.reads } == ["deepseek"])
    }
    for base in [
      "https://gateway.example/proxy", "https://api.deepseek.com:8443", "http://api.deepseek.com",
    ] {
      let harness = ConfigurationHarness()
      #expect(
        await harness.run(
          config: "provider = 'deepseek'\n[providers.deepseek]\nbase_url = '\(base)'",
          variables: [:]) == 0)
      #expect(harness.snapshot.resolved?.apiKey == nil)
      #expect(harness.provider.recordedRequests.count == 1)
    }
  }

  @Test func forbiddenDiagnosticUsesOnlySafeTableLabels() async {
    for (prefix, label) in [
      ("", "root"), ("[providers.openai]\n", "providers.openai"),
      ("[providers.openai.oddname]\n", "providers.openai"),
      ("[providers.oddname]\n", "providers"), ("[oddname]\n", "root"),
      ("[models.'private-model-name']\n", "models"),
      ("[models.'private-model-name'.extra_body.oddname]\n", "models.extra_body"),
      ("[[models.'private-model-name'.extra_body.oddname]]\n", "models.extra_body"),
    ] {
      let harness = ConfigurationHarness()
      #expect(await harness.run(config: prefix + "clientSecret = 'fake-test-key-value'") == 78)
      #expect(
        harness.snapshot.err.contains("credential-shaped field in config.toml table \(label)."))
      for hidden in ["clientSecret", "fake-test-key-value", "private-model-name", "oddname"] {
        #expect(!harness.snapshot.err.contains(hidden))
      }
    }
  }

  @Test func verboseReportsRequestMetadata() async {
    let harness = ConfigurationHarness()
    #expect(await harness.run(["fix", "input", "--verbose"]) == 0)
    #expect(harness.provider.recordedRequests.count == 1)
    #expect(harness.snapshot.err.contains("pl: request=fix preset=openai"))
  }

  @Test func realHelperSmoke() async {
    // Empty environment, no config or Keychain access.
    let result = await APIKeyCommand.run("printf x", timeout: 30, environment: [:])
    #expect(result.termination == .exit(0))
    #expect(result.stdout == Data("x".utf8))
  }
}

private struct CLIReasoningCase: Sendable {
  let provider: String
  let model: String
  let efforts: [String]
  let off: Bool
}
private let cliReasoningCases: [CLIReasoningCase] = [
  .init(provider: "deepseek", model: "deepseek-flash", efforts: ["low", "high", "max"], off: true),
  .init(
    provider: "deepseek", model: "deepseek-v4-pro", efforts: ["low", "high", "max"], off: true),
  .init(
    provider: "gemini", model: "gemini-3.5-flash-lite",
    efforts: ["minimal", "low", "medium", "high"], off: false),
  .init(
    provider: "gemini", model: "gemini-3.8-flash", efforts: ["low", "medium", "high"], off: false),
  .init(
    provider: "openai", model: "gpt-6-luna", efforts: ["low", "medium", "high", "xhigh", "max"],
    off: true),
  .init(
    provider: "openai", model: "gpt-6.1-sol", efforts: ["low", "medium", "high", "xhigh", "max"],
    off: false),
  .init(
    provider: "claude", model: "claude-haiku-5-5",
    efforts: ["low", "medium", "high", "xhigh", "max"], off: true),
  .init(
    provider: "claude", model: "claude-sonnet-5-5",
    efforts: ["low", "medium", "high", "xhigh", "max"], off: true),
]
private struct CLIReasoningCombination: Sendable {
  let row: CLIReasoningCase
  let effort: String?
  let thinking: String?
  var valid: Bool {
    if let effort, !row.efforts.contains(effort) { return false }
    if thinking == "off" {
      if !row.off { return false }
      if let effort {
        return row.provider == "claude" && ["low", "medium", "high"].contains(effort)
      }
    }
    return true
  }
}
private let cliCombinations = cliReasoningCases.flatMap { row in
  ([nil] + ["minimal", "low", "medium", "high", "xhigh", "max"].map(Optional.some)).flatMap {
    effort in
    [nil, "on", "off"].map { CLIReasoningCombination(row: row, effort: effort, thinking: $0) }
  }
}

extension ConfigurationTests {
  @Test(arguments: cliCombinations)
  fileprivate func reasoningCombinationsBeforeRequest(_ item: CLIReasoningCombination) async {
    let harness = ConfigurationHarness()
    let config =
      "provider = '\(item.row.provider)'\n"
      + (item.effort.map { "effort = '\($0)'\n" } ?? "")
      + (item.thinking.map { "thinking = '\($0)'\n" } ?? "")
    let variables = Dictionary(
      uniqueKeysWithValues: ProviderPreset.all.map {
        ($0.apiKeyEnvironmentVariable, "fake-test-key")
      })
    let code = await harness.run(
      ["fix", "input", "--model", item.row.model, "--json"], config: config, variables: variables)
    #expect(code == (item.valid ? 0 : 78))
    if item.valid {
      #expect(harness.provider.recordedRequests.count == 1)
      #expect(!harness.snapshot.err.contains("unknown field"))
    } else {
      #expect(harness.provider.recordedRequests.isEmpty)
      #expect(harness.snapshot.out.isEmpty)
      #expect(harness.snapshot.resolved == nil)
      #expect(harness.keychain.calls.withLock { $0.reads.isEmpty })
      #expect(harness.snapshot.commands.isEmpty)
      #expect(harness.snapshot.err.contains(item.row.model))
      #expect(harness.snapshot.err.contains("use ") || harness.snapshot.err.contains("omit "))
    }
  }

  @Test(
    arguments: ["fix", "explain"],
    [
      ["--effort", "extreme"], ["--effort", "none"], ["--thinking", "true"],
      ["--first-text-timeout", "0"], ["--first-text-timeout", "111"],
      ["--first-text-timeout", "1.5"], ["--first-text-timeout", "abc"],
      ["--first-text-timeout", "999999999999999999999"],
    ])
  func invalidReasoningArguments(command: String, options: [String]) async {
    let harness = ConfigurationHarness()
    #expect(await harness.run([command, "input", "--json"] + options) == 64)
    #expect(harness.provider.recordedRequests.isEmpty)
    #expect(harness.snapshot.out.isEmpty)
  }

  @Test(
    arguments: ["", "[models.'gpt-6-luna']\n"],
    [
      "effort = 'extreme'", "effort = 'none'", "effort = 5", "effort = true",
      "thinking = 'yes'", "thinking = false", "thinking = []",
      "first_text_timeout = 0", "first_text_timeout = 111", "first_text_timeout = 1.5",
      "first_text_timeout = 30.0", "first_text_timeout = '30'", "first_text_timeout = true",
    ])
  func invalidReasoningConfiguration(prefix: String, value: String) async {
    let harness = ConfigurationHarness()
    #expect(await harness.run(config: prefix + value) == 78)
    #expect(harness.provider.recordedRequests.isEmpty)
    #expect(harness.snapshot.out.isEmpty)
    #expect(harness.snapshot.err.contains("use "))
  }

  @Test func reasoningPrecedenceIsPerFieldAndOnlySelectedModelIsValidated() async throws {
    let config = """
      provider = 'claude'
      effort = 'high'
      thinking = 'off'
      first_text_timeout = 60
      [models.'claude-haiku-5-5']
      effort = 'low'
      thinking = 'on'
      first_text_timeout = 70
      [models.'unused']
      effort = 'extreme'
      thinking = false
      first_text_timeout = 500
      """
    for (options, effort, thinking, timeout) in [
      ([], "low", "on", 70),
      (["--effort", "medium"], "medium", "on", 70),
      (["--thinking", "off"], "low", "off", 70),
      (["--first-text-timeout", "80"], "low", "on", 80),
      (["--effort", "high", "--thinking", "on", "--first-text-timeout", "90"], "high", "on", 90),
    ] {
      let harness = ConfigurationHarness()
      #expect(
        await harness.run(
          ["fix", "input"] + options, config: config,
          variables: ["ANTHROPIC_API_KEY": "fake-test-key"]) == 0)
      let provider = try #require(harness.snapshot.resolved)
      #expect(provider.effectiveEffort == effort)
      #expect(provider.effectiveThinking == thinking)
      #expect(provider.firstTextTimeout == .seconds(timeout))
      #expect(!harness.snapshot.err.contains("unknown field"))
    }
    let top = ConfigurationHarness()
    #expect(await top.run(config: "effort = 'high'\nfirst_text_timeout = 60") == 0)
    #expect(top.snapshot.resolved?.effectiveThinking == "on")
    #expect(top.snapshot.resolved?.effectiveEffort == "high")
    #expect(top.snapshot.resolved?.firstTextTimeout == .seconds(60))
    let overridden = ConfigurationHarness()
    #expect(
      await overridden.run(
        ["fix", "input", "--effort", "low", "--thinking", "on", "--first-text-timeout", "1"],
        config: "effort = false\nthinking = 10\nfirst_text_timeout = 111") == 0)
    let modelOverridesTop = ConfigurationHarness()
    #expect(
      await modelOverridesTop.run(
        config: "effort = 'minimal'\n[models.'gpt-6-luna']\neffort = 'low'") == 0)
    for model in ["gemini-3.5-flash-lite", "gemini-3.8-flash"] {
      let harness = ConfigurationHarness()
      #expect(
        await harness.run(
          ["fix", "input", "--provider", "gemini", "--model", model], config: "effort = 'minimal'",
          variables: ["GEMINI_API_KEY": "fake-test-key"])
          == (model == "gemini-3.5-flash-lite" ? 0 : 78))
    }
  }

  @Test(arguments: ["fix", "explain"], ["unknown", "claude-opus-5-5"])
  func unknownReasoningModel(command: String, model: String) async {
    for config in ["effort = 'low'", "thinking = 'on'", "[models.'\(model)']\nthinking = 'off'"] {
      let harness = ConfigurationHarness()
      #expect(await harness.run([command, "input", "--model", model], config: config) == 78)
      #expect(harness.snapshot.err.contains("[models.\"\(model)\"].extra_body"))
      #expect(harness.provider.recordedRequests.isEmpty)
    }
    for args in [["--effort", "low"], ["--thinking", "on"]] {
      let harness = ConfigurationHarness()
      #expect(await harness.run([command, "input", "--model", model] + args) == 78)
      #expect(harness.provider.recordedRequests.isEmpty)
    }
    let timeout = ConfigurationHarness()
    _ = await timeout.run([command, "input", "--model", model, "--first-text-timeout", "110"])
    #expect(timeout.snapshot.resolved?.firstTextTimeout == .seconds(110))
    #expect(!timeout.provider.recordedRequests.isEmpty)
  }

  @Test(arguments: ["fix", "explain"])
  func reasoningVerboseAndHelp(command: String) async {
    let defaults = ConfigurationHarness()
    _ = await defaults.run([command, "input", "--verbose"])
    #expect(
      defaults.snapshot.err.contains(
        "effort=none(default) thinking=off(default) first_text_timeout=30"))
    let custom = ConfigurationHarness()
    _ = await custom.run([
      command, "input", "--effort", "high", "--first-text-timeout", "60", "--verbose",
    ])
    #expect(custom.snapshot.err.contains("effort=high thinking=on first_text_timeout=60"))
    #expect(!custom.snapshot.err.contains("(default)"))
    #expect(!custom.provider.recordedRequests.isEmpty)
    let help = ConfigurationHarness()
    #expect(await help.run([command, "--help"]) == 0)
    for text in [
      "--effort", "minimal", "xhigh", "--thinking", "on or off", "--first-text-timeout", "1–110",
      "default 30",
    ] {
      #expect(help.snapshot.out.contains(text))
    }
  }

  @Test func reasoningConfigShowAndCredentialNames() async {
    for name in ["effort", "thinking", "first_text_timeout"] {
      #expect(!CLIConfiguration.forbidden(name))
    }
    #expect(CLIConfiguration.forbidden("first_token_timeout"))
    let harness = ConfigurationHarness()
    #expect(
      await harness.run(
        ["config", "show"],
        config:
          "effort = 'low'\nthinking = 'on'\nfirst_text_timeout = 60\n[models.'gpt-6-luna']\neffort = 'high'\nfirst_text_timeout = 75"
      ) == 0)
    for text in [
      "effort = high [models.\"gpt-6-luna\"]", "thinking = on [config]",
      "first_text_timeout = 75 [models.\"gpt-6-luna\"]",
    ] { #expect(harness.snapshot.out.contains(text)) }
    #expect(harness.snapshot.err.isEmpty)
    let defaults = ConfigurationHarness()
    #expect(await defaults.run(["config", "show"]) == 0)
    for text in [
      "effort = none [default]", "thinking = off [default]", "first_text_timeout = 30 [default]",
    ] { #expect(defaults.snapshot.out.contains(text)) }
  }
}

extension ConfigurationTests {
  @Test(
    arguments: ["config", "model", "flag"],
    [
      ("thinking", "thinking = 'private-value'"),
      ("reasoning_effort", "reasoning_effort = 'private-value'"),
      ("output_config.effort", "output_config = { effort = 'private-value' }"),
    ])
  func reasoningExtraBodyConflict(source: String, field: (String, String)) async {
    for setting in ["effort", "thinking"] {
      let value = setting == "effort" ? "medium" : "off"
      let config =
        "provider = 'claude'\n"
        + (source == "config" ? "\(setting) = '\(value)'\n" : "")
        + "[models.'claude-haiku-5-5']\n"
        + (source == "model" ? "\(setting) = '\(value)'\n" : "")
        + "extra_body = { \(field.1) }"
      let harness = ConfigurationHarness()
      let flags = source == "flag" ? ["--\(setting)", value] : []
      #expect(await harness.run(["fix", "input"] + flags, config: config) == 78)
      #expect(harness.snapshot.err.contains("extra_body.\(field.0)"))
      #expect(harness.snapshot.err.contains("effort or thinking"))
      #expect(!harness.snapshot.err.contains("private-value"))
      #expect(harness.provider.recordedRequests.isEmpty)
      #expect(harness.snapshot.commands.isEmpty)
      #expect(harness.keychain.calls.withLock { $0.reads.isEmpty })
    }
  }

  @Test func configShowEffectiveReasoningAndSources() async {
    let config = """
      provider = 'claude'
      effort = 'high'
      thinking = 'on'
      first_text_timeout = 60
      [models.'claude-haiku-5-5']
      effort = 'low'
      first_text_timeout = 75
      """
    for flags in [[], ["--effort", "medium", "--thinking", "off", "--first-text-timeout", "90"]] {
      let harness = ConfigurationHarness()
      #expect(await harness.run(["config", "show"] + flags, config: config) == 0)
      let expected =
        flags.isEmpty
        ? [
          "effort = low [models.\"claude-haiku-5-5\"]", "thinking = on [config]",
          "first_text_timeout = 75 [models.\"claude-haiku-5-5\"]",
        ]
        : ["effort = medium [flag]", "thinking = off [flag]", "first_text_timeout = 90 [flag]"]
      for line in expected { #expect(harness.snapshot.out.contains(line)) }
      #expect(harness.provider.recordedRequests.isEmpty)
      #expect(harness.keychain.calls.withLock { $0.reads.isEmpty })
    }
    for (flags, expected) in [
      (["--thinking", "on"], ["effort = medium [flag]", "thinking = on [flag]"]),
      (["--effort", "high"], ["effort = high [flag]", "thinking = on [flag]"]),
    ] {
      let harness = ConfigurationHarness()
      #expect(await harness.run(["config", "show"] + flags) == 0)
      for line in expected { #expect(harness.snapshot.out.contains(line)) }
    }
  }
}

extension ConfigurationTests {
  @Test(arguments: [false, true])
  func extraBodyWithoutReasoningKeepsAdvancedSettings(timeoutOnly: Bool) async throws {
    let harness = ConfigurationHarness()
    let config = """
      provider = 'claude'
      \(timeoutOnly ? "first_text_timeout = 60" : "")
      [models.'claude-haiku-5-5']
      extra_body = { thinking = { type = 'disabled' }, output_config = { effort = 'high', other = true }, reasoning_effort = 'low' }
      """
    #expect(
      await harness.run(config: config, variables: ["ANTHROPIC_API_KEY": "fake-test-key"]) == 0)
    let resolved = try #require(harness.snapshot.resolved)
    let body = resolved.requestBody(for: .init(messages: []))
    #expect(body["thinking"] == .object(["type": .string("disabled")]))
    #expect(body["output_config"] == .object(["effort": .string("high"), "other": .bool(true)]))
    #expect(body["reasoning_effort"] == .string("low"))
  }

  @Test func extraBodyOtherOutputFieldsMergeWithReasoning() async throws {
    let harness = ConfigurationHarness()
    #expect(
      await harness.run(
        config: """
          provider = 'claude'
          effort = 'low'
          [models.'claude-haiku-5-5']
          extra_body = { output_config = { other = true } }
          [models.'unused']
          effort = 'high'
          extra_body = { reasoning_effort = 'private-value' }
          """, variables: ["ANTHROPIC_API_KEY": "fake-test-key"]) == 0)
    let resolved = try #require(harness.snapshot.resolved)
    #expect(
      resolved.requestBody(for: .init(messages: []))["output_config"]
        == .object([
          "effort": .string("low"), "other": .bool(true),
        ]))
  }

  @Test(arguments: [
    "thinking = false", "reasoning_effort = false", "output_config = { effort = false }",
    "output_config = 'private-value'",
  ])
  func extraBodyConflictsDependOnFieldPresence(field: String) async {
    let harness = ConfigurationHarness()
    #expect(
      await harness.run(
        ["config", "show", "--thinking", "on"],
        config: """
          provider = 'claude'
          [models.'claude-haiku-5-5']
          extra_body = { \(field) }
          """) == 78)
    #expect(harness.snapshot.err.contains("extra_body."))
    #expect(!harness.snapshot.err.contains("private-value"))
    #expect(harness.snapshot.out.isEmpty)
  }

  @Test func configShowRecommendedAndInferredSources() async {
    let recommended = ConfigurationHarness()
    #expect(
      await recommended.run(
        ["config", "show"],
        config: "provider = 'claude'\n[providers.claude]\nmodel = 'claude-sonnet-5-5'") == 0)
    #expect(recommended.snapshot.out.contains("effort = low [default]"))
    #expect(recommended.snapshot.out.contains("thinking = off [default]"))
    let inferred = ConfigurationHarness()
    #expect(
      await inferred.run(["config", "show"], config: "[models.'gpt-6-luna']\nthinking = 'on'") == 0)
    #expect(inferred.snapshot.out.contains("effort = medium [models.\"gpt-6-luna\"]"))
    #expect(inferred.snapshot.out.contains("thinking = on [models.\"gpt-6-luna\"]"))
    let disabled = ConfigurationHarness()
    #expect(
      await disabled.run(
        ["config", "show"], config: "provider = 'claude'\neffort = 'high'\nthinking = 'off'") == 0)
    #expect(disabled.snapshot.out.contains("effort = high [config]"))
    #expect(disabled.snapshot.out.contains("thinking = off [config]"))
  }
}

extension ConfigurationTests {
  @Test(
    arguments: [
      ("thinking = 'private-value'", false, true),
      ("output_config = { effort = 'private-value' }", true, false),
      ("reasoning_effort = 'private-value'", true, true),
      ("output_config = 'private-value'", true, false),
      ("output_config = { other = 'private-value' }", false, false),
      ("thinking = false, output_config = { effort = false }", true, true),
    ], [false, true])
  func extraBodyReasoningMetadata(fields: (String, Bool, Bool), timeoutOnly: Bool) async {
    let config = """
      provider = 'claude'
      \(timeoutOnly ? "first_text_timeout = 60" : "")
      [models.'claude-haiku-5-5']
      extra_body = { \(fields.0) }
      """
    let show = ConfigurationHarness()
    #expect(await show.run(["config", "show"], config: config) == 0)
    #expect(
      show.snapshot.out.contains(
        fields.1 ? "effort = <set> [extra_body]" : "effort = medium [default]"))
    #expect(
      show.snapshot.out.contains(
        fields.2 ? "thinking = <set> [extra_body]" : "thinking = on [default]"))
    #expect(!show.snapshot.out.contains("private-value"))
    for command in ["fix", "explain"] {
      let harness = ConfigurationHarness()
      _ = await harness.run(
        [command, "input", "--verbose"], config: config,
        variables: ["ANTHROPIC_API_KEY": "fake-test-key"])
      #expect(
        harness.snapshot.err.contains(fields.1 ? "effort=(extra_body)" : "effort=medium(default)"))
      #expect(
        harness.snapshot.err.contains(fields.2 ? "thinking=(extra_body)" : "thinking=on(default)"))
      #expect(!harness.snapshot.err.contains("private-value"))
      #expect(!harness.snapshot.out.contains("private-value"))
      #expect(harness.snapshot.err.contains("first_text_timeout=\(timeoutOnly ? 60 : 30)"))
    }
  }
}
