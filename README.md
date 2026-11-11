# Parlance

![Parlance parrot][mascot]

Read and write the language of coding agents. `pl` is a free, open-source CLI for macOS: rewrite a prompt in natural English, or translate and explain an agent's output with optional context and deeper explanations. Bring your own model provider and API key.

Parlance for Mac is a separate paid, proprietary app.

## Install

```bash
brew install zjlgdx/tap/parlance
pl --version
```

Installation builds from source. It requires **macOS 15.6 or later** and **Xcode or Command Line Tools 26.0 or later** (Swift 6.2+). Before macOS 26.2, use **26.0–26.3**. There is no prebuilt bottle.

If `pl` runs Apple's plist utility instead, a terminal opened before the install may still remember that old location: run `rehash` (zsh) or `hash -r` (bash), or open a new terminal. If it still happens, check `which pl`: Homebrew's `bin` directory must precede `/usr/bin` in `PATH`. Follow Homebrew's `brew shellenv` setup instructions for your shell.

## Set up

Store a key in Keychain from an interactive terminal; `auth set` reads it without echo and does not send a verification request:

```bash
pl auth set --provider deepseek
pl auth status --provider deepseek
pl config path
pl config show
```

Create the file printed by `pl config path` to select a provider and languages. `pl` does not write that file:

```toml
provider = "deepseek"
target_language = "en"
native_language = "zh-Hans"
tone = "agent"
```

Provider IDs are `deepseek`, `gemini`, `openai`, `claude`, and `compatible`. For `compatible`, configure `base_url` and `model` under `[providers.compatible]`. Command-line options override configuration. `auth status` and `config show` report key sources without displaying keys or executing key helpers.

## Use

```bash
pl fix "帮我把这个函数拆开，太长了"
pl fix "make this clearer" --tone casual --target en --native zh-Hans
pl fix "I has three branch to merge" --mode correct   # fix mistakes only
printf '%s\n' 'please split this function' | pl fix - --json
pl explain "connection pool exhausted" --target zh-Hans
pl explain "connection pool exhausted" --context agent-output.txt --deep vocab --deep domain
pl explain 'git rebase -i --autosquash origin/main'   # a shell command, part by part
pl explain --doc < plan.md                      # a whole document, section by section
pl explain --session claude                     # explain the latest completed reply here
pl explain --session codex "one-sided skip"     # look up a phrase in the session
pl session watch codex   # explain each new reply in an adjacent terminal
pl explain < agent-output.txt
pl explain "connection pool exhausted" --show-sent
```

Both commands accept text arguments or stdin, plus `--target`, `--native`, `--provider`, `--model`, `--json`, `--no-color`, and `--verbose`. `fix` adds `--tone agent|casual` and `--mode polish|correct`: `correct` fixes only spelling, grammar and wrong words in text already in the target language, and in our evaluation met the scoring bar only on `gemini-3.8-flash`. `explain` adds `--session claude|codex|pi[:ID]`, `--context <file>` (or `-` for stdin), repeatable `--deep vocab|domain`, `--doc`, and `--show-sent`. Input text and context cannot both consume stdin. `--session` and `--context` cannot be combined.

When the input looks like a shell command, `explain` goes through it part by part: each command, option, pipe and redirection, with side effects marked. `--doc` explains a whole document of up to 60,000 characters: a short gist, what it asks you to decide or do, then each section. Without `--doc`, input over 20,000 characters is refused. `--doc` cannot be combined with `--deep` or with a `--session` lookup phrase; `pl explain --doc --session claude` explains a long latest reply. With `compatible`, including local models, the server decides the context window and some servers cut longer input without an error: set your model's context length large enough to hold the whole document.

Each built-in model starts with a recommended reasoning effort and thinking setting. To change them, set `effort` (`minimal` to `max`), `thinking` (`on` or `off`), or `first_text_timeout` (seconds, 1–110, default 30) in the configuration file, at the top level or under `[models."<model id>"]`, or pass `--effort`, `--thinking`, or `--first-text-timeout` for one run. Accepted values depend on the model; `pl` reports an unsupported combination when the configuration loads, and `pl config show` prints the effective values.

Identifiers, paths, flags, URLs, and backtick-delimited text are protected during rewriting. Put ordinary words or short flags in backticks when they must remain unchanged. Piped output is emitted only after it is complete and valid; `--json` emits one structured result.

```bash
pl fix --help
pl explain --help
pl --generate-completion-script zsh
```

Homebrew installs shell completions automatically.

## Claude Code

A Claude Code mod explains each of Claude's replies in a pane beside the chat, and `/parlance <phrase>` looks up a phrase from the session there. Install it at the Claude Code prompt:

```text
/plugin install parlance --marketplace zjlgdx/parlance
```

Answer `y` to add the marketplace, or add it first with `/plugin marketplace add zjlgdx/parlance`. The mod runs `pl` without a terminal, so `pl` does not read Keychain there: give it the key through the provider's environment variable, set where Claude Code starts, or through `api_key_cmd`. See the [mod's README][claude-mod].

## Privacy

- There is no Parlance server and no telemetry. Requests go to the provider endpoint you configure.
- API keys come from an environment variable, macOS Keychain, or an `api_key_cmd` helper. Keys are never written to the configuration file. Noninteractive and SSH requests skip Keychain reads; use the provider's environment variable or a configured helper for those calls.
- `pl fix` does **not** redact secrets from its input. It removes terminal escape codes, replaces protected terms with placeholders when sending, and restores those terms in the returned rewrite. Avoid submitting secrets you do not want the provider to receive.
- `pl explain` redacts its input and context before sending. Pattern-based redaction can miss unusual formats. Use `pl explain --show-sent` to inspect the redacted text sent to the provider on stderr.
- `pl explain --session` and `pl session watch` read local Claude Code, Codex or pi session records. It sends only question and reply text, with the same secret scrubbing; tool calls, tool results, thinking, recognized injected system text and compacted summaries are excluded. Session attachments contain at most the latest 1 MiB, cut at turn boundaries. Use `--show-sent` to inspect the actual content sent. Session paths and IDs are not sent. `pl session watch` automatically sends the latest completed reply at start and each new reply; while an explanation runs, only the newest new reply is kept.
- While the Claude Code mod is installed and its pane is on screen (shown, not a tab behind another pane), it sends each completed reply of Claude's main conversation automatically, through `pl` with the same scrubbing and exclusions; each request also carries text from the session's earlier questions and replies. Subagent replies and interrupted turns are not sent, and the explanation is drawn only in the pane.
- `api_key_cmd` receives no stdin; stdout and stderr are captured, and helper output is never printed. Unlock helpers that require stdin or stderr interaction before running `pl`.

## Contribute and license

See [Contributing][contributing] for development and submission instructions, and the [Contributor License Agreement][cla] for signing your first contribution. Contributors retain their copyright and grant the maintainer relicensing rights, including for proprietary products.

The code is licensed under [GPL-3.0-or-later][license]. The Parlance name, icon, and mascot are not covered by that license; see the [Trademark policy][trademark].

[mascot]: Mascot.png
[claude-mod]: integrations/claude-code/README.md
[contributing]: CONTRIBUTING.md
[cla]: CLA.md
[license]: LICENSE
[trademark]: TRADEMARK.md
