# Contributing to Parlance

Thanks for helping. Parlance is the `pl` command-line tool and the
`ParlanceCore` Swift package it is built on.

## Sign the CLA first

Every contribution needs a signed [Contributor License Agreement](CLA.md).
You keep the copyright in your work; the CLA lets the maintainer license
contributions under GPL-3.0 and under other terms, including in the
proprietary Parlance for Mac app.

To sign, add one file to your first pull request:

1. Find your numeric GitHub user id: `gh api users/<your-login> --jq .id`,
   or open `https://api.github.com/users/<your-login>` and read `id`.
2. Create `cla/signatures/<id>.md` containing exactly the statement under
   "How to sign" in [CLA.md](CLA.md), with only the five bracketed fields
   filled in.
3. Open the pull request from that same GitHub account.

The signature is checked when the pull request is merged, not by CI, so you
will not see a CLA status on the pull request. If something is missing, the
maintainer will say exactly what in a comment. Every commit author and
`Co-authored-by` in your pull request must also have signed, in their own
pull request merged before yours, unless it is
you or an AI coding tool whose co-author email is listed in `cla/bots`
(for example Claude Code's `noreply@anthropic.com`); such a line counts as
your own work. To add another tool's email, open a separate pull request
for `cla/bots` first.

## Development

Requirements: macOS 15.6 or later with Xcode or the Command Line Tools 26.0
or later, plus `shellcheck`, `actionlint` and `gitleaks` for
`scripts/gate`, which fails when a tool it needs is missing.

```bash
brew install shellcheck actionlint gitleaks   # tools scripts/gate needs
swift build          # build pl and ParlanceCore
swift test           # run the tests; no network, no API keys
scripts/gate         # every check CI runs, in one command
```

- Tests use Swift Testing. `swift test` and CI must not touch the network,
  real API keys, the clipboard or your Keychain; use the mock provider and
  injected fakes. The live provider tests (`PARLANCE_LIVE_TESTS=1`,
  `PARLANCE_LIVE_EVAL=1`, with your own key) and the real-Keychain tests
  (`PARLANCE_KEYCHAIN_TESTS=1`, an isolated service name and an obviously
  fake key that the test removes) run only when you switch them on, and
  never in CI.
- `ParlanceCore` must not import AppKit, and dependencies must be MIT,
  Apache-2.0 or BSD licensed.
- Keep pull requests small and focused on one change. Describe what you
  changed and how you checked it.
- Pull request titles follow `type(scope): imperative summary`, for example
  `fix(cli): keep the exit code when stdout is closed`.

## Merging (maintainers)

Pull requests are merged only with `bash scripts/land <PR>`, run from a
checkout that tracks `main`. It squash-merges after checking the head's CI,
review threads and CLA signatures, and it runs the copy of itself on
`origin/main`, so a pull request cannot change the checks it is merged
under. It reads the `- Head:` line under `## Verification` in the pull
request body, which must name the final commit; the maintainer updates
that line before merging.

## Reporting bugs

Open an issue with the command you ran, what you expected and what
happened. Run with `--verbose` for request metadata; never paste an API key
or text you would not want public.
