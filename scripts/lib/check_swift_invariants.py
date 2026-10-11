#!/usr/bin/env python3
"""Swift-stage invariants that the compiler cannot enforce: two from the MVP design and one that keeps the
gate's verdict about the commit. Driven by the package manifest (`swift package dump-package`), not by a
hard-coded layout, and fail-closed.

1. ParlanceCore stays UI-free: no AppKit/Cocoa/SwiftUI/Carbon/ApplicationServices/ScreenCaptureKit/Vision
   import in the ParlanceCore target or in any local or external product target it depends on, directly or
   transitively (an `@_exported import AppKit` in a dependency target leaks AppKit into the core just the
   same). In Swift sources every `import` word in the file is tried, wherever it stands (after a `;` too):
   followed by whitespace or nested comments, an optional declaration kind and one of these modules exactly
   (backticked or not), it is a finding. The same words inside a comment or string literal also fail, which
   errs towards rejecting. In a local target every file is read with the C rules, whatever its name and
   whether or not the manifest selects it (`exclude:`, `resources:` and `sources:` do not stop a compiled
   C-family file from `#include`-ing a neighbour, a header, an `.inc` or an excluded `.swift`); a Swift file
   the manifest compiles is read with the Swift rules as well. The file is read as the preprocessor
   would start to: BOM dropped, backslash-newline splices joined (ASCII blanks after the backslash allowed, as
   clang does, not a NUL or a Unicode blank; the break may be `\r\n`, `\n\r`, `\r` or `\n`, as clang's escaped
   newline allows; the line count follows clang's, where `\n\r` is two lines, as it is for swiftc in Swift
   files), `\r\n` and `\r` line breaks normalised, once with trigraphs replaced and once without, because the manifest's language standard
   decides which clang does and a `??/` before a newline splices only under one of them; the findings of both
   readings count. A NUL byte and clang's Unicode whitespace (NBSP, U+3000 and the like) count as blanks, as
   clang treats them (with a warning). Nothing is stripped or skipped after that: as with Swift, a directive is matched wherever the
   text shows one, with blanks or block comments (which may span lines) allowed between its tokens and a `#`
   counted only where nothing but those precedes it on its line, so no string, character or raw string literal
   this check does not lex can hide a directive from it. The same text inside a multi-line comment, a raw string
   or a stringized macro argument therefore fails too, which errs towards rejecting (a `/* #include … */` or
   `// #include …` on one line does not). The scan is linear in the file: comment ends are looked up, not
   re-parsed from every newline, and a gap shared by many line starts is walked once, so a long comment or
   blank run cannot stall the gate. A `#import`, `#include` or `#include_next` directive (`%:` digraph included)
   is a finding when the first path component in the angle brackets or quotes is one of these frameworks in
   any case-folded spelling (clang finds `"AppKit/AppKit.h"` in the framework too, and the SDK sits on a
   case-insensitive volume; a directory of that name beside the source is not told apart); so is an include
   whose path is absolute or holds a `..` component (not resolved: `"../include/X.h"` fails even when it stays
   inside the target) and one whose argument is not a `<…>` or `"…"` literal (a macro). A module import
   wherever it stands (`@import M`, `#pragma clang module import M`, `_Pragma("clang module import M")`, the
   same words stringized through a macro; newlines and line comments may separate its tokens) is a finding when
   its top-level module is one of these frameworks under any case-folded spelling (clang compares module names
   exactly, so `@import appkit;` is not a bypass and this errs towards rejecting); so is a `@` or `@import` whose next token stands after a
   directive line, a `_Pragma` operator or beyond the end of the file (clang processes the directive or the
   operator between the tokens, so `@` NEWLINE `#define X 1` NEWLINE `import M;` and `@ _Pragma("once") import
   M;` import M, a conditional group or an `#include` there can supply the rest of the import from text this
   check reads in another context, and a file ending in `@` is continued by the file that includes it: such a
   split import is reported, not followed). That rule also rejects a few compiled layouts: a macro whose body is
   `@` followed by a directive line, a line starting with `_Pragma` or the end of the file (`#define LIT @`
   NEWLINE `#define X 1`), a `@` left alone on its line before a conditional literal (`id a = @` NEWLINE `#if 1`
   NEWLINE `"x";` …), and a line comment ending in `@` before a directive line or a `_Pragma` line, or followed
   only by blank or comment lines to the end of the file; putting the `@` on the same line as
   its token (for the macro, a line carrying a token, not a blank or comment line, after it; for a comment,
   rewording it) is the remedy;
   so is `link framework` naming one (any case-folded spelling) and `clang module build` (an inline module map, which this
   check does not parse any more than a module map file). Because nothing is lexed away and every file is read,
   the same words in a comment, a string, a Swift doc comment or a README (`@import AppKit`, `link framework
   AppKit`, a line starting `# include the helpers`) fail too; rewording the text is the remedy.
   Not recognised: a forbidden framework reached through another framework that re-exports it
   (`<Quartz/Quartz.h>` includes AppKit, `@import Quartz;` makes `NSView` visible), and a module import whose name, `import` or `@` comes from a macro
   (`#define AK AppKit` then `@import AK;`, or `#define IMP(m) @import m;` then `IMP(AppKit)`, or a macro
   expanding to nothing between the tokens, `@` NEWLINE `EMPTY` NEWLINE `import AppKit;`, which clang
   accepts; the macro may also come from the manifest, `cSettings: [.define("AK", to: "AppKit")]`, whose
   values this check does not read; a `#include MACRO` by contrast fails as unresolved), which only the
   preprocessor could expand. Local targets must have no
   `*.modulemap` or `module.map` file anywhere under their directory, selected or not: a module map can
   `link framework "AppKit"` or map a header outside the target, and this check does not parse it. An ignored,
   untracked file is not read: it is not in the commit, and item 3 rejects it unless it is a per-machine LOCAL_ONLY
   file outside `resources:`; an include naming such a file (`#include "AGENTS.override.md"` under any spelling the default volume's
   Unicode case folding opens, `agents.override.md` or `AGENTſ.override.md` alike; the name ends at a NUL, as
   clang's lookup does) fails instead, because that
   file would be a preprocessing input no commit holds. Every file read must be a regular file whose real path stays inside the package (a link to a device would
   never finish reading).
   Directories come from each target's `path:` or the SwiftPM default, and symlinked directories
   are followed, as SwiftPM follows them. Swift files the manifest keeps out of a target get the C rules only,
   not the Swift rules: those under an `exclude:` entry or a `resources:` entry (SwiftPM copies or processes
   those, never compiles them) and, when `sources:` is set, those outside it. A manifest without a ParlanceCore target, a target directory that
   does not exist, a binary or system-library target in the closure (its sources cannot be scanned), a target
   in the closure that uses a build-tool plugin (it generates code outside the target directory this check
   walks), sets unsafeFlags for any tool (`-Xfrontend -import-module AppKit` imports without an import line) or
   links one of these frameworks (under any case-folded spelling) with linkedFramework, or a scan that finds no source file
   is a failure. Prevents an app-only dependency leaking into the GPL core and the CLI. External products are
   resolved from SwiftPM dependency identities and paths; missing checkouts, unreadable manifests/sources,
   missing or ambiguous products, and unscannable targets fail closed. Before its manifest dump is used or its
   sources are scanned, a source-control package's checkout must have HEAD at the Package.resolved revision and
   no tracked, staged, untracked or ignored changes and no index entry marked assume-unchanged or
   skip-worktree; each submodule, at any depth and whatever a .gitmodules says, must be initialized and match
   its committed gitlink the same way (SwiftPM has already evaluated every dependency manifest by
   then: the gate resolves and builds first, and show-dependencies loads the graph; a dirty checkout still
   fails). This catches a checkout that drifted and anything the dependency commits (.gitmodules settings,
   nested submodules); it trusts the checkout's own .git (config, info/attributes, replace refs, index stat
   data), which whoever can write there could use as easily to edit this script.
   Registry (or any other non-git) dependencies fail: an extracted archive cannot be verified that way. Path
   dependencies are rejected by item 2 because they cannot be pinned. Unrelated targets are not
   scanned. External target directories, followed directories and scanned files must resolve inside the
   package root. Explicit sources must also stay inside it; sources outside the target subtree fail because
   this scanner does not walk them. External targets must be pure Swift: any C-family source/header,
   `*.modulemap` or `module.map` under the target (even excluded or unselected), or a system/binary target, fails because
   this check cannot follow Clang header lookup. In local targets in the core closure, publicHeadersPath
   and C/C++ headerSearchPath must resolve inside that target's directory, so a search path cannot add an
   unscanned sibling header tree.
2. Every package dependency declared in Package.swift is pinned in Package.resolved (path dependencies never
   are, so they cannot be license-checked), and every pin is listed in scripts/dependency-licenses.json, under
   its lowercase identity, with an allowed license (MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, Apache-2.0
   WITH Swift-exception) and the `url` the pin resolves to: an approval is for one origin, so a fork or
   replacement that keeps the identity has to be approved again. The allowlist has no stale entries. Prevents
   a copyleft or unknown-license dependency entering the core, which would block the closed-source app from
   reusing it. Package.resolved carries no license data and SwiftPM's SBOM has none either, so the allowlist
   is maintained by hand (issue #2). scripts/gate runs `swift package resolve` first and refuses a
   Package.resolved that resolution creates or rewrites, so the pins read here are the committed ones.
3. No gitignored file sits in the package: Package.swift, Sources/, Tests/, every target directory, every
   `resources:` entry (which may lie outside its target) and whatever a symlink in them points at (SwiftPM
   follows the link, git stores only the link). SwiftPM builds what is on disk, while git leaves an ignored file
   out of the commit and out of `git status`, so the gate would pass (and stamp) a commit that does not build
   from a fresh clone. For the same reason a link, target or resource path that leads outside the repository
   fails. An ignored .DS_Store or per-machine agent override (CLAUDE.local.md,
   AGENTS.local.md, AGENTS.override.md: .gitignore ignores them at any depth, and none is a source) does not
   count, unless it is or sits under a target's `resources:` entry (`.copy` or `.process`) or whatever a symlink
   there points at: SwiftPM copies (`.copy`) or processes file by file (`.process`) what is on disk there into the
   product bundle, so the per-machine file may ship. Entries are compared by file identity, so another letter
   case or a link naming the same file counts too. Each file is listed with the ignore rule that matches it.

Usage: check_swift_invariants.py [--manifest <dump-package.json>]
       (run from the repo root; without --manifest it runs `swift package dump-package` itself)
Exit codes: 0 ok, 1 violation, 2 usage error or unreadable manifest.
"""
import bisect
import itertools
import json
import os
import re
import subprocess
import sys
from array import array

CORE_TARGET = "ParlanceCore"
FORBIDDEN = ("AppKit", "Cocoa", "SwiftUI", "Carbon", "ApplicationServices", "ScreenCaptureKit", "Vision")
IMPORT_KINDS = ("class", "struct", "enum", "protocol", "typealias", "func", "var", "let")
WORD_RX = re.compile(r"\w+")


def swift_imports(text):
    """Yield (line, module) for each `import [kind] <forbidden module>` token sequence in Swift source. Every
    `import` word is tried on its own, wherever it stands (after `;`, inside a comment or string too), so no
    region is ever skipped; between the words Swift allows whitespace (NUL included), line comments, nested
    block comments, or nothing before a backticked name. `text` must have its line breaks as `\n` (a file read
    in text mode does)."""
    # Where each `/*` ends, nesting included: one pass pairs every opener with the closer a depth count from it
    # reaches, so trying many `import` words stays linear. An opener without a closer is not a gap.
    # Openers in text order and each one's end as parallel arrays indexed by the opener's ordinal (8 bytes per
    # comment, no dict and no Python int per comment), looked up by bisect.
    openers = array("q", (m.start() for m in re.finditer(r"/\*", text)))
    ends, opened = array("q", [-1]) * len(openers), array("q")  # end per opener ordinal; -1 = no closer
    for marker in re.finditer(r"/\*|\*/", text):
        if marker.group() == "/*":
            opened.append(bisect.bisect_left(openers, marker.start()))
        elif opened:
            ends[opened.pop()] = marker.end()
    del opened

    def comment_index(i):  # the comment opened at `i`, or -1 when no closer pairs with it
        k = bisect.bisect_left(openers, i)
        return k if k < len(openers) and openers[k] == i and ends[k] >= 0 else -1

    newlines = array("q", (m.start() for m in re.finditer("\n", text)))
    # Where a gap that passes through a comment ends, memoised at each comment's end: many `import` words inside
    # a run of line comments would otherwise each re-walk the whole run (quadratic in the file).
    # Where a gap ends, memoised by the ordinal of the comment or newline it passed: -1 unknown, -2 no gap end
    # (an unterminated comment on the way).
    after_comment, after_newline = array("q", [-1]) * (len(ends) + 1), array("q", [-1]) * (len(newlines) + 1)

    def gap(i):
        start, landed_c, landed_n = i, array("q"), array("q")
        while i < len(text):
            if text[i] in MODULE_BLANKS:  # the same blanks as the C scanner: ASCII, NUL, clang's Unicode set, line breaks
                i += 1
                continue
            if text.startswith("//", i):
                k = bisect.bisect_left(newlines, i)
                i = newlines[k] if k < len(newlines) else len(text)
                cache, landed = after_newline, landed_n
            elif text.startswith("/*", i):
                k = comment_index(i)
                if k < 0:
                    i = -2
                    break
                i, cache, landed = ends[k], after_comment, landed_c
            else:
                break
            if cache[k] != -1:
                i = cache[k]
                break
            landed.append(k)
        for k in landed_c:
            after_comment[k] = i
        for k in landed_n:
            after_newline[k] = i
        if i < 0:
            return None
        return i if i > start or text.startswith("`", i) else None

    def name(i):
        if text.startswith("`", i):
            end = text.find("`", i + 1)
            return (text[i + 1:end], end + 1) if end > 0 else (None, i)
        match = WORD_RX.match(text, i)
        return (match.group(), match.end()) if match else (None, i)

    # Many `import` words inside one run of comments converge on the same name position; the name (and after a
    # declaration kind, the second gap and name) is read once, from the first of them. The mark names the stage
    # (before the first name or before the second), as `directives` does. Swiftc sees the last of such words at
    # most, so the finding is anchored at the first, inside the comment, which errs towards rejecting.
    parsed = bytearray(len(text) + 1)
    NAME, KIND_NAME = 1, 2

    def first(i, stage):
        if parsed[i] & stage:
            return False
        parsed[i] |= stage
        return True

    line, counted = 1, 0
    # A backtick may end an attribute right before the keyword (@`_exported`import); `import` as an escaped
    # identifier then counts too, which errs towards rejecting.
    for match in re.finditer(r"(?<!\w)import(?!\w)", text):
        i = gap(match.end())
        if i is None or not first(i, NAME):
            continue
        word, after = name(i)
        if word in IMPORT_KINDS:
            i = gap(after)
            if i is None or not first(i, KIND_NAME):
                continue
            word, after = name(i)
        if word in FORBIDDEN:
            line, counted = line + text.count("\n", counted, match.start()), match.start()
            yield line, word


# The C preprocessor's first phases, as far as a directive scanner needs them, and the directive shapes. Nothing is
# ever stripped or skipped: a directive is matched wherever the text shows one, so no misread string or comment can
# hide it, and the same text inside a comment or string literal fails too (errs towards rejecting).
TRIGRAPHS = {"=": "#", "/": "\\", "'": "^", "(": "[", ")": "]", "!": "|", "<": "{", ">": "}", "-": "~"}
TRIGRAPH_RX = re.compile(r"\?\?([=/'()!<>-])")
# An escaped newline: ASCII blanks may follow the backslash (clang warns, then splices; a NUL or a Unicode blank there
# is no splice), and the line break may be `\r\n`, `\n\r`, `\r` or `\n`. clang's line numbers count the raw text
# left to right, a `\r\n` pair as one line and any other `\r` or `\n` as one each, splice or not.
SPLICE_RX = re.compile(r"\\[ \t\v\f]*(\r\n|\n\r|\r|\n)")
NEWLINE_RX = re.compile(r"\r\n|\r")  # the remaining breaks, normalised to `\n` one each (`\n\r` becomes two, as clang counts)
# Comment ends are looked up, never re-scanned: a block comment opened at any `/*` ends at the first `*/` after it
# (found by bisecting the sorted `*/` positions), so a long comment costs the same from every newline or `@` inside
# it, and a `/*` inside a string literal still opens a comment for the gap, as nothing is lexed away.
# clang's Unicode whitespace (isUnicodeWhitespace: NEL, NBSP, Ogham, Mongolian vowel separator, the U+2000 spaces, line and
# paragraph separators, narrow and medium spaces, ideographic space), accepted between tokens with a warning.
UNICODE_BLANKS = "\u0085\u00a0\u1680\u180e" + "".join(chr(c) for c in range(0x2000, 0x200b)) + "\u2028\u2029\u202f\u205f\u3000"
DIRECTIVE_BLANKS = " \t\v\f\0" + UNICODE_BLANKS  # between a directive's tokens clang allows these and block comments, not a newline
MODULE_BLANKS = DIRECTIVE_BLANKS + "\n"  # between the tokens of an `@import` or pragma, newlines and line comments too
AFTER_WORD = r"(?=[\s\0\u180e/])"  # a keyword ends where a blank (U+180E is not `\s`) or a comment follows
INCLUDE_KEYWORDS = ("include_next", "include", "import")
NAME_RX = re.compile(r"[\w.]+")


def fold(name):
    """Fold a file or framework name as the default (case-insensitive) APFS volume does: full Unicode case
    folding, so `ſ` (U+017F) and `ﬆ` (U+FB06) open `s` and `st`, which `str.lower()` would keep apart."""
    return name.casefold()


FORBIDDEN_BY_FOLD = {fold(name): name for name in FORBIDDEN}


def spliced(text, trigraphs):
    """The file after the preprocessor's first phases: BOM dropped, trigraphs replaced when asked (clang does so only
    under a strict ISO standard), every backslash-newline splice joined, and the line breaks left normalised to `\\n`
    (`\\r\\n` and `\\r` one each, so `\\n\\r` counts two lines, as clang's line numbers do).
    Returns (text, line_at): `line_at(pos)` is the original line of a position in the spliced text, computed from
    the newline positions and the offsets where a splice was removed (per line and per splice, not per character,
    so a large file costs little beyond its own size)."""
    text = text.lstrip("\ufeff")
    if trigraphs:
        text = TRIGRAPH_RX.sub(lambda m: TRIGRAPHS[m.group(1)], text)
    # Positions live in compact arrays (8 bytes each, no per-object overhead): a file of blank lines has one per byte.
    # A splice over `\n\r` is entered twice: it takes two of clang's lines with it.
    parts, splices, pos, kept = [], array("q"), 0, 0
    for match in SPLICE_RX.finditer(text):
        parts.append(NEWLINE_RX.sub("\n", text[pos:match.start()]))
        kept += len(parts[-1])
        splices.append(kept)
        if match.group(1) == "\n\r" and not text.startswith("\n", match.end()):
            splices.append(kept)  # two lines, unless the `\r` pairs with the `\n` after it (that `\n` stays and counts)
        pos = match.end()
    parts.append(NEWLINE_RX.sub("\n", text[pos:]))
    text = "".join(parts)
    newlines = array("q", (m.start() for m in re.finditer("\n", text)))

    def line_at(position):
        return 1 + bisect.bisect_left(newlines, position) + bisect.bisect_right(splices, position)

    return text, line_at, newlines


def directives(text, line_at, newlines):
    """Yield (line, kind, what) per directive in spliced text: kind "import" names a forbidden framework or module,
    "link" a forbidden framework named by `link framework` (an inline module map), "build" marks `clang module
    build` (an inline module map this check does not parse), "escape" quotes an include whose path is absolute or holds
    `..`, "machine" quotes an include whose file name case-folds to a per-machine LOCAL_ONLY name (such a
    file is ignored and untracked, so this check never reads it; the name ends at a NUL, as clang's lookup does),
    "unresolved" quotes an include argument that is no `<…>` or `"…"` literal, "split" marks a `@` or
    `@import` whose next token stands after a directive line, a `_Pragma` operator or beyond the end of the file, and "ok" marks a
    literal include with nothing to report. The line is where the `#` (or the module name, the `clang` word of a
    module build, the framework name of a link, the `#` of the directive or the `_Pragma` that splits a module
    import, the `@` the file ends with) stands; candidates
    converging on one argument through a comment are one directive, anchored at the first of them (when that one
    sits in a string literal whose `/*` reaches the real directive, the line names the literal). An include
    directive is `#` (or the `%:` digraph) first on its line, with only
    blanks and block comments before it since the previous newline, the keyword, then the rest of the line as the
    raw argument; a module import is `@import` or `module import` wherever it stands (`#pragma clang module import`,
    `_Pragma("clang module import …")`, the same words stringized through a macro), the name optionally quoted,
    blanks, newlines and comments allowed between the tokens; a directive line there (`@` NEWLINE `#define X 1`
    NEWLINE `import AppKit;`), a `_Pragma` operator or the end of the file is reported as a split import, not
    followed."""
    n = len(text)
    closers = array("q", (m.start() for m in re.finditer(r"\*/", text)))

    # Many line starts (or many `@` inside one comment) converge on the same gap after a shared `*/`. Two walks can
    # only merge where a comment jump lands, so the gap's end is memoised at those landings (one entry per comment,
    # not per character): each stretch is walked once, and a `#` or `import` reached from several starts is parsed
    # once. That keeps the scan linear in the file.
    # A landing is just after the k-th `*/` or at the k-th newline, so the memo is indexed by that ordinal: 8 bytes
    # per comment or line, never per character. One pair of arrays per mode (`line_comments` or not).
    memo = ((array("q", [-1]) * (len(closers) + 1), None),  # directive mode never skips a line comment
            (array("q", [-1]) * (len(closers) + 1), array("q", [-1]) * (len(newlines) + 1)))

    def skip(i, blanks, line_comments):
        (by_closer, by_newline), landed_c, landed_n = memo[line_comments], array("q"), array("q")
        while i < n:
            if text[i] in blanks:
                i += 1
                continue
            if text.startswith("/*", i):
                k = bisect.bisect_left(closers, i + 2)
                i = closers[k] + 2 if k < len(closers) else n  # unterminated: clang stops with an error
                cache, landed = by_closer, landed_c
            elif line_comments and text.startswith("//", i):
                k = bisect.bisect_left(newlines, i)
                i = newlines[k] if k < len(newlines) else n
                cache, landed = by_newline, landed_n
            else:
                break
            if cache[k] >= 0:
                i = cache[k]
                break
            landed.append(k)
        for k in landed_c:
            by_closer[k] = i
        for k in landed_n:
            by_newline[k] = i
        return i

    def end_of_line(i):
        k = bisect.bisect_left(newlines, i)
        return newlines[k] if k < len(newlines) else n

    def word(i, keyword):
        return text.startswith(keyword, i) and not (i + len(keyword) < n and (text[i + len(keyword)].isalnum() or text[i + len(keyword)] == "_"))

    # Candidates that converge after their gaps are one directive to clang (the earlier ones sit inside the comment
    # the gap jumped over), so a name or argument position is classified once, anchored at the first candidate.
    # Each loop marks the positions it has classified from, after every gap it skips, so candidates converging on
    # a shared tail (`"link /*\n" * N + "*/ framework …"`, `'@import "/*\n' * N + '*/ ' + name`) walk it once. A
    # mark names the parsing stage, not just the loop: two candidates can land on the same character expecting
    # different tokens (`#include /* @import /* */ <AppKit/AppKit.h>`; `"@import /*"; @ /* */ import AppKit;`,
    # where the candidate in the string expects a name where the real one expects `import`) and must not share one.
    parsed = array("H", [0]) * (n + 1)  # one 16-bit word per position, not a Python int per candidate
    (LINK_FRAMEWORK, LINK_NAME, BUILD_MODULE, BUILD_BUILD, IMPORT_KEYWORD, IMPORT_NAME, IMPORT_QUOTED_NAME,
     INCLUDE_HASH, INCLUDE_KEYWORD, INCLUDE_ARG, AT_KEYWORD, AT_NAME, AT_QUOTED_NAME) = (1 << k for k in range(13))

    def first(i, stage):
        if parsed[i] & stage:
            return False
        parsed[i] |= stage
        return True

    for match in re.finditer(r"\blink" + AFTER_WORD, text):
        # `link framework "AppKit"` inside an inline module map (`#pragma clang module build`) links the framework
        # with no module map file for the rule above to reject.
        i = skip(match.end(), MODULE_BLANKS, True)
        if not (first(i, LINK_FRAMEWORK) and word(i, "framework")):
            continue
        i = skip(i + len("framework"), MODULE_BLANKS, True)
        if not first(i, LINK_NAME):
            continue
        name = NAME_RX.match(text, i + 1 if text.startswith('"', i) else i)
        module = FORBIDDEN_BY_FOLD.get(fold(name.group().split(".")[0])) if name else None  # `AppKit.framework` too
        if module:
            yield line_at(i), "link", module
    for match in re.finditer(r"\bclang" + AFTER_WORD, text):
        # `#pragma clang module build X` (also through `_Pragma` or a stringized macro) opens an inline module map,
        # which this check does not parse any more than a module map file.
        i = skip(match.end(), MODULE_BLANKS, True)
        if first(i, BUILD_MODULE) and word(i, "module"):
            i = skip(i + len("module"), MODULE_BLANKS, True)
            if first(i, BUILD_BUILD) and word(i, "build"):
                yield line_at(match.start()), "build", None
    def split(start, i, at):
        """True when the gap from `start` landed on a `_Pragma` operator (it yields no token: `@ _Pragma("once")
        import AppKit;` imports AppKit) or, for a `@` candidate, on a directive line (a `#`/`%:` after a newline;
        one inside a block comment counts too, where clang then rejects the `@`) or ran out of file. clang
        processes that directive between the two tokens (`@` NEWLINE `#define X 1` NEWLINE `import AppKit;`
        imports AppKit; a conditional group or an `#include` there can supply the rest of the import from text
        this check reads in another context), and a file ending in `@` or `@import` is continued by the file that
        includes it, so the candidate is reported as split rather than followed. A pragma is one line and clang
        reads a `_Pragma` inside it as the module name, so a `module` candidate is never split."""
        return at and (word(i, "_Pragma") or i >= n or ((text.startswith("#", i) or text.startswith("%:", i))
                                                         and bisect.bisect_left(newlines, start) < bisect.bisect_left(newlines, i)))

    for match in re.finditer(r"@|\bmodule" + AFTER_WORD, text):
        # Only a `@` can be split by a directive line (a pragma is one line), so `@` and `module` candidates
        # carry different stage marks: what follows a landing depends on which of the two reached it.
        at = match.group() == "@"
        i = skip(match.end(), MODULE_BLANKS, True)
        if split(match.end(), i, at):  # only a `@` splits
            if first(i, AT_KEYWORD):
                yield line_at(match.start() if i >= n else i), "split", None  # the directive's line, or the `@`'s at EOF
            continue
        if not word(i, "import") or not first(i, AT_KEYWORD if at else IMPORT_KEYWORD):
            continue
        start = i + len("import")
        i = skip(start, MODULE_BLANKS, True)
        if not first(i, AT_NAME if at else IMPORT_NAME):
            continue
        if split(start, i, at):
            yield line_at(match.start() if i >= n else i), "split", None
            continue
        if i < n and text[i] in "\"'\\":
            while i < n and text[i] in "\"'\\":
                i += 1
            i = skip(i, MODULE_BLANKS, True)
            if not first(i, AT_QUOTED_NAME if at else IMPORT_QUOTED_NAME):
                continue
            if at and word(i, "_Pragma"):
                yield line_at(i), "split", None
                continue
        name = NAME_RX.match(text, i)
        module = FORBIDDEN_BY_FOLD.get(fold(name.group().split(".")[0])) if name else None
        if module:
            yield line_at(i), "import", module

    for line_start in itertools.chain((0,), (p + 1 for p in newlines)):
        i = skip(line_start, DIRECTIVE_BLANKS, False)
        if text.startswith("%:", i):
            hash_at, i = i, i + 2
        elif text.startswith("#", i):
            hash_at, i = i, i + 1
        else:
            continue
        if not first(hash_at, INCLUDE_HASH):
            continue  # line starts inside one comment all land on this `#`; the blanks after it are walked once
        i = skip(i, DIRECTIVE_BLANKS, False)
        keyword = next((k for k in INCLUDE_KEYWORDS if word(i, k)), None)
        if keyword is None or not first(i, INCLUDE_KEYWORD):
            continue
        i = skip(i + len(keyword), DIRECTIVE_BLANKS, False)
        if not first(i, INCLUDE_ARG):
            continue
        arg = text[i:end_of_line(i)].strip(DIRECTIVE_BLANKS)
        line = line_at(hash_at)
        closer = {"<": ">", '"': '"'}.get(arg[:1])
        end = arg.find(closer, 1) if closer else -1
        if end < 0:
            yield line, "unresolved", arg or "<nothing>"
            continue
        path = arg[1:end].split("\0", 1)[0]  # clang opens the name up to a NUL (a C string): classify and quote that
        parts = path.split("/")
        module = FORBIDDEN_BY_FOLD.get(fold(parts[0])) if len(parts) > 1 else None
        if module:
            yield line, "import", module
        elif path.startswith("/") or os.pardir in parts:
            yield line, "escape", arg[0] + path + closer
        elif fold(parts[-1]) in LOCAL_ONLY_FOLD:  # the default volume opens the file under any case-folded spelling
            yield line, "machine", arg[0] + path + closer
        else:
            yield line, "ok", None


def c_findings(text):
    """Return sorted (line, kind, what) findings for a C-family file, joined over two readings: trigraphs replaced
    and left alone, because the manifest's language standard decides which clang does and a `??/` before a newline
    splices only under one of them. An "unresolved" argument is dropped where the other reading saw a literal
    include on the same line (the argument merely held a trigraph): a trigraph never produces the `<` or `"` a
    literal starts with, so this cannot hide a macro."""
    found, literal = set(), set()
    for trigraphs in (True, False):
        for line, kind, what in directives(*spliced(text, trigraphs)):
            if kind in ("ok", "import", "escape", "machine"):  # a literal argument (a module import too: fails anyway)
                literal.add(line)
            if kind != "ok":
                found.add((line, kind, what if what is None or len(what) <= 120 else what[:117] + "..."))
    return sorted(item for item in found if not (item[1] == "unresolved" and item[0] in literal))


HEADER_EXTS = (".h", ".hh", ".hpp", ".hxx")
C_FAMILY_EXTS = (".m", ".mm", ".c", ".cc", ".cpp", ".cxx") + HEADER_EXTS
SOURCE_EXTS = (".swift",) + C_FAMILY_EXTS
DEFAULT_SOURCE_ROOTS = ("Sources", "Source", "src", "srcs")
ALLOWLIST = "scripts/dependency-licenses.json"
ALLOWED_LICENSES = {"MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0 WITH Swift-exception"}
# Ignored on purpose at any depth and never a source: .DS_Store and .gitignore's per-machine agent overrides.
LOCAL_ONLY = {".DS_Store", "CLAUDE.local.md", "AGENTS.local.md", "AGENTS.override.md"}
LOCAL_ONLY_FOLD = {fold(name) for name in LOCAL_ONLY}
# These change how git reads every pathspec (GIT_LITERAL_PATHSPECS turns `:(literal)x` into a file of that name, and
# check-ignore then explains nothing); the ignore checks run git without them.
PATHSPEC_ENV = {"GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS"}


def pathspec_env():
    return {k: v for k, v in os.environ.items() if k not in PATHSPEC_ENV}


def swift_package(root, *args):
    command = ["swift", "package"]
    env = dict(os.environ)
    if env.get("CODEX_SANDBOX") or env.get("PARLANCE_SWIFTPM_DISABLE_SANDBOX") == "1":
        command.append("--disable-sandbox")
        env["CLANG_MODULE_CACHE_PATH"] = os.path.abspath(".build/ModuleCache")
    out = subprocess.run(command + list(args), cwd=root, env=env, capture_output=True, text=True)
    if out.returncode != 0:
        raise ValueError(f"swift package {' '.join(args)} failed: {out.stderr.strip()}")
    return json.loads(out.stdout)


def load_manifest(argv):
    if argv[:1] == ["--manifest"] and len(argv) == 2:
        with open(argv[1], encoding="utf-8") as fh:
            return json.load(fh)
    if argv:
        raise ValueError("usage: check_swift_invariants.py [--manifest <dump-package.json>]")
    return swift_package(".", "dump-package")


def target_dir(target, package_root="."):
    def rooted(path):
        return path if package_root == "." else os.path.join(package_root, path)

    if target.get("path"):
        return rooted(target["path"])
    name = target["name"]
    by_type = {"test": ("Tests",) + DEFAULT_SOURCE_ROOTS, "plugin": ("Plugins",)}
    roots = by_type.get(target.get("type"), DEFAULT_SOURCE_ROOTS)
    for root in roots:
        if os.path.isdir(rooted(os.path.join(root, name))):
            return rooted(os.path.join(root, name))
    return rooted(os.path.join(roots[0], name))


def dependency_names(manifest):
    """Direct dependency identities and explicit names used for target dependency resolution."""
    names = {}
    for dep in manifest.get("dependencies", []):
        for entries in dep.values():
            for entry in entries or []:
                identity = entry["identity"].lower()
                names[identity] = {identity, (entry.get("nameForTargetDependencyResolutionOnly") or identity).lower()}
    return names


def resolved_pins():
    """Both supported lockfile versions store identities and revisions in the pins array."""
    with open("Package.resolved", encoding="utf-8") as fh:
        resolved = json.load(fh)
    if resolved.get("version") not in (2, 3):
        raise ValueError(f"Package.resolved: unsupported format version {resolved.get('version')!r}")
    return {pin["identity"].lower(): pin for pin in resolved.get("pins", [])}


def verify_repository(root, revision):
    """Require HEAD at `revision`, no tracked, staged, untracked or ignored change, no index entry whose flags
    hide a change from git status, and the same for every submodule against its committed gitlink. Submodules
    are walked here, not left to git status, because a .gitmodules `ignore` setting below the first level
    hides them from it; each must be initialized, as a fresh SwiftPM checkout has it."""
    # A git hook exports GIT_DIR, GIT_INDEX_FILE and friends for this repository; they must not leak into the
    # dependency's checkout.
    local = subprocess.run(["git", "rev-parse", "--local-env-vars"], capture_output=True, text=True, check=True)
    env = {k: v for k, v in os.environ.items() if k not in local.stdout.split()}
    env["GIT_OPTIONAL_LOCKS"] = "0"

    def git(*args):
        # Bytes, not text: universal newlines would turn a `\r` in a NUL-separated path into `\n`.
        out = subprocess.run(["git", "--no-optional-locks", "-C", root] + list(args), env=env, capture_output=True)
        if out.returncode:
            raise ValueError(f"git {args[0]} failed in {root}: {os.fsdecode(out.stderr).strip()}")
        return [os.fsdecode(entry) for entry in out.stdout.split(b"\0") if entry]

    head = "".join(git("rev-parse", "--verify", "HEAD")).strip()
    status = git("status", "--porcelain", "-z", "--untracked-files=all", "--ignored", "--ignore-submodules=none")
    if head != revision or status:
        raise ValueError(f"{root} has local changes or is not at the pinned revision {revision}")
    # `ls-files -v` tags assume-unchanged entries in lowercase and skip-worktree entries with S.
    hidden = [entry[2:] for entry in git("ls-files", "-v", "-z") if entry[0].islower() or entry[0] == "S"]
    if hidden:
        raise ValueError(f"{root} has index entries git status does not check: {', '.join(hidden[:5])}")
    for entry in git("ls-tree", "-r", "-z", "HEAD"):
        meta, _, path = entry.partition("\t")
        if not meta.startswith("160000 commit "):
            continue
        sub = os.path.join(root, path)
        if not os.path.exists(os.path.join(sub, ".git")):
            raise ValueError(f"submodule {sub} is not initialized; its pinned sources would not be scanned")
        verify_repository(sub, meta.split()[2])


def verify_checkout(root, identity, product):
    """Verify a checkout before trusting its manifest or scanning its targets."""
    context = f"checkout of package '{identity}' (product '{product}')"
    try:
        pin = resolved_pins().get(identity)
        revision = pin.get("state", {}).get("revision") if pin else None
        if not isinstance(revision, str) or not revision:
            raise ValueError("Package.resolved has no pinned revision")
        verify_repository(root, revision)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        raise ValueError(f"{context}: {exc}; run `swift package reset` or restore it") from exc


def core_closure(manifest, errors):
    """Yield (package root, target, product context) throughout the core's dependency closure."""
    if not any(t["name"] == CORE_TARGET for t in manifest.get("targets", [])):
        errors.append(
            f"Package.swift has no target named {CORE_TARGET}; the AppKit check cannot run "
            "(update scripts/lib/check_swift_invariants.py together with the layout decision)"
        )
        return
    packages = {None: (".", manifest)}
    graph, graph_error, seen = None, None, set()

    def package(identity, kind, product):
        nonlocal graph, graph_error
        if graph_error:
            raise ValueError(graph_error)
        if graph is None:
            graph = {}
            try:
                resolved = swift_package(".", "--force-resolved-versions", "show-dependencies", "--format", "json")

                def collect(node):
                    key = node["identity"].lower()
                    if key in graph:
                        if graph[key] != node["path"]:
                            raise ValueError(f"conflicting paths for package '{key}'")
                        return
                    graph[key] = node["path"]
                    for child in node.get("dependencies", []):
                        collect(child)

                collect(resolved)
            except (OSError, ValueError, KeyError, TypeError) as exc:
                graph_error = str(exc)
                raise ValueError(graph_error) from exc
        if identity not in packages:
            root = graph.get(identity)
            if not root or not os.path.isdir(root):
                raise ValueError("resolved package directory is missing")
            if kind == "sourceControl":
                verify_checkout(root, identity, product)
            elif kind != "fileSystem":
                # An extracted registry archive is mutable and has no git state to hold against the pin.
                raise ValueError(f"{kind} dependencies are not supported: only a source-control checkout can be "
                                 "verified against its pin before it is scanned")
            # fileSystem dependencies have no pin and are already rejected by check_licenses.
            # dump-package creates scratch files; keep them out of the checkout we just verified.
            scratch = os.path.abspath(os.path.join(".build", "invariant-manifests", identity))
            packages[identity] = (root, swift_package(root, "--scratch-path", scratch, "dump-package"))
        return packages[identity]

    def external_products(owner_manifest, product, requested):
        names = dependency_names(owner_manifest)
        kinds = declared_dependencies(owner_manifest)
        candidates = [identity for identity, aliases in names.items() if requested is None or requested.lower() in aliases]
        if not candidates:
            errors.append(f"cannot read package '{requested or '<unknown>'}' for product '{product}': no declared dependency")
            return
        matches, unreadable = [], False
        for identity in candidates:
            try:
                root, dep_manifest = package(identity, kinds[identity], product)
            except (OSError, ValueError) as exc:
                errors.append(f"cannot read package '{identity}' for product '{product}': {exc}")
                unreadable = True
                continue
            for declared in dep_manifest.get("products", []):
                if declared["name"] == product:
                    matches.append((identity, root, dep_manifest, declared))
        if unreadable:
            return
        if len(matches) != 1:
            reason = "product not found" if not matches else "ambiguous product"
            errors.append(f"cannot read package '{', '.join(candidates)}' for product '{product}': {reason}")
            return
        identity, root, dep_manifest, declared = matches[0]
        context = f"{CORE_TARGET} depends on product '{product}' (package '{identity}')"
        if not declared.get("targets"):
            errors.append(f"{context}: product has no targets to scan")
        for name in declared.get("targets", []):
            yield from visit(identity, root, dep_manifest, name, context)

    def visit(identity, root, current, name, context):
        key = (identity, name)
        if key in seen:
            return
        seen.add(key)
        targets = {t["name"]: t for t in current.get("targets", [])}
        if name not in targets:
            errors.append(f"{context or CORE_TARGET}: target '{name}' not found")
            return
        target = targets[name]
        yield root, target, context
        for dep in target.get("dependencies", []):
            for kind, args in dep.items():
                if kind == "target" or (kind == "byName" and args[0] in targets):
                    yield from visit(identity, root, current, args[0], context)
                elif kind in ("byName", "product"):
                    yield from external_products(current, args[0], args[1] if kind == "product" else None)
                else:
                    errors.append(f"{context or CORE_TARGET}: unsupported target dependency {dep!r}")

    yield from visit(None, ".", manifest, CORE_TARGET, "")


def inside_root(path, root):
    """Compare resolved path components, not a string prefix."""
    root = os.path.realpath(root)
    return os.path.commonpath([root, os.path.realpath(path)]) == root


def require_package_path(path, package_root, target):
    if not inside_root(path, package_root):
        raise ValueError(
            f"target '{target['name']}': {path} leads outside package root {os.path.realpath(package_root)} "
            f"(to {os.path.realpath(path)})"
        )


def require_header_path(path, tdir, target):
    if not inside_root(path, tdir):
        raise ValueError(
            f"target '{target['name']}': header path {path} resolves outside target directory "
            f"{os.path.realpath(tdir)} (to {os.path.realpath(path)})"
        )


def target_files(tdir, check_directory=None):
    """Yield (path, path relative to tdir) for every file under tdir, following symlinked directories as
    SwiftPM does. Only a real cycle is cut (a directory that is one of its own ancestors): a directory reached
    under two names is walked under both, because SwiftPM compiles it under every name the manifest does not
    exclude."""
    def walk(dirpath, ancestors):
        if check_directory is not None:
            check_directory(dirpath)
        real = os.path.realpath(dirpath)
        if real in ancestors:
            return
        with os.scandir(dirpath) as it:
            entries = sorted(it, key=lambda entry: entry.name)
        for entry in entries:
            path = os.path.join(dirpath, entry.name)
            if entry.is_dir():  # a symlink to a directory counts
                yield from walk(path, ancestors | {real})
            else:
                yield path, os.path.relpath(path, tdir)

    yield from walk(tdir, frozenset())


def under(rel, entries):
    """Whether the target-relative path is one of the manifest entries or inside one."""
    rel = os.path.normpath(rel)
    return any(rel == e or rel.startswith(e + os.sep) for e in (os.path.normpath(entry) for entry in entries))


def compiled(target, rel):
    """Whether SwiftPM builds the Swift file into the target: not under `exclude:` or `resources:` and, when
    `sources:` is set, under one of its entries."""
    if under(rel, target.get("exclude") or []):
        return False
    if under(rel, [resource["path"] for resource in target.get("resources") or []]):
        return False
    return target.get("sources") is None or under(rel, target["sources"])


def is_modulemap(path):
    name = fold(os.path.basename(path))
    return name.endswith(".modulemap") or name == "module.map"  # clang still reads the legacy name


def locally_ignored(paths):
    """The subset of `paths` git ignores and does not track (check-ignore reports untracked ignored paths only),
    in one git call. Each path's directory is resolved first (check-ignore refuses a path through a symlinked
    directory) but its own name is kept: a tracked link to an ignored file is the link, which git tracks, so the
    file it points at is read. Outside a repository nothing is ignored, so every file is scanned."""
    real = {path: os.path.relpath(os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))) for path in paths}
    out = subprocess.run(["git", "check-ignore", "-z", "--stdin"], capture_output=True, env=pathspec_env(),
                         input=b"".join(os.fsencode(r) + b"\0" for r in real.values()))  # names need not be UTF-8
    ignored = {os.fsdecode(r) for r in out.stdout.split(b"\0")} if out.returncode == 0 else set()
    return {path for path, r in real.items() if r in ignored}


def reject_external_clang(target, detail):
    raise ValueError(
        f"target '{target['name']}' {detail}; external dependencies of the core must be pure Swift, "
        "because this check cannot follow Clang header lookup"
    )


def scan_target(package_root, target):
    """Return (file, line, module) findings using the same source selection for every package."""
    if target.get("type") in ("binary", "system"):
        if package_root != ".":
            reject_external_clang(target, f"is a {target['type']} target")
        raise ValueError(f"depends on {target['type']} target '{target['name']}', whose sources this check cannot scan for AppKit")
    if target.get("pluginUsages"):
        plugins = ", ".join(sorted(str(next(iter(usage.values()))[0]) for usage in target["pluginUsages"]))
        raise ValueError(
            f"target '{target['name']}' uses build-tool plugin(s) {plugins}, whose generated sources this check "
            "cannot scan for AppKit"
        )
    for setting in target.get("settings", []):
        kind = setting.get("kind", {})
        if "unsafeFlags" in kind:
            raise ValueError(
                f"target '{target['name']}' sets unsafeFlags for {setting.get('tool')}, which can import or link "
                "a module without an import line this check scans for"
            )
        framework = (kind.get("linkedFramework") or {}).get("_0")
        # The SDK sits on a case-insensitive volume, where `-framework appkit` links AppKit.
        if fold(str(framework)) in FORBIDDEN_BY_FOLD:
            raise ValueError(f"target '{target['name']}' links framework {framework}")
    tdir = target_dir(target, package_root)

    def check_path(path):  # a linked directory outside the package fails on entry, not after a walk of its tree
        require_package_path(path, package_root, target)

    if package_root != ".":
        check_path(tdir)
        for entry in target.get("sources") or []:
            path = os.path.join(tdir, entry)
            check_path(path)
            # This walker selects files under tdir; do not silently omit an explicit sibling source.
            rel = os.path.relpath(os.path.abspath(path), os.path.abspath(tdir))
            if rel == os.pardir or rel.startswith(os.pardir + os.sep):
                raise ValueError(f"target '{target['name']}': sources entry {path} is outside target directory {tdir}")
    else:
        header_paths = []
        if target.get("publicHeadersPath") is not None:
            header_paths.append(target["publicHeadersPath"])
        for setting in target.get("settings", []):
            search = setting.get("kind", {}).get("headerSearchPath")
            if search is not None:
                header_paths.append(search["_0"])
        for entry in header_paths:
            path = os.path.join(tdir, entry)
            require_header_path(path, tdir, target)
    if not os.path.isdir(tdir):
        raise ValueError(f"target '{target['name']}': source directory {tdir} does not exist")
    files = list(target_files(tdir, check_path))
    for path, rel in files:
        if package_root != ".":
            # Folded on purpose: SwiftPM matches extensions exactly, so this rejects more than it would compile.
            if fold(path).endswith(C_FAMILY_EXTS) or is_modulemap(path):
                reject_external_clang(target, f"contains C-family sources ({os.path.relpath(path, package_root)})")
        elif is_modulemap(path):
            raise ValueError(
                f"target '{target['name']}' holds a module map ({rel}), which can link a framework or map headers "
                "outside the target; this check does not parse module maps, so local targets in the core closure "
                "must rely on the one SwiftPM generates"
            )
    # An ignored, untracked file is not in the commit this gate stamps, so it is not read: item 3 lets a per-machine
    # LOCAL_ONLY file outside `resources:` be and rejects every other one, with its ignore rule, before this check could misreport it.
    for path, _ in files:
        check_path(path)  # before git is asked about the batch: a path outside the package has no place in it
    ignored = locally_ignored([path for path, _ in files]) if package_root == "." else set()
    findings, scanned = [], 0
    for path, rel in files:
        swift = path.endswith(".swift") and compiled(target, rel)
        if package_root != ".":
            if not swift:
                continue  # a pure-Swift external target compiles nothing else
        elif path in ignored:
            continue  # an ignored, untracked file is item 3's business
        # Read only regular files: a link to a device or FIFO would never return.
        if not os.path.isfile(os.path.realpath(path)):
            raise ValueError(f"target '{target['name']}': {path} is not a regular file")
        scanned += swift or path.endswith(C_FAMILY_EXTS)
        with open(path, encoding="utf-8", errors="replace", newline="") as fh:
            text = fh.read()  # raw line breaks: the C scanner tells an escaped `\n\r` from two breaks, which universal newlines cannot
        swift_text = text.replace("\r\n", "\n").replace("\r", "\n")
        found = {(lineno, "import", module) for lineno, module in swift_imports(swift_text)} if swift else set()
        if package_root == ".":
            # Any file can be `#include`d by a compiled C-family one, selected by the manifest or not: a Swift
            # file too, compiled or not. Directive-shaped prose in a comment, string or README fails as well,
            # which errs towards rejecting (documented in item 1).
            found |= set(c_findings(text))  # the two scanners can report the same line once each
        findings += [(os.path.relpath(path, package_root), lineno, kind, what) for lineno, kind, what in sorted(found)]
    if not scanned:
        raise ValueError(f"no source files found in target '{target['name']}'; nothing was checked")
    return findings


def describe(kind, what, local):
    if kind == "import":
        return f"must not import {what}" if local else f"imports {what}"
    if kind == "link" and not local:
        return f"links framework {what} (through an inline module map)"
    if kind == "link":
        return f"must not link framework {what} (through an inline module map)"
    if kind == "build":
        return "holds an inline module map (`#pragma clang module build`), which this check does not parse"
    if kind == "escape":
        return f"includes {what}, an absolute or `..` path this check does not resolve and that can leave the target directory"
    if kind == "machine":
        return (f"includes {what}, a per-machine file name: such a file is ignored and untracked, so a build could read "
                "a file no commit holds and this check does not read")
    if kind == "split":
        return ("holds a `@` (or `@import`) whose next token stands after a directive line, a `_Pragma` operator or in the file that "
                "includes this one: a module import could be split there, which this check does not follow (put the `@` on the same line as its token, or reword the comment)")
    return f"holds an include directive whose argument {what} this check cannot resolve (not a <…> or \"…\" literal)"


def check_core_imports(manifest):
    errors = []
    for root, target, context in core_closure(manifest, errors):
        try:
            findings = scan_target(root, target)
        except (OSError, ValueError) as exc:
            errors.append(f"{context or CORE_TARGET}: {exc}")
            continue
        for path, lineno, kind, what in findings:
            if context:
                errors.append(f"{context}: {path}:{lineno}: {describe(kind, what, False)} (target '{target['name']}')")
            else:
                where = "" if target["name"] == CORE_TARGET else f" (via its dependency '{target['name']}')"
                hint = " (move UI/system-integration code to the app target; see the MVP design, 与 CLI 共享的核心)"
                errors.append(f"{path}:{lineno}: {CORE_TARGET} {describe(kind, what, True)}{where}{hint if kind == 'import' else ''}")
    return errors


def declared_dependencies(manifest):
    """{identity: kind} for the package dependencies Package.swift declares (sourceControl/registry/fileSystem)."""
    out = {}
    for dep in manifest.get("dependencies", []):
        for kind, entries in dep.items():
            for entry in entries or []:
                if isinstance(entry, dict) and entry.get("identity"):
                    out[entry["identity"].lower()] = kind
    return out


def origin(url):
    """A repository URL or path reduced for comparison: no scheme, user, trailing slash or `.git`, symlinks in
    a local path resolved (SwiftPM pins a file:// dependency as a plain path), case-folded."""
    url = re.sub(r"^[\w.+-]+@([^:/]+):", r"\1/", url.strip())  # scp-style git@host:owner/repo
    url = re.sub(r"^[a-z][\w.+-]*://(?:[^@/]+@)?", "", url, flags=re.I)
    url = re.sub(r"(?:\.git)?/*$", "", url, flags=re.I)
    return (os.path.realpath(url) if url.startswith("/") else url).lower()


def same_origin(url, location):
    return all(isinstance(u, str) and u.strip() for u in (url, location)) and origin(url) == origin(location)


def check_licenses(manifest):
    errors = []
    pins = {}
    if os.path.isfile("Package.resolved"):
        try:
            pins = resolved_pins()
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
            return [f"cannot read dependency pins: {exc}"]
    for identity, kind in sorted(declared_dependencies(manifest).items()):
        if identity in pins:
            continue
        if kind == "fileSystem":
            errors.append(
                f"Package.swift declares path dependency '{identity}': path dependencies are never pinned in "
                "Package.resolved, so the license allowlist cannot cover them"
            )
        elif not pins:
            errors.append(
                f"Package.swift declares dependency '{identity}' but Package.resolved is missing: run "
                "`swift package resolve` and commit Package.resolved"
            )
        else:
            errors.append(f"Package.swift declares dependency '{identity}', which Package.resolved does not pin")
    if not pins and not os.path.isfile(ALLOWLIST):
        return errors
    if not os.path.isfile(ALLOWLIST):
        errors.append(
            f"{ALLOWLIST} is missing but Package.resolved pins {len(pins)} package(s). Add an entry per pin: "
            '{"<identity>": {"license": "<SPDX id>", "url": "<the pin\'s location>", "reason": "<why we need it>"}}'
        )
        return errors
    with open(ALLOWLIST, encoding="utf-8") as fh:
        listed = json.load(fh)
    allow = {}
    for key, entry in listed.items():  # Package.resolved writes identities in lowercase
        if key != key.lower():
            errors.append(f"{ALLOWLIST}: key '{key}' must be the lowercase package identity '{key.lower()}'")
        allow[key.lower()] = entry
    for identity, pin in sorted(pins.items()):
        entry = allow.get(identity)
        if entry is None:
            errors.append(f"dependency '{identity}' ({pin.get('location')}) is not in {ALLOWLIST}")
        elif entry.get("license") not in ALLOWED_LICENSES:
            errors.append(
                f"dependency '{identity}' has license {entry.get('license')!r}; allowed: {sorted(ALLOWED_LICENSES)}"
            )
        elif not same_origin(entry.get("url"), pin.get("location")):
            errors.append(
                f"dependency '{identity}' resolves to {pin.get('location')!r}, but {ALLOWLIST} approved "
                f"{entry.get('url')!r}: check the license of this origin and update the entry's url"
            )
    for identity in sorted(set(allow) - set(pins)):
        errors.append(f"{ALLOWLIST}: stale entry '{identity}' is no longer pinned in Package.resolved; remove it")
    return errors


def file_id(path):
    """(device, inode) of what `path` leads to, links followed, or None when nothing is there."""
    try:
        st = os.stat(path)
    except OSError:
        return None
    return st.st_dev, st.st_ino


def resource_path(target, resource):
    return os.path.join(target_dir(target), resource["path"])


def resource_ids(manifest):
    """The file identities of every target's `resources:` entries (`.copy` and `.process`) and of whatever a
    symlink under them points at: SwiftPM copies or processes what is on disk there into the product bundle,
    following links, so a per-machine file in them may ship with the product. Identities, not path strings, so a
    differently cased spelling on a case-insensitive volume or an entry that is itself a link still matches."""
    root = os.path.realpath(".")
    todo = [resource_path(t, r) for t in manifest.get("targets", []) for r in t.get("resources") or []]
    ids = set()
    while todo:
        path = todo.pop()
        ident = file_id(path)
        if ident is None or ident in ids or not inside_root(path, root):
            continue  # missing: SwiftPM reports it; outside: package_paths reports it
        ids.add(ident)
        for dirpath, dirnames, files in os.walk(os.path.realpath(path)):
            todo += [link for link in (os.path.join(dirpath, name) for name in dirnames + files) if os.path.islink(link)]
    return ids


def in_resources(path, ids):
    """Whether the repo-relative path, or a directory above it, is one of the resource identities."""
    while path:
        if file_id(path) in ids:
            return True
        path = os.path.dirname(path)
    return False


def on_disk(rel, root):
    """The repo-relative path as the directory entries spell it. realpath keeps the spelling it is given, and the
    default volume opens `core` or `über` as `Core` or `Über` (Unicode case folding), while git matches pathspecs
    byte for byte; each component is matched to its parent's entry by identity, the last one without following a
    link. A component that is not there is kept as given."""
    cur, out = root, []
    for part in rel.split(os.sep):
        try:
            want = os.lstat(os.path.join(cur, part))
            names = os.listdir(cur)
        except OSError:
            want, names = None, []
        if want is not None and part not in names:
            for name in names:
                st = os.lstat(os.path.join(cur, name))
                if (st.st_dev, st.st_ino) == (want.st_dev, want.st_ino):
                    part = name
                    break
        out.append(part)
        cur = os.path.join(cur, part)
    return os.path.join(*out)


def package_paths(manifest):
    """(paths, outside): the package's files and directories as repo-relative paths with symlinks resolved, and
    the links, target or resource paths that lead outside the repository. SwiftPM follows a symlink while git
    lists only the link, so whatever a link under a package path points at is a package path too; a `resources:`
    entry may lie outside its target directory (`.copy("../Shared")`), and SwiftPM copies it all the same."""
    root = os.path.realpath(".")
    todo = ["Package.swift", "Sources", "Tests"] + [target_dir(t) for t in manifest.get("targets", [])]
    todo += [resource_path(t, r) for t in manifest.get("targets", []) for r in t.get("resources") or []]
    paths, outside = set(), set()
    while todo:
        path = todo.pop()
        if os.path.islink(path):  # the link itself may be ignored, and git lists it under its own name
            link = os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))
            if inside_root(os.path.dirname(link), root):
                paths.add(on_disk(os.path.relpath(link, root), root))
        real = os.path.realpath(path)
        if not inside_root(real, root):
            outside.add(path)
            continue
        rel = on_disk(os.path.relpath(real, root), root)
        if rel in paths:
            continue
        paths.add(rel)
        for dirpath, dirnames, files in os.walk(rel):
            todo += [link for link in (os.path.join(dirpath, name) for name in dirnames + files) if os.path.islink(link)]
    return sorted(paths), sorted(outside)


def ignore_rules(paths):
    """{path: "<ignore file>:<line>: <pattern>"} for the paths `git check-ignore -v` explains."""
    out = subprocess.run(
        ["git", "-c", "core.quotePath=false", "check-ignore", "-v", "-z", "--stdin"],
        env=pathspec_env(),
        input="".join(path + "\0" for path in paths), capture_output=True, encoding="utf-8", errors="replace",
    )
    fields = out.stdout.split("\0")  # source, line, pattern, path, source, ...
    return {fields[i + 3]: f"{fields[i]}:{fields[i + 1]}: {fields[i + 2]}" for i in range(0, len(fields) - 3, 4)}


def check_ignored_files(manifest):
    paths, outside = package_paths(manifest)
    errors = [
        f"{path} leads outside the repository (to {os.path.realpath(path)}): SwiftPM builds what is there, and the "
        "commit does not hold it"
        for path in outside
    ]
    out = subprocess.run(
        ["git", "-c", "core.quotePath=false", "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--"]
        + [":(literal)" + path for path in paths],
        capture_output=True, encoding="utf-8", errors="replace",
        env=pathspec_env(),
    )
    if out.returncode != 0:
        return errors + [f"cannot list the gitignored files in the package: {out.stderr.strip() or 'git ls-files failed'}"]
    resources = resource_ids(manifest)
    ignored = [
        path for path in out.stdout.split("\0")
        if path and (os.path.basename(path) not in LOCAL_ONLY or in_resources(path, resources))
    ]
    if not ignored:
        return errors
    rules = ignore_rules(ignored[:20])
    listing = "".join(
        f"\n  {path}" + (f"  (ignored by {rules[path]})" if path in rules else "") for path in ignored[:20]
    )
    return errors + [
        "gitignored files inside the package (on disk for this build, absent from the commit): remove or rename "
        f"them, or change the ignore rule shown{listing}"
    ]


def main(argv):
    if argv == ["--help"]:
        print("usage: check_swift_invariants.py [--manifest <dump-package.json>]")
        return 0
    try:
        manifest = load_manifest(argv)
    except (OSError, ValueError) as exc:
        print(f"check_swift_invariants: {exc}", file=sys.stderr)
        return 2
    errors = check_core_imports(manifest) + check_licenses(manifest) + check_ignored_files(manifest)
    for e in errors:
        print(e)
    if errors:
        print(f"check_swift_invariants: {len(errors)} violation(s)")
        return 1
    print("check_swift_invariants: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
