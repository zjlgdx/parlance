import Foundation

/// A heuristic for shell input, not a shell parser or a safety check. Unknown first words are an
/// accepted miss: they receive the normal quick explanation instead of command parts. Commands without
/// strong shell evidence (such as `git status`, `make test` or `ls`) also stay ordinary.
public enum ShellCommandDetector {
  private static let commands = Set(
    """
    git gh find sed awk grep egrep rg fd curl wget docker docker-compose podman kubectl helm npm npx
    pnpm yarn bun deno node python python3 pip pip3 uv poetry ruby gem bundle go cargo rustc swift
    swiftc xcodebuild xcrun brew make cmake ls cd cp mv rm rmdir mkdir touch ln chmod chown cat less
    head tail wc sort uniq cut tr tee xargs echo printf export env unset source ssh scp rsync tar zip
    unzip gzip gunzip jq yq kill pkill ps top lsof open defaults launchctl codesign security plutil
    ditto diff patch bash sh zsh terraform aws gcloud az systemctl journalctl tmux sqlite3 psql mysql
    redis-cli openssl base64 shasum md5 date sleep wait watch which type alias true false test
    """.split(whereSeparator: \.isWhitespace).map(String.init))
  private static let wrappers: Set<String> = [
    "sudo", "env", "time", "nohup", "command", "exec", "xargs",
  ]
  private static let valueOptions: [String: Set<String>] = [
    "sudo": ["-u", "-g", "-h", "-p", "-C", "-U", "-r", "-t", "-D"],
    "env": ["-u", "-C", "-S"],
    "xargs": ["-n", "-I", "-L", "-P", "-s", "-E", "-d"],
    "exec": ["-a"],
  ]

  private static let proseWords = Set(
    """
    the an to of is are was were be been being it its this that these those and but nor because so
    than then there their they them we our you your he she his her my me should would could can will
    may might must not does did has have had with without about into from by for on at as why how
    what where who whom whose when which
    """.split(whereSeparator: \.isWhitespace).map(String.init))
  private static let longValueOptions: [String: Set<String>] = [
    "sudo": [
      "--user", "--group", "--host", "--prompt", "--chdir", "--role", "--type", "--close-from",
    ],
    "env": ["--unset", "--chdir", "--split-string"],
    "xargs": [
      "--max-args", "--replace", "--max-lines", "--max-procs", "--max-chars", "--eof",
      "--delimiter",
    ],
  ]

  public static func isCommand(_ input: String) -> Bool {
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty, input.count <= 4000 else { return false }
    let lines = input.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    guard lines.count <= 30 else { return false }
    var logicalLines: [(text: String, prompted: Bool)] = []
    var pending = ""
    var prompted = false
    for physical in lines {
      var line = String(physical)
      let content = line.drop(while: { $0.isWhitespace })
      let hasPrompt = content.hasPrefix("$ ") || content.hasPrefix("% ")
      if hasPrompt { line = String(content.dropFirst(2)) }
      let body = line.drop(while: { $0.isWhitespace })
      guard !body.isEmpty, !body.hasPrefix("#") else { continue }
      prompted = prompted || hasPrompt
      pending += line
      if scan(pending).continuation {
        pending.removeLast()
      } else {
        logicalLines.append((pending, prompted))
        pending = ""
        prompted = false
      }
    }
    if !pending.isEmpty { logicalLines.append((pending, prompted)) }
    return !logicalLines.isEmpty
      && logicalLines.allSatisfy { isCommandLine($0.text, prompted: $0.prompted) }
  }

  private static func isCommandLine(_ line: String, prompted: Bool) -> Bool {
    let scanned = scan(line)
    guard !scanned.unclosedQuote, !scanned.unquotedCJK else { return false }
    let tokens = scanned.segments.flatMap { $0 }
    if let last = tokens.last, last != ".", last != "..",
      let end = last.last, ".。?？!！:".contains(end)
    {
      return false
    }
    let evidence =
      prompted || scanned.operatorEvidence || scanned.closedQuotedToken
      || tokens.contains(where: isEvidence)
    var foundCommand = false
    for (index, segment) in scanned.segments.enumerated() where !segment.isEmpty {
      guard let commandIndex = commandWord(in: segment) else { return false }
      let word = segment[commandIndex]
      guard
        !segment.enumerated().contains(where: {
          $0.offset != commandIndex && proseWords.contains($0.element.lowercased())
        })
      else { return false }
      let relativeExecutable = ["./", "../", "~/"].contains {
        word.hasPrefix($0) && word.count > $0.count
      }
      // Bare relative paths are accepted only after an operator, as in scripts/check.sh.
      let path =
        relativeExecutable || (word.hasPrefix("/") && word.count > 1)
        || (index > 0 && word.contains("/") && !word.hasSuffix("/"))
      guard commands.contains(word) || path else { return false }
      foundCommand = true
    }
    return foundCommand && evidence
  }

  private static func commandWord(in segment: [String]) -> Int? {
    var words = segment[...]
    while let word = words.first {
      if isAssignment(word) {
        words = words.dropFirst()
        continue
      }
      guard wrappers.contains(word) else { return words.startIndex }
      let wrapperIndex = words.startIndex
      words = words.dropFirst()
      while let option = words.first, option.hasPrefix("-") {
        words = words.dropFirst()
        if option == "--" { break }
        if takesSeparateValue(option, wrapper: word) {
          guard !words.isEmpty else { return nil }
          words = words.dropFirst()
        }
      }
      if word == "xargs", words.isEmpty { return wrapperIndex }
    }
    return nil
  }

  private static func takesSeparateValue(_ option: String, wrapper: String) -> Bool {
    if option.hasPrefix("--") {
      return !option.contains("=") && longValueOptions[wrapper]?.contains(option) == true
    }
    let letters = Array(option.dropFirst())
    if let firstValue = letters.firstIndex(where: {
      valueOptions[wrapper]?.contains("-" + String($0)) == true
    }) {
      return firstValue == letters.count - 1
    }
    return false
  }

  private static func isEvidence(_ token: String) -> Bool {
    let option = token.range(of: "^(-[A-Za-z0-9]|--[A-Za-z])", options: .regularExpression) != nil
    let redirection =
      [">", "<", "2>", "&>"].contains { token.hasPrefix($0) }
      || token.contains(">&")
    let variable = token.range(of: "\\$[({A-Za-z_]", options: .regularExpression) != nil
    return option || redirection || variable || token.contains("`")
  }

  private static func isAssignment(_ word: String) -> Bool {
    guard let equal = word.firstIndex(of: "=") else { return false }
    let name = word[..<equal]
    return name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
  }

  private struct Scan {
    var segments: [[String]] = [[]]
    var continuation = false
    var unclosedQuote = false
    var unquotedCJK = false
    var closedQuotedToken = false
    var operatorEvidence = false
  }

  /// Keep quotes and substitutions intact; this only recognizes structure and never expands input.
  private static func scan(_ line: String) -> Scan {
    var result = Scan()
    var token = ""
    var quote: Character?
    var escaped = false
    var previous: Character?
    var substitutions: [(closing: Character, outerQuote: Character?)] = []
    func endWord() {
      if !token.isEmpty {
        result.segments[result.segments.count - 1].append(token)
        token = ""
      }
    }
    let characters = Array(line)
    var index = 0
    while index < characters.count {
      let character = characters[index]
      let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
      defer {
        previous = character
        index += 1
      }
      if quote == nil,
        String(character).range(
          of: "[\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}]",
          options: .regularExpression) != nil
      {
        result.unquotedCJK = true
      }
      if escaped {
        token.append(character)
        escaped = false
      } else if character == "\\", quote != "'" {
        token.append(character)
        escaped = true
      } else if quote == nil, let frame = substitutions.last, character == frame.closing {
        token.append(character)
        quote = frame.outerQuote
        substitutions.removeLast()
      } else if quote != "'", character == "$", next == "(" || next == "{" {
        token.append(character)
        token.append(next!)
        substitutions.append((next == "(" ? ")" : "}", quote))
        quote = nil
        index += 1
      } else if quote != "'", character == "`" {
        token.append(character)
        substitutions.append(("`", quote))
        quote = nil
      } else if let current = quote {
        token.append(character)
        if character == current {
          quote = nil
          if token.first == current,
            token.dropFirst().dropLast().contains(where: {
              !$0.isLetter && !$0.isNumber && $0 != " "
            })
          {
            result.closedQuotedToken = true
          }
        }
      } else if character == "'" || character == "\"" {
        token.append(character)
        quote = character
      } else if !substitutions.isEmpty {
        token.append(character)
        if (character == "(" && substitutions.last?.closing == ")")
          || (character == "{" && substitutions.last?.closing == "}")
        {
          substitutions.append((character == "(" ? ")" : "}", nil))
        }
      } else if character == "|" || character == ";"
        || (character == "&" && previous != ">" && previous != "<" && next != ">")
      {
        let trailing = characters[(index + 1)...].allSatisfy(\.isWhitespace)
        if character != "&" || next == "&" || previous == "&" || trailing {
          result.operatorEvidence = true
        }
        endWord()
        result.segments.append([])
      } else if character.isWhitespace {
        endWord()
      } else {
        token.append(character)
      }
    }
    endWord()
    result.continuation = escaped && quote == nil && substitutions.isEmpty
    result.unclosedQuote = quote != nil || !substitutions.isEmpty
    return result
  }
}
