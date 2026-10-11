import Foundation
import ParlanceCore
import Testing

struct RedactorTests {
  private struct Fixture: Decodable {
    struct Span: Decodable {
      let start: Int
      let end: Int
      let pem: Bool
    }
    let name: String
    let input: String
    let expected: String
    let pem: Bool
    let spans: [Span]?
  }

  private func fixtures(_ group: String) throws -> [Fixture] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/redaction/\(group).json")
    return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
  }

  @Test(arguments: [
    "openai", "aws", "github", "google", "assignments", "pem", "jwt", "random", "ordinary",
    "coordinates",
  ]) func fixtureRules(_ group: String) throws {
    for fixture in try fixtures(group) {
      let result = Redactor.redact(fixture.input)
      #expect(result.text == fixture.expected, "\(group): \(fixture.name)")
      #expect(result.pemRedacted == fixture.pem, "\(group): \(fixture.name)")
      let ranges = Redactor.ranges(in: fixture.input)
      if let spans = fixture.spans {
        #expect(ranges.map(\.range) == spans.map { $0.start..<$0.end }, "\(fixture.name)")
        #expect(ranges.map(\.isPEM) == spans.map(\.pem), "\(fixture.name)")
      }
      #expect(ranges.allSatisfy { !$0.range.isEmpty })
      for (left, right) in zip(ranges, ranges.dropFirst()) {
        #expect(left.range.upperBound < right.range.lowerBound, "\(fixture.name)")
      }
      if fixture.input == fixture.expected {
        #expect(ranges.isEmpty, "\(fixture.name)")
      }
    }
  }

  @Test(arguments: [
    "com.example.SomeLongIdentifier",
    "com.example.AbstractSingletonProxyFactoryBeanConfigurationProvider",
    "/Users/AppData/Local/Packages/Microsoft2024/LocalCache/Roaming",
    "sorted(xs, key=${VAR})",
    "KEY= # comment",
    "KEY=$VAR;", "TOKEN=${VAR},", "SECRET=<your-key>)",
    "sk-learn", "task-runner", "disk-usage", "AKIAS", "akia", "ghp_short", "github_path",
    "AIza", "AIzaShortWord", "eyJordinaryWord", "a.b.c",
    "KEYBOARD=us", "monkey=1", "token_count = 5", "password == other", "PASSWORD === other",
    "mykey=value", "mytoken=value", "clientSecret: reference", "api_key_count: 5",
    "KEY=", "TOKEN=\"\"", "SECRET=''", "PASSWORD: \nordinary text",
    "KEY=\nordinary text", "KEY=$VAR", "TOKEN=${VAR}", "SECRET=<your-key>",
    "PASSWORD=\"$VAR\"", "API_KEY='${VAR}'", "api_key: \"<your-key>\"",
    "TOKEN=$VAR; ordinary text", "{\"api_key\": \"${VAR}\"}",
    "d3adb33", "a1b2c3d4e5f6", "0123456789abcdef0123456789abcdef01234567",
    "0123456789ABCDEF0123456789abcdef0123456789ABCDEF0123456789abcdef01234567",
    "A1234567-b89C-4d01-A234-56789abcDef0", "A1234567b89C4d01A23456789abcDef012",
    "AbstractSingletonProxyFactoryBeanConfigurationProvider",
    "NSHTTPURLResponseUnexpectedStatusCode404Handler",
    "test_redaction_ruleMatchesBase64Encoded2Values",
    "kCFStreamPropertySSLPeerCertificatesV2Extended",
    "AbstractSingletonProxyFactoryBeanConfigurationProvider123",
    "ABSTRACT_SINGLETON_PROXY_FACTORY_BEAN_CONFIGURATION_PROVIDER",
    "abstract_singleton_proxy_factory_bean_configuration_provider",
    "/workspace/Services/Payments/Production/Region1234567890",
    "src/AbstractSingletonProxyFactoryBeanConfigurationProvider.swift",
    "ordinary text\nwithout markers", "", "🧪e\u{301} 中文",
  ]) func ordinaryTextIsUnchanged(_ input: String) {
    #expect(Redactor.redact(input).text == input)
    #expect(!Redactor.redact(input).pemRedacted)
    #expect(Redactor.ranges(in: input).isEmpty)
  }

  @Test func assignmentSyntaxIsPreserved() {
    #expect(Redactor.redact("func f(key: String) -> Int").text == "func f(key: [REDACTED]) -> Int")
    #expect(Redactor.redact("sorted(xs, key=len)").text == "sorted(xs, key=[REDACTED])")
    #expect(Redactor.redact("let token: String").text == "let token: [REDACTED]")
  }

  @Test func unpairedEndUsesOnlyPreviousPEMRange() throws {
    let fixture = try #require(fixtures("pem").first { $0.name == "unpaired end" })
    let ranges = Redactor.ranges(in: fixture.input)
    #expect(ranges.count == 1)
    #expect(ranges.first?.range.lowerBound == 0)
    #expect(ranges.first?.isPEM == true)
    #expect(Redactor.redact(fixture.input).text == fixture.expected)
  }

  @Test func mergedRangesKeepPEMProvenance() throws {
    for name in ["adjacent non-PEM", "overlap assignment", "complete then end"] {
      let fixture = try #require(fixtures("pem").first { $0.name == name })
      let ranges = Redactor.ranges(in: fixture.input)
      #expect(ranges.count == 1, "\(name)")
      #expect(ranges.first?.isPEM == true, "\(name)")
    }
  }

  @Test func outputPreservesScalarsOutsideRanges() throws {
    for fixture in try fixtures("coordinates") {
      let scalars = Array(fixture.input.unicodeScalars)
      var rebuilt: [Unicode.Scalar] = []
      var start = 0
      for match in Redactor.ranges(in: fixture.input) {
        rebuilt += scalars[start..<match.range.lowerBound]
        rebuilt += Redactor.placeholder.unicodeScalars
        start = match.range.upperBound
      }
      rebuilt += scalars[start...]
      #expect(rebuilt == Array(fixture.expected.unicodeScalars), "\(fixture.name)")
      #expect(Array(Redactor.redact(fixture.input).text.unicodeScalars) == rebuilt)
    }
  }
}
