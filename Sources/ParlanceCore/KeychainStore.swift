import Foundation
import Security

/// Account names shared by the CLI and App (CLI and core design §7).
public enum KeychainAccount {
  /// `<id>` for a preset on its default origin, `<id>@<origin>` for another origin, and always
  /// `<id>@<origin>` for a preset without a default URL (`compatible`). Nil when such a preset has no
  /// origin to qualify it with: the design has no account for that case (the CLI exits 78, the App
  /// requires a base URL), so callers must not probe or write anything. A named preset whose override
  /// lacks an origin falls back to `<id>`; `BaseURLPolicy` rejects such URLs before this is reached.
  public static func `for`(_ preset: ProviderPreset, baseURL: URL?) -> String? {
    guard let baseURL, let origin = origin(of: baseURL) else {
      return preset.baseURL == nil ? nil : preset.id
    }
    if let defaultURL = preset.baseURL, origin == self.origin(of: defaultURL) {
      return preset.id
    }
    return "\(preset.id)@\(origin)"
  }

  public static func `for`(_ provider: ResolvedProvider) -> String? {
    Self.for(provider.preset, baseURL: provider.baseURL)
  }

  /// Lowercases scheme and host, omits default HTTP(S) ports, and drops other URL components.
  /// Returns nil if the scheme or host is missing; URL validation belongs to `BaseURLPolicy`.
  public static func origin(of url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
      let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
    else { return nil }
    // Brackets keep an IPv6 host distinct from the optional port.
    let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    var origin = "\(scheme)://\(authority)"
    if let port = url.port,
      !(scheme == "https" && port == 443), !(scheme == "http" && port == 80)
    {
      origin += ":\(port)"
    }
    return origin
  }
}

/// Failures that callers can classify without inspecting Security status codes.
public enum KeychainError: Error, Sendable, Equatable {
  case notFound
  /// `errSecAuthFailed` or `errSecUserCanceled`: the user declined the prompt or authentication failed.
  case denied
  /// `errSecInteractionNotAllowed`: Security needed a prompt (typically to unlock the keychain) and
  /// could not show one.
  case locked
  /// `errSecNotAvailable` or `errSecNoSuchKeychain`: no keychain to talk to.
  case unavailable
  /// The store refused to read because the caller said interaction is not allowed; Security was not
  /// called.
  case interactionNotAllowed
  case other(OSStatus)

  /// A success status is a programming error, not a Keychain failure.
  public init(status: OSStatus) {
    precondition(status != errSecSuccess, "A successful Keychain operation is not an error")
    switch status {
    case errSecItemNotFound: self = .notFound
    case errSecAuthFailed, errSecUserCanceled: self = .denied
    case errSecInteractionNotAllowed: self = .locked
    case errSecNotAvailable, errSecNoSuchKeychain: self = .unavailable
    default: self = .other(status)
    }
  }
}

public protocol KeychainStoring: Sendable {
  /// Reads the secret; may show a system prompt for an item another program created.
  func read(account: String) throws -> String
  /// Probes attributes without requesting the secret data.
  func exists(account: String) throws -> Bool
  /// Creates or replaces an item; empty secrets are rejected with `.other(errSecParam)`.
  func write(account: String, secret: String) throws
  /// Deletes an item; throws `.notFound` when absent.
  func delete(account: String) throws
}

public struct KeychainStore: KeychainStoring {
  public static let defaultService = "Parlance"
  public var service: String
  /// False refuses reads before calling Security; `exists`, `write` and `delete` are not gated.
  /// Updating or deleting an item another program created can also need the authorisation prompt,
  /// so a caller that runs non-interactively decides for itself whether to attempt those.
  public var allowsInteraction: Bool

  public init(service: String = defaultService, allowsInteraction: Bool = true) {
    self.service = service
    self.allowsInteraction = allowsInteraction
  }

  /// Only stderr terminal status matters. SSH variables count as set even when empty.
  public static func interactionAllowed(
    stderrIsTerminal: Bool, environment: [String: String]
  ) -> Bool {
    stderrIsTerminal && environment["SSH_CONNECTION"] == nil && environment["SSH_TTY"] == nil
  }

  public func read(account: String) throws -> String {
    guard allowsInteraction else { throw KeychainError.interactionNotAllowed }
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    // Invalid result types and non-UTF-8 data share Security's decoding failure code.
    guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
      throw KeychainError.other(errSecDecode)
    }
    return secret
  }

  /// Attribute-only query. The design assumes it does not trigger the authorisation prompt even for an
  /// item another program created; docs/notes/2026-10-10-keychain-store-validation.md records the
  /// measurement.
  public func exists(account: String) throws -> Bool {
    var query = baseQuery(account: account)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return false }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    return true
  }

  public func write(account: String, secret: String) throws {
    guard !secret.isEmpty else { throw KeychainError.other(errSecParam) }
    let data = Data(secret.utf8)
    let query = baseQuery(account: account)
    var attributes = query
    attributes[kSecValueData as String] = data
    var status = SecItemAdd(attributes as CFDictionary, nil)
    if status == errSecDuplicateItem {
      status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
  }

  public func delete(account: String) throws {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess else { throw KeychainError(status: status) }
  }

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      // Use the traditional keychain so sharing does not require a data-protection access group.
      // Omit synchronizable (which can select data protection) and authentication UI flags
      // (which do not suppress prompts for traditional keychain items on macOS).
      kSecUseDataProtectionKeychain as String: false,
    ]
  }
}
