import Foundation
import Testing

@testable import ParlanceCore

struct SettingsTests {
  @Test func accountDoesNotRequireModel() {
    var settings = ParlanceSettings()
    settings.providerPresetID = "compatible"
    settings.baseURLOverride = "https://example.com/v1"
    #expect(settings.modelFormValidation() == .missingModel)
    #expect(settings.keychainAccount == "compatible@https://example.com")
    settings.baseURLOverride = "ftp://example.com"
    #expect(settings.keychainAccount == nil)
  }

  @Test func defaultsAndRoundTrip() throws {
    var settings = ParlanceSettings()
    #expect(settings.preset == .deepseek)
    #expect(settings.effectiveModel == ProviderPreset.deepseek.defaultModel)
    #expect(settings.targetLanguage == RewriteSettings().targetLanguage)
    #expect(settings.nativeLanguage == RewriteSettings().nativeLanguage)
    #expect(settings.autoExpandItems.isEmpty)
    #expect(!settings.screenContextEnabled)
    settings.tone = .casual
    settings.autoExpandItems = [.vocab, .domain]
    settings.excludedAppBundleIDs = ["com.example.editor"]
    settings.screenContextEnabled = true
    let decoded = try JSONDecoder().decode(
      ParlanceSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded == settings)
    settings.providerPresetID = "future-provider"
    #expect(settings.preset == .deepseek)
  }

  @Test func compatibleRequiresModelAndURL() {
    var settings = ParlanceSettings()
    settings.providerPresetID = "compatible"
    #expect(settings.modelFormValidation() == .missingModel)
    #expect(settings.keychainAccount == nil)
    settings.modelOverride = "example-model"
    #expect(settings.modelFormValidation() == .missingBaseURL)
    settings.baseURLOverride = "http://localhost:11434/v1"
    #expect(settings.modelFormValidation(savingKey: true) == nil)
    #expect(!settings.effectiveRequiresKey)
    #expect(settings.keychainAccount == "compatible@http://localhost:11434")
  }

  @Test func changedOriginMakesKeyOptionalWithoutChangingPreset() {
    var settings = ParlanceSettings()
    settings.providerPresetID = "claude"
    settings.baseURLOverride = "https://proxy.example/v1"
    #expect(!settings.effectiveRequiresKey)
    #expect(settings.keySources.changedOrigin)
    #expect(settings.keychainAccount == "claude@https://proxy.example")
    #expect(settings.preset == .claude)
    #expect(settings.effectiveModel == ProviderPreset.claude.defaultModel)
    settings.baseURLOverride = "https://API.ANTHROPIC.COM:443/other-path"
    #expect(settings.effectiveRequiresKey)
    #expect(settings.keychainAccount == "claude")
  }

  @Test(arguments: [
    "not a URL", "ftp://example.com", "https:///", "https://user:password@example.com",
    "https://example.com?q=1", "https://example.com/#part",
  ])
  func invalidURLHasNoKeychainAccount(_ url: String) {
    var settings = ParlanceSettings()
    settings.baseURLOverride = url
    #expect(settings.modelFormValidation() == .invalidBaseURL)
    #expect(settings.keychainAccount == nil)
  }

  @Test(arguments: [
    "http://localhost/v1", "http://127.0.0.8:1234", "http://[::1]/v1", "https://example.com",
  ])
  func allowedKeyOrigins(_ url: String) {
    var settings = ParlanceSettings()
    settings.baseURLOverride = url
    #expect(settings.modelFormValidation(savingKey: true) == nil)
  }

  @Test func remoteHTTPRefusesKeyButAllowsKeylessConfiguration() {
    var settings = ParlanceSettings()
    settings.baseURLOverride = "http://example.com/v1"
    #expect(settings.modelFormValidation() == nil)
    #expect(settings.modelFormValidation(savingKey: true) == .insecureKey)
    #expect(!settings.effectiveRequiresKey)
  }
}
