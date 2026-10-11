import Foundation

/// The sources a caller may query, in lookup order. Presence and secret reads stay with the caller.
/// Status may probe an excluded Keychain account, but must label it as unused in this mode.
public struct KeySources: Sendable, Equatable {
  public let environmentVariable: String?
  public let keychainAccount: String?
  public let usesKeychain: Bool
  public let usesCommand: Bool
  public let changedOrigin: Bool
  public let effectiveRequiresKey: Bool

  public init(preset: ProviderPreset, baseURL: URL?, usesKeychain: Bool) {
    let baseURL = baseURL ?? preset.baseURL
    keychainAccount = KeychainAccount.for(preset, baseURL: baseURL)
    changedOrigin =
      preset.baseURL != nil
      && baseURL.map { KeychainAccount.origin(of: $0) }
        != preset.baseURL.map {
          KeychainAccount.origin(of: $0)
        }
    environmentVariable = changedOrigin ? nil : preset.apiKeyEnvironmentVariable
    self.usesKeychain = usesKeychain && keychainAccount != nil
    usesCommand = !changedOrigin
    effectiveRequiresKey = preset.requiresKey && !changedOrigin
  }

  /// API-key variables count as set only when non-empty. This is deliberately different from
  /// SSH mode variables, whose presence alone disables interactive Keychain reads.
  public static func hasEnvironmentKey(_ value: String?) -> Bool {
    value.map { !$0.isEmpty } ?? false
  }

  /// Evaluate before reading secrets or running a helper. The probe must use `keychainAccount`.
  public func hasSource(environment: [String: String], keychainExists: Bool, command: String?)
    -> Bool
  {
    Self.hasEnvironmentKey(environmentVariable.flatMap { environment[$0] })
      || (usesKeychain && keychainExists) || (usesCommand && command != nil)
  }
}
