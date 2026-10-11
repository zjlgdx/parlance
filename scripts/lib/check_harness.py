#!/usr/bin/env python3
"""Structural checks for the agent harness (run by `scripts/gate harness`).

Public snapshots omit the private instruction, skill and runner checks, but keep the script, test
isolation and CI gate contract checks (with hosted runners and fork PRs enabled).

Each check names the drift it prevents:
- AGENTS.md over its byte budget: agy truncates a rule file at 24,000 bytes and Codex injects at most
  32 KiB of AGENTS.md text in total, silently cutting the tail (Chinese text costs ~3 bytes per character).
- CLAUDE.md not importing AGENTS.md: Claude Code would read a different rule set from Codex/agy.
- A committed AGENTS.override.md: Codex would silently replace the shared contract.
- Skill/agent frontmatter: `name` must equal the directory/file name (agy lists a nameless skill as
  "SKILL"), descriptions must exist and stay ≤1024 characters, unknown keys are usually typos, SKILL.md
  stays ≤500 lines, and every skill ships a worked example (owner's skill-writing rule). Unquoted values
  must survive a real YAML loader: ` #` would cut the value short, `: ` would make the whole block invalid
  (the loader then drops every key), and a leading indicator character changes the type.
- Hook/script wiring: every script referenced by .claude/settings.json or a skill exists; harness scripts
  are executable and use #!/bin/bash (bash 3.2 everywhere, including the macOS CI guest). The guard hook
  must cover every tool that runs a shell command line (Bash and Monitor): a matcher naming only one of
  them leaves the other unguarded.
- The vendored design-doc checker was edited locally instead of resynced from upstream.
- Repo paths cited in backticks in AGENTS.md, CLAUDE.md, docs/development.md and skill docs exist.
- The CI workflow runs scripts/gate as the CI workflow contract pins it: scripts/land accepts a job by its
  name and conclusion and by the conclusion of its gate step, which it finds by the step's name. A job that
  skips the gate inside the script, softens it (`|| true`, continue-on-error) or narrows it would still look
  green, and one whose gate step has another name, or none, would look as if the gate never ran. The step
  that runs the gate must have the contract's name (`Gate (portable components)` in the gate job,
  `Gate (swift)` in the swift job), no `if:`, and the contract's script line for line (no wrapping `if`, no
  `set -n`) with the contract's `env:` and nothing else (no BASH_ENV, no other GATE_BASE); no `env:` or
  `defaults:` above it and no $GITHUB_ENV/$GITHUB_PATH write in the job's other steps may change how it
  runs. The script is a plain scalar or a literal block (`run: |`); a folded block
  (`run: >`) is refused, because YAML joins its lines into one and a `#` line at the top would then turn the
  whole script into a comment. Every step of the two gate jobs is a block mapping (a flow-style
  `- { run: ... }` step cannot be read here), and the file holds none of the characters that only some YAML
  parsers take for a line end (U+0085, U+2028, ...), which would hide a script line from this check or from
  bash. The gate job's component list must equal scripts/gate's components minus swift, so a new component
  cannot be left out of CI. Not pinned: what the job's other steps do otherwise (a step could still check
  out another commit); review covers those.
- A workflow job that asks for a local runner label together with other labels: the single-use runners
  carry exactly one label (`parlance-linux`; `parlance-macos` once that tier exists), so GitHub would never
  assign the job, and the controller would not start a runner for it. The `runs-on:` values are read line
  by line, so this also covers a workflow the subset parser below cannot place.
- Test scripts that create git repositories clear git's local variables first: under a hook, GIT_DIR and
  GIT_INDEX_FILE point at this repository, and the test's git commands would rewrite its config and refs.

Usage: check_harness.py  |  check_harness.py --self-test   (the settings and workflow rules on samples that must
       pass and mutants that must fail; the samples are built in, so it does not read the repository)
Exit codes: 0 ok, 1 violations or a wrong self-test verdict, 2 usage error.
"""
import glob
import hashlib
import json
import os
import re
import subprocess
import sys

AGENTS_MAX_BYTES = 16384
CLAUDE_MAX_BYTES = 4096
SKILL_MAX_LINES = 500
DESC_MAX = 1024
VENDORED_DESIGN_CHECKER_SHA256 = "30844c5070667315952282bf52ed1652c26f6450308bc052eebb064e9181dd8f"
SKILL_KEYS = {
    "name", "description", "when_to_use", "argument-hint", "arguments", "disable-model-invocation",
    "user-invocable", "allowed-tools", "disallowed-tools", "model", "effort", "context", "agent",
    "background", "hooks", "paths", "shell", "metadata", "license", "compatibility",
}
AGENT_KEYS = {
    "name", "description", "tools", "disallowedTools", "model", "permissionMode", "maxTurns", "skills",
    "mcpServers", "hooks", "memory", "background", "omitClaudeMd", "effort", "isolation", "color",
    "initialPrompt",
}
HARNESS_SCRIPT_GLOBS = [
    "scripts/gate", "scripts/land", "scripts/bootstrap", "scripts/doctor", "scripts/*.sh", "scripts/lib/*.sh",
    "scripts/lib/*.py", ".githooks/*", ".claude/hooks/*", ".claude/skills/*/scripts/*", "tools/ci-runner/*.sh",
    "tools/ci-runner/runnerctl",
]
PATH_DOCS = ["AGENTS.md", "CLAUDE.md", "docs/development.md"]
PATH_PREFIXES = ("scripts/", "docs/", ".claude/", ".github/", ".githooks/", "tools/", "assets/")
ROOT_FILES = {"AGENTS.md", "CLAUDE.md", "README.md", ".gitignore", ".gitleaks.toml", ".shellcheckrc"}
BACKTICK = re.compile(r"`([^`\n]+)`")
YAML_INDICATORS = "[]{},#&*!%@`|>"  # cannot start a plain scalar; - ? : cannot either when followed by a space
CI_WORKFLOW = ".github/workflows/ci.yml"
CI_IF = {
    "gate": "github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository",
    "swift": "needs.gate.outputs.swift == 'true' && vars.PL_MACOS_RUNNER != ''",
}
CI_RUNS_ON = {
    "gate": "${{ fromJSON(vars.PL_LINUX_RUNNER || '\"parlance-linux\"') }}",
    "swift": "${{ fromJSON(vars.PL_MACOS_RUNNER || '\"parlance-macos\"') }}",
}
CI_GATE_ENV = {"GATE_BASE": "${{ github.event.pull_request.base.sha || github.event.before }}"}
CI_GATE_STEP = {"gate": "Gate (portable components)", "swift": "Gate (swift)"}  # scripts/land finds it by name
# A line end to Python's splitlines; to YAML parsers only some of them (YAML 1.1 ones), to bash none.
ODD_LINE_ENDS = "\x0b\x0c\x1c\x1d\x1e\x85\u2028\u2029"
RUNNER_LABELS = ("parlance-linux", "parlance-macos")
RUNS_ON = re.compile(r"""^(\s*)["']?runs-on["']?\s*:(?:\s+(.*))?$""")
JOBS_KEY = re.compile(r"""^["']?jobs["']?\s*:""")
GUARD_HOOK = ".claude/hooks/guard-bash.py"
GUARDED_TOOLS = ("Bash", "Monitor")  # the tools that run a shell command line
TEST_SCRIPT_GLOBS = ["scripts/lib/test*", "tools/ci-runner/test*", ".claude/skills/*/scripts/test*"]
GIT_REPO_SH = re.compile(r"\bgit(?:\s+-[Cc]\s+\S+|\s+--?[\w-]+(?:=\S+)?)*\s+(?:init|clone)\b(?!\.)")
GIT_REPO_PY = re.compile(r"""["']git["']\s*,(?:\s*[^,\])]+\s*,)*?\s*["'](?:init|clone)["']""")

errors = []


def err(msg):
    errors.append(msg)


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def frontmatter(path):
    """Return (keys->value, body) for a ---delimited YAML frontmatter, or (None, text) without one.

    Not a YAML parser (the stdlib has none): block scalars are joined and outer quotes stripped. Unquoted
    scalar values that a real YAML loader would read differently are reported as errors here.
    """
    text = read(path)
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---", 4)
    if end < 0:
        return None, text
    block, body = text[4:end], text[end + 4:]
    keys, inline, current = {}, {}, None
    for line in block.splitlines():
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if m:
            current = m.group(1)
            keys[current] = inline[current] = m.group(2).strip()
        elif current and line.startswith((" ", "\t")):
            keys[current] = (keys[current] + " " + line.strip()).strip()
    for k, v in keys.items():
        if inline[k]:  # a scalar on the key line (an empty one introduces a nested block: not checked)
            for problem in yaml_hazards(inline[k] if inline[k][0] in "|>" else v):
                err(f"{path}: frontmatter `{k}`: {problem}; quote the value (single quotes if it contains \")")
        if v.startswith((">", "|")):
            v = v[1:].lstrip("-+").strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        keys[k] = v
    return keys, body


def yaml_hazards(value):
    """Why a YAML loader would not read this frontmatter value as the text it shows ([] when it would)."""
    if value[0] in "\"'":
        quote, i = value[0], 1
        while i < len(value):
            if (quote == '"' and value[i] == "\\") or (quote == "'" and value[i:i + 2] == "''"):
                i += 2  # an escaped character, or '' for a quote inside single quotes
            elif value[i] == quote:
                rest = value[i + 1:].strip()
                return [] if not rest or rest.startswith("#") else [f"text follows the closing {quote}"]
            else:
                i += 1
        return [f"the {quote}-quoted value is not closed"]
    if value[0] in "|>":
        return [] if re.match(r"^[|>][-+0-9]*$", value) else [f"a leading '{value[0]}' starts a block scalar"]
    out = []
    if " #" in value or "\t#" in value:
        out.append("' #' starts a YAML comment, so the value would be cut short there")
    if ": " in value or value.endswith(":"):
        out.append("': ' (or a trailing ':') is a mapping indicator, so the frontmatter would not parse")
    if value[0] in YAML_INDICATORS or (value[0] in "-?:" and value[1:2] in ("", " ")):
        out.append(f"a leading '{value[0]}' is a YAML indicator")
    return out


def tracked(path):
    return subprocess.run(["git", "ls-files", "--error-unmatch", path], capture_output=True).returncode == 0


def check_instruction_files():
    if not os.path.isfile("AGENTS.md"):
        err("AGENTS.md is missing")
    else:
        size = os.path.getsize("AGENTS.md")
        if size > AGENTS_MAX_BYTES:
            err(f"AGENTS.md is {size} bytes (budget {AGENTS_MAX_BYTES}); move detail into linked docs or skills")
    if not os.path.isfile("CLAUDE.md"):
        err("CLAUDE.md is missing (it must import AGENTS.md)")
    else:
        lines = [ln for ln in read("CLAUDE.md").splitlines() if ln.strip()]
        if not lines or lines[0].strip() != "@AGENTS.md":
            err("CLAUDE.md must start with the line '@AGENTS.md'")
        if os.path.getsize("CLAUDE.md") > CLAUDE_MAX_BYTES:
            err(f"CLAUDE.md is over {CLAUDE_MAX_BYTES} bytes; Claude-only notes belong in skills")
    for name in ("AGENTS.override.md", "AGENTS.local.md", "CLAUDE.local.md"):
        if tracked(name):
            err(f"{name} is committed; it would silently override the shared contract for one tool")


def check_skills():
    for skill_md in sorted(glob.glob(".claude/skills/*/SKILL.md")):
        sdir = os.path.dirname(skill_md)
        name = os.path.basename(sdir)
        keys, body = frontmatter(skill_md)
        if keys is None:
            err(f"{skill_md}: missing YAML frontmatter")
            continue
        if keys.get("name") != name:
            err(f"{skill_md}: name must equal the directory name '{name}' (got {keys.get('name')!r})")
        desc = keys.get("description", "")
        if not desc:
            err(f"{skill_md}: description is empty")
        elif len(desc) > DESC_MAX:
            err(f"{skill_md}: description is {len(desc)} chars (max {DESC_MAX})")
        unknown = set(keys) - SKILL_KEYS
        if unknown:
            err(f"{skill_md}: unknown frontmatter key(s) {sorted(unknown)}")
        nlines = read(skill_md).count("\n") + 1
        if nlines > SKILL_MAX_LINES:
            err(f"{skill_md}: {nlines} lines (max {SKILL_MAX_LINES}); move detail to references/")
        if not os.path.isfile(os.path.join(sdir, "references", "worked-example.md")):
            err(f"{sdir}: missing references/worked-example.md")
        for ref in re.findall(r"\$\{CLAUDE_SKILL_DIR\}/([A-Za-z0-9_./-]+)", body):
            if not os.path.exists(os.path.join(sdir, ref)):
                err(f"{skill_md}: references ${{CLAUDE_SKILL_DIR}}/{ref}, which does not exist")


def check_agents():
    for agent_md in sorted(glob.glob(".claude/agents/*.md")):
        keys, _ = frontmatter(agent_md)
        stem = os.path.splitext(os.path.basename(agent_md))[0]
        if keys is None:
            err(f"{agent_md}: missing YAML frontmatter")
            continue
        if keys.get("name") != stem:
            err(f"{agent_md}: name must equal the file name '{stem}'")
        if not keys.get("description"):
            err(f"{agent_md}: description is empty")
        unknown = set(keys) - AGENT_KEYS
        if unknown:
            err(f"{agent_md}: unknown frontmatter key(s) {sorted(unknown)}")


def check_settings():
    path = ".claude/settings.json"
    if not os.path.isfile(path):
        err(f"{path} is missing")
        return
    try:
        settings = json.loads(read(path))
    except ValueError as exc:
        err(f"{path}: invalid JSON ({exc})")
        return
    hooks = settings.get("hooks") or {}
    for event, entries in hooks.items():
        for entry in entries:
            for hook in entry.get("hooks", []):
                for ref in re.findall(r"\$CLAUDE_PROJECT_DIR/([A-Za-z0-9_./-]+)", hook.get("command", "")):
                    if not os.path.isfile(ref):
                        err(f"{path}: {event} hook runs {ref}, which does not exist")
    lint_guard_hook(hooks, path)


def matcher_covers(matcher, tool):
    """Whether a hook matcher selects the tool: "" and "*" select every tool, anything else is a regular
    expression that must match the whole tool name (`Bash|Monitor`, `Notebook.*`)."""
    if matcher in ("", "*"):
        return True
    try:
        return re.fullmatch(matcher, tool) is not None
    except re.error:
        return False


def lint_guard_hook(hooks, path):
    guarded = [
        entry.get("matcher", "") for entry in hooks.get("PreToolUse", [])
        if any(GUARD_HOOK in hook.get("command", "") for hook in entry.get("hooks", []))
    ]
    for tool in GUARDED_TOOLS:
        if not any(matcher_covers(matcher, tool) for matcher in guarded):
            err(
                f"{path}: no PreToolUse hook runs {GUARD_HOOK} for the {tool} tool; {' and '.join(GUARDED_TOOLS)} "
                "both run shell command lines, so the guard must match both"
            )


def check_scripts():
    seen = set()
    for pattern in HARNESS_SCRIPT_GLOBS:
        for path in glob.glob(pattern):
            if path in seen or not os.path.isfile(path) or path.endswith((".md", ".json", ".plist", ".toml", ".yml", ".yaml")):
                continue
            seen.add(path)
            if not os.access(path, os.X_OK):
                err(f"{path}: not executable (chmod +x)")
            with open(path, encoding="utf-8", errors="replace") as fh:
                first, second = fh.readline().rstrip("\n"), fh.readline()
            if path.endswith(".py"):
                if first != "#!/usr/bin/env python3":
                    err(f"{path}: Python scripts start with '#!/usr/bin/env python3'")
            elif first != "#!/bin/bash" and "Vendored from" not in second:
                err(f"{path}: shell scripts start with '#!/bin/bash' (bash 3.2 on every Mac and CI guest); got {first!r}")
    vendored = "scripts/lib/check-design-doc.sh"
    if os.path.isfile(vendored):
        with open(vendored, "rb") as fh:
            body = b"".join(fh.readlines()[3:])
        digest = hashlib.sha256(body).hexdigest()
        if digest != VENDORED_DESIGN_CHECKER_SHA256:
            err(f"{vendored}: body differs from the pinned upstream copy; resync from yy-skills and update the pin")


def check_cited_paths():
    docs = PATH_DOCS + glob.glob(".claude/skills/*/SKILL.md") + glob.glob(".claude/skills/*/references/*.md")
    docs += glob.glob(".claude/agents/*.md")
    for doc in docs:
        if not os.path.isfile(doc):
            continue
        for lineno, line in enumerate(read(doc).splitlines(), 1):
            for span in BACKTICK.findall(line):
                token = span.strip().split()[0] if span.strip() else ""
                token = token.rstrip(".,;:)）。，")
                if not token or any(c in token for c in "<>{}*$[]|") or "..." in token:
                    continue
                if not (token.startswith(PATH_PREFIXES) or token in ROOT_FILES):
                    continue
                last = token.rstrip("/").rsplit("/", 1)[-1]
                if token.startswith("docs/") and not token.endswith("/") and "." not in last:
                    continue  # a branch name such as docs/1-cli-core-design, not a path

                if not os.path.exists(token.split("#", 1)[0]):
                    err(f"{doc}:{lineno}: cites `{token}`, which does not exist")


def strip_comment(value):
    """Drop a trailing YAML comment (` #...` outside quotes)."""
    quote = None
    for i, ch in enumerate(value):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"" and (i == 0 or value[i - 1] in " \t[{,:("):
            quote = ch
        elif ch == "#" and (i == 0 or value[i - 1] in " \t"):
            return value[:i].rstrip()
    return value.rstrip()


class Folded(str):
    """The text of a folded block scalar (`key: >`): its lines joined with spaces, as YAML joins them (the
    lines YAML would keep apart, more-indented ones and those after a blank line, are joined as well)."""


def parse_workflow(text):
    """Parse the block-style YAML subset GitHub workflows use into dicts, lists and raw scalar strings.

    Not a YAML parser: quotes are kept, flow collections stay strings, a literal block scalar (`run: |`)
    becomes its dedented text and a folded one (`run: >`) a `Folded` string, and a scalar wrapped onto
    more-indented lines is joined with spaces. Enough for the workflow checks; raises ValueError on a line
    it cannot place.
    """
    lines, pos = text.splitlines(), 0

    def indent(line):
        return len(line) - len(line.lstrip(" "))

    def is_item(line):
        return line.strip() == "-" or line.strip().startswith("- ")

    def skip():
        nonlocal pos
        while pos < len(lines) and (not lines[pos].strip() or lines[pos].lstrip().startswith("#")):
            pos += 1

    def node():
        skip()
        if pos >= len(lines):
            return ""
        return sequence(indent(lines[pos])) if is_item(lines[pos]) else mapping(indent(lines[pos]))

    def mapping(ind):
        nonlocal pos
        out = {}
        while True:
            skip()
            if pos >= len(lines) or indent(lines[pos]) != ind or is_item(lines[pos]):
                return out
            m = re.match(r"^\s*([^\s#'\"\[{][^:]*?)\s*:(?:\s+(.*))?$", lines[pos])
            if not m:
                raise ValueError(f"line {pos + 1}: cannot parse {lines[pos].strip()!r}")
            pos += 1
            out[m.group(1)] = value(strip_comment(m.group(2) or ""), ind)

    def wrapped(first, ind):
        """A scalar plus its continuation lines: the following lines indented deeper than its key or dash."""
        nonlocal pos
        parts = [first]
        while pos < len(lines) and lines[pos].strip() and indent(lines[pos]) > ind \
                and not lines[pos].lstrip().startswith("#"):
            parts.append(strip_comment(lines[pos].strip()))
            pos += 1
        return " ".join(parts)

    def value(rest, ind):
        nonlocal pos
        if re.match(r"^[|>][-+0-9]*$", rest):
            body = []
            while pos < len(lines) and (not lines[pos].strip() or indent(lines[pos]) > ind):
                body.append(lines[pos])
                pos += 1
            while body and not body[-1].strip():
                body.pop()
            if rest[0] == ">":
                return Folded(" ".join(b.strip() for b in body if b.strip()))
            base = min((indent(b) for b in body if b.strip()), default=0)
            return "\n".join(b[base:] for b in body)
        if rest:
            return wrapped(rest, ind)
        skip()
        if pos < len(lines) and (indent(lines[pos]) > ind or (indent(lines[pos]) == ind and is_item(lines[pos]))):
            return node()
        return ""

    def sequence(ind):
        nonlocal pos
        out = []
        while True:
            skip()
            if pos >= len(lines) or indent(lines[pos]) != ind or not is_item(lines[pos]):
                return out
            after_dash = lines[pos].strip()[1:]
            rest = after_dash.strip()
            if re.match(r"^[^\s#'\"\[{][^:]*?\s*:(?:\s|$)", rest):
                col = ind + 1 + len(after_dash) - len(after_dash.lstrip(" "))
                lines[pos] = " " * col + rest  # the item's first key: read the item as a mapping at its column
                out.append(mapping(col))
            else:
                pos += 1
                out.append(wrapped(strip_comment(rest), ind) if rest else node())

    result = node()
    skip()
    if pos < len(lines):
        raise ValueError(f"line {pos + 1}: unexpected indentation")
    return result


def gate_components():
    """scripts/gate's component names, or None when they cannot be read."""
    m = re.search(r'^ALL_COMPONENTS="([^"]+)"', read("scripts/gate"), re.M) if os.path.isfile("scripts/gate") else None
    return m.group(1).split() if m else None


def check_ci_workflow(private=True):
    path = CI_WORKFLOW
    if not os.path.isfile(path):
        err(f"{path} is missing")
        return
    components = gate_components()
    if components is None:
        err("scripts/gate: ALL_COMPONENTS not found, so the CI gate step cannot be checked")
        return
    lint_ci_workflow(read(path), components, private=private)


def lint_ci_workflow(text, components, private=True, path=CI_WORKFLOW):
    odd = sorted({f"U+{ord(ch):04X}" for ch in text if ch in ODD_LINE_ENDS})
    if odd:
        err(
            f"{path}: contains {', '.join(odd)}: this check, YAML parsers and bash disagree on whether that "
            "character ends a line, so the script a gate step would run cannot be read here; remove it"
        )
        return
    try:
        wf = parse_workflow(text)
    except ValueError as exc:
        err(f"{path}: {exc}")
        return
    portable = " ".join(c for c in components if c != "swift")
    want = {  # per job: the gate step's `env:` and its script, comments and blank lines aside
        "gate": (CI_GATE_ENV, [
            'if [ -n "${GATE_BASE:-}" ] && [ -n "$(printf \'%s\' "$GATE_BASE" | tr -d 0)" ]; then',
            f'bash scripts/gate --require-clean --base "$GATE_BASE" {portable}',
            "else",
            f"bash scripts/gate --require-clean {portable}",
            "fi",
        ]),
        "swift": ({}, ["bash scripts/gate --require-clean swift"]),
    }
    jobs = wf.get("jobs") if isinstance(wf, dict) else None
    if not isinstance(jobs, dict):
        err(f"{path}: no jobs")
        return
    for key in ("defaults", "env"):
        if key in wf:
            err(f"{path}: workflow-level `{key}:` would change how the gate steps run")
    ci_if = CI_IF if private else {"gate": "", "swift": ""}
    runs_on = CI_RUNS_ON if private else {"gate": "ubuntu-24.04", "swift": "macos-26"}
    for name in ("gate", "swift"):
        job = jobs.get(name)
        if not isinstance(job, dict):
            err(f"{path}: job `{name}` is missing")
            continue
        where = f"{path}: jobs.{name}"
        expr = re.sub(r"^\$\{\{\s*(.*?)\s*\}\}$", r"\1", job.get("if", "") if isinstance(job.get("if"), str) else "")
        if expr != ci_if[name]:
            err(f"{where}.if must be `{ci_if[name]}`")
        if job.get("runs-on") != runs_on[name]:
            err(f"{where}.runs-on must be `{runs_on[name]}`")
        for key in ("continue-on-error", "defaults", "env"):
            if key in job:
                err(f"{where}: `{key}:` is not allowed on a gate job")
        want_env, want_run = want[name]
        gate_steps = 0
        steps = job.get("steps") if isinstance(job.get("steps"), list) else []
        for i, step in enumerate(steps, 1):
            if not isinstance(step, dict):
                err(f"{where} step {i}: not a block mapping (one `key: value` per line), so it cannot be checked; "
                    "a flow-style step `- { ... }` is not allowed in a gate job")
                continue
            label = f"{where} step {step.get('name') or i}"
            run = step.get("run", "") if isinstance(step.get("run"), str) else ""
            if "continue-on-error" in step:
                err(f"{label}: `continue-on-error:` would let a red gate pass")
            if "check_pr_title" in run:
                err(f"{label}: CI must not check the PR title (it reads a frozen title; scripts/land checks the live one)")
            if re.search(r"GITHUB_(?:ENV|PATH)", run):
                err(f"{label}: writing $GITHUB_ENV or $GITHUB_PATH would change how the gate step runs (BASH_ENV, PATH)")
            if "scripts/gate" not in run:
                continue
            gate_steps += 1
            if step.get("name") != CI_GATE_STEP[name]:
                err(f"{label}: the step that runs scripts/gate must be `name: {CI_GATE_STEP[name]}`: scripts/land "
                    "finds the gate step by that name and refuses a PR whose CI job has no such step")
            for key in ("if", "shell", "working-directory"):
                if key in step:
                    err(f"{label}: `{key}:` is not allowed on a step that runs scripts/gate")
            if step.get("env", {}) != want_env:
                err(f"{label}: `env:` must be {'exactly ' + json.dumps(want_env) if want_env else 'absent'}")
            if isinstance(run, Folded):
                err(f"{label}: `run: >` folds the script's lines into one, so a comment line would swallow the gate "
                    "call; write `run: |`")
            code = [ln.strip() for ln in run.splitlines() if ln.strip() and not ln.strip().startswith("#")]
            if code != want_run:
                err(f"{label}: the script must be exactly these lines, in this order: `{'` / `'.join(want_run)}`")
        if gate_steps != 1:
            err(f"{where} must have exactly one step that runs scripts/gate (found {gate_steps})")
    gate, swift = jobs.get("gate"), jobs.get("swift")
    if isinstance(gate, dict):
        outputs = gate.get("outputs") if isinstance(gate.get("outputs"), dict) else {}
        steps = gate.get("steps") if isinstance(gate.get("steps"), list) else []
        if outputs.get("swift") != "${{ steps.stage.outputs.swift }}" or not any(
            isinstance(s, dict) and s.get("id") == "stage" for s in steps
        ):
            err(f"{path}: jobs.gate must output `swift: ${{{{ steps.stage.outputs.swift }}}}` from a step with id `stage`")
    if isinstance(swift, dict) and swift.get("needs") not in ("gate", "[gate]", "[ gate ]"):
        err(f"{path}: jobs.swift.needs must be `gate`")


def check_runner_labels():
    for path in sorted(glob.glob(".github/workflows/*.yml") + glob.glob(".github/workflows/*.yaml")):
        lint_runner_labels(read(path), path)


def owner_line(lines, i):
    """Index of the nearest line above line i that is indented less (its parent in block YAML), or None."""
    indent = len(lines[i]) - len(lines[i].lstrip(" "))
    for j in range(i - 1, -1, -1):
        text = lines[j].strip()
        if text and not text.startswith("#") and len(lines[j]) - len(lines[j].lstrip(" ")) < indent:
            return j
    return None


def runs_on_labels(text):
    """Yield (line number, labels) for the `runs-on:` key of each job (a key directly under a job id under
    `jobs:`; a matrix axis of that name, or the text in a script, is not one). A line scan, not a parse, so
    that a workflow actionlint accepts but parse_workflow cannot place (a quoted key, a flow collection closed
    on a later line) still has its labels read. Reads a scalar (an expression is one label, also when it
    wraps onto the next line), a flow or block sequence and the `group:` / `labels:` mapping."""
    def bare(piece):  # without the brackets of a flow collection around it; an expression keeps its braces
        piece = piece.strip().lstrip("-")
        return piece.strip(" \t[]") if "${{" in piece else piece.strip(" \t[]{}")

    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = RUNS_ON.match(line)
        if not m:
            continue
        job = owner_line(lines, i)
        jobs = owner_line(lines, job) if job is not None else None
        if jobs is None or not JOBS_KEY.match(lines[jobs]):
            continue
        ind, parts, depth = len(m.group(1)), [], 0
        for j in range(i, len(lines)):
            part = strip_comment(m.group(2) or "" if j == i else lines[j])
            col = len(part) - len(part.lstrip(" "))
            if j > i and part.strip() and depth <= 0 and (col < ind or (col == ind and part.strip()[0] != "-")):
                break  # the next key at this level or above; an open `[` or `{` runs on to its closing line
            depth += sum(part.count(c) for c in "[{") - sum(part.count(c) for c in "]}")
            parts.append(part)
        if "\n".join(parts).strip().startswith("${{"):
            yield i + 1, [" ".join(" ".join(parts).split())]
            continue
        labels = []
        for piece in re.split(r"[,\n]", "\n".join(parts)):
            piece = bare(piece)
            key = re.match(r"^(\w[\w-]*)\s*:\s*(.*)$", piece)  # `group: local`, `labels: [a`
            if key:
                piece = bare(key.group(2)) if key.group(1) == "labels" else ""
            piece = piece.strip("'\"")
            if piece and not re.match(r"^[|>][-+0-9]*$", piece):  # a block scalar's indicator is not a label
                labels.append(piece)
        yield i + 1, labels


def lint_runner_labels(text, path):
    for lineno, labels in runs_on_labels(text):
        if len(labels) > 1 and any(label.lower() in RUNNER_LABELS for label in labels):
            err(
                f"{path}:{lineno}: runs-on asks for {', '.join(labels)}: the local runners carry exactly one "
                "label, so GitHub would never assign this job; name that label alone"
            )


def check_test_isolation():
    paths = sorted({p for pattern in TEST_SCRIPT_GLOBS for p in glob.glob(pattern) if os.path.isfile(p)})
    for path in paths:
        text = read(path)
        if (GIT_REPO_SH.search(text) or GIT_REPO_PY.search(text)) and "--local-env-vars" not in text:
            err(
                f"{path}: creates git repositories without first clearing git's local variables; under a hook "
                "GIT_DIR/GIT_INDEX_FILE would point its git commands at this repository. Add (bash) "
                "`unset $(git rev-parse --local-env-vars)` or (python) pop each name it prints from os.environ"
            )


# --- self-test: the settings and workflow rules on built-in samples -----------------------------------------

SAMPLE_COMPONENTS = ["docs", "shell", "actions", "harness", "secrets", "swift"]
CI_SAMPLE = """\
name: ci
on:
  pull_request:
    types: [opened, synchronize,
      reopened]
permissions:
  contents: read
jobs:
  gate:
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ${{ fromJSON(vars.PL_LINUX_RUNNER || '"parlance-linux"') }}
    outputs:
      swift: ${{ steps.stage.outputs.swift }}
    steps:
      - uses: actions/checkout@v5
      - id: stage
        run: echo "swift=false" >> "$GITHUB_OUTPUT"
      - name: Gate (portable components)
        env:
          GATE_BASE: ${{ github.event.pull_request.base.sha || github.event.before }}
        run: |
          # the previous main tip on a push

          if [ -n "${GATE_BASE:-}" ] && [ -n "$(printf '%s' "$GATE_BASE" | tr -d 0)" ]; then
            bash scripts/gate --require-clean --base "$GATE_BASE" docs shell actions harness secrets
          else
            bash scripts/gate --require-clean docs shell actions harness secrets
          fi
  swift:
    needs: gate
    if: needs.gate.outputs.swift == 'true' && vars.PL_MACOS_RUNNER != ''
    runs-on: ${{ fromJSON(vars.PL_MACOS_RUNNER || '"parlance-macos"') }}
    steps:
      - uses: actions/checkout@v5
      - name: Gate (swift)
        run: bash scripts/gate --require-clean swift
"""
CI_IF_LINE = '          if [ -n "${GATE_BASE:-}" ] && [ -n "$(printf \'%s\' "$GATE_BASE" | tr -d 0)" ]; then\n'
CI_FULL_LINE = "            bash scripts/gate --require-clean docs shell actions harness secrets\n"
CI_SWIFT_RUN = "        run: bash scripts/gate --require-clean swift\n"
CI_GATE_NAME = "      - name: Gate (portable components)\n"
CI_SWIFT_NAME = "      - name: Gate (swift)\n"
# (name, [(text in CI_SAMPLE, its replacement), ...], the problem expected): workflows that must pass ...
CI_GOOD = [
    ("the contract's workflow", [], None),
    ("another job with an `if:` wrapped onto a second line", [(
        "  swift:\n",
        "  notify:\n    needs: [gate, swift]\n    if: always() && needs.gate.result == 'failure' &&\n"
        "      github.event_name == 'push'\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo failed\n  swift:\n",
    )], None),
    ("the gate job's `if:` wrapped onto a second line", [(
        "    if: github.event_name != 'pull_request' || github",
        "    if: github.event_name != 'pull_request' ||\n      github",
    )], None),
]
# ... and mutants that must not, each with the words of the problem it must raise. scripts/land reads a job's
# conclusion and that of its gate step: to it, most of them still look like "the gate ran".
SCRIPT, ENV = "the script must be exactly", "`env:` must be exactly"
GATE_NAME, SWIFT_NAME = "must be `name: Gate (portable components)`", "must be `name: Gate (swift)`"
CI_BAD = [
    ("gate wrapped in a docs-only skip", [
        (CI_IF_LINE, "          if git diff --name-only \"$GATE_BASE\" HEAD | grep -qv '^docs/'; then\n" + CI_IF_LINE),
        ("          fi\n", "          fi\n          fi\n"),
    ], SCRIPT),
    ("gate wrapped in `if false`", [
        (CI_IF_LINE, "          if false; then\n" + CI_IF_LINE), ("          fi\n", "          fi\n          fi\n"),
    ], SCRIPT),
    ("`set -n` before the gate", [(CI_IF_LINE, "          set -n\n" + CI_IF_LINE)], SCRIPT),
    ("`exit 0` before the gate", [(CI_IF_LINE, "          exit 0\n" + CI_IF_LINE)], SCRIPT),
    ("`|| true` after a gate call", [(CI_FULL_LINE, CI_FULL_LINE.rstrip("\n") + " || true\n")], SCRIPT),
    ("a component left out", [(" docs shell actions harness secrets\n          else", " docs shell actions harness\n          else")], SCRIPT),
    ("--require-clean dropped", [(CI_FULL_LINE, CI_FULL_LINE.replace(" --require-clean", ""))], SCRIPT),
    ("`else` turned into a dead branch", [("          else\n", "          elif false; then\n")], SCRIPT),
    ("step env BASH_ENV", [("        env:\n", "        env:\n          BASH_ENV: ./ci-skip.sh\n")], ENV),
    ("GATE_BASE narrowed to the PR head", [("pull_request.base.sha ||", "pull_request.head.sha ||")], ENV),
    ("gate step without its env", [
        ("        env:\n          GATE_BASE: ${{ github.event.pull_request.base.sha || github.event.before }}\n", ""),
    ], ENV),
    ("job env BASH_ENV", [("    outputs:\n", "    env:\n      BASH_ENV: ./ci-skip.sh\n    outputs:\n")], "jobs.gate: `env:` is not allowed"),
    ("workflow env BASH_ENV", [("permissions:\n", "env:\n  BASH_ENV: ./ci-skip.sh\npermissions:\n")], "workflow-level `env:`"),
    ("workflow defaults", [("permissions:\n", "defaults:\n  run:\n    shell: sh\npermissions:\n")], "workflow-level `defaults:`"),
    ("an earlier step writes $GITHUB_ENV", [
        ('>> "$GITHUB_OUTPUT"', '>> "$GITHUB_OUTPUT"; echo "BASH_ENV=$PWD/ci-skip.sh" >> "$GITHUB_ENV"'),
    ], "writing $GITHUB_ENV"),
    ("gate step `if:`", [(CI_GATE_NAME, CI_GATE_NAME + "        if: github.event_name == 'push'\n")], "`if:` is not allowed"),
    ("gate step `shell:`", [(CI_GATE_NAME, CI_GATE_NAME + "        shell: bash -n {0}\n")], "`shell:` is not allowed"),
    ("gate step continue-on-error", [(CI_GATE_NAME, CI_GATE_NAME + "        continue-on-error: true\n")], "would let a red gate pass"),
    ("gate job continue-on-error", [("    outputs:\n", "    continue-on-error: true\n    outputs:\n")], "`continue-on-error:` is not allowed"),
    ("gate job `if:` softened", [(" || github.event.pull_request.head.repo.full_name == github.repository", " || false")], "jobs.gate.if must be"),
    ("gate job on another runner", [
        ("vars.PL_LINUX_RUNNER || '\"parlance-linux\"'", "vars.PL_LINUX_RUNNER || '\"ubuntu-latest\"'"),
    ], "jobs.gate.runs-on must be"),
    ("no gate step", [(CI_SWIFT_RUN, "        run: echo skipped\n")], "exactly one step that runs scripts/gate (found 0)"),
    ("two gate steps", [(CI_SWIFT_RUN, CI_SWIFT_RUN + "      - run: bash scripts/gate --require-clean swift\n")], "(found 2)"),
    ("swift step with `set -n`", [
        (CI_SWIFT_RUN, "        run: |\n          set -n\n          bash scripts/gate --require-clean swift\n"),
    ], SCRIPT),
    ("swift step env", [(CI_SWIFT_RUN, "        env:\n          BASH_ENV: ./ci-skip.sh\n" + CI_SWIFT_RUN)], "`env:` must be absent"),
    ("swift job no longer needs gate", [("    needs: gate\n", "")], "jobs.swift.needs must be"),
    ("a PR-title step", [
        (CI_GATE_NAME, "      - run: python3 scripts/lib/check_pr_title.py \"$TITLE\"\n" + CI_GATE_NAME),
    ], "must not check the PR title"),
    ("stage output dropped", [("      - id: stage\n", "      - id: other\n")], "jobs.gate must output `swift:"),
    # YAML hands bash something other than the lines written: a folded scalar is one line, so its comment line
    # swallows the script; a line end that only this check sees hides the `#` in front of each script line
    ("gate step as a folded scalar", [("        run: |\n          # the previous", "        run: >\n          # the previous")], "`run: >` folds"),
    ("swift step as a folded scalar under a comment line", [
        (CI_SWIFT_RUN, "        run: >\n          # the swift tier\n          bash scripts/gate --require-clean swift\n"),
    ], "`run: >` folds"),
    ("`#` and U+2028 in front of script lines", [
        (CI_IF_LINE, "          #\u2028" + CI_IF_LINE), (CI_FULL_LINE, "            #\u2028" + CI_FULL_LINE),
    ], "U+2028"),
    ("`exit 0` after a comment and U+0085", [(CI_IF_LINE, "          # note\x85          exit 0\n" + CI_IF_LINE)], "U+0085"),
    # ... while a bare CR ends a line for every YAML parser, so it must end one here too (not only "\n")
    ("`exit 0` after a comment and a bare CR", [(CI_IF_LINE, "          # note\r          exit 0\n" + CI_IF_LINE)], SCRIPT),
    ("a flow-style step that writes $GITHUB_ENV", [
        (CI_GATE_NAME, "      - { run: 'echo \"BASH_ENV=$PWD/ci-skip.sh\" >> \"$GITHUB_ENV\"' }\n" + CI_GATE_NAME),
    ], "not a block mapping"),
    # scripts/land finds the gate step by its name: under another name (another letter case too) or without one,
    # the gate runs as before and land sees a job that has no gate step
    ("gate step renamed", [(CI_GATE_NAME, "      - name: Gate\n")], GATE_NAME),
    ("gate step without a name", [(CI_GATE_NAME + "        env:\n", "      - env:\n")], GATE_NAME),
    ("swift gate step renamed", [(CI_SWIFT_NAME, "      - name: Gate (Swift)\n")], SWIFT_NAME),
    ("swift gate step without a name", [
        (CI_SWIFT_NAME + CI_SWIFT_RUN, "      - run: bash scripts/gate --require-clean swift\n"),
    ], SWIFT_NAME),
]
# A workflow parse_workflow cannot place (a quoted key, a flow list closed on its own line); actionlint accepts it.
LABEL_SAMPLE = '"on":\n  push:\n    paths: [\n      docs/**\n    ]\njobs:\n  build:\n    runs-on: %s\n    steps:\n      - run: echo ok\n'
LABEL_CASES = [  # (runs-on value, accepted?)
    ("parlance-linux", True),
    ("${{ fromJSON(vars.PL_LINUX_RUNNER || '\"parlance-linux\"') }}", True),
    ("[parlance-linux]", True),
    ("[self-hosted, macOS]", True),
    ("[self-hosted, parlance-linux]", False),
    ("[ Parlance-Linux, \"big\" ]", False),
    ("\n      - self-hosted\n      - parlance-macos", False),
    ("\n      group: local\n      labels: [parlance-linux, big]", False),
    ("\n      group: local\n      labels: parlance-linux", True),
    ("[\n      parlance-linux\n    ]", True),
    ("[\n      self-hosted, parlance-linux\n    ]", False),
    ("[self-hosted,\n      parlance-macos]  # two labels", False),
    ("\n    - self-hosted\n    - parlance-linux", False),
    (">-\n      parlance-linux", True),
]
LABEL_DOCS = [  # (name, workflow, accepted?): `runs-on` that is not a job's own key, and a wrapped expression
    ("matrix axis named runs-on", "on: push\njobs:\n  build:\n    strategy:\n      matrix:\n        runs-on: [parlance-linux, parlance-macos]\n    runs-on: ${{ matrix.runs-on }}\n    steps:\n      - run: echo ok\n", True),
    ("expression wrapped onto a second line", "on: push\njobs:\n  build:\n    runs-on: ${{ inputs.hosted && 'ubuntu-24.04-arm' ||\n      'parlance-linux' }}\n    steps:\n      - run: echo ok\n", True),
    ("runs-on text inside a script", "on: push\njobs:\n  build:\n    runs-on: parlance-linux\n    steps:\n      - run: |\n          cat <<EOF\n          runs-on: [self-hosted, parlance-linux]\n          EOF\n", True),
    ("a job's own two labels in the same file", "on: push\njobs:\n  build:\n    strategy:\n      matrix:\n        runs-on: [a, b]\n    runs-on: [self-hosted, parlance-linux]\n    steps:\n      - run: echo ok\n", False),
]
GUARD_COMMAND = {"hooks": [{"type": "command", "command": f'python3 "$CLAUDE_PROJECT_DIR/{GUARD_HOOK}"'}]}
HOOK_CASES = [  # (name, hooks, accepted?)
    ("Bash|Monitor", {"PreToolUse": [dict(GUARD_COMMAND, matcher="Bash|Monitor")]}, True),
    ("Monitor|Bash|Write", {"PreToolUse": [dict(GUARD_COMMAND, matcher="Monitor|Bash|Write")]}, True),
    ("*", {"PreToolUse": [dict(GUARD_COMMAND, matcher="*")]}, True),
    ("no matcher", {"PreToolUse": [GUARD_COMMAND]}, True),
    ("one entry per tool", {"PreToolUse": [dict(GUARD_COMMAND, matcher="Bash"), dict(GUARD_COMMAND, matcher="Monitor")]}, True),
    ("Bash only", {"PreToolUse": [dict(GUARD_COMMAND, matcher="Bash")]}, False),
    ("Monitor only", {"PreToolUse": [dict(GUARD_COMMAND, matcher="Monitor")]}, False),
    ("BashOutput|Monitor", {"PreToolUse": [dict(GUARD_COMMAND, matcher="BashOutput|Monitor")]}, False),
    ("Bash|Mon (part of a name)", {"PreToolUse": [dict(GUARD_COMMAND, matcher="Bash|Mon")]}, False),
    ("Monitor matched by another hook", {"PreToolUse": [
        dict(GUARD_COMMAND, matcher="Bash"),
        {"matcher": "Monitor", "hooks": [{"type": "command", "command": "true"}]},
    ]}, False),
    ("guard under PostToolUse", {"PostToolUse": [dict(GUARD_COMMAND, matcher="Bash|Monitor")]}, False),
    ("no hooks", {}, False),
]


def reported(check, *args):
    """What one check reports for the given input."""
    global errors
    saved, errors = errors, []
    try:
        check(*args)
        return errors
    finally:
        errors = saved


def self_test():
    wrong = []

    def expect(name, problems, why):  # why: None = no problem, else words one of the problems must contain
        if (why is None and problems) or (why is not None and not any(why in p for p in problems)):
            wrong.append(f"{name}: expected {'no problem' if why is None else repr(why)}, got {problems or 'none'}")

    for name, edits, why in CI_GOOD + CI_BAD:
        text = CI_SAMPLE
        for old, new in edits:
            if text.count(old) != 1:
                wrong.append(f"ci.yml {name}: the sample has {text.count(old)} copies of {old!r}, expected 1")
            text = text.replace(old, new)
        expect(f"ci.yml {name}", reported(lint_ci_workflow, text, SAMPLE_COMPONENTS), why)
    for runs_on, accepted in LABEL_CASES:
        problems = reported(lint_runner_labels, LABEL_SAMPLE % runs_on, "sample.yml")
        expect(f"runs-on {runs_on!r}", problems, None if accepted else "carry exactly one label")
    for name, text, accepted in LABEL_DOCS:
        problems = reported(lint_runner_labels, text, "sample.yml")
        expect(f"runs-on: {name}", problems, None if accepted else "carry exactly one label")
    for name, hooks, accepted in HOOK_CASES:
        expect(f"guard hook matcher {name}", reported(lint_guard_hook, hooks, "settings.json"), None if accepted else GUARD_HOOK)
    for line in wrong:
        print(f"check_harness self-test: {line}")
    if wrong:
        return 1
    print(f"check_harness: self-test ok ({len(CI_GOOD) + len(CI_BAD) + len(LABEL_CASES) + len(LABEL_DOCS) + len(HOOK_CASES)} cases)")
    return 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    if argv:
        print("usage: check_harness.py | check_harness.py --self-test", file=sys.stderr)
        return 2
    private = any(os.path.exists(p) for p in ("AGENTS.md", "CLAUDE.md", ".claude", "tools")) or tracked("AGENTS.md")
    if private:
        check_instruction_files()
        check_skills()
        check_agents()
        check_settings()
        check_cited_paths()
    else:
        print("private harness structure: N/A (public snapshot has no agent or runner files)")
    check_scripts()
    check_ci_workflow(private=private)
    public_ci = "public/.github/workflows/ci.yml"
    if private and os.path.isfile(public_ci) and gate_components() is not None:
        # The exported CI must meet the public contract before export, not only inside a snapshot.
        lint_ci_workflow(read(public_ci), gate_components(), private=False, path=public_ci)
    check_runner_labels()
    check_test_isolation()
    for e in errors:
        print(e)
    if errors:
        print(f"check_harness: {len(errors)} problem(s)")
        return 1
    print("check_harness: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
