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
printf '%s\n' 'please split this function' | pl fix - --json
pl explain "connection pool exhausted" --target zh-Hans
pl explain "connection pool exhausted" --context agent-output.txt --deep vocab --deep domain
pl explain < agent-output.txt
pl explain "connection pool exhausted" --show-sent
```

Both commands accept text arguments or stdin, plus `--target`, `--native`, `--provider`, `--model`, `--json`, `--no-color`, and `--verbose`. `fix` adds `--tone agent|casual`. `explain` adds `--context <file>` (or `-` for stdin), repeatable `--deep vocab|domain`, and `--show-sent`. Input text and context cannot both consume stdin.

Each built-in model starts with a recommended reasoning effort and thinking setting. To change them, set `effort` (`minimal` to `max`), `thinking` (`on` or `off`), or `first_text_timeout` (seconds, 1–110, default 30) in the configuration file, at the top level or under `[models."<model id>"]`, or pass `--effort`, `--thinking`, or `--first-text-timeout` for one run. Accepted values depend on the model; `pl` reports an unsupported combination when the configuration loads, and `pl config show` prints the effective values.

Identifiers, paths, flags, URLs, and backtick-delimited text are protected during rewriting. Put ordinary words or short flags in backticks when they must remain unchanged. Piped output is emitted only after it is complete and valid; `--json` emits one structured result.

```bash
pl fix --help
pl explain --help
pl --generate-completion-script zsh
```

Homebrew installs shell completions automatically.

## Privacy

- There is no Parlance server and no telemetry. Requests go to the provider endpoint you configure.
- API keys come from an environment variable, macOS Keychain, or an `api_key_cmd` helper. Keys are never written to the configuration file. Noninteractive and SSH requests skip Keychain reads; use the provider's environment variable or a configured helper for those calls.
- `pl fix` does **not** redact secrets from its input. It removes terminal escape codes, replaces protected terms with placeholders when sending, and restores those terms in the returned rewrite. Avoid submitting secrets you do not want the provider to receive.
- `pl explain` redacts its input and context before sending. Pattern-based redaction can miss unusual formats. Use `pl explain --show-sent` to inspect the redacted text sent to the provider on stderr.
- `api_key_cmd` receives no stdin; stdout and stderr are captured, and helper output is never printed. Unlock helpers that require stdin or stderr interaction before running `pl`.

## Contribute and license

See [Contributing][contributing] for development and submission instructions, and the [Contributor License Agreement][cla] for signing your first contribution. Contributors retain their copyright and grant the maintainer relicensing rights, including for proprietary products.

The code is licensed under [GPL-3.0-or-later][license]. The Parlance name, icon, and mascot are not covered by that license; see the [Trademark policy][trademark].

[mascot]: Mascot.png
[contributing]: CONTRIBUTING.md
[cla]: CLA.md
[license]: LICENSE
[trademark]: TRADEMARK.md
