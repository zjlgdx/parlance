import Testing

@testable import ParlanceCore

struct TermProtectionTests {
  @Test func recognitionOrder() {
    let input =
      "run src/Main.swift with --flag=1 and `pl fix` at https://example.com/a. then os.path.join and fooBar, my_var"
    let result = TermProtection.protect(input)
    #expect(result.text == "run ⟦0⟧ with ⟦1⟧ and ⟦2⟧ at ⟦3⟧. then ⟦4⟧ and ⟦5⟧, ⟦6⟧")
    #expect(
      result.fragments == [
        "src/Main.swift", "--flag=1", "`pl fix`", "https://example.com/a", "os.path.join", "fooBar",
        "my_var",
      ])
    #expect(result.restore(result.text) == input)
  }

  @Test(arguments: [
    "`fooBar src/X.swift`", "https://example.com/a", "git+ssh://host/path", "src/Foo.swift",
    "docs/notes/x.md", "./run", "../run", "~/.config/pl", "/usr/bin/env", "a+b/@c%20/d",
    "src/Makefile", "bin/tool", "docs/notes", "v2/api", "my_dir/x",
    "--flag", "--flag=fooBar", "--1", "--max_tokens=100", "--pattern=(foo)", "foo.bar()",
    "foo.bar.x()", "np.e", "a.b()", "foo.A()", "URLSession.shared", "os.path.join",
    "https://en.wikipedia.org/wiki/Function_(mathematics)",
    "fooBar", "URLSession", "ParlanceCore", "utf8Decode", "foo_bar", "__init__", "MAX_LEN", "_tmp",
  ]) func category(_ input: String) {
    let result = TermProtection.protect(input)
    #expect(result.text == "⟦0⟧")
    #expect(result.fragments == [input])
  }

  @Test func ordinaryTextAndBoundaries() {
    let input =
      "config -v e.g. i.e. x.y U.S. and/or he/she km/h yes/no Hello HTML OK 2024 中文 / ___ //"
    #expect(TermProtection.protect(input).text == input)
    // A missing space before a sentence is prose the rewrite may fix, not a member access.
    for typo in ["I was late.I missed it", "done.A new day", "a Ph.D. in math"] {
      #expect(TermProtection.protect(typo).text == typo, "\(typo)")
    }
    for fragment in ["``", "`two\nlines`"] {
      #expect(TermProtection.protect(fragment).text == fragment)
    }
    #expect(TermProtection.protect("中文fooBar界").text == "中文⟦0⟧界")
    #expect(
      TermProtection.protect("x--flag (--flag) [--other] '--quote'").text
        == "x--flag (⟦0⟧) [⟦1⟧] '⟦2⟧'")
    #expect(
      TermProtection.protect("1foo.bar _https://host").fragments.allSatisfy {
        $0 != "foo.bar" && $0 != "https://host"
      })
  }

  @Test func punctuation() {
    #expect(TermProtection.protect("https://example.com/a.,;:!?)]}>\"'").text == "⟦0⟧.,;:!?)]}>\"'")
    #expect(TermProtection.protect("src/Main.swift.,:;)").text == "⟦0⟧.,:;)")
    // CJK sentence punctuation and closing quotes belong to the sentence, not the fragment.
    #expect(TermProtection.protect("https://example.com/a。").text == "⟦0⟧。")
    #expect(TermProtection.protect("(https://example.com/a)").text == "(⟦0⟧)")
    #expect(TermProtection.protect("见https://example.com/a——这个…").text == "见⟦0⟧——这个…")
    #expect(TermProtection.protect("「https://example.com/a」，").text == "「⟦0⟧」，")
    #expect(TermProtection.protect("--flag=1，然后").text == "⟦0⟧，然后")
  }

  @Test func cjkTextAdjoinsFragments() {
    // Chinese prose often has no space before a URL or flag; ASCII identifier characters are the
    // only boundary that matters.
    #expect(TermProtection.protect("访问https://example.com/a。").text == "访问⟦0⟧。")
    #expect(TermProtection.protect("加上--verbose即可").text == "加上⟦0⟧即可")
    #expect(TermProtection.protect("改src/Main.swift里的fooBar").text == "改⟦0⟧里的⟦1⟧")
    #expect(TermProtection.protect("x--flag a-b--flag").text == "x--flag a-b--flag")
    // CJK text, curly quotes and the enumeration comma end a URL or flag value.
    #expect(TermProtection.protect("看https://example.com/a的说明").text == "看⟦0⟧的说明")
    #expect(TermProtection.protect("加--level=debug即可").text == "加⟦0⟧即可")
    #expect(TermProtection.protect("参考“https://example.com/a”，").text == "参考“⟦0⟧”，")
    #expect(TermProtection.protect("用--foo=1、--bar=2").text == "用⟦0⟧、⟦1⟧")
    #expect(TermProtection.protect("見るhttps://example.com/aをカタカナ").text == "見る⟦0⟧をカタカナ")
    #expect(TermProtection.protect("보기https://example.com/a한글").text == "보기⟦0⟧한글")
  }

  @Test func reuseAndCounts() {
    let result = TermProtection.protect("fooBar then other_name then fooBar")
    #expect(result.text == "⟦0⟧ then ⟦1⟧ then ⟦0⟧")
    #expect(result.fragments == ["fooBar", "other_name"])
    #expect(result.counts == [2, 1])
    #expect(result.validate("⟦0⟧ ⟦1⟧ ⟦0⟧ ⟪7⟫"))
    for text in [
      "⟦0⟧ ⟦1⟧", "⟦0⟧ ⟦0⟧", "⟦0⟧ ⟦1⟧ ⟦0⟧ ⟦0⟧", "⟦0⟧ ⟦1⟧ ⟦0⟧ ⟦7⟧", "⟦00⟧ ⟦1⟧ ⟦0⟧",
      // Stray delimiter scalars of the chosen pair are invented by the model.
      "⟦0⟧⟧ ⟦1⟧ ⟦0⟧", "⟦0⟧ ⟦1⟧ ⟦ 0 ⟧", "⟦0⟧ ⟦1⟧ ⟦0⟧ ⟦x⟧", "⟦0⟧ ⟦1⟧ ⟦0⟧ ⟦",
    ] {
      #expect(!result.validate(text), "\(text)")
    }
    #expect(result.restore("⟦0⟧ ⟦7⟧ ⟪0⟫ ⟧") == "fooBar ⟦7⟧ ⟪0⟫ ⟧")
    #expect(result.containsUnknownToken("⟦7⟧"))
    #expect(result.containsUnknownToken("⟦00⟧"))
    #expect(result.containsUnknownToken("⟦9999999999999999999999999⟧"))
    #expect(result.containsUnknownToken("⟦0⟧ ⟦x⟧"))
    #expect(result.containsUnknownToken("⟦0⟧ ⟦１⟧"))
    #expect(result.containsUnknownToken("⟦0⟧⟧"))
    #expect(!result.containsUnknownToken("⟦0⟧ ⟪7⟫ 〖1〗"))
  }

  @Test func delimiterFallback() {
    let result = TermProtection.protect("literal ⟦0⟧ fooBar")
    #expect(result.text == "literal ⟦0⟧ ⟪0⟫")
    #expect(result.validate("literal ⟦0⟧ ⟪0⟫"))
    #expect(result.restore(result.text) == "literal ⟦0⟧ fooBar")
    #expect(!result.validate("⟦0⟧ ⟪0⟫ ⟪1⟫"))
    #expect(TermProtection.protect("⟧ ⟪ fooBar").text == "⟧ ⟪ 〖0〗")
    let input = "⟦0⟧ ⟪0⟫ 〖0〗 fooBar"
    let unavailable = TermProtection.protect(input)
    #expect(unavailable.delimiters == nil)
    #expect(unavailable.text == input)
    #expect(unavailable.fragments.isEmpty)
    #expect(!unavailable.validate(input))
    #expect(unavailable.restore(input) == input)
  }

  @Test func preservesExactScalars() {
    let input = "`é` `e\u{301}`"
    let result = TermProtection.protect(input)
    #expect(result.text == "⟦0⟧ ⟦1⟧")
    #expect(Array(result.restore(result.text).unicodeScalars) == Array(input.unicodeScalars))
  }

  @Test func noFragments() {
    let result = TermProtection.protect("ordinary text")
    #expect(result.validate("new ordinary text"))
    #expect(!result.validate("⟦3⟧"))
    #expect(result.restore("⟦3⟧") == "⟦3⟧")
  }

  @Test func kindsNameEachFragment() {
    let result = TermProtection.protect(
      "用 `--dry-run` 跑 scripts/migrate.sh，见 https://example.com/a 与 fooBar、`x = 1`、`src/A.swift`")
    #expect(result.kinds == [.flag, .path, .url, .identifier, .code, .path])
    #expect(TermProtection.protect("plain").kinds.isEmpty)
    // A repeated fragment reuses its number and kind; a backticked span whose content only starts
    // with a fragment is code; two names joined by one slash are not called a file path.
    let repeated = TermProtection.protect("fooBar 与 fooBar、`fetchUser()`、async/await、src/a/b")
    #expect(repeated.fragments == ["fooBar", "`fetchUser()`", "async/await", "src/a/b"])
    #expect(repeated.kinds == [.identifier, .code, .slashTerm, .path])
  }
}
