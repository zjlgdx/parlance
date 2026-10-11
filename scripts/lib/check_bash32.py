#!/usr/bin/env python3
"""Static bash 3.2 compatibility lint for repo shell scripts (run by `scripts/gate shell`).

Every repo script runs under macOS /bin/bash 3.2, while the Linux CI image's /bin/bash is 5.x, so neither
`bash -n` there nor shellcheck catches bash 4+ syntax. This scan flags, outside comments and quoted strings
(as far as a line-based lexer allows: here-document bodies with a quoted delimiter are skipped, a command
substitution is code again even inside double quotes, a `'` inside a double-quoted `${...}` opens a quote, as
bash 3.2 reads it, and a `case` pattern's `)` inside `$(...)` is taken for the end of the substitution):

- declare/local/typeset with -A, -n, -g, -l, -u (associative arrays, namerefs, ...), readonly -A, `local -`
- mapfile / readarray, coproc, `|&`, `&>>`, the `;&` and `;;&` case terminators
- `[[ -v`; `[ -v`, `test -v` and `wait` with an option (-n, -f, -p) where a command can start (`swift test -v`
  and `xcrun notarytool wait -p` are another program's flags)
- shopt options bash 3.2 does not have (globstar, lastpipe, inherit_errexit, ...), unless the line handles the
  failure (`shopt -s globstar 2>/dev/null || true`, `if shopt -q lastpipe 2>/dev/null`: a probe)
- `{fd}>` named file descriptors, a fractional `read -t`, `{1..10..2}` step ranges and assignments to a negative
  subscript
- case conversion ${x,,} ${x^^} ${x,} ${x^}, ${x@Q}-style transformations, negative subscripts ${a[-1]} and
  the variables bash 3.2 never sets ($BASHPID, $EPOCHSECONDS, $EPOCHREALTIME, $SRANDOM), unless the expansion
  brings its own fallback (`${EPOCHSECONDS:-$(date +%s)}`); bash also expands these inside double quotes and
  unquoted here-documents, so those are scanned too

A line whose trailing comment contains `# bash32-ok` (optionally followed by `: <reason>`) is exempt.

A quote or substitution still open when the file ends is reported as well, and `# bash32-ok` does not exempt
it: the code after the point where it opened was not linted (in a script that `bash -n` accepts, the lexer has
lost its place there).

Usage: check_bash32.py <script> [...]  |  check_bash32.py --self-test
Exit codes: 0 ok, 1 findings, 2 usage error or unreadable file.
"""
import re
import sys

EXEMPT = re.compile(r"#\s*bash32-ok\b")
NAME = r"(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*])(?:\[[^\]]*\])?"
WORD_START = r"(?:^|[\s;&|(){}`])"  # before a word that may be a command name
CMD_START = r"(?:^|[;&|(){}!`]|\b(?:if|then|do|else|elif|while|until)\b)\s*"  # where a command starts
DECLARE = re.compile(WORD_START + r"(declare|typeset|local|readonly)((?:\s+[-+][A-Za-z]+)+)")
SHOPT = re.compile(WORD_START + r"shopt((?:\s+-[A-Za-z]+)*)((?:\s+[A-Za-z_][A-Za-z0-9_]*)+)")
# A shopt whose failure the line handles is a probe: `if shopt ...`, `shopt ... 2>/dev/null || true`.
SHOPT_PROBE_BEFORE = re.compile(r"(?:\b(?:if|elif|while|until)|!)\s*$")
SHOPT_PROBE_AFTER = re.compile(r"(?:\s*(?:&>|[0-9]*[<>]&?)\s*[^\s;&|]+)*\s*(?:\|\||&&)")
SHOPT_32 = frozenset(  # `shopt` under /bin/bash 3.2.57
    "cdable_vars cdspell checkhash checkwinsize cmdhist compat31 dotglob execfail expand_aliases extdebug "
    "extglob extquote failglob force_fignore gnu_errfmt histappend histreedit histverify hostcomplete huponexit "
    "interactive_comments lithist login_shell mailwarn no_empty_cmd_completion nocaseglob nocasematch nullglob "
    "progcomp promptvars restricted_shell shift_verbose sourcepath xpg_echo".split()
)
CODE_RULES = [
    (re.compile(WORD_START + r"(mapfile|readarray)(?=\s|$)"), "mapfile/readarray"),
    (re.compile(WORD_START + r"coproc(?=\s|$)"), "coproc"),
    (re.compile(r"\|&"), "|& (pipe stderr)"),
    (re.compile(r"&>>"), "&>> (append both streams)"),
    (re.compile(r";;?&"), ";& / ;;& case terminator"),
    (re.compile(r"(?:\[\[|" + CMD_START + r"(?:\[|test))\s+(?:!\s+)?-v\s"), "-v test (variable is set)"),
    (re.compile(WORD_START + r"local\s+-(?=\s|;|$)"), "local - (saves the shell options)"),
    (re.compile(CMD_START + r"wait\s+-[A-Za-z]"), "wait with an option (-n, -f, -p)"),
    (re.compile(r"(?<!\$)\{[A-Za-z_][A-Za-z0-9_]*\}[<>]"), "{fd}> named file descriptor"),
    (re.compile(WORD_START + r"read\b[^;&|]*\s-[A-Za-z]*t\s*[0-9]*\.[0-9]"), "read -t with a fraction"),
    (re.compile(r"\{[^{}\s]+\.\.[^{}\s]+\.\.[^{}\s]+\}"), "{a..b..step} brace expansion"),
    (re.compile(WORD_START + r"[A-Za-z_][A-Za-z0-9_]*\[\s*-\s*[0-9$][^\]=]*\]\+?="), "negative array subscript"),
]
NEW_VARS = "BASHPID|EPOCHSECONDS|EPOCHREALTIME|SRANDOM"
EXPAND_RULES = [
    (re.compile(r"\$\{[#!]?" + NAME + r"(?:\^\^|,,|\^|,)"), "${x,,}/${x^^} case conversion"),
    (re.compile(r"\$\{!?" + NAME + r"@[QEPAaULuKk]\}"), "${x@Q}-style transformation"),
    (re.compile(r"\$\{[#!]?[A-Za-z_][A-Za-z0-9_]*\[\s*-\s*[0-9$]"), "negative array subscript"),
    # not ${VAR-...}, ${VAR:-...}, ${VAR+...}, ${VAR:+...}, ${VAR=...}, ${VAR:=...}: they work while VAR is unset
    (re.compile(r"\$(?:" + NEW_VARS + r")\b|\$\{[#!]?(?:" + NEW_VARS + r")\b(?!:?[-+=])"),
     "$BASHPID/$EPOCHSECONDS/$EPOCHREALTIME/$SRANDOM"),
]
DECLARE_OK = {"declare": set("afFirtxp"), "typeset": set("afFirtxp"), "local": set("afFirtxp"), "readonly": set("afp")}
QUOTED = ("'", '"', "$'", "${", "${'")  # contexts whose text is not code
UNCLOSED = (
    "a quote or substitution that opens on this line or below is never closed, as this lint reads the file, so "
    "the code after it was not linted; rewrite it (bash 3.2 takes a ' inside \"${...}\" for an opening quote)"
)


def scan_line(line, stack):
    """Lex one line. `stack` lists the contexts earlier lines left open, innermost last, and is updated in
    place: "'", '"' and "$'" are quoted strings; "$(" and "`" are command substitutions, which are code again
    even inside double quotes (their quotes nest: a `"` there does not close the outer string); "(" is a
    parenthesis inside a substitution, so that its `)` does not end the substitution; "${" is a parameter
    expansion inside double quotes, where a `"` opens a nested string and a `'` the context "${'" (bash 3.2 pairs
    single quotes there, whatever the operator: `"${x#'"'}"` strips a quote, `"${x:-it's}"` is a syntax error; in
    a default-value word it still expands what is between them, so that text stays in `expand`).

    Returns (code, expand, comment, heredocs): `code` has quoted text blanked, `expand` keeps double-quoted
    text (bash expands ${...} there), `heredocs` lists (delimiter, strip_tabs, expands).
    """
    code, expand, heredocs = [], [], []
    i, n = 0, len(line)

    def emit(c, e):
        code.append(c)
        expand.append(e)

    while i < n:
        c = line[i]
        top = stack[-1] if stack else None
        if top == "'" or top == "$'":
            if top == "$'" and c == "\\" and i + 1 < n:
                emit("  ", "  ")
                i += 2
                continue
            if c == "'":
                stack.pop()
                emit(c, c)
            else:
                emit(" ", " ")
            i += 1
            continue
        if top == "${'":
            if c == "'":
                stack.pop()
            emit(" ", c)
            i += 1
            continue
        if top == '"' or top == "${":
            if c == "\\" and i + 1 < n:  # an escaped character is text: \$ starts no expansion
                emit("  ", "  ")
                i += 2
            elif line.startswith("$(", i):
                stack.append("$(")
                emit("$(", "$(")
                i += 2
            elif line.startswith("${", i):
                stack.append("${")
                emit("  ", "${")
                i += 2
            else:
                if c == "`":
                    stack.append("`")
                elif c == '"' and top == '"':
                    stack.pop()
                elif c == '"':
                    stack.append('"')
                elif c == "}" and top == "${":
                    stack.pop()
                elif c == "'" and top == "${":
                    stack.append("${'")
                emit(c if c in '`"' else " ", c)
                i += 1
            continue
        # code: the top level, a command substitution, or a parenthesis inside one
        if c == "\\":  # the escaped character is text, never part of an operator or an expansion
            esc = "\\ " if i + 1 < n else "\\"
            emit(esc, esc)
            i += 2
            continue
        if line.startswith("$'", i) or line.startswith("$(", i):
            stack.append(line[i:i + 2])
            emit(line[i:i + 2], line[i:i + 2])
            i += 2
            continue
        if c in "'\"":
            stack.append(c)
            emit(c, c)
            i += 1
            continue
        if c == "`":  # closes the innermost open backtick substitution, or opens one
            j = len(stack) - 1
            while j >= 0 and stack[j] in ("(", "$("):
                j -= 1
            if j >= 0 and stack[j] == "`":
                del stack[j:]
            else:
                stack.append("`")
            emit(c, c)
            i += 1
            continue
        if (c == "(" and stack) or (c == ")" and top in ("(", "$(")):
            if c == "(":
                stack.append("(")
            else:
                stack.pop()
            emit(c, c)
            i += 1
            continue
        if c == "#" and (i == 0 or line[i - 1] in " \t;&|()<>"):
            return "".join(code), "".join(expand), line[i:], heredocs
        if line.startswith("<<<", i):  # here-string, not a here-document
            emit("<<<", "<<<")
            i += 3
            continue
        if line.startswith("<<", i):
            before = "".join(code)
            if before.count("((") <= before.count("))"):  # not a shift inside (( ... ))
                j = i + 2
                strip = j < n and line[j] == "-"
                if strip:
                    j += 1
                while j < n and line[j] in " \t":
                    j += 1
                word, quoted = [], False
                while j < n and line[j] not in " \t;&|()<>":
                    if line[j] in "'\"":
                        quoted, q = True, line[j]
                        j += 1
                        while j < n and line[j] != q:
                            word.append(line[j])
                            j += 1
                        j += 1
                    elif line[j] == "\\":
                        quoted = True
                        word.append(line[j + 1:j + 2])
                        j += 2
                    else:
                        word.append(line[j])
                        j += 1
                if word and re.match(r"[A-Za-z_'\"\\]", line[i + 2:].lstrip("- \t")[:1] or "-"):
                    heredocs.append(("".join(word), strip, not quoted))
                    emit(line[i:j], line[i:j])
                    i = j
                    continue
        emit(c, c)
        i += 1
    return "".join(code), "".join(expand), "", heredocs


def findings_in(text):
    """Yield (line number, construct) for every bash 4+ construct in a script's text, and (line number,
    UNCLOSED) when the text ends inside a quote or substitution."""
    stack, pending, body, start = [], [], None, 1
    for lineno, line in enumerate(text.splitlines(), 1):
        if not stack:
            start = lineno  # the last line that begins outside every quote and substitution
        if body is not None:  # inside a here-document
            delim, strip, expands = body
            if (line.lstrip("\t") if strip else line) == delim:
                body = pending.pop(0) if pending else None
                continue
            if expands and not EXEMPT.search(line):
                for rx, what in EXPAND_RULES:
                    if rx.search(line):
                        yield lineno, what
            continue
        code, expand, comment, heredocs = scan_line(line, stack)
        pending.extend(heredocs)
        if pending and (not stack or stack[-1] not in QUOTED):  # the line ended outside a quoted string
            body = pending.pop(0)
        if EXEMPT.search(comment):
            continue
        m = DECLARE.search(code)
        while m:
            flags = set("".join(f.lstrip("-+") for f in m.group(2).split()))
            bad = sorted(flags - DECLARE_OK[m.group(1)])
            if bad:
                yield lineno, f"{m.group(1)} -{''.join(bad)}"
            m = DECLARE.search(code, m.end())
        for m in SHOPT.finditer(code):
            unknown = [name for name in m.group(2).split() if name not in SHOPT_32]
            probe = SHOPT_PROBE_BEFORE.search(code[:m.start(1) - len("shopt")]) or SHOPT_PROBE_AFTER.match(code, m.end())
            if unknown and not probe and "o" not in m.group(1).replace("-", ""):  # with -o: `set -o` options
                yield lineno, f"shopt {' '.join(unknown)}"
        for rx, what in CODE_RULES:
            if rx.search(code):
                yield lineno, what
        for rx, what in EXPAND_RULES:
            if rx.search(expand):
                yield lineno, what
    if stack:
        yield start, UNCLOSED


SELF_TEST_BAD = [
    """echo "${1:-'${name,,}'}\"""",
    """echo "${1:-'$BASHPID'}\"""",
    "declare -A map=()",
    "  local -A seen",
    "typeset -n ref=target",
    "declare -g counter=0",
    "local -rA table",
    "declare -r -A table",
    "readonly -A table=()",
    "declare -l lower",
    "mapfile -t lines < file",
    "readarray lines < file",
    "x=1; mapfile -t lines < file",
    'echo "${name,,}"',
    "echo ${name^^}",
    'echo "${name^}"',
    'echo "${arr[@],}"',
    'echo "${1,,}"',
    'printf %s "${value@Q}"',
    'echo "${arr[@]@Q}"',
    "make 2>&1 |& tee log",
    "make &>> log",
    "coproc worker { cat; }",
    "if [[ -v HOME ]]; then :; fi",
    "if [ -v HOME ]; then :; fi",
    "test -v HOME && echo set",
    "if [[ ! -v HOME ]]; then :; fi",
    "  test -v HOME || exit 1",
    "x=1 && [ -v HOME ] && echo set",
    "while test ! -v DONE; do :; done",
    "if ! test -v HOME; then :; fi",
    "  a) echo a ;&",
    "  b) echo b ;;&",
    'cat <<EOF\n${name,,}\nEOF',
    'x="multi\nline"; declare -A m',
    "echo 'a' # c\ndeclare -A m",
    # code inside a command substitution, also one inside double quotes
    'x="$(mapfile -t a < f; echo "${a[0]}")"',
    'x="$(echo "${name,,}")"',
    'echo "$( [ -v HOME ] && echo y )"',
    "x=$(declare -A m; echo 1)",
    'x="`mapfile -t a < f`"',
    # runtime-only failures: `bash -n` on 3.2 accepts these
    'a=(1 2 3); echo "${a[-1]}"',
    'echo "${a[-$n]}"',
    "echo ${#a[-1]}",
    "a[-1]=x",
    "shopt -s globstar",
    "shopt -s nullglob lastpipe",
    "set -e; shopt -s inherit_errexit",
    "sleep 1 & wait -n",
    "f() { sleep 1 & wait -n; }",
    "if ! wait -n; then :; fi",
    "exec {fd}>/dev/null",
    'exec {lock}<"$file"',
    "read -r -t 0.5 x",
    "read -rt .5 x",
    "while IFS= read -r -t 0.5 line; do :; done",  # an assignment comes first: not only where a command starts
    "echo {1..10..2}",
    'echo "now=$EPOCHSECONDS"',
    'echo "pid=${BASHPID}"',
    'echo "${EPOCHSECONDS:?}" "${#SRANDOM}"',
    "echo $SRANDOM $EPOCHREALTIME",
    "cat <<EOF\npid=$BASHPID\nEOF",
    "f() { local -; set -e; }",
    # single quotes pair inside a double-quoted ${...}: the code after these lines must still be linted
    'x=\'"hello"\'\ny="${x#\'"\'}"\ny="${y%\'"\'}"\ndeclare -A seen',
    'y="${x#\'"\'}"\ndeclare -A seen',
    'y="${v%%\'$(\'*}"\nmapfile -t lines < file',
    'y="${v//\'`\'/}"\necho "${name,,}"',
    # the lexer never sees these closed: reported, because the rest of the file was not linted
    'echo "${x:-it\'s}"\necho ok',
    'echo "$(printf %s "a)"\necho ok',
]
SELF_TEST_GOOD = [
    "declare -a list=()",
    "local -a files=()",
    "local -r name=x",
    "declare -i n=0",
    "declare -p PATH",
    "export -n NAME",
    "readonly -a list",
    "# declare -A only in a comment",
    "echo 'declare -A in single quotes'",
    'echo "mapfile and coproc in double quotes"',
    'echo "a |& b ;& c"',
    "grep -v pattern file",
    "swift test -v --filter ParlanceCoreTests",
    "go test -v ./...",
    "if my_test -v x; then :; fi",
    "command -v test >/dev/null",
    'echo "${#name}" "${name:-a,b}" "${name/,/;}" "${arr[@]}" "${@}" "$#"',
    "echo ${x#prefix} ${x##*/} $(( 16#ff ))",
    "case $x in a) echo a ;; esac",
    "cmd >file 2>&1; other &",
    "echo hi | tee log",
    "IFS=$'\\n' read -r line",
    "printf '%s\\n' \"it's\"",
    "x=$'it\\'s'; echo \"$x\"",
    "declare -A map=()  # bash32-ok",
    "echo \"${name,,}\"  # bash32-ok: documented exception",
    "cat <<'EOF'\ndeclare -A m\n${name,,}\nEOF",
    "cat <<-\"EOF\"\n\tmapfile x\n\tEOF\necho done",
    "cat <<\\EOF\n${x^^}\nEOF",
    "cat <<EOF\nplain body\nEOF\necho ok",
    "read -r x <<< \"$y\"",
    "echo $(( 1 << 3 ))",
    'echo "$(( 1 << 3 ))"\necho \'declare -A in single quotes\'',
    "if [[ $BASE =~ ^([0-9]{4}-[0-9]{2})(-[a-z]+){1,5}\\.md$ ]]; then :; fi",
    "trap '[[ -n \"$TMP\" ]] && rm -f \"$TMP\"' EXIT",
    "echo \"a\nb # not a comment\nc\"; echo done",
    "echo foo#bar",
    # quotes nest inside a substitution or an expansion in double quotes: the lexer must stay in sync
    'msg="$(printf "%s" "can\'t stop")"\necho "$msg"\necho \'usage: mapfile is not used here\'',
    'echo "${msg:-"can\'t"}"\necho \'usage: mapfile is not used here\'',
    'x="$(cat <<\'EOF\'\nit\'s "quoted\nEOF\n)"\necho "not code: declare -A m"',
    'x="$(echo ")")"\necho \'coproc in single quotes\'',
    'n="$(wc -l < "$f" | tr -d \' \')"; echo \'readarray in single quotes\'',
    # escaped characters are text
    'echo "\\${1,}"',
    "echo \\${1,} \\|& x",
    'echo "\\$(mapfile) \\`coproc\\`"',
    # bash 3.2 has these
    "shopt -s nullglob dotglob extglob",
    "shopt -qo pipefail",
    'shopt -s "$opt"',
    'wait "$pid"',
    "read -r -t 5 line",
    "echo {1..10} {a..e} file.{txt,md}",
    'echo "${a[${#a[@]}-1]}" "${a[@]: -1}" "${a[i-1]}" "${x:-1}"',
    "a[i-1]=x; a[0]=y; b[$n]+=z",
    'exec 3>/dev/null; echo "${x}">"$f"; echo ${x}>f',
    "local -r x=1; local y",
    'echo "$BASH_VERSION $BASH_SOURCE $EPOCH $RANDOM $$"',
    # another program's `wait` subcommand
    'xcrun notarytool wait -p parlance-notary "$id"',
    "docker wait -h; tmux wait -S build-done",
    # fallbacks and probes that run under bash 3.2
    'now=${EPOCHSECONDS:-$(date +%s)}; pid=${BASHPID:-$$}; echo "${SRANDOM-$RANDOM}" "${EPOCHREALTIME:+x}"',
    ': "${EPOCHSECONDS:=$(date +%s)}"',
    "shopt -s globstar 2>/dev/null || true",
    "shopt -s lastpipe >/dev/null 2>&1 && piped=1",
    "if shopt -q lastpipe 2>/dev/null; then :; fi",
    # single quotes inside a double-quoted ${...} quote, a `"` inside a nested string does not
    'y="${x#\'"\'}"; y="${y%\'"\'}"\necho \'declare -A in single quotes\'',
    'echo "${x:-\'}\'}" "${x%"it\'s"}"\necho \'usage: mapfile is not used here\'',
]


def self_test():
    wrong = [t for t in SELF_TEST_BAD if not list(findings_in(t))]
    wrong += [t for t in SELF_TEST_GOOD if list(findings_in(t))]
    for t in wrong:
        print(f"check_bash32 self-test: wrong verdict for {t!r}: {list(findings_in(t))}")
    if wrong:
        return 1
    print(f"check_bash32: self-test ok ({len(SELF_TEST_BAD) + len(SELF_TEST_GOOD)} cases)")
    return 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    if not argv or any(a.startswith("-") for a in argv):
        print("usage: check_bash32.py <script> [...] | --self-test", file=sys.stderr)
        return 2
    found = 0
    for path in argv:
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError as exc:
            print(f"check_bash32: cannot read {path}: {exc}")
            return 2
        for lineno, what in findings_in(text):
            if what == UNCLOSED:
                print(f"{path}:{lineno}: {what}")
            else:
                print(f"{path}:{lineno}: {what} is bash 4+ (macOS /bin/bash is 3.2); rewrite it, "
                      "or end the line with '# bash32-ok' if it never runs under bash 3.2")
            found += 1
    if found:
        print(f"check_bash32: {found} finding(s)")
        return 1
    print(f"check_bash32: ok ({len(argv)} script(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
