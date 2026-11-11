import Foundation

extension RewriteSettings.Tone: Codable {}
extension RewriteSettings.Mode: Codable {}
extension ExplainDeepSection: Codable {}

/// The shared settings value. Each client owns its persistence and secret storage.
public struct ParlanceSettings: Sendable, Equatable, Codable {
  public var providerPresetID = ProviderPreset.deepseek.id
  public var modelOverride: String?
  public var baseURLOverride: String?
  public var targetLanguage = RewriteSettings().targetLanguage
  public var nativeLanguage = RewriteSettings().nativeLanguage
  public var tone = RewriteSettings().tone
  /// The 改写档位: polish or 只改错.
  public var rewriteMode = RewriteSettings().mode
  public var autoExpandItems: Set<ExplainDeepSection> = []
  public var excludedAppBundleIDs: [String] = []
  public var glossaryEnabled = true
  public var contextEnabled = true
  public var screenContextEnabled = false
  /// Asks for the 纠错 (fixes) section when the input is already in the target language.
  public var includeFixes = true

  public init() {}

  private enum CodingKeys: String, CodingKey {
    case providerPresetID, modelOverride, baseURLOverride, targetLanguage, nativeLanguage, tone
    case rewriteMode, glossaryEnabled
    case autoExpandItems, excludedAppBundleIDs, screenContextEnabled, includeFixes, contextEnabled
  }

  /// New default-on switches remain enabled when older stored settings omit them.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    providerPresetID = try values.decode(String.self, forKey: .providerPresetID)
    modelOverride = try values.decodeIfPresent(String.self, forKey: .modelOverride)
    baseURLOverride = try values.decodeIfPresent(String.self, forKey: .baseURLOverride)
    targetLanguage = try values.decode(String.self, forKey: .targetLanguage)
    nativeLanguage = try values.decode(String.self, forKey: .nativeLanguage)
    tone = try values.decode(RewriteSettings.Tone.self, forKey: .tone)
    rewriteMode =
      try values.decodeIfPresent(RewriteSettings.Mode.self, forKey: .rewriteMode) ?? .polish
    autoExpandItems = try values.decode(Set<ExplainDeepSection>.self, forKey: .autoExpandItems)
    excludedAppBundleIDs = try values.decode([String].self, forKey: .excludedAppBundleIDs)
    screenContextEnabled = try values.decode(Bool.self, forKey: .screenContextEnabled)
    glossaryEnabled = try values.decodeIfPresent(Bool.self, forKey: .glossaryEnabled) ?? true
    contextEnabled = try values.decodeIfPresent(Bool.self, forKey: .contextEnabled) ?? true
    includeFixes = try values.decodeIfPresent(Bool.self, forKey: .includeFixes) ?? true
  }

  /// Window OCR (and its prewarm) runs only while context is on and the screen-context switch is on.
  public var windowContextActive: Bool { contextEnabled && screenContextEnabled }

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
