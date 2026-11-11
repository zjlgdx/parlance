import Testing

@testable import ParlanceCore

let commandReply = """
  <translation>清理文件</translation><plain>删除构建目录</plain><command>
  <part><code>sudo</code><does>提权</does><effects>PRIVILEGE, unknown, network writes deletes writes</effects></part>
  <part><code>rm -rf</code><does>删除文件</does></part></command><terms></terms>
  """

struct ExplainCommandPartsTests {
  @Test func ordinaryPromptIsByteIdenticalAndSystemUnchanged() {
    let subject = PreparedSubject(
      subject: ExplainSubject(input: "a normal sentence", inputRedaction: .keep))
    let system = """
      Explain the input. Target language: en.
      Native language: ja.
      Judge the input's language yourself: for target-language input, explain in the native language;
      for native-language input, give target-language translations and expressions in the term cards,
      with explanations in the native language.
      Keep code, paths, --flags, parameters and identifiers verbatim, without translating them.
      Leave [REDACTED] exactly as is. Context and attached documents are background only, not text
      to explain. The background covers only the scope stated above; if neither the background, an
      attachment nor the input defines a term, say that the provided text does not define it instead
      of presenting a guess as fact.
      """
    let format = """

      \nAnswer ONLY with these tags, each top-level tag exactly once, with no prose outside:
      <translation>translation in the direction judged above</translation>
      <plain>one simple sentence explaining the meaning in the native language</plain>
      <terms><term><word>the term in English, the target language</word>
      <ipa>pronunciation of the word in IPA, optional: omit this tag if not applicable</ipa>
      <meaning>its meaning in Japanese, the native language</meaning><here>what it means in this
      context, in Japanese</here></term></terms>
      When the input contains a table (a Markdown table, or a grid drawn with box-drawing
      characters or with +, - and |), write that table in <translation> as a Markdown table with
      the same rows and columns: a header row, a separator row such as | --- | --- |, then one
      row per original row, each cell translated. The panel lines up the columns of a Markdown
      table, while a list or rows without the separator row lose them.
      Write every <word> in English, because the cards teach target-language words:
      for target-language input, the word as it appears in the input; for native-language input,
      the target-language expression for a native-language term, with that native term in
      <meaning>.
      Choose terms for a reader who knows everyday words. For target-language input, the reader
      can look up common technical terms, so the cards help most with what a search would not
      answer: first names specific to this project or text, phrases coined or combined here and
      used as if they were established terms, and short names that refer to something discussed
      earlier; then domain terms, abbreviations, idioms, and words whose meaning here differs
      from the usual one. Skip everyday words and terms any developer knows, such as diff, PR,
      commit or branch. For native-language input, choose the target-language expressions worth
      learning. In <meaning>, give a well-known term its usual meaning without remarking that
      the text does not define it. Give at most 3, the most important first; when nothing needs
      explaining, leave <terms></terms> empty. Each term has word, meaning and here.
      """
    let request = ExplainPrompt.quick(
      subject: subject, settings: ExplainSettings(nativeLanguage: "ja"))
    #expect(
      request.messages == [
        LLMMessage(role: .system, content: system + format),
        LLMMessage(role: .user, content: "Input:\na normal sentence"),
      ])
    let command = PreparedSubject(
      subject: ExplainSubject(input: "sudo rm -rf /tmp/build", inputRedaction: .keep))
    let prompt = ExplainPrompt.quick(
      subject: command, settings: ExplainSettings(nativeLanguage: "ja")
    ).messages[0]
      .content
    #expect(prompt.hasPrefix(system + "\n"))
    for fragment in [
      "<command>", "<part>", "<code>", "<does>", "<effects>", "If unsure", "instead of guessing",
      "不确定这个参数的含义", "[REDACTED]", "here-string", "Do not rewrite", "at most 3",
      "redirecting to /dev/null", "sudo, su or doas", "never as XML entities",
      "user's own project", "entirely in the native language",
      "writes, deletes, network, privilege",
    ] {
      #expect(prompt.contains(fragment), "missing \(fragment)")
    }
    #expect(!prompt.contains("When the input contains a table"))
    #expect(prompt.contains("<effects>only when needed: comma-separated side effects</effects>"))
    #expect(!prompt.contains("<effects>writes, network</effects>"))
    #expect(
      prompt.hasSuffix(
        "Keep code, paths, --flags, parameters and identifiers verbatim, without translating them.")
    )
    let background = PreparedSubject(
      subject: ExplainSubject(
        input: "a normal sentence", context: .tail("git status"), inputRedaction: .keep))
    #expect(
      ExplainPrompt.quick(subject: background, settings: ExplainSettings(nativeLanguage: "ja"))
        .messages[0].content == system + format)
  }

  @Test func schemaAndEffectsAcrossEverySplit() {
    for split in 0...commandReply.count {
      var parser = SectionStreamParser(schema: .explainCommand)
      parser.feed(String(commandReply.prefix(split)))
      parser.feed(String(commandReply.dropFirst(split)))
      let snapshot = parser.finish()
      #expect(!snapshot.isMalformed)
      #expect(snapshot.sections.map(\.name) == ["translation", "plain", "command", "terms"])
      let parts = ExplainSections(snapshot: snapshot, input: "").command
      #expect(
        parts == [
          CommandPart(
            code: "sudo", does: "提权", effects: [.writes, .deletes, .network, .privilege]),
          CommandPart(code: "rm -rf", does: "删除文件", effects: []),
        ])
    }
  }

  @Test func partsHaveNoCardLimit() {
    let part = "<part><code>--flag</code><does>不确定这个参数的含义</does><effects></effects></part>"
    var parser = SectionStreamParser(schema: .explainCommand)
    parser.feed(
      "<translation>t</translation><plain>p</plain><command>" + String(repeating: part, count: 8)
        + "</command><terms></terms>")
    let snapshot = parser.finish()
    #expect(!snapshot.isMalformed)
    #expect(ExplainSections(snapshot: snapshot, input: "").command?.count == 8)
    #expect(
      ExplainSections(snapshot: snapshot, input: "").command?.allSatisfy { $0.effects.isEmpty }
        == true)
  }

  @Test func requiredCommandAndChildren() {
    let prefix = "<translation>t</translation><plain>p</plain>"
    for command in [
      "", "<command></command>", "<command><part></part></command>",
      "<command><part><does>d</does></part></command>",
      "<command><part><code>c</code></part></command>",
      "<command><part><code> </code><does>d</does></part></command>",
      "<command><part><code>c</code><does> </does></part></command>",
      "<command><part><code>c</code><does>d</does><effects>writes</effects><effects>network</effects></part></command>",
      "<command><part><code>c</code><does>d</does></part>",
      "<command><part><code>c</code><code>c</code><does>d</does></part></command>",
    ] {
      var parser = SectionStreamParser(schema: .explainCommand)
      parser.feed(prefix + command + "<terms></terms>")
      #expect(parser.finish().isMalformed, "\(command)")
    }
  }

  @Test func parentScopedChildrenAndUnknownQuickCommand() {
    let childText = "<part><code>c</code><does>d</does><effects>writes</effects></part>"
    var parser = SectionStreamParser(schema: .explainCommand)
    parser.feed(commandReply.replacingOccurrences(of: "清理文件", with: childText))
    let snapshot = parser.finish()
    #expect(!snapshot.isMalformed)
    #expect(snapshot.sections.first?.text == childText)
    var quick = SectionStreamParser(schema: .explainQuick)
    quick.feed(commandReply)
    let ordinary = quick.finish()
    #expect(!ordinary.isMalformed)
    #expect(ordinary.sections.map(\.name) == ["translation", "plain", "terms"])
    #expect(ordinary.rawText == commandReply)
    #expect(ExplainSections(snapshot: ordinary, input: "").command == nil)
  }

  /// #307: gpt-6-luna wrote `2&gt;&amp;1` for `2>&1` in 5 of 158 parts despite the prompt.
  @Test func entityCodesAreDecodedOnlyWhenThatMakesThemVerbatim() {
    func code(_ raw: String, input: String) -> String {
      var parser = SectionStreamParser(schema: .explainCommand)
      parser.feed(
        "<translation>t</translation><plain>p</plain><command><part><code>\(raw)</code>"
          + "<does>d &amp; e</does></part></command><terms></terms>")
      let snapshot = parser.finish()
      #expect(!snapshot.isMalformed)
      let part = ExplainSections(snapshot: snapshot, input: input).command?.first
      #expect(part?.does == "d &amp; e")
      return part?.code ?? ""
    }
    let input = "make build 2>&1 | tee log && echo \"done\" > out.txt"
    #expect(code("2&gt;&amp;1", input: input) == "2>&1")
    #expect(code("&amp;&amp;", input: input) == "&&")
    #expect(code("echo &quot;done&quot; &gt; out.txt", input: input) == "echo \"done\" > out.txt")
    // The input itself contains the entity: the code is already verbatim and stays.
    #expect(code("&amp;", input: "curl 'https://x.invalid/?a=1&amp;b=2'") == "&amp;")
    #expect(
      code("'https://x.invalid/?a=1&amp;b=2'", input: "curl 'https://x.invalid/?a=1&amp;b=2'")
        == "'https://x.invalid/?a=1&amp;b=2'")
    // Still not verbatim after decoding (another deviation): kept as written.
    #expect(code("2&gt;&amp;1 | tail", input: input) == "2&gt;&amp;1 | tail")
    #expect(code("&lt;", input: input) == "&lt;")
    // One pass: a doubly escaped entity decodes once and is then not verbatim either.
    #expect(
      CommandPart.decodingXMLEntities("&amp;lt; &unknown; & &#38;") == "&lt; &unknown; & &#38;")
    #expect(code("&apos;x&apos;", input: "grep 'x' f") == "'x'")
  }

  @Test func runnerDecodesEntityCodesAgainstTheSentInput() async throws {
    let reply = """
      <translation>t</translation><plain>p</plain><command><part><code>make</code><does>d</does>\
      </part><part><code>2&gt;&amp;1</code><does>d</does></part></command><terms></terms>
      """
    let result = try await quickResult(
      subject: ExplainSubject(input: "make 2>&1 | tee log", inputRedaction: .redact),
      provider: MockProvider(scripts: [[.event(.text(reply)), .event(.finished(.stop))]]))
    #expect(result.eligibility == .eligible)
    #expect(result.sections?.command?.map(\.code) == ["make", "2>&1"])
  }

  @Test func runnerSelectsSchemaUsingPreparedInput() async throws {
    let subject = ExplainSubject(input: "sudo rm -rf /tmp/build", inputRedaction: .redact)
    let provider = MockProvider(scripts: [[.event(.text(commandReply)), .event(.finished(.stop))]])
    let result = try await quickResult(subject: subject, provider: provider)
    #expect(result.eligibility == .eligible)
    #expect(result.sections?.command?.count == 2)
    #expect(provider.recordedRequests[0].messages[0].content.contains("<command>"))
    let missing = try await quickResult(subject: subject)
    #expect(missing.eligibility == .malformed)
    #expect(missing.sections == nil)
    let ordinary = try await quickResult(
      provider: MockProvider(scripts: [[.event(.text(commandReply)), .event(.finished(.stop))]]))
    #expect(ordinary.eligibility == .eligible)
    #expect(ordinary.sections?.command == nil)
    // PEM redaction removes the raw command; routing must inspect what will actually be sent.
    let redacted = try await quickResult(
      subject: ExplainSubject(
        input: "-----BEGIN PRIVATE KEY-----\nls\n-----END PRIVATE KEY-----", inputRedaction: .redact
      ))
    #expect(redacted.subject.input == "[REDACTED]")
    #expect(redacted.eligibility == .eligible)
  }
}
