# Parlance for Claude Code

A Claude Code mod that explains each of Claude's replies in your native language, in a pane beside the chat. It runs the Parlance CLI, `pl`, with your own provider and key. Claude's model is never called for it, and the explanations are drawn only in the pane, never added to the conversation.

## Requirements

- Claude Code with mod support, in a terminal (checked on 2.1.318).
- A `pl` that knows `pl explain --session` (`pl explain --help` lists it), set up with a provider and languages as the [CLI instructions](../../README.md) describe.
- An API key that `pl` can read without a terminal. See [API key](#api-key).

## Install

At the Claude Code prompt:

```text
/plugin install parlance --marketplace zjlgdx/parlance
```

Answer `y` to add the marketplace, then pick a scope. Or add the marketplace first with `/plugin marketplace add zjlgdx/parlance`. From a shell: `claude plugin install parlance --marketplace zjlgdx/parlance`.

## Use

- On a terminal at least 144 columns wide the pane opens by itself, beside the chat in fullscreen mode and above the prompt otherwise. On a narrower terminal, run `/parlance` to open it.
- When Claude finishes a turn, the pane shows a translation, a plain explanation and cards for the jargon of that reply. Earlier turns of the session are read as context.
- `/parlance <phrase>` looks up a phrase, such as a name Claude coined several turns ago, in the whole session. It runs at once, even while Claude is working, and only the pane shows the result.
- One request runs at a time: a newer reply or lookup stops the one in progress.
- Replies are explained only while the pane is on screen: the pane Claude Code shows, not a tab behind another pane and not held back on a narrow terminal. Close it or show another pane to pause; `/parlance` opens a closed pane again, and a pane behind another tab comes back when you click its tab.

## API key

The mod starts `pl` with its standard error connected to a pipe, not a terminal, so `pl` treats the run as non-interactive and never reads the macOS Keychain. A key stored only with `pl auth set` is not used here, and the pane shows `pl`'s "an API key is required" diagnostic. Give `pl` the key in one of these ways:

- An environment variable in the environment Claude Code was started from: `DEEPSEEK_API_KEY`, `GEMINI_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or `PARLANCE_API_KEY` for the `compatible` provider.
- An `api_key_cmd` helper in `pl`'s configuration file, such as a password manager command that needs no prompt.

Claude Code reads `ANTHROPIC_API_KEY` too and would then use that key for its own requests, so for the `claude` provider prefer `api_key_cmd`.

A built-in provider whose `base_url` you pointed at another origin has no key source in this mode; use the `compatible` provider for a custom endpoint.

## Privacy

While the pane is on screen, every completed reply of Claude's main conversation is sent automatically, through `pl`, to the provider you configured. Replies of subagents and turns that were interrupted, refused or ended by an error are not sent.

Each request also carries text from the session's earlier turns. `pl` reads the local session record and sends the last 3,000 characters of the conversation before the reply, plus the session's questions and replies from its latest 1 MiB: all of them when they come to at most 12,000 characters; otherwise, when the reply or `/parlance` phrase is a single line of 2 to 200 characters, up to 2,400 characters of the lines that mention it, and in every other case their first 2,400 characters. For such a single line, up to 900 characters of older conversation lines that mention it may also be sent. It reads only question and reply text, with the same secret scrubbing and exclusions as `pl explain --session`: no tool calls, tool results or thinking. There is no Parlance server and no telemetry.

To see what a request sends, copy the reply or phrase, then run the same request yourself in the session's directory. The session ID is the name of its transcript file in `~/.claude/projects/`, without `.jsonl`. The command reads the text from the clipboard, so nothing in it is run by your shell; it sends the request to your provider again, with the session as it is now, and prints what it sent on standard error:

```bash
pbpaste | pl explain --session claude:<session id> --show-sent -- -
```

## Troubleshooting

The pane shows the last diagnostic line `pl` wrote when a request fails. It also says when:

- `pl` cannot be started: install it with `brew install zjlgdx/tap/parlance`. Claude Code finds `pl` through the `PATH` it was started with.
- the `pl` it found is not Parlance's: macOS ships an unrelated `/usr/bin/pl`. Homebrew's `bin` directory must come before `/usr/bin` in `PATH`.
- `pl` is too old to read sessions: upgrade it with `brew upgrade parlance`.
