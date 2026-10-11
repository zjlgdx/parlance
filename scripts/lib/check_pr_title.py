#!/usr/bin/env python3
"""Check a PR title against the convention in AGENTS.md (约定): `type(scope): English imperative summary`.

Squash merges use the PR title as the commit subject on main, so the title is the history. Single source of
the rule: /pl-next checks the title before opening the PR, and scripts/land checks the live title at merge
time (CI does not: a workflow run only sees the title as it was when the run was triggered).

A closing keyword with an issue reference (`fix #24`, `closes owner/repo#3`) is refused: GitHub acts on closing
keywords in commit messages that reach the default branch, so the squash subject would close that issue without
scripts/land having checked it (owner confirmation) or listed it. `Closes`/`Refs` belong in the PR body.

Usage: check_pr_title.py "<title>"     Exit codes: 0 ok, 1 violation, 2 usage error.
Counterexamples: `check_pr_title.py --self-test`.
"""
import re
import sys

sys.dont_write_bytecode = True  # importing pr_refs.py must not leave __pycache__ beside the scripts
from pr_refs import REF  # the reference forms scripts/land reads in a PR body

TYPES = ("feat", "fix", "perf", "refactor", "test", "docs", "build", "ci", "chore", "spike", "release", "revert")
SCOPES = ("core", "cli", "app", "repo", "ci", "release")
PATTERN = re.compile(r"^(%s)(\((%s)\))?: \S.*$" % ("|".join(TYPES), "|".join(SCOPES)))
MAX_LEN = 72
CLOSING = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?\s*%s" % REF, re.I)

GOOD = [
    "feat(core): add Redactor rules",
    "docs(cli): add CLI and ParlanceCore design",
    "chore: add the agent harness",
    "fix(app): restore the clipboard when paste-back is abandoned",
    "fix(core): fix the redaction race from #24",
    "docs(repo): add the provider notes, refs #5",
    "fix: prefixes #4 with the type",
]
BAD = [
    "Add Redactor rules",
    "feat(ui): add panel",
    "feat(core):add rules",
    "feat(core): ",
    "feature(core): add rules",
    "feat(core): " + "x" * 80,
    "feat(core): two\nlines",
    "fix(app): fix #24 paste-back race",
    "fix: #24 paste-back race",
    "feat(app): add the signing script, resolves #25",
    "fix(core): Closes owner/parlance#3 race",
    "fix(core): fixed https://github.com/zjlgdx/parlance/issues/9",
]


def problems(title):
    out = []
    if "\n" in title or "\r" in title:
        out.append("title must be a single line")
    elif not PATTERN.match(title):
        out.append(f"must match type(scope): summary — types {', '.join(TYPES)}; scopes {', '.join(SCOPES)} (optional)")
    if len(title) > MAX_LEN:
        out.append(f"{len(title)} characters (max {MAX_LEN}; it becomes the squash commit subject)")
    closing = CLOSING.search(title)
    if closing:
        out.append(f"closing keyword {closing.group(0)!r}: the title becomes the squash subject on main and would "
                   "close that issue there; put Closes/Refs in the PR body")
    return out


def main(argv):
    if argv == ["--self-test"]:
        bad = [t for t in GOOD if problems(t)] + [t for t in BAD if not problems(t)]
        for t in bad:
            print(f"check_pr_title self-test: wrong verdict for {t!r}")
        return 1 if bad else 0
    if len(argv) != 1:
        print('usage: check_pr_title.py "<title>"', file=sys.stderr)
        return 2
    found = problems(argv[0])
    for p in found:
        print(f"PR title {argv[0]!r}: {p}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
