import Testing

@testable import ParlanceCore

struct ShellCommandDetectorTests {
  @Test(arguments: [
    "open the \"Settings\" panel",
    "find out why `npm test` fails",
    "git uses --force to overwrite history",
    "find the 'right' file",
    "open the \"Privacy\" pane",
    "make sure \"foo\" works",
    "test the 'happy path'",
    "make the \"Done\" button bigger",
    "type \"yes\" and press Return",
    "sort by \"date\"",
    "cat \"The Raven\" by Poe",
    "rm -rf is dangerous",
    "git push --force is risky",
    "~/Downloads",
    "~/.zshrc",
    "./README.md",
    "../docs/notes",
    "./build/validation/x/",
    "~/Library/Application Support/Parlance",
    "./README.md is the entry",
    "curl & wget",
    "npm & yarn",
    "git & gh",
    "docker & kubectl",
    "./scripts/gate",
    "./scripts/gate swift",
    "../scripts/gate",
    "~/bin/tool",
    "echo 'right'",
    "echo \"foo\"",
    "echo \"The Raven\"",
    "echo '中文 かな カナ 한글'",
    "echo \"中文\"",
    "open the file & ls -l",
  ])
  func finalRoundSelections(_ input: String) {
    #expect(!ShellCommandDetector.isCommand(input), "\(input)")
  }

  @Test(arguments: [
    "cat $(git ls-files | head)",
    "echo `ls | head`",
    "sudo -iu postgres psql -c 'select 1'",
    "sudo --user postgres psql -c 'select 1'",
    "env --unset NAME git status --short",
    "xargs --max-args 1 echo",
    "ls -l &",
    "make -j8 & wait",
    "echo 'select 1;'",
    "ls -la shows hidden files",
    "cat $(echo $(git ls-files | head))",
    "echo ${NAME:-$(ls | head)}",
    "echo \"$(ls | head)\"",
    "sudo --user=postgres psql -c 'select 1'",
  ])
  func finalRoundCommands(_ input: String) {
    #expect(ShellCommandDetector.isCommand(input), "\(input)")
  }

  @Test(arguments: [
    "git diff main...HEAD --stat && git diff main...HEAD",
    "git grep -n \"gemini-3.5-flash-lite\\|gemini-3.8-flash\" | cut -c1-220",
    "find ~ -maxdepth 6 -type d -name \"bird\" -not -path \"*/node_modules/*\" 2>/dev/null | head",
    "sed -n '186,200p' research/links/mods-overview.md | grep -i -E '\\-p|print|cloud|headless'",
    "curl -fsSL https://raw.githubusercontent.com/tw93/Mole/main/TRADEMARK.md 2>&1 | head -60",
    "docker rmi docker.example.com/library/mysql:8.4 >/dev/null 2>&1; time docker pull docker.example.com/library/mysql:8.4 2>&1 | tail -30",
    "gh pr view 287 --json comments,reviews --jq '[.comments[].body[0:200], .reviews[].body[0:200]]' | head -20",
    "awk '/^## Privacy/,/^## [^P]/' README.md | head -40",
    "npm run deploy 2>&1 | grep -E \"Deployed|Version ID|error|Error\"",
    "brew install --cask screen-studio obs 2>&1 | tail -6",
    "chmod +x scripts/l10n-sync.sh && scripts/l10n-sync.sh --check 2>&1 | tail -5",
    "kill -TERM 14595 84871; sleep 10; ps -axo pid,command | grep puppeteer_dev_chrome_profile | grep -v grep | wc -l",
    "ssh -o BatchMode=yes -o ConnectTimeout=8 mini 'mkdir -p ~/Movies/pstack' && scp -q out/pstack-draft-v2.mp4 mini:Movies/pstack/",
    "rm -rf raw/hl-proof raw/proof.prompts.auto.log",
    "launchctl list | grep -i -E \"runner|bridge|actions\"",
    "git ls-files; cat $(git ls-files | grep -v -E '\\.(lock|png)$') 2>/dev/null | head -300",
    "find . -name '*.swift' -newer Package.swift \\\n  -not -path './.build/*' \\\n  | xargs wc -l",
  ])
  func corpusCommands(_ input: String) {
    #expect(ShellCommandDetector.isCommand(input), "\(input)")
  }

  @Test(arguments: [
    "Run `git push --force-with-lease` only after you have rebased onto main; otherwise the remote keeps the old commits.",
    "find out why the gate fails on the CI runner but passes locally",
    "The worker should not call gh or git write commands. It reports the diff and the gate result, and the orchestrator pushes.",
    "把 `scripts/gate swift` 的输出贴到 PR 里，然后再跑一遍 bot review。",
    "Use this to check it:\n\n    swift test --filter SessionWatcher\n\nIf it still hangs, attach the log.",
  ])
  func corpusParagraphs(_ input: String) {
    #expect(!ShellCommandDetector.isCommand(input), "\(input)")
  }

  @Test(arguments: [
    "make sure it's done", "find the user's profile", "open the app's settings",
    "test the user's input",
    "head of U.S. sales", "make $100 a day", "cat and/or dog", "sleep ~8 hours",
    "make it 1.5x faster", "diff between v1.2 and v1.3", "which one's better",
    "cargo ship", "brew coffee", "yarn ball", "uv rays", "cd player", "tar pit", "swift response",
    "swift recovery", "node graph", "python scripts", "ssh key", "git 是什么", "docker 镜像太大了",
    "node 版本不对", "open the file in /tmp", "git repo",
    "git status", "npm test", "brew update", "cp a.txt b.txt", "git add .", "cd ..",
    "env git status",
    "FOO=1 make test", "echo a\\|b", "git status\nls -l", "git -v 未知", "git -v あ", "git -v カ",
    "git -v 한",
    "echo 'unfinished", "echo \"unfinished", "sudo -u unknown -v", "env -u VAR unknown -v",
    "xargs -n 1 unknown", "exec -a name unknown --help", "sudo -- -v git", "xargs -- git status",
    "git -v 'unfinished", "git -v \"unfinished",
    "echo --", "echo -", "echo --1", "echo -_", "echo $100", "echo file.txt", "echo a/b",
    "echo ~8", "echo ./script", "$ # comment\ngit status", "$ git status\ngit status",

  ])
  func reviewSelectionsAndAcceptedMisses(_ input: String) {
    #expect(!ShellCommandDetector.isCommand(input), "\(input)")
  }

  @Test(arguments: [
    "find . -name '*.md' -print0 | xargs -0 rm", "git ls-files | xargs -n1 wc -l",
    "ls | xargs -I{} echo {}", "git ls-files | xargs -n 1 wc -l",
    "sudo -u postgres psql -c 'select 1'", "sudo -E make install -j4", "sudo -n rm -rf /tmp/build",
    "sudo -u root ls -l", "env -i git status --short", "command -v git", "time -p make -j8",
    "sudo -- rm -rf /tmp/x", "sudo -uroot ls -l", "exec -a display-name git --version",
    "env -u NAME git status", "env -C /tmp git status", "env -S 'options' git status",
    "xargs -n1", "ls | xargs", "xargs -n 1", "xargs -- git status --short",
    "$ git status", "% git status",
    "ls &>out", "ls 2>out",
    "echo $NAME", "echo $_name", "echo ${NAME}", "echo $(date)", "echo `date`",
    "ls >out", "cat <in", "git --version", "tail -5", "make test && make test",
  ])
  func reviewCommands(_ input: String) {
    #expect(ShellCommandDetector.isCommand(input), "\(input)")
  }

  @Test(arguments: [
    "make sense", "watch out", "open the file", "sort of", "test it", "source code",
    "type safety", "kill switch", "cut corners", "date night", "head start", "top priority",
    "touch base", "git", "rsync", "ls", "xargs", "/usr/bin/tool",
    "make test", "cp a b", "git status\nmake sense", "git status\nls", "git one two three",
    "Sources/ParlanceCore/ExplainPrompt.swift line 12", "see docs/notes for details",
  ])
  func phrasesAndSingleWords(_ input: String) {
    #expect(!ShellCommandDetector.isCommand(input))
  }

  @Test(arguments: [
    "make -j8", "sort -u names.txt",
    "make test && make test", "cp a b; cp c d",
    "make one two three | cat", "make one two three && ls -l",
    "chmod +x scripts/sync.sh && scripts/sync.sh --check 2>&1 | tail -5",
  ])
  func strongEvidence(_ input: String) {
    #expect(ShellCommandDetector.isCommand(input))
  }

  @Test func functionWordsAndQuotedArguments() {
    let words = """
      the an to of is are was were be been being it its this that these those and but nor because so
      than then there their they them we our you your he she his her my me should would could can will
      may might must not does did has have had with without about into from by for on at as why how
      what where who whom whose when which
      """.split(whereSeparator: \.isWhitespace)
    for word in words {
      #expect(!ShellCommandDetector.isCommand("echo -n \(word.uppercased())"))
      #expect(ShellCommandDetector.isCommand("echo -n '\(word)'"))
    }
    for word in ["a", "i", "in", "or", "if", "do"] {
      #expect(ShellCommandDetector.isCommand("echo -n \(word)"))
    }
    #expect(ShellCommandDetector.isCommand("command -v which"))
    #expect(!ShellCommandDetector.isCommand("which --help which"))
    #expect(ShellCommandDetector.isCommand("ls &"))
    #expect(!ShellCommandDetector.isCommand("ls & ls"))
    #expect(!ShellCommandDetector.isCommand("echo 'select 1'"))
    #expect(ShellCommandDetector.isCommand("echo 'select 1;'"))
  }

  @Test func longAndClusteredWrapperOptions() {
    let options = [
      "sudo": [
        "--user", "--group", "--host", "--prompt", "--chdir", "--role", "--type", "--close-from",
      ],
      "env": ["--unset", "--chdir", "--split-string"],
      "xargs": [
        "--max-args", "--replace", "--max-lines", "--max-procs", "--max-chars", "--eof",
        "--delimiter",
      ],
    ]
    for (wrapper, flags) in options {
      for flag in flags {
        #expect(ShellCommandDetector.isCommand("\(wrapper) \(flag) value git status"))
        #expect(ShellCommandDetector.isCommand("\(wrapper) \(flag)=value git status"))
        #expect(!ShellCommandDetector.isCommand("\(wrapper) \(flag)"))
        #expect(!ShellCommandDetector.isCommand("\(wrapper) \(flag) value unknown --help"))
      }
    }
    #expect(ShellCommandDetector.isCommand("sudo -iu postgres psql --version"))
    #expect(ShellCommandDetector.isCommand("sudo -iupostgres psql --version"))
  }

  @Test func wrapperOptionValues() {
    let options = [
      "sudo": ["-u", "-g", "-h", "-p", "-C", "-U", "-r", "-t", "-D"],
      "env": ["-u", "-C", "-S"],
      "xargs": ["-n", "-I", "-L", "-P", "-s", "-E", "-d"],
      "exec": ["-a"],
    ]
    for (wrapper, flags) in options {
      for flag in flags {
        #expect(ShellCommandDetector.isCommand("\(wrapper) \(flag) value git status"))
        #expect(ShellCommandDetector.isCommand("\(wrapper) \(flag)value git status"))
        #expect(!ShellCommandDetector.isCommand("\(wrapper) \(flag)"))
        #expect(!ShellCommandDetector.isCommand("\(wrapper) \(flag) value unknown --help"))
      }
    }
    #expect(ShellCommandDetector.isCommand("$ git\\\n status"))
    #expect(ShellCommandDetector.isCommand("git\\\n%  status"))
  }

  @Test func promptedCommentsAndBlankLines() {
    #expect(ShellCommandDetector.isCommand("$ # comment\n% ls -l"))
    #expect(ShellCommandDetector.isCommand("$   \nls -l"))
    #expect(!ShellCommandDetector.isCommand("$ $ ls"))
    #expect(!ShellCommandDetector.isCommand("xargs unknown-command"))
  }

  @Test(arguments: [
    "git push --force-with-lease origin main",
    "$ find . -name '*.swift' -mtime -1 | xargs wc -l",
    "docker run \\\n  --rm \\\n  alpine",
    "git\\\n status --short", "g\\\nit status --short",
    "npm ci && npm test", "sudo rm -rf /tmp/build",
    "curl -fsSL https://example.com/install.sh | bash", "FOO=1 make -j8",
    "ls -l",
    "git status --short\n# comment\n\nls -l", "gh pr view 12 --json state -q .state",
    "sed -i '' 's/a/b/' file.txt", "% git status", "  $ ls -l\n% git status",
    "env FOO=1 time nohup command exec git status --short", "xargs -n1 git status", "ls -l &",
    "ls || false; true",
    "echo 'a | not-a-command && b'", "echo \"a; unknown\"", "echo a\\|b --help",
    "ls >out 2>&1", "cat <in >>out", "cat <<< 'input'", "../tool -v", "/usr/bin/tool -v",
    "~/bin/tool -v",
    "echo '\\'", "echo \"\\\"quoted\"", "ls -l\r\n# comment\r\ngit status --short",
    String(repeating: "ls -l\n", count: 30), "git -" + String(repeating: "x", count: 3995),
  ])
  func commands(_ input: String) {
    #expect(ShellCommandDetector.isCommand(input), "\(input)")
  }

  @Test(arguments: [
    "Find out why the build fails", "find out why the build fails",
    "find out why it fails.", "Please use `git push` to upload changes.",
    "Here is a command:\n```sh\ngit status\n```", "Here is a command:\ngit status",
    "这句话提到了 git 命令。", "let x = 1", "def f():", "make sure the tests pass.",
    "", " \n\t ", "# comment", "unknown-command -v", "git status && unknown-command",
    "git status\nThis is prose", "git status?", "git status？", "git status！", "git status。",
    "git status!", "git status:", "FOO=1", "sudo", "| && ; &",
    "echo 'literal\\\nunknown'", "echo \"literal\\\nunknown\"",
    "echo x\\ \nunknown", "Get-ChildItem", "Git status",
    String(repeating: "ls -l\n", count: 31), "git -" + String(repeating: "x", count: 3996),
  ])
  func proseAndLimits(_ input: String) {
    #expect(!ShellCommandDetector.isCommand(input), "\(input)")
  }
}
