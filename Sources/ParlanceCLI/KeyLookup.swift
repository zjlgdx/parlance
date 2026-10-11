import Foundation
import ParlanceCore

struct KeyLookup {
  let environment: CLIEnvironment
  let sources: KeySources
  let command: String?
  let store: any KeychainStoring

  init(preset: ProviderPreset, baseURL: URL?, command: String?, environment: CLIEnvironment) {
    let interactive = KeychainStore.interactionAllowed(
      stderrIsTerminal: environment.stderrIsTTY, environment: environment.variables)
    self.environment = environment
    self.sources = KeySources(preset: preset, baseURL: baseURL, usesKeychain: interactive)
    self.command = command
    self.store = environment.makeKeychain(interactive)
  }

  func key(for provider: ResolvedProvider) async throws -> String? {
    if !BaseURLPolicy.allowsKey(provider.baseURL) {
      // Short circuit env/cmd presence before probing, but use the same account as the later read.
      var exists = false
      if !sources.hasSource(
        environment: environment.variables, keychainExists: false, command: command),
        sources.usesKeychain, let account = sources.keychainAccount
      {
        do { exists = try store.exists(account: account) } catch {
          try cliFail(
            3, "could not check Keychain before plain HTTP. Use HTTPS or check Keychain access.",
            environment)
        }
      }
      if sources.hasSource(
        environment: environment.variables, keychainExists: exists, command: command)
      {
        try cliFail(
          78, "refusing to send an API key over plain HTTP. Use HTTPS or a loopback address.",
          environment)
      }
    }
    if sources.changedOrigin && command != nil {
      environment.stderr("pl: api_key_cmd skipped because the named preset uses another origin.\n")
    }
    if sources.changedOrigin && !sources.usesKeychain {
      environment.stderr(
        "pl: this named preset has no key source in non-interactive mode. Use compatible for a custom origin.\n"
      )
    }
    if let variable = sources.environmentVariable, let value = environment.variables[variable],
      KeySources.hasEnvironmentKey(value)
    {
      return value
    }
    if sources.usesKeychain, let account = sources.keychainAccount {
      do {
        let value = try store.read(account: account)
        if !value.isEmpty { return value }
      } catch KeychainError.notFound {
        // Missing credentials fall through to the helper.
      } catch KeychainError.denied {
        environment.stderr("pl: Keychain access denied; continuing key lookup.\n")
      } catch KeychainError.locked {
        environment.stderr("pl: Keychain is locked; continuing key lookup.\n")
      } catch {
        try cliFail(
          3, "could not read Keychain. Check Keychain access or set an environment key.",
          environment)
      }
    } else {
      environment.stderr("pl: Keychain skipped in non-interactive mode.\n")
    }
    if sources.usesCommand, let command {
      let result = await environment.runKeyCommand(command, 30)
      let detail: String
      switch result.termination {
      case .exit(0) where result.stdoutOverflowed:
        detail = "exited with status 0 but returned too much output"
      case .exit(0):
        if let raw = String(data: result.stdout, encoding: .utf8) {
          let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
          if !value.isEmpty && value.rangeOfCharacter(from: .newlines) == nil { return value }
        }
        detail = "exited with status 0 but returned an invalid key"
      case .exit(let code): detail = "exited with status \(code)"
      case .signal(let signal): detail = "terminated by signal \(signal)"
      case .timeout: detail = "timed out after 30s"
      case .launchFailed: detail = "could not start"
      }
      try cliFail(
        3, "api_key_cmd \(detail); run the api_key_cmd yourself to see its output.", environment)
    }
    if sources.effectiveRequiresKey {
      try cliFail(
        3,
        "an API key is required. Please set \(provider.preset.apiKeyEnvironmentVariable), use pl auth set or configure api_key_cmd.",
        environment)
    }
    return nil
  }

  /// Attribute probes are allowed in status even when reads are excluded by this invocation's mode.
  func status() -> String {
    let envUsable =
      KeySources.hasEnvironmentKey(
        sources.environmentVariable.flatMap { environment.variables[$0] })
    var keychainUsable = false
    var parts: [String] = []
    if envUsable { parts.append("env (used)") }
    if let account = sources.keychainAccount {
      do {
        if try store.exists(account: account) {
          keychainUsable = sources.usesKeychain
          parts.append(
            "keychain (\(sources.usesKeychain ? (envUsable ? "fallback" : "used") : "not used in non-interactive mode"))"
          )
        }
      } catch { parts.append("keychain (unavailable)") }
    }
    if command != nil {
      parts.append(
        sources.usesCommand
          ? "cmd configured (\(envUsable || keychainUsable ? "fallback" : "used"))"
          : "cmd configured (not used: changed origin)")
    }
    return parts.isEmpty ? "none" : parts.joined(separator: "; ")
  }
}
