import Foundation
import ParlanceCore
import Security
import Testing

struct KeychainTests {
  @Test(arguments: [
    ("https://API.DeepSeek.com/v1/", "https://api.deepseek.com"),
    ("https://host:443/x", "https://host"),
    ("http://localhost:11434/v1", "http://localhost:11434"),
    ("http://host:80", "http://host"),
    ("https://host:8443", "https://host:8443"),
    ("HTTPS://Host", "https://host"),
    ("https://user:x@host/v1?query=value#fragment", "https://host"),
    ("http://[::1]:11434/v1", "http://[::1]:11434"),
    ("https://[::1]:443/v1", "https://[::1]"),
  ])
  func normalizedOrigins(input: String, expected: String) throws {
    let url = try #require(URL(string: input))
    #expect(KeychainAccount.origin(of: url) == expected)
  }

  @Test(arguments: ["file:///x", "https://", "/relative"])
  func missingOriginsFallBackToIDOnlyForNamedPresets(input: String) throws {
    let url = try #require(URL(string: input))
    #expect(KeychainAccount.origin(of: url) == nil)
    for preset in ProviderPreset.all {
      let expected: String? = preset.baseURL == nil ? nil : preset.id
      #expect(KeychainAccount.for(preset, baseURL: url) == expected)
    }
  }

  @Test func absentOverridesUseIDAndCompatibleHasNoAccount() {
    for preset in ProviderPreset.all {
      let expected: String? = preset.baseURL == nil ? nil : preset.id
      #expect(KeychainAccount.for(preset, baseURL: nil) == expected)
      if let baseURL = preset.baseURL {
        #expect(KeychainAccount.for(preset, baseURL: baseURL) == preset.id)
      }
    }
    #expect(KeychainAccount.for(.compatible, baseURL: nil) == nil)
  }

  @Test(arguments: [
    ("https://api.deepseek.com/v1/", "deepseek"),
    ("https://api.deepseek.com:443/v1/", "deepseek"),
    ("https://API.DeepSeek.com/v1/", "deepseek"),
    ("https://openrouter.ai/api/v1", "deepseek@https://openrouter.ai"),
    ("http://api.deepseek.com/v1", "deepseek@http://api.deepseek.com"),
    ("https://api.deepseek.com:8443/v1", "deepseek@https://api.deepseek.com:8443"),
  ])
  func namedAccounts(input: String, expected: String) throws {
    let url = try #require(URL(string: input))
    #expect(KeychainAccount.for(.deepseek, baseURL: url) == expected)
    let provider = ResolvedProvider(preset: .deepseek, baseURL: url, model: "test-model")
    #expect(KeychainAccount.for(provider) == expected)
  }

  @Test func compatibleAccountIncludesOrigin() throws {
    let url = try #require(URL(string: "http://localhost:11434/v1"))
    let expected = "compatible@http://localhost:11434"
    #expect(KeychainAccount.for(.compatible, baseURL: url) == expected)
    let provider = ResolvedProvider(preset: .compatible, baseURL: url, model: "test-model")
    #expect(KeychainAccount.for(provider) == expected)
  }

  @Test(arguments: [
    (errSecItemNotFound, KeychainError.notFound),
    (errSecAuthFailed, .denied),
    (errSecUserCanceled, .denied),
    (errSecInteractionNotAllowed, .locked),
    (errSecNotAvailable, .unavailable),
    (errSecNoSuchKeychain, .unavailable),
    (OSStatus(-12345), .other(-12345)),
    (errSecDecode, .other(errSecDecode)),
    (errSecParam, .other(errSecParam)),
  ])
  func classifiesStatus(status: OSStatus, expected: KeychainError) {
    #expect(KeychainError(status: status) == expected)
  }

  @Test func interactionPolicy() {
    #expect(KeychainStore.interactionAllowed(stderrIsTerminal: true, environment: [:]))
    for environment in [
      [:], ["SSH_CONNECTION": "test-connection"], ["SSH_TTY": "/dev/test-tty"],
      ["SSH_CONNECTION": ""], ["SSH_TTY": ""],
    ] {
      #expect(!KeychainStore.interactionAllowed(stderrIsTerminal: false, environment: environment))
      if !environment.isEmpty {
        #expect(!KeychainStore.interactionAllowed(stderrIsTerminal: true, environment: environment))
      }
    }
    #expect(
      KeychainStore.interactionAllowed(stderrIsTerminal: true, environment: ["TERM": "test"]))
  }

  @Test func nonInteractiveReadIsRefused() {
    let store = KeychainStore(service: "com.parlance.tests.keychain", allowsInteraction: false)
    #expect(throws: KeychainError.interactionNotAllowed) {
      try store.read(account: "probe-\(UUID())")
    }
  }

  @Test func storeDefaults() {
    let store = KeychainStore()
    #expect(store.service == "Parlance")
    #expect(store.allowsInteraction)
  }

  @Test func memoryRoundTrip() throws {
    let memory = MemoryKeychain()
    let store: any KeychainStoring = memory
    #expect(try !store.exists(account: "test"))
    try store.write(account: "test", secret: "pl-test-fake-key-first")
    #expect(try store.exists(account: "test"))
    #expect(try store.read(account: "test") == "pl-test-fake-key-first")
    try store.write(account: "test", secret: "pl-test-fake-key-second")
    #expect(try store.read(account: "test") == "pl-test-fake-key-second")
    #expect(memory.secrets == ["test": "pl-test-fake-key-second"])
    try store.delete(account: "test")
    #expect(try !store.exists(account: "test"))
    #expect(throws: KeychainError.notFound) { try store.read(account: "test") }
    #expect(throws: KeychainError.notFound) { try store.delete(account: "test") }
    #expect(memory.secrets.isEmpty)
  }

  @Test func memoryFailuresArePersistentAndScopedToAccount() throws {
    let initial = ["blocked": "pl-test-fake-key-blocked", "working": "pl-test-fake-key-working"]
    let store = MemoryKeychain(initial: initial)
    store.fail(account: "blocked", with: .locked)
    #expect(throws: KeychainError.locked) { try store.read(account: "blocked") }
    #expect(throws: KeychainError.locked) { try store.exists(account: "blocked") }
    #expect(throws: KeychainError.locked) {
      try store.write(account: "blocked", secret: "pl-test-fake-key-replacement")
    }
    #expect(throws: KeychainError.locked) { try store.delete(account: "blocked") }
    #expect(store.secrets == initial)
    #expect(try store.read(account: "working") == initial["working"])
    #expect(try store.exists(account: "working"))
    try store.write(account: "working", secret: "pl-test-fake-key-new")
    #expect(try store.read(account: "working") == "pl-test-fake-key-new")
    try store.delete(account: "working")
    #expect(try !store.exists(account: "working"))
    store.fail(account: "blocked", with: .denied)
    #expect(throws: KeychainError.denied) { try store.read(account: "blocked") }
  }

  @Test func memoryRejectsEmptySecretsWithoutChangingStoredValue() throws {
    let store = MemoryKeychain(initial: ["test": "pl-test-fake-key-original"])
    store.fail(account: "blocked", with: .locked)
    for account in ["test", "absent", "blocked"] {
      #expect(throws: KeychainError.other(errSecParam)) {
        try store.write(account: account, secret: "")
      }
    }
    #expect(store.secrets == ["test": "pl-test-fake-key-original"])
  }

  @Test func memoryExistsReportsInjectedNotFoundAsFalse() throws {
    let store = MemoryKeychain(initial: ["test": "pl-test-fake-key"])
    store.fail(account: "test", with: .notFound)
    #expect(try !store.exists(account: "test"))
    #expect(throws: KeychainError.notFound) { try store.read(account: "test") }
    store.fail(account: "test", with: .unavailable)
    #expect(throws: KeychainError.unavailable) { try store.exists(account: "test") }
  }

  @Test func memorySupportsConcurrentAccounts() async throws {
    let store = MemoryKeychain()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<100 {
        group.addTask {
          let account = "test-\(index)"
          let secret = "pl-test-fake-key-\(index)"
          try store.write(account: account, secret: secret)
          #expect(try store.exists(account: account))
          #expect(try store.read(account: account) == secret)
          try store.delete(account: account)
        }
      }
      try await group.waitForAll()
    }
    #expect(store.secrets.isEmpty)
  }
}
