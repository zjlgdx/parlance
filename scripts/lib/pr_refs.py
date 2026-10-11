#!/usr/bin/env python3
"""PR-to-issue association, shared by scripts/land and the /pl-next selector (select_next.py).

Both decide whether a PR is tied to an owner-gated issue, so they must read a PR body and branch name
the same way. Prevents the two disagreeing about which PRs wait for the owner.

  body_refs(body, repo)   issue numbers named after a reference keyword (Refs/Closes/Fixes/Resolves, any
                          tense, optional colon) in the PR body: `#N`, `owner/repo#N` and issue/PR URLs of
                          `repo`; lists ("#3, #4 and #5") count; HTML comments (the PR template's guidance)
                          and other repositories' issues do not. A Markdown link is read by where it
                          leads: `[text](URL)` counts as its URL when that is an issue or PR URL (the text
                          then names nothing, so a link into another repository is no reference whatever
                          its text says) and as its text otherwise; `<URL>` counts as the URL. An
                          issue or PR URL names its number whatever follows it (`#issuecomment-1`).
                          Not read: reference-style links (`[text][label]`), HTML anchors, emphasis
                          around a reference (`**#24**`) and link text that spans lines.
  branch_issue(branch)    N for a branch named <type>/<N>-<slug>; None for a ticketless <type>/<slug>,
                          including a slug that starts with a date (docs/2026-10-05-notes). Any other
                          leading number is read as N: scripts/land drops it when the repository has no
                          such issue, and AGENTS.md 约定 keeps ticketless slugs from starting with a digit.

Usage: pr_refs.py --self-test
Exit codes: 0 ok, 1 self-test failure, 2 usage.
"""
import re
import sys

REF = r"(?:https://github\.com/([\w.-]+/[\w.-]+)/(?:issues|pull)/|([\w.-]+/[\w.-]+)?#)(\d+)"
REF_RX = re.compile(REF)
KEYWORD_RX = re.compile(
    r"\b(?:refs?|close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?\s*((?:%s\b[\s,]*(?:and\s+)?)+)" % REF, re.I
)
COMMENT_RX = re.compile(r"<!--.*?-->", re.S)
# An inline link `[text](destination "title")`, destination bare or in angle brackets, or an autolink `<URL>`.
LINK_RX = re.compile(r"\[([^\]\n]*)\]\(\s*<?([^\s<>)]*)[^)\n]*\)|<(https://[^\s<>]+)>")
# What follows the number of an issue or PR URL (`#issuecomment-1`, `?x=1`, `/files`): dropped before a list of
# references is read, so that it does not end the list.
URL_TAIL_RX = re.compile(r"(https://github\.com/[\w.-]+/[\w.-]+/(?:issues|pull)/\d+)[/?#][^\s,;<>()\[\]]*")
BRANCH_RX = re.compile(r"^[a-z]+/(?!\d{4}-\d{2}-\d{2}(?!\d))(\d+)-")


def _unlink(link):
    """What a Markdown link reads as: its destination when that is an issue or PR URL, else its text."""
    text, destination, autolink = link.groups()
    if autolink:
        return autolink
    url = REF_RX.match(destination)
    return destination if url and url.group(1) else text


def body_refs(body, repo):
    refs = set()
    prose = URL_TAIL_RX.sub(r"\1", LINK_RX.sub(_unlink, COMMENT_RX.sub("", body or "")))
    for keyword in KEYWORD_RX.finditer(prose):
        for url_slug, slug, number in REF_RX.findall(keyword.group(1)):
            named = url_slug or slug
            if not named or named.lower() == repo.lower():
                refs.add(int(number))
    return refs


def branch_issue(branch):
    m = BRANCH_RX.match(branch or "")
    return int(m.group(1)) if m else None


BODY_CASES = [
    ("Closes #7. Refs #5, #1", {1, 5, 7}),
    ("Refs #3, #4 and #5", {3, 4, 5}),
    ("Refs https://github.com/zjlgdx/parlance/issues/1", {1}),
    ("Refs zjlgdx/parlance#13", {13}),
    ("Refs ZJLGDX/Parlance#13", {13}),
    ("Refs other/repo#2", set()),
    ("Closes #7 <!-- Closes #15 -->", {7}),
    ("Refs:#5", {5}),
    ("Refs\n#6", {6}),
    ("Fix #12", {12}),
    ("Resolved #9, fixes #10", {9, 10}),
    ("CLOSES: #7", {7}),
    ("Refs #24 (signing script).", {24}),
    ("Refs https://github.com/zjlgdx/parlance/pull/9", {9}),
    ("Refs https://github.com/other/repo/issues/3", set()),
    ("Refs [#24](https://github.com/zjlgdx/parlance/issues/24)", {24}),
    ("Refs [the signing ticket](https://github.com/zjlgdx/parlance/issues/24)", {24}),
    ("Refs [#24](https://github.com/other/repo/issues/24)", set()),
    ("Refs [#9](https://github.com/zjlgdx/parlance/issues/24)", {24}),
    ("Refs [#24](https://github.com/zjlgdx/parlance/blob/main/docs/notes/signing.md)", {24}),
    ("Refs [the notes](docs/notes/signing.md)", set()),
    ("Refs [section 24](#24)", set()),
    ("Closes [#7](https://github.com/zjlgdx/parlance/issues/7), refs [#5](https://github.com/zjlgdx/parlance/pull/5) and #1", {1, 5, 7}),
    ("Refs [the signing ticket](<https://github.com/zjlgdx/parlance/issues/24> \"signing\")", {24}),
    ("Refs [#24](https://github.com/zjlgdx/parlance/issues/24#issuecomment-1)", {24}),
    ("Refs <https://github.com/zjlgdx/parlance/issues/24>", {24}),
    ("Refs <https://github.com/other/repo/issues/24>", set()),
    ("Refs [the thread](https://github.com/zjlgdx/parlance/issues/7#issuecomment-1) and #24", {7, 24}),
    ("Refs https://github.com/zjlgdx/parlance/issues/7#issuecomment-1 and #24", {7, 24}),
    ("Refs <https://github.com/zjlgdx/parlance/issues/7?x=1>, #24", {7, 24}),
    ("Refs https://github.com/zjlgdx/parlance/pull/7/files #24", {7, 24}),
    ("Refs https://github.com/other/repo/issues/7#top and #24", {24}),
    ("Refs https://github.com/zjlgdx/parlance/issues/7. See #24", {7}),
    ("See [#8](https://github.com/zjlgdx/parlance/issues/8) for context", set()),
    ("Closes #", set()),
    ("See #8 for context", set()),
    ("prefixes #4", set()),
    ("", set()),
    (None, set()),
]
BRANCH_CASES = [
    ("feat/7-redactor", 7),
    ("docs/1-cli-core-design", 1),
    ("docs/2026-10-05-provider-notes", None),
    ("docs/2026-10-05", None),
    ("chore/dev-harness", None),
    ("build/27-xcode-pin", 27),
    ("feat/12-2fa-prompt", 12),
    ("feat/7-10-05-notes", 7),
    ("7-redactor", None),
    ("", None),
    (None, None),
]


def self_test():
    failures = 0
    for body, want in BODY_CASES:
        got = body_refs(body, "zjlgdx/parlance")
        if got != want:
            failures += 1
            print(f"pr_refs: FAIL body_refs({body!r}) = {sorted(got)}, expected {sorted(want)}")
    for branch, want in BRANCH_CASES:
        got = branch_issue(branch)
        if got != want:
            failures += 1
            print(f"pr_refs: FAIL branch_issue({branch!r}) = {got}, expected {want}")
    if failures:
        print(f"pr_refs: {failures} self-test case(s) failed")
        return 1
    print("pr_refs: self-test ok")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    print(__doc__.strip(), file=sys.stderr)
    sys.exit(2)
