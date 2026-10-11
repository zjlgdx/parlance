import Foundation

extension RewriteSettings.Tone: Codable {}
extension ExplainDeepSection: Codable {}

/// The shared settings value. Each client owns its persistence and secret storage.
public struct ParlanceSettings: Sendable, Equatable, Codable {
  public var providerPresetID = ProviderPreset.deepseek.id
  public var modelOverride: String?
  public var baseURLOverride: String?
  public var targetLanguage = RewriteSettings().targetLanguage
  public var nativeLanguage = RewriteSettings().nativeLanguage
  public var tone = RewriteSettings().tone
  public var autoExpandItems: Set<ExplainDeepSection> = []
  public var excludedAppBundleIDs: [String] = []
  public var screenContextEnabled = false

  public init() {}

  public var preset: ProviderPreset { ProviderPreset.named(providerPresetID) ?? .deepseek }
  public var effectiveModel: String? { Self.nonempty(modelOverride) ?? preset.defaultModel }
  public var effectiveBaseURL: URL? {
    if let override = Self.nonempty(baseURLOverride) { return URL(string: override) }
    return preset.baseURL
  }
  public var keySources: KeySources {
    KeySources(preset: preset, baseURL: effectiveBaseURL, usesKeychain: true)
  }
  public var effectiveRequiresKey: Bool { keySources.effectiveRequiresKey }
  public var keychainAccount: String? {
    guard let url = effectiveBaseURL, BaseURLPolicy.violation(of: url) == nil else { return nil }
    return keySources.keychainAccount
  }

  public enum ModelFormError: Error, Sendable, Equatable {
    case missingModel, missingBaseURL, invalidBaseURL, insecureKey
  }

  public func modelFormValidation(savingKey: Bool = false) -> ModelFormError? {
    guard effectiveModel != nil else { return .missingModel }
    if preset.baseURL == nil && Self.nonempty(baseURLOverride) == nil { return .missingBaseURL }
    guard let url = effectiveBaseURL, BaseURLPolicy.violation(of: url) == nil else {
      return .invalidBaseURL
    }
    if savingKey && !BaseURLPolicy.allowsKey(url) { return .insecureKey }
    return nil
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
}
