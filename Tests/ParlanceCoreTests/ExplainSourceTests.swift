import Foundation
import Testing

@testable import ParlanceCore

struct ExplainSourceTests {
  @Test func sourceSecretsAreRedactedEvenWhenInputIsKept() {
    let subject = PreparedSubject(
      subject: ExplainSubject(
        input: "selection", inputRedaction: .keep,
        source: ExplainSource(app: "KEY=FAKE-value", title: "TOKEN=FAKE-value", scope: .none)))
    #expect(subject.source?.app == "KEY=[REDACTED]")
    #expect(subject.source?.title == "TOKEN=[REDACTED]")
    #expect(!subject.pemRedacted)
  }

  @Test(arguments: [false, true]) func sourcePEMSetsFlag(_ inTitle: Bool) {
    let pem = "-----BEGIN PRIVATE KEY-----\nFAKE-TEST-NOT-A-KEY"
    let subject = PreparedSubject(
      subject: ExplainSubject(
        input: "selection", inputRedaction: .keep,
        source: ExplainSource(
          app: inTitle ? "Example" : pem, title: inTitle ? pem : nil, scope: .none)))
    #expect(subject.pemRedacted)
    #expect((inTitle ? subject.source?.title : subject.source?.app) == "[REDACTED]")
  }

  @Test(arguments: [ContextScope.focusedText, .visibleWindow], ["Example title", nil, ""])
  func sourceAndScopePromptSnapshot(_ scope: ContextScope, _ title: String?) {
    let subject = PreparedSubject(
      subject: ExplainSubject(
        input: "term", context: .around(before: "before", after: "after"), inputRedaction: .keep,
        source: ExplainSource(app: "Example", title: title, scope: scope)))
    let source = title == nil || title == "" ? "Source: Example" : "Source: Example — Example title"
    let scopeText =
      scope == .focusedText
      ? "from the focused text field" : "recognised from the visible window; may be partial"
    #expect(
      ExplainPrompt.user(subject: subject) == """
        \(source)

        Input:
        term

        Background before input (\(scopeText)):
        before

        Background after input (\(scopeText)):
        after
        """)
  }

  @Test func noScopeOrNoContextHasNoBackground() {
    for (scope, context): (ContextScope, ExplainContext?) in [
      (.none, .around(before: "unused", after: "unused")), (.focusedText, nil),
    ] {
      let subject = PreparedSubject(
        subject: ExplainSubject(
          input: "term", context: context, inputRedaction: .keep,
          source: ExplainSource(app: "Example", title: nil, scope: scope)))
      #expect(ExplainPrompt.user(subject: subject) == "Source: Example\n\nInput:\nterm")
    }
  }

  @Test func cliPromptBytesStayUnchanged() {
    let cases: [(ExplainContext?, String)] = [
      (
        .around(before: "before", after: "after"),
        "Input:\nterm\n\nBackground before input:\nbefore\n\nBackground after input:\nafter"
      ),
      (.tail("tail"), "Input:\nterm\n\nBackground context:\ntail"),
      (nil, "Input:\nterm"),
    ]
    for (context, expected) in cases {
      let subject = PreparedSubject(
        subject: ExplainSubject(input: "term", context: context, inputRedaction: .keep))
      #expect(Array(ExplainPrompt.user(subject: subject).utf8) == Array(expected.utf8))
    }
  }

  @Test func promptRequiresHonestyAboutUndefinedTerms() {
    let subject = PreparedSubject(subject: ExplainSubject(input: "term", inputRedaction: .keep))
    let request = ExplainPrompt.quick(subject: subject, settings: ExplainSettings())
    #expect(request.messages[0].content.contains("provided text does not define it"))
  }

  @Test func sourceFieldsStayOnOneLineAndAreClipped() throws {
    let long = String(repeating: "a", count: 250)
    let subject = PreparedSubject(
      subject: ExplainSubject(
        input: "term", inputRedaction: .keep,
        source: ExplainSource(
          app: "Example\nApp", title: "line one\r\nline\ttwo " + long, scope: .none)))
    #expect(subject.source?.app == "Example App")
    let title = try #require(subject.source?.title)
    #expect(!title.contains("\n") && !title.contains("\r") && !title.contains("\t"))
    #expect(title.hasPrefix("line one  line two "))
    #expect(title.unicodeScalars.count == 201)
    #expect(title.hasSuffix("…"))
    #expect(
      ExplainPrompt.user(subject: subject).hasPrefix("Source: Example App — line one  line two "))
  }

  @Test func clippingNeverSplitsAPlaceholderAndKeepsJoiners() throws {
    let prefix = String(repeating: "a", count: 184) + " TOKEN="
    let subject = PreparedSubject(
      subject: ExplainSubject(
        input: "term", inputRedaction: .keep,
        source: ExplainSource(
          app: "👨‍💻 Example", title: prefix + "FAKE-value tail", scope: .none)))
    // The placeholder would occupy scalars 191..<201; the clip stops before it.
    #expect(subject.source?.title == prefix + "…")
    #expect(subject.source?.app == "👨‍💻 Example")
  }

  @Test func windowContextNeedsBothSwitches() {
    for (context, screen) in [(false, false), (false, true), (true, false), (true, true)] {
      var settings = ParlanceSettings()
      settings.contextEnabled = context
      settings.screenContextEnabled = screen
      #expect(settings.windowContextActive == (context && screen))
    }
  }

  @Test func contextSettingMigrationAndRoundTrip() throws {
    let legacy = Data(
      """
      {"providerPresetID":"deepseek","targetLanguage":"en","nativeLanguage":"zh-Hans",
       "tone":"agent","autoExpandItems":[],"excludedAppBundleIDs":[],"screenContextEnabled":false}
      """.utf8)
    var settings = try JSONDecoder().decode(ParlanceSettings.self, from: legacy)
    #expect(settings.contextEnabled)
    settings.contextEnabled = false
    let decoded = try JSONDecoder().decode(
      ParlanceSettings.self, from: JSONEncoder().encode(settings))
    #expect(!decoded.contextEnabled)
  }
}
