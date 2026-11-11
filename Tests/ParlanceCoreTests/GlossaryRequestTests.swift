import Foundation
import Testing

@testable import ParlanceCore

struct GlossaryRequestTests {
  // A missing file and unrelated entries produce the wire bytes in the request fixtures.
  @Test(arguments: [false, true]) func unchangedRequests(unrelatedEntry: Bool) async throws {
    let directory = glossaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GlossaryStore(directory: directory)
    if unrelatedEntry { try store.add(glossaryEntry("backpressure", "背压")) }
    let input = "Please check the rate limit."
    let explain = MockProvider(scripts: [[.error(.auth(status: 401))]])
    for try await _ in ExplainRunner.quick(
      subject: ExplainSubject(input: input, inputRedaction: .redact),
      settings: ExplainSettings(), provider: explain, cancellation: LLMCancellation(),
      glossaryStore: store)
    {}
    let rewrite = MockProvider(scripts: [[.error(.auth(status: 401))]])
    for try await _ in RewriteRunner.run(
      input: input, settings: RewriteSettings(), provider: rewrite,
      cancellation: LLMCancellation(), glossaryStore: store)
    {}
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    for (name, provider) in [("explain", explain), ("rewrite", rewrite)] {
      let request = try #require(provider.recordedRequests.first)
      let bytes = try encoder.encode(resolved(.claude).requestBody(for: request))
      let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/glossary/\(name)-request.json")
      #expect(bytes == (try Data(contentsOf: path)))
    }
  }
}

extension GlossaryRequestTests {
  @Test(arguments: ["quick", "document", "rewrite"])
  func unmatchedStoreEqualsNoStore(_ mode: String) async throws {
    let directory = glossaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GlossaryStore(directory: directory)
    try store.add(glossaryEntry("backpressure", "背压"))
    let input = "Please check `rate_limit`."
    var requests: [Data] = []
    for source in [nil, store] as [GlossaryStore?] {
      let provider = MockProvider(scripts: [[.error(.auth(status: 401))]])
      let subject = ExplainSubject(input: input, inputRedaction: .redact)
      switch mode {
      case "quick":
        for try await _ in ExplainRunner.quick(
          subject: subject, settings: ExplainSettings(), provider: provider,
          cancellation: LLMCancellation(), glossaryStore: source)
        {}
      case "document":
        for try await _ in ExplainRunner.document(
          subject: subject, settings: ExplainSettings(), provider: provider,
          cancellation: LLMCancellation(), glossaryStore: source)
        {}
      default:
        for try await _ in RewriteRunner.run(
          input: input, settings: RewriteSettings(), provider: provider,
          cancellation: LLMCancellation(), glossaryStore: source)
        {}
      }
      let request = try #require(provider.recordedRequests.first)
      if mode == "rewrite" {
        #expect(request.messages[1].content.contains("⟦0⟧"))
        #expect(request.messages[0].content.contains("⟦"))
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      requests.append(try encoder.encode(resolved(.claude).requestBody(for: request)))
    }
    #expect(requests[0] == requests[1])
  }
}
