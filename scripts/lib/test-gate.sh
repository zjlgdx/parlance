#!/bin/bash
# scripts/lib/test-gate.sh — counterexample table for scripts/gate itself and its non-swift components (run by
# `scripts/gate harness`; the slow swift table is test-swift-gate.sh). Runs the self-tests of the two static
# lints (check_bash32.py, check_harness.py; each has to print its own success line) and check_harness.py on two
# sample workflows it must report, then a copy of the gate in a throwaway repository, and checks that: a
# failing tool is FAIL, never N/A (actionlint findings, usage and fatal errors), while "no workflows" is N/A;
# files whose names contain spaces or non-ASCII characters reach the docs, shell and secrets checks, and files
# deleted from the tree are skipped; bash 4+ syntax fails the shell component unless the line says
# `# bash32-ok`, also after a quote inside a double-quoted `${...}`, while another program's `-v` and `wait`
# flags and bash 3.2-safe fallbacks pass; a caller's SHELLCHECK_OPTS weakens neither shellcheck nor actionlint;
# gitleaks applies the repo's .gitleaks.toml to untracked files, leaves a stash alone, sees a secret that only
# a merge resolution added, is not blinded by the caller's git colour settings or by diff attributes, and
# fails when it logs an error (a git warning is not one); every harness check is required and none sees a
# hook's GIT_DIR/GIT_INDEX_FILE; `--staged` notices a harness file renamed out of the watched paths; a
# component that changes the working tree, or HEAD moving while the gate runs (in a reftable checkout too,
# where git can create one), fails the run and leaves no stamp. Exit 0 when every case behaves as expected.

set -u
# shellcheck disable=SC2046  # the variable names are single words
unset $(git rev-parse --local-env-vars)
unset GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML
ROOT=$(git rev-parse --show-toplevel) || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pl-gatetest.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name tester
git config --file "$GIT_CONFIG_GLOBAL" user.email tester@example.com
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

failures=0
cases=0
for lint in check_bash32.py check_harness.py; do
  # Exit 0 is not enough: a copy that predates --self-test would run its normal check instead and pass.
  if ! python3 "$ROOT/scripts/lib/$lint" --self-test >"$TMP/out.log" 2>&1 \
    || ! grep -Eq "^${lint%.py}: self-test ok \([0-9]+ cases\)$" "$TMP/out.log"; then
    failures=$((failures + 1))
    echo "test-gate: FAIL $lint --self-test"
    cat "$TMP/out.log"
  fi
done
# Those tables sit in the files they test, so an older copy of a lint passes its own table. check_bash32.py is
# also driven through the gate below; check_harness.py runs here in a bare tree, where it reports everything that
# tree lacks: what counts is that it reports these two workflows too (a folded `run:` on a step that calls the
# gate; a local runner label next to another one, in a workflow whose quoted key its parser cannot place).
BARE="$TMP/bare"
mkdir -p "$BARE/.github/workflows" "$BARE/scripts"
cp "$ROOT/scripts/gate" "$BARE/scripts/gate"
cat > "$BARE/.github/workflows/ci.yml" <<'EOF'
on: push
jobs:
  gate:
    steps:
      - run: >
          # a comment line
          bash scripts/gate
EOF
cat > "$BARE/.github/workflows/notes.yml" <<'EOF'
"on": push
jobs:
  notes:
    runs-on: [self-hosted, parlance-linux]
    steps:
      - run: echo ok
EOF
(cd "$BARE" && python3 "$ROOT/scripts/lib/check_harness.py") >"$TMP/out.log" 2>&1
for rx in 'ci\.yml: jobs\.gate step 1: .run: >. folds' \
  'notes\.yml:4: runs-on asks for self-hosted, parlance-linux'; do
  cases=$((cases + 1))
  grep -Eq "$rx" "$TMP/out.log" \
    || { failures=$((failures + 1)); echo "test-gate: FAIL check_harness.py in a bare tree: no line matching /$rx/"; }
done

REPO="$TMP/repo"
mkdir -p "$REPO/scripts/lib" "$REPO/tools/ci-runner" "$REPO/.github/workflows" "$REPO/docs/notes" \
  "$REPO/.claude/skills/pl-next/scripts"
cp "$ROOT/scripts/gate" "$REPO/scripts/gate"
for f in check_docs.py check-design-doc.sh check_bash32.py; do cp "$ROOT/scripts/lib/$f" "$REPO/scripts/lib/$f"; done
cp "$ROOT/.gitleaks.toml" "$ROOT/.shellcheckrc" "$REPO/"
printf 'build/\n' > "$REPO/.gitignore"
printf '# Probe\n\nSee [the note](docs/notes/ok.md).\n' > "$REPO/README.md"
printf '# OK\n' > "$REPO/docs/notes/ok.md"
cat > "$REPO/.github/workflows/ci.yml" <<'EOF'
name: ci
on: push
permissions:
  contents: read
jobs:
  probe:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF
# Stand-ins for the harness checks, so the full runs below do not recurse into this table. The git-hooks one
# fails if a hook's git variables reach it.
CHECKS=(scripts/lib/check_harness.py scripts/lib/pr_refs.py scripts/lib/test_guard.py scripts/lib/test-git-hooks.sh
  scripts/lib/test-land.sh scripts/lib/test-cla-check.sh tools/ci-runner/test-controller.sh tools/ci-runner/test-macos-controller.sh scripts/lib/test-doctor.sh
  .claude/skills/pl-next/scripts/test_select_next.py .claude/skills/pl-next/scripts/test-codex-worker.sh
  scripts/lib/check_pr_title.py scripts/lib/test-gate.sh)
for f in "${CHECKS[@]}"; do
  case "$f" in
    *.py) printf '#!/usr/bin/env python3\n' > "$REPO/$f" ;;
    *) printf '#!/bin/bash\nexit 0\n' > "$REPO/$f" ;;
  esac
done
cat > "$REPO/scripts/lib/test-git-hooks.sh" <<'EOF'
#!/bin/bash
[ -z "${GIT_DIR:-}${GIT_INDEX_FILE:-}" ] || { echo "leaked: GIT_DIR=${GIT_DIR:-} GIT_INDEX_FILE=${GIT_INDEX_FILE:-}"; exit 1; }
EOF
cd "$REPO" || exit 1
git init -q && git add -A && git commit -q -m init

GATE_ENV=()
expect() {  # expect <pass|fail> <name> <ERE the output must match, or ''> [gate args...]
  local want=$1 name=$2 rx=$3 got
  shift 3
  cases=$((cases + 1))
  if env ${GATE_ENV[@]+"${GATE_ENV[@]}"} bash scripts/gate "$@" >"$TMP/out.log" 2>&1; then got=pass; else got=fail; fi
  if [ "$got" != "$want" ] || { [ -n "$rx" ] && ! grep -Eq "$rx" "$TMP/out.log"; }; then
    failures=$((failures + 1))
    echo "test-gate: FAIL $name: expected $want${rx:+ matching /$rx/}, got $got"
    tail -n 15 "$TMP/out.log" | sed 's/^/    /'
  fi
}
stamped() { [ -f "$(git rev-parse --git-common-dir)/parlance-gate/${1:-$(git rev-parse HEAD)}" ]; }  # stamped [sha]
reset_tree() { git reset -q && git checkout -q -- . && git clean -qfd; }

# App-only routing and xcresult counts work on portable runners through tool stand-ins.
expect pass "neither package nor App project is Swift N/A" 'swift +N/A' swift
mkdir -p App/Parlance.xcodeproj App/Parlance "$TMP/appbin"
printf '{}\n' > .swift-format
printf 'let value = 1\n' > App/Parlance/Probe.swift
cat > "$TMP/appbin/swift" <<'EOF'
#!/bin/bash
if [ "${APP_LINT_FAIL:-0}" = 1 ]; then exit 1; fi
exit 0
EOF
cat > "$TMP/appbin/xcodebuild" <<'EOF'
#!/bin/bash
case " $* " in
  *' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= '*) ;;
  *) echo 'missing ad-hoc signing overrides'; exit 1 ;;
esac
exit "${APP_BUILD_EXIT:-0}"
EOF
cat > "$TMP/appbin/xcrun" <<'EOF'
#!/bin/bash
case "${APP_RESULT:-pass}" in
  pass) printf '%s\n' '{"result":"Passed","passedTests":3,"failedTests":0,"skippedTests":1}' ;;
  zero) printf '%s\n' '{"result":"Passed","passedTests":0,"failedTests":0,"skippedTests":0}' ;;
  skipped) printf '%s\n' '{"result":"Passed","passedTests":0,"failedTests":0,"skippedTests":3}' ;;
  failed) printf '%s\n' '{"result":"Failed","passedTests":2,"failedTests":1,"skippedTests":0}' ;;
  missing) exit 1 ;;
  malformed) printf '{}\n' ;;
esac
EOF
chmod +x "$TMP/appbin/"*
GATE_ENV=("PATH=$TMP/appbin:$PATH")
expect pass "App-only Swift applies in --list" 'swift +active' --list
expect pass "App-only build and executed tests" 'swift +PASS.*tests=3' swift
rm .swift-format
expect fail "App requires the repository formatter configuration" '\.swift-format is missing' swift
printf '{}\n' > .swift-format
GATE_ENV=("PATH=$TMP/appbin:$PATH" "APP_BUILD_EXIT=1")
expect fail "App build failure with otherwise passing result" 'swift +FAIL' swift
for result in zero skipped failed missing malformed; do
  GATE_ENV=("PATH=$TMP/appbin:$PATH" "APP_RESULT=$result")
  expect fail "App result $result fails closed" 'swift +FAIL' swift
done
GATE_ENV=("PATH=$TMP/appbin:$PATH" "APP_LINT_FAIL=1")
git add App/Parlance/Probe.swift
expect fail "--staged lints App Swift sources" 'swift +FAIL' --staged swift
GATE_ENV=()
reset_tree

expect pass "baseline" 'GATE result=pass' docs shell actions secrets

# A failing tool is FAIL, whatever its exit code; only "nothing to check" is N/A.
cat > .github/workflows/bad.yml <<'EOF'
on: push
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - run: echo "${{ github.nope( }}"
EOF
expect fail "actionlint findings (exit 1)" 'actions +FAIL' actions
reset_tree
printf 'self-hosted-runner:\n  labels: [unclosed\n' > .github/actionlint.yaml
expect fail "actionlint fatal error (exit 3) is not N/A" 'actions +FAIL' actions
reset_tree
mkdir -p "$TMP/bin" && printf '#!/bin/bash\nexit 2\n' > "$TMP/bin/actionlint" && chmod +x "$TMP/bin/actionlint"
GATE_ENV=("PATH=$TMP/bin:$PATH")
expect fail "actionlint usage error (exit 2)" 'actions +FAIL' actions
GATE_ENV=()
git rm -q -r .github
expect pass "no workflows is N/A" 'actions +N/A' actions
reset_tree

# Names with spaces or non-ASCII characters reach the checkers (git would C-quote or word-split them).
printf '# Note\n\n[x](missing.md)\n' > "docs/notes/验证.md"
expect fail "non-ASCII-named Markdown file is checked" 'broken link' docs
reset_tree
printf '# Note\n\n[x](missing.md)\n' > "docs/notes/a note.md"
expect fail "space-named Markdown file is checked" 'broken link' docs
reset_tree
rm docs/notes/ok.md README.md
expect pass "tracked Markdown files deleted from the tree are skipped" 'docs +PASS' docs
reset_tree
rm scripts/lib/test-land.sh
expect pass "tracked shell scripts deleted from the tree are skipped" 'shell +PASS' shell
reset_tree
printf '#!/bin/bash\nif then\n' > "scripts/坏.sh"
expect fail "non-ASCII-named script is checked" 'syntax error' shell
reset_tree
printf '#!/bin/bash\nif then\n' > "scripts/bad name.sh"
expect fail "space-named script is checked" 'syntax error' shell
reset_tree

# bash 3.2: bash -n and shellcheck accept bash 4+ syntax; the static lint must not.
cat > scripts/assoc.sh <<'EOF'
#!/bin/bash
declare -A seen=()
echo "${#seen[@]}"
EOF
expect fail "bash 4+ construct" 'is bash 4\+' shell
sed -i.bak 's/^declare -A seen=()$/declare -A seen=()  # bash32-ok: never runs on macOS/' scripts/assoc.sh && rm -f scripts/assoc.sh.bak
expect pass "# bash32-ok exempts the line" '' shell
reset_tree
# check_bash32.py's own table sits in the file it tests, so an older copy of that file passes it. These rows
# reach the real lint through the gate: another program's flags and bash 3.2-safe fallbacks pass; a construct
# that only fails at run time, and one that follows a quote inside a double-quoted ${...}, do not.
cat > scripts/release-wait.sh <<'EOF'
#!/bin/bash
swift test -v --filter ParlanceCoreTests
xcrun notarytool wait -p parlance-notary "$1"
now=${EPOCHSECONDS:-$(date +%s)}
shopt -s globstar 2>/dev/null || true
echo "$now"
EOF
expect pass "another program's -v and wait flags, bash 3.2-safe fallbacks" 'shell +PASS' shell
reset_tree
printf '#!/bin/bash\nsleep 1 &\nwait -n\n' > scripts/waiter.sh
expect fail "runtime-only bash 4+ construct (wait -n)" 'waiter\.sh:3: wait with an option .* is bash 4\+' shell
reset_tree
cat > scripts/strip.sh <<'EOF'
#!/bin/bash
x='"hello"'
y="${x#'"'}"
y="${y%'"'}"
declare -A seen
seen[$y]=1
echo "${#seen[@]}"
EOF
expect fail "bash 4+ construct after quotes inside a double-quoted \${...}" 'strip\.sh:5: declare -A is bash 4\+' shell
reset_tree

# The caller's SHELLCHECK_OPTS must not weaken shellcheck, here or inside actionlint (both would report SC2086).
GATE_ENV=("SHELLCHECK_OPTS=--severity=error")
cat > scripts/sc.sh <<'EOF'
#!/bin/bash
rm -f $1
EOF
expect fail "SHELLCHECK_OPTS cannot weaken shellcheck" 'shell +FAIL' shell
reset_tree
cat > .github/workflows/sc.yml <<'EOF'
on: push
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - run: rm -f $f
EOF
expect fail "SHELLCHECK_OPTS cannot weaken actionlint" 'actions +FAIL' actions
GATE_ENV=()
reset_tree

# gitleaks reads .gitleaks.toml for untracked files too (a user GITLEAKS_CONFIG must not replace it). The
# sample is assembled at run time, so this file holds nothing secret-shaped.
fake="ghp_$(printf %s Qm7xT2 kP9wZ4 rB6nY1 vH3cL8 jD5sF0 gA2eU7)"
mkdir -p Tests/CoreTests/Fixtures/redaction
printf 'sample=%s\n' "$fake" > Tests/CoreTests/Fixtures/redaction/samples.txt
GATE_ENV=("GITLEAKS_CONFIG=$TMP/absent.toml")
expect pass "untracked Redactor fixture is allowlisted" '' secrets
GATE_ENV=()
reset_tree
mkdir -p Sources/X
printf 'sample=%s\n' "$fake" > "Sources/X/样例 key.txt"
expect fail "untracked secret with a non-ASCII, space-containing name" 'secrets +FAIL' secrets
reset_tree
# A stash is local work in progress that no push sends; the full-history scan (`--all`) would read it.
printf 'token: %s\n' "$fake" >> README.md
git stash -q
expect pass "a stashed secret-shaped edit is not scanned" 'secrets +PASS' --base HEAD secrets
git stash drop -q

# Under a hook, GIT_DIR/GIT_INDEX_FILE point at the repository; the harness self-tests must not inherit them.
GATE_ENV=("GIT_DIR=$REPO/.git" "GIT_INDEX_FILE=$REPO/.git/index")
expect pass "harness checks run without a hook's git variables" 'harness +PASS' harness
GATE_ENV=()

# Every harness check is required: a missing one fails the component, also in the pre-commit subset when a
# rename takes it out of the watched paths (git lists a rename under its new path only, unless told otherwise).
for f in "${CHECKS[@]}"; do
  rm "$f"
  expect fail "harness check $f is required" "harness check missing: $f" harness
  reset_tree
done
mkdir -p attic && git mv scripts/lib/test-land.sh attic/test-land.sh
expect fail "--staged sees a harness file renamed out of a watched path" 'harness check missing: scripts/lib/test-land.sh' --staged
reset_tree

# A full run on a clean tree stamps HEAD; HEAD moving while the gate runs (a commit, or a switch to another
# branch and back, which `git status` cannot show) fails the run, unstamped.
expect pass "full run on a clean tree" 'stamp written'
stamped || { failures=$((failures + 1)); echo "test-gate: FAIL full run on a clean tree: no stamp file"; }
harness_stub() {  # harness_stub <command>: make a stand-in harness check run it, committed
  printf '#!/bin/bash\n%s\n' "$1" > scripts/lib/test-land.sh
  git commit -q -am "stand-in harness check: $1"
}
harness_stub 'git commit -q --allow-empty -m moved'
start=$(git rev-parse HEAD)
expect fail "a commit made while the gate runs" 'head-moved-during-gate'
! stamped "$start" || { failures=$((failures + 1)); echo "test-gate: FAIL a commit made while the gate runs: stamp written"; }
harness_stub 'git checkout -q -b elsewhere && git checkout -q -'
start=$(git rev-parse HEAD)
expect fail "a switch to another branch and back while the gate runs" 'head-moved-during-gate'
! stamped "$start" || { failures=$((failures + 1)); echo "test-gate: FAIL a switch to another branch and back: stamp written"; }
# The same in a reftable checkout, which has no logs/HEAD file to count. git before 2.45 cannot create one.
if git clone -q --ref-format=reftable . "$TMP/reftable" 2>/dev/null; then
  cd "$TMP/reftable" || exit 1
  expect fail "a switch to another branch and back in a reftable checkout" 'head-moved-during-gate'
  ! stamped || { failures=$((failures + 1)); echo "test-gate: FAIL a switch and back in a reftable checkout: stamp written"; }
  cd "$REPO" || exit 1
else
  echo "test-gate: skipped the reftable case (this git cannot create a reftable repository)"
fi
harness_stub 'exit 0'

# A component that writes into the tree fails the run, unstamped.
printf '#!/usr/bin/env python3\nopen("stray.txt", "w").write("x")\n' > scripts/lib/check_docs.py
git commit -q -am "check_docs writes into the tree"
expect fail "a component that changes the tree" 'tree-modified-by-gate'
! stamped || { failures=$((failures + 1)); echo "test-gate: FAIL a component that changes the tree: stamp written"; }
rm -f stray.txt
expect fail "--require-clean run that changes the tree" 'tree-modified-by-gate' --require-clean docs
rm -f stray.txt

# Secrets in history (last: these commits stay; the cases match gitleaks' own "leaks found" line, so a scan
# that merely errors does not count as a find). `git log -p` prints no patch for a merge commit by default, so
# a token that only the conflict resolution added must still be found, in a range and in the full history.
fork=$(git rev-parse HEAD)
printf 'status: draft\n' > docs/notes/probe.md && git add docs/notes/probe.md && git commit -q -m "probe note"
git checkout -q -b side
printf 'status: side\n' > docs/notes/probe.md && git commit -q -am "side edit"
git checkout -q main
printf 'status: main\n' > docs/notes/probe.md && git commit -q -am "main edit"
git merge -q side >/dev/null 2>&1  # conflicts
printf 'status: merged\ntoken: %s\n' "$fake" > docs/notes/probe.md
git commit -q -am "merge side (the resolution adds a token)"
expect fail "secret only in a merge resolution (range)" 'leaks found: [1-9]' --base "$fork" secrets
expect fail "secret only in a merge resolution (full history)" 'leaks found: [1-9]' --base HEAD secrets

# gitleaks reads git's patches: colour forced on by the caller's configuration or environment, or a diff
# attribute, must not leave it with nothing to read. Each range holds one ordinary commit that adds a token.
base=$(git rev-parse HEAD)
printf 'sample=%s\n' "$fake" > leak.txt && git add leak.txt && git commit -q -m "add a token"
for setting in color.diff color.ui; do
  git config --file "$TMP/colour.gitconfig" "$setting" always
  GATE_ENV=("GIT_CONFIG_GLOBAL=$TMP/colour.gitconfig")
  expect fail "committed secret under $setting=always" 'leaks found: [1-9]' --base "$base" secrets
  rm -f "$TMP/colour.gitconfig"
done
GATE_ENV=("GIT_CONFIG_PARAMETERS='color.diff=always'")
expect fail "committed secret under git -c color.diff=always" 'leaks found: [1-9]' --base "$base" secrets
GATE_ENV=("GIT_CONFIG_COUNT=1" "GIT_CONFIG_KEY_0=color.diff" "GIT_CONFIG_VALUE_0=always")
expect fail "committed secret under GIT_CONFIG_COUNT color.diff=always" 'leaks found: [1-9]' --base "$base" secrets
printf '*.txt -diff\n' > "$TMP/attributes" && git config --file "$TMP/colour.gitconfig" core.attributesFile "$TMP/attributes"
GATE_ENV=("GIT_CONFIG_GLOBAL=$TMP/colour.gitconfig")
expect fail "committed secret under the user's attributes file (-diff)" 'leaks found: [1-9]' --base "$base" secrets
GATE_ENV=("GIT_CONFIG_GLOBAL=$TMP/colour.gitconfig" "GIT_CONFIG_PARAMETERS='color.diff=always'")
printf 'staged=%s\n' "$fake" > staged.txt && git add staged.txt
expect fail "staged secret under colour and attributes settings" 'leaks found: [1-9]' --staged
GATE_ENV=()
reset_tree
base=$(git rev-parse HEAD)
printf '*.txt binary\n' > .gitattributes
printf 'sample=%s\n' "$fake" > leak2.txt && git add .gitattributes leak2.txt && git commit -q -m "add a token in a file marked binary"
expect fail "committed secret in a file .gitattributes marks binary" 'leaks found: [1-9]' --base "$base" secrets

# gitleaks exits 0 when its own git call fails; the error only shows in its log. A warning from git shows there
# as an error as well (here: CRLF conversion under core.autocrlf), but the scan is complete.
base=$(git rev-parse HEAD)
git config core.autocrlf input
printf 'one\r\ntwo\r\n' > notes.cfg && git add notes.cfg 2>/dev/null && git commit -q -m "a CRLF file"
printf 'one\r\ntwo\r\nthree\r\n' > notes.cfg
expect pass "git warns about CRLF while gitleaks scans" 'secrets +PASS' --base "$base" secrets
grep -Eq 'ERR.*warning: .*CRLF will be replaced by LF' build/gate/secrets.log \
  || { failures=$((failures + 1)); echo "test-gate: FAIL git warns about CRLF while gitleaks scans: no such warning in the log, the case tested nothing"; }
git config --unset core.autocrlf
reset_tree
mkdir -p "$TMP/glbin"
cat > "$TMP/glbin/gitleaks" <<'EOF'
#!/bin/bash
printf '\033[90m10:00PM\033[0m \033[31mERR\033[0m [git] fatal: bad revision\n' >&2
EOF
chmod +x "$TMP/glbin/gitleaks"
GATE_ENV=("PATH=$TMP/glbin:$PATH")
expect fail "gitleaks logs an error but exits 0" 'gitleaks logged an error' secrets
GATE_ENV=()

if [ "$failures" -gt 0 ]; then
  echo "test-gate: $failures problem(s) in $cases case(s)"
  exit 1
fi
echo "test-gate: ok ($cases cases)"
