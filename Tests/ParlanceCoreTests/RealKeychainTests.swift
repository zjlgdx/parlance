import Foundation
import ParlanceCore
import Security
import Testing

struct RealKeychainTests {
  static var enabled: Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["CI"] == nil && environment["PARLANCE_KEYCHAIN_TESTS"] == "1"
  }

  @Test(.enabled(if: RealKeychainTests.enabled))
  func roundTrip() throws {
    let store = KeychainStore(service: "com.parlance.tests.keychain")
    let account = "probe-\(UUID())"
    let secret = "pl-test-fake-key-\(UUID())"
    let replacement = "pl-test-fake-key-\(UUID())-中文"
    defer { try? store.delete(account: account) }

    #expect(try !store.exists(account: account))
    try store.write(account: account, secret: secret)
    #expect(try store.exists(account: account))
    #expect(try store.read(account: account) == secret)
    try store.write(account: account, secret: replacement)
    #expect(try store.read(account: account) == replacement)
    #expect(throws: KeychainError.other(errSecParam)) {
      try store.write(account: account, secret: "")
    }
    #expect(try store.read(account: account) == replacement)
    try store.delete(account: account)
    #expect(try !store.exists(account: account))
    #expect(throws: KeychainError.notFound) { try store.read(account: account) }
    #expect(throws: KeychainError.notFound) { try store.delete(account: account) }
  }

  @Test(.enabled(if: RealKeychainTests.enabled))
  func nonInteractivePolicyOnlyGatesReads() throws {
    let store = KeychainStore(service: "com.parlance.tests.keychain", allowsInteraction: false)
    let account = "probe-\(UUID())"
    defer { try? store.delete(account: account) }

    #expect(try !store.exists(account: account))
    try store.write(account: account, secret: "pl-test-fake-key-\(UUID())")
    #expect(try store.exists(account: account))
    #expect(throws: KeychainError.interactionNotAllowed) { try store.read(account: account) }
    try store.write(account: account, secret: "pl-test-fake-key-\(UUID())")
    try store.delete(account: account)
    #expect(try !store.exists(account: account))
    #expect(throws: KeychainError.interactionNotAllowed) { try store.read(account: account) }
  }

  @Test(.enabled(if: RealKeychainTests.enabled))
  func invalidUTF8ProducesDecodeError() throws {
    let store = KeychainStore(service: "com.parlance.tests.keychain")
    let account = "probe-\(UUID())"
    defer { try? store.delete(account: account) }
    var data = Data("pl-test-fake-key-\(UUID())".utf8)
    data.append(0xFF)
    let attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: store.service,
      kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: false,
      kSecValueData as String: data,
    ]
    try #require(SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess)
    #expect(try store.exists(account: account))
    #expect(throws: KeychainError.other(errSecDecode)) { try store.read(account: account) }
  }
}
