import Foundation
import Testing

@testable import ParlanceCore

struct KeySourcesTests {
  @Test func originAndModeDetermineEverySource() throws {
    for preset in ProviderPreset.all {
      for interactive in [false, true] {
        let custom = try #require(URL(string: "https://gateway.example:8443/path"))
        let sources = KeySources(preset: preset, baseURL: custom, usesKeychain: interactive)
        #expect(sources.keychainAccount == "\(preset.id)@https://gateway.example:8443")
        #expect(sources.usesKeychain == interactive)
        #expect(!sources.effectiveRequiresKey)
        #expect(sources.usesCommand == (preset.id == "compatible"))
        #expect(
          sources.environmentVariable == (preset.id == "compatible" ? "PARLANCE_API_KEY" : nil))
        #expect(
          sources.hasSource(environment: [:], keychainExists: true, command: nil) == interactive)
        #expect(
          sources.hasSource(environment: [:], keychainExists: false, command: "fake-test-helper")
            == (preset.id == "compatible"))
      }
    }
    let same = KeySources(
      preset: .deepseek, baseURL: URL(string: "https://API.DEEPSEEK.COM:443/proxy"),
      usesKeychain: true)
    #expect(same.keychainAccount == "deepseek")
    #expect(same.environmentVariable == "DEEPSEEK_API_KEY")
    #expect(same.usesCommand)
    #expect(same.effectiveRequiresKey)
    #expect(
      !same.hasSource(environment: ["DEEPSEEK_API_KEY": ""], keychainExists: false, command: nil))
    #expect(
      !same.hasSource(
        environment: ["PARLANCE_API_KEY": "fake-test-key"], keychainExists: false, command: nil))
    let defaultOrigin = KeySources(preset: .openai, baseURL: nil, usesKeychain: true)
    #expect(defaultOrigin.environmentVariable == "OPENAI_API_KEY")
    #expect(defaultOrigin.keychainAccount == "openai")
    #expect(defaultOrigin.usesCommand)
    #expect(defaultOrigin.effectiveRequiresKey)
    let missing = KeySources(preset: .compatible, baseURL: nil, usesKeychain: true)
    #expect(missing.keychainAccount == nil)
    #expect(!missing.usesKeychain)
  }

  @Test func environmentKeyPresenceIsNonempty() {
    for (value, expected) in [(nil, false), ("", false), ("fake-test-key", true), (" ", true)]
      as [(String?, Bool)]
    {
      #expect(KeySources.hasEnvironmentKey(value) == expected)
      for preset in ProviderPreset.all {
        let sources = KeySources(preset: preset, baseURL: preset.baseURL, usesKeychain: false)
        var environment: [String: String] = [:]
        environment[preset.apiKeyEnvironmentVariable] = value
        #expect(
          sources.hasSource(environment: environment, keychainExists: false, command: nil)
            == expected)
      }
    }
  }

  @Test func everyNamedPresetKeepsKeyRequirementOnItsOrigin() throws {
    for preset in ProviderPreset.all where preset.id != "compatible" {
      let base = try #require(preset.baseURL)
      for variant in [
        base.absoluteString, "https://\(base.host()!):443/proxy",
        "https://\(base.host()!.uppercased())/proxy",
      ] {
        let sources = KeySources(preset: preset, baseURL: URL(string: variant), usesKeychain: false)
        #expect(!sources.changedOrigin)
        #expect(sources.keychainAccount == preset.id)
        #expect(sources.effectiveRequiresKey)
      }
    }
  }

}
