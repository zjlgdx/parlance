#!/usr/bin/env python3
"""Fail when a Markdown file links to a repo path that does not exist.

Prevents README/docs/skills pointing at moved, renamed or never-created files. Checks Markdown links and
images ``[text](target)`` plus HTML ``src=``/``href=`` attributes; skips URLs with a scheme, pure anchors,
placeholders (targets containing < > { } * or `...`) and anything inside fenced or inline code.

Every argument must be an existing file (scripts/gate drops files deleted from the tree): a missing one is
reported, so a caller that mangles names (C-quoted or word-split paths) fails instead of checking nothing.

Usage: check_docs.py <file.md> [...]
Exit codes: 0 ok, 1 broken links found, 2 usage error or missing file.
"""
import os
import re
import sys
import urllib.parse

MD_LINK = re.compile(r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+[\"'(][^)]*)?\)")
HTML_ATTR = re.compile(r"""\b(?:src|href)\s*=\s*["']([^"']+)["']""", re.IGNORECASE)
FENCE = re.compile(r"^\s*(```|~~~)")
INLINE_CODE = re.compile(r"`[^`\n]*`")
SCHEME = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")


def targets(text):
    in_fence = False
    for lineno, line in enumerate(text.splitlines(), 1):
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        stripped = INLINE_CODE.sub("", line)
        for rx in (MD_LINK, HTML_ATTR):
            for m in rx.finditer(stripped):
                yield lineno, m.group(1)


def is_checkable(target):
    if not target or target.startswith("#") or SCHEME.match(target):
        return False
    return not any(ch in target for ch in "<>{}*") and "..." not in target


def main(argv):
    if not argv:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        print("usage: check_docs.py <file.md> [...]", file=sys.stderr)
        return 2
    root = os.getcwd()
    broken = missing = 0
    for path in argv:
        if not os.path.isfile(path):
            print(f"check_docs: no such file: {path}")
            missing += 1
            continue
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        base = os.path.dirname(path)
        for lineno, raw in targets(text):
            if not is_checkable(raw):
                continue
            target = urllib.parse.unquote(raw.split("#", 1)[0].split("?", 1)[0])
            if not target:
                continue
            resolved = os.path.join(root, target.lstrip("/")) if target.startswith("/") else os.path.join(base, target)
            if not os.path.exists(resolved):
                print(f"{path}:{lineno}: broken link -> {raw}")
                broken += 1
    if broken:
        print(f"check_docs: {broken} broken link(s)")
    if missing or broken:
        return 2 if missing else 1
    print(f"check_docs: ok ({len(argv)} markdown file(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
