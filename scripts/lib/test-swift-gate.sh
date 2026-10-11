#!/bin/bash
# scripts/lib/test-swift-gate.sh — counterexample table for the swift component of scripts/gate, which this
# repository cannot exercise until Package.swift exists (issue #2). Copies the gate into a throwaway package
# (with a local git package as a versioned dependency, so it runs offline) and checks that it passes on a
# clean package and fails on each fail-open trap: zero executed tests (none, only `.disabled`, only a
# switched-off `.enabled(if:)`, only tests that cancel themselves with `Test.cancel`, also when the skip or
# cancel comment spans lines), a gitignored source file inside the package or behind a symlink in it (built
# here, absent from the commit), a symlink in the package that leads outside the repository, a --strict format
# violation, AppKit in ParlanceCore (directly, under a custom `path:`, through a symlinked directory, through a
# symlink to a directory the manifest excludes, re-exported by a target it depends on, or included under a
# quoted header name or from C++ sources and headers by a C-family target it depends on), a local C-family
# target whose excluded, unselected or resource files include a framework header, whose includes leave the
# target directory or come from a macro, hide behind splices, comments, trigraphs or a BOM, import a module
# through a pragma, or that holds a module map, a manifest without a
# ParlanceCore target, a dependency missing from the license allowlist, approved for another origin or under a
# mixed-case key, a stale allowlist entry, a Package.resolved that is untracked, absent or stale, a path
# dependency (never pinned), external product imports and unreadable closures, and a missing .swift-format. Layouts that keep an AppKit file out of ParlanceCore
# through the manifest (`exclude:`, or a shared `path:` with disjoint `sources:`) pass, and so does a package
# that holds an ignored .DS_Store or per-machine agent override file outside its resources: directories (one
# inside them, or behind a symlink there, fails: SwiftPM copies it into the bundle).
# Also checks `scripts/gate --staged` once Package.swift exists: a docs-only change passes, a badly formatted
# staged Swift file fails.
# Slow (many swift builds), so it is not part of `scripts/gate`; run it after changing the swift component.
# Exit 0 when every case behaves as expected.

set -u
# shellcheck disable=SC2046  # the variable names are single words
unset $(git rev-parse --local-env-vars)
ROOT=$(git rev-parse --show-toplevel) || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pl-swiftgate.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name tester
git config --file "$GIT_CONFIG_GLOBAL" user.email tester@example.com
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

DEP="$TMP/dep"  # tagged clean versions and an AppKit-importing 1.2.0
mkdir -p "$DEP/Sources/Dep"
cat > "$DEP/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Dep",
  products: [.library(name: "Dep", targets: ["Dep"])],
  targets: [.target(name: "Dep")]
)
EOF
printf 'public let depVersion = 1\n' > "$DEP/Sources/Dep/Dep.swift"
printf 'Sources/Dep/Generated.swift\n' > "$DEP/.gitignore"
(cd "$DEP" && git init -q && git add -A && git commit -q -m v1 && git tag 1.0.0 \
  && printf 'public let depVersion = 2\n' > Sources/Dep/Dep.swift && git commit -q -am v2 && git tag 1.1.0 \
  && printf '@_exported import AppKit\n\npublic let depVersion = 3\n' > Sources/Dep/Dep.swift \
  && git commit -q -am v3 && git tag 1.2.0) || exit 1

# Commit links into versioned dependencies so checkout cleanliness cannot reject these escapes for us.
mkdir -p "$TMP/escape-sources"
printf 'public let linkedValue = 1\n' > "$TMP/escape-sources/Linked.swift"
(
  cd "$DEP" || exit 1
  printf 'public let depVersion = 4\n' > Sources/Dep/Dep.swift
  mkdir PinnedSources
  printf 'public let linkedValue = 1\n' > PinnedSources/Linked.swift
  ln -s "$TMP/escape-sources" Sources/Dep/Linked
  git add -A && git commit -q -m absolute-link && git tag 1.3.0 || exit 1
  rm Sources/Dep/Linked
  # Relative to pkg/.build/checkouts/dep/Sources/Dep, where SwiftPM compiles this link.
  ln -s ../../../../../../escape-sources Sources/Dep/Linked
  git add -A && git commit -q -m relative-link && git tag 1.4.0 || exit 1
  rm Sources/Dep/Linked
  ln -s ../../PinnedSources Sources/Dep/Linked
  git add -A && git commit -q -m internal-link && git tag 1.5.0 || exit 1
) || exit 1

PKG="$TMP/pkg"
mkdir -p "$PKG/scripts/lib" "$PKG/Sources/ParlanceCore" "$PKG/Tests/ParlanceCoreTests"
cp "$ROOT/scripts/gate" "$PKG/scripts/gate"
cp "$ROOT"/scripts/lib/*.py "$ROOT"/scripts/lib/*.sh "$PKG/scripts/lib/"
cp "$ROOT/.gitleaks.toml" "$ROOT/.shellcheckrc" "$PKG/"
printf '.DS_Store\n.build/\n.swiftpm/\nbuild/\nCLAUDE.local.md\nAGENTS.override.md\n' > "$PKG/.gitignore"
cat > "$PKG/Package.swift" <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Probe",
  platforms: [.macOS(.v14)],
  products: [.library(name: "ParlanceCore", targets: ["ParlanceCore"])],
  targets: [
    .target(name: "ParlanceCore"),
    .testTarget(name: "ParlanceCoreTests", dependencies: ["ParlanceCore"]),
  ]
)
EOF
printf '{\n  "version": 1\n}\n' > "$PKG/.swift-format"
cat > "$PKG/Sources/ParlanceCore/Core.swift" <<'EOF'
public func answer() -> Int {
  42
}
EOF
cat > "$PKG/Tests/ParlanceCoreTests/CoreTests.swift" <<'EOF'
import Testing

@testable import ParlanceCore

@Test func answerIsStable() {
  #expect(answer() == 42)
}
EOF
cd "$PKG" || exit 1
git init -q && git add -A && git commit -q -m init

failures=0
cases=0
expect() {  # expect <pass|fail> <name> <ERE the output or a component log must match, or ''> [gate args; default swift]
  local want=$1 name=$2 rx=$3 got
  shift 3
  [ $# -gt 0 ] || set -- swift
  cases=$((cases + 1))
  rm -rf build/gate
  if bash scripts/gate "$@" >"$TMP/out.log" 2>&1; then got=pass; else got=fail; fi
  if [ "$got" != "$want" ] || { [ -n "$rx" ] && ! cat "$TMP/out.log" build/gate/*.log 2>/dev/null | grep -Eq "$rx"; }; then
    failures=$((failures + 1))
    echo "test-swift-gate: FAIL $name: expected $want${rx:+ matching /$rx/}, got $got"
    grep -v "^    *[◇↳✔]" "$TMP/out.log" | tail -n 25 | sed 's/^/    /'
  fi
}
refute() {  # refute <name> <ERE the last run's output and component logs must not match>
  if cat "$TMP/out.log" build/gate/*.log 2>/dev/null | grep -Eq "$2"; then
    failures=$((failures + 1))
    echo "test-swift-gate: FAIL $1: output matches /$2/"
  fi
}
also() {  # also <name> <ERE the last run's output and component logs must match as well>
  cases=$((cases + 1))
  if ! cat "$TMP/out.log" build/gate/*.log 2>/dev/null | grep -Eq "$2"; then
    failures=$((failures + 1))
    echo "test-swift-gate: FAIL $1: output lacks /$2/"
  fi
}
reset_tree() { git reset -q && git checkout -q -- . && git clean -qfd; }
core_imports_appkit() {  # core_imports_appkit <dir>
  printf 'import AppKit\n\npublic func answer() -> Int {\n  42\n}\n' > "$1/Core.swift"
}

expect pass "clean package" 'tests=1 skipped=0'

cat > Tests/ParlanceCoreTests/CoreTests.swift <<'EOF'
import Testing
EOF
expect fail "zero tests" 'zero tests executed'
cat > Tests/ParlanceCoreTests/CoreTests.swift <<'EOF'
import Testing

@testable import ParlanceCore

@Test(.disabled("flaky")) func answerIsStable() {
  #expect(answer() == 42)
}
EOF
expect fail "only .disabled tests" 'zero tests executed'
cat > Tests/ParlanceCoreTests/CoreTests.swift <<'EOF'
import Foundation
import Testing

@testable import ParlanceCore

@Test(.enabled(if: ProcessInfo.processInfo.environment["PARLANCE_LIVE_TESTS"] == "1"))
func answerIsStableLive() {
  #expect(answer() == 42)
}
EOF
expect fail "only .enabled(if:) tests, switched off" 'zero tests executed'
cat > Tests/ParlanceCoreTests/CoreTests.swift <<'EOF'
import Foundation
import Testing

@testable import ParlanceCore

@Test func answerIsStableLive() throws {
  guard ProcessInfo.processInfo.environment["PARLANCE_LIVE_TESTS"] == "1" else {
    try Test.cancel("live tests are off")
  }
  #expect(answer() == 42)
}
EOF
expect fail "only runtime-cancelled tests (Test.cancel)" 'zero tests executed'
cat > Tests/ParlanceCoreTests/CoreTests.swift <<'EOF'
import Testing

@testable import ParlanceCore

@Test(.disabled("not on this machine:\nno provider key")) func answerIsStable() {
  #expect(answer() == 42)
}

@Test func answerIsStableLive() throws {
  try Test.cancel("live tests are off:\nset PARLANCE_LIVE_TESTS=1")
}
EOF
expect fail "a skip and a cancel whose comments span lines" 'zero tests executed'
reset_tree

# SwiftPM builds a gitignored file that sits in a target directory, wherever the manifest puts that directory;
# the commit does not contain it. The explicit rm lines are needed: reset_tree's `git clean -fd` keeps ignored
# files.
ignored_helper() {  # ignored_helper <target dir>: a source file under an ignored build/ directory
  mkdir -p "$1/build" && printf 'func helper() -> Int {\n  0\n}\n' > "$1/build/Helper.swift"
}
ignored_helper Sources/ParlanceCore
expect fail "gitignored source inside Sources/" 'Sources/ParlanceCore/build/Helper\.swift +\(ignored by \.gitignore:[0-9]+: build/\)'
rm -rf Sources/ParlanceCore/build
touch Sources/ParlanceCore/.DS_Store Tests/CLAUDE.local.md
mkdir -p Sources/ParlanceCore/Notes
printf 'Local notes:\n\nExample:\n#include <AppKit/AppKit.h>\n' > Sources/ParlanceCore/Notes/AGENTS.override.md
ln -s Notes Sources/ParlanceCore/Alias  # the override is also reached through a symlinked directory
expect pass "an ignored .DS_Store or per-machine agent override is not a source" 'tests=1 skipped=0'
git add -f Sources/ParlanceCore/Notes/AGENTS.override.md
expect fail "a tracked file under a per-machine name is scanned like any other" 'Notes/AGENTS\.override\.md:4: ParlanceCore must not import AppKit'
git rm -q --cached Sources/ParlanceCore/Notes/AGENTS.override.md
# A tracked link whose target is an ignored per-machine file is a source to SwiftPM: it is read through the link.
ln -s Notes/AGENTS.override.md Sources/ParlanceCore/Bridge.inc
git add Sources/ParlanceCore/Bridge.inc
expect fail "a tracked link to an ignored per-machine file is scanned" 'Bridge\.inc:4: ParlanceCore must not import AppKit'
git rm -q --cached Sources/ParlanceCore/Bridge.inc
# A tracked file that includes the ignored per-machine file makes it a preprocessing input no commit holds.
rm Sources/ParlanceCore/Bridge.inc
printf '#include "Notes/AGENTS.override.md"\n' > Sources/ParlanceCore/Bridge.inc
git add Sources/ParlanceCore/Bridge.inc
expect fail "an include naming an ignored per-machine file fails instead of being skipped" 'Bridge\.inc:1: ParlanceCore includes "Notes/AGENTS\.override\.md", a per-machine file name'
# The default volume opens the file in any letter case, and clang's lookup stops at a NUL inside the name.
printf '#include <Notes/agents.OVERRIDE.md>\n#import "Notes/AGENTS.override.md\0zz"\n' > Sources/ParlanceCore/Bridge.inc
expect fail "a miscased include of a per-machine file fails too" 'Bridge\.inc:1: ParlanceCore includes <Notes/agents\.OVERRIDE\.md>, a per-machine file name'
expect fail "a NUL-cut include of a per-machine file fails too" 'Bridge\.inc:2: ParlanceCore includes "Notes/AGENTS\.override\.md", a per-machine file name'
# The volume's case folding is Unicode full folding: a long s (U+017F) or an st ligature (U+FB06) opens the file.
printf '#include "Notes/AGENT\xc5\xbf.override.md"\n#import <Notes/.DS_\xef\xac\x86ore>\n' > Sources/ParlanceCore/Bridge.inc
expect fail "a case-folded Unicode spelling of a per-machine file fails too" 'Bridge\.inc:1: ParlanceCore includes "Notes/AGENTſ\.override\.md", a per-machine file name'
expect fail "an st ligature spelling of .DS_Store fails too" 'Bridge\.inc:2: ParlanceCore includes <Notes/\.DS_ﬆore>, a per-machine file name'
git rm -q --cached Sources/ParlanceCore/Bridge.inc
rm -rf Sources/ParlanceCore/.DS_Store Sources/ParlanceCore/Notes Sources/ParlanceCore/Alias Sources/ParlanceCore/Bridge.inc Tests/CLAUDE.local.md
reset_tree
# SwiftPM copies or processes a `resources:` entry from disk into the product bundle, so a per-machine file there
# may ship; the same names elsewhere in the target stay exempt.
resources_target() {  # resources_target <resources: list>: the committed manifest with this list on ParlanceCore
  git checkout -q -- Package.swift && sed -i.bak "s|\.target(name: \"ParlanceCore\"),|.target(name: \"ParlanceCore\", resources: $1),|" Package.swift && rm -f Package.swift.bak
}
mkdir -p Sources/ParlanceCore/Notes Sources/ParlanceCore/Assets
printf 'notes\n' > Sources/ParlanceCore/Notes/About.txt
printf 'assets\n' > Sources/ParlanceCore/Assets/About.txt
resources_target '[.copy("Notes"), .process("Assets")]'
touch Sources/ParlanceCore/AGENTS.override.md Sources/ParlanceCore/.DS_Store
expect pass "a per-machine file outside resources: stays exempt" 'tests=1 skipped=0'
touch Sources/ParlanceCore/Notes/.DS_Store Sources/ParlanceCore/Assets/AGENTS.override.md
expect fail "a per-machine file in a .copy resource directory" 'Sources/ParlanceCore/Notes/\.DS_Store +\(ignored by \.gitignore:[0-9]+: \.DS_Store\)'
expect fail "a per-machine file in a .process resource directory" 'Sources/ParlanceCore/Assets/AGENTS\.override\.md +\(ignored by \.gitignore:[0-9]+: AGENTS\.override\.md\)'
refute "per-machine files outside resources: are not listed" 'Sources/ParlanceCore/(AGENTS\.override\.md|\.DS_Store) '
rm -f Sources/ParlanceCore/Notes/.DS_Store Sources/ParlanceCore/Assets/AGENTS.override.md
mkdir -p Shared && touch Shared/AGENTS.override.md
ln -s ../../../Shared Sources/ParlanceCore/Notes/Shared  # SwiftPM copies the linked directory into the bundle
expect fail "a per-machine file a resource directory reaches through a symlink" 'Shared/AGENTS\.override\.md +\(ignored by'
rm -rf Shared Sources/ParlanceCore/Notes/Shared Sources/ParlanceCore/.DS_Store
ln -s ../AGENTS.override.md Sources/ParlanceCore/Notes/Readme.md  # SwiftPM copies the override's content as Readme.md
expect fail "a per-machine file a link in a resource directory names" 'Sources/ParlanceCore/AGENTS\.override\.md +\(ignored by'
rm -f Sources/ParlanceCore/Notes/Readme.md Sources/ParlanceCore/AGENTS.override.md
if [ Sources/ParlanceCore/notes -ef Sources/ParlanceCore/Notes ]; then  # a case-insensitive volume: SwiftPM copies Notes
  resources_target '[.copy("notes")]'
  touch Sources/ParlanceCore/Notes/AGENTS.override.md
  expect fail "a per-machine file in a resource directory spelled in another case" 'Sources/ParlanceCore/Notes/AGENTS\.override\.md +\(ignored by'
  rm -f Sources/ParlanceCore/Notes/AGENTS.override.md
fi
mkdir -p Shared && printf 'shared\n' > Shared/notes.txt
ln -s ../../Shared/notes.txt Sources/ParlanceCore/AGENTS.override.md
resources_target '[.copy("AGENTS.override.md")]'  # the ignored link is the resource itself
expect fail "a per-machine link named as a single-file resource" 'Sources/ParlanceCore/AGENTS\.override\.md +\(ignored by'
rm -rf Shared Sources/ParlanceCore/AGENTS.override.md
mkdir -p Shared && printf 'shared\n' > Shared/notes.txt && touch Shared/.DS_Store
resources_target '[.copy("../../Shared")]'  # a resource outside the target directory is copied too
expect fail "a per-machine file in a resource directory outside the target" 'Shared/\.DS_Store +\(ignored by'
rm -rf Shared
mkdir -p Shared Assets && printf 'readme\n' > Assets/readme.txt && ln -s ../Assets/readme.txt Shared/AGENTS.override.md
resources_target '[.copy("../../Shared/AGENTS.override.md")]'  # git lists the ignored link, not what it names
expect fail "a per-machine link outside the target named as a resource" 'Shared/AGENTS\.override\.md +\(ignored by'
rm -rf Shared Assets
mkdir -p Shared
if [ Shared -ef shared ]; then
  touch Shared/.DS_Store
  resources_target '[.copy("../../shared")]'  # git matches pathspecs by case, the volume does not
  expect fail "a per-machine file in an outside-target resource spelled in another case" 'Shared/\.DS_Store +\(ignored by'
fi
rm -rf Shared
upper=$'\xc3\x9cber' lower=$'\xc3\xbcber'  # Über, über: git's icase folds ASCII only
mkdir -p "$upper"
if [ "$upper" -ef "$lower" ]; then
  touch "$upper/.DS_Store"
  resources_target "[.copy(\"../../$lower\")]"
  expect fail "an outside-target resource spelled with another non-ASCII letter case" '\.DS_Store +\(ignored by'
fi
rm -rf "$upper"
mkdir -p Shared && touch Shared/.DS_Store
resources_target '[.copy("../../Shared")]'
GIT_LITERAL_PATHSPECS=1 expect fail "GIT_LITERAL_PATHSPECS does not hide ignored files" 'Shared/\.DS_Store +\(ignored by'
rm -rf Shared
mkdir -p "$TMP/outside-resources" && printf 'x\n' > "$TMP/outside-resources/x.txt"
resources_target '[.copy("../../../outside-resources")]'  # $TMP/outside-resources, beside the package
expect fail "a resource entry outside the repository" 'outside-resources leads outside the repository'
reset_tree
# SwiftPM follows a symlink, git lists only the link: what the link points at must not be gitignored either,
# and has to lie inside the repository.
mkdir -p build/gen && printf 'func helper() -> Int {\n  0\n}\n' > build/gen/Helper.swift
ln -s ../../build/gen Sources/ParlanceCore/Generated
expect fail "gitignored source behind a symlink in Sources/" 'build/gen/Helper\.swift +\(ignored by \.gitignore:[0-9]+: build/\)'
rm -rf build/gen Sources/ParlanceCore/Generated
mkdir -p "$TMP/outside" && printf 'func helper() -> Int {\n  0\n}\n' > "$TMP/outside/Helper.swift"
ln -s "$TMP/outside" Sources/ParlanceCore/Outside
expect fail "symlink in Sources/ that leads outside the repository" 'Sources/ParlanceCore/Outside leads outside the repository'
rm -f Sources/ParlanceCore/Outside
reset_tree
mv Sources/ParlanceCore Core
ignored_helper Core
sed -i.bak 's|\.target(name: "ParlanceCore"),|.target(name: "ParlanceCore", path: "Core"),|' Package.swift && rm -f Package.swift.bak
expect fail "gitignored source in a target directory outside Sources/" 'gitignored files inside the package'
rm -rf Core/build
reset_tree

printf 'public func answer() -> Int {\n        42\n}\n' > Sources/ParlanceCore/Core.swift
expect fail "format violation" 'Core\.swift:[0-9]+:[0-9]+: (warning|error)'
reset_tree

core_imports_appkit Sources/ParlanceCore
expect fail "AppKit import in ParlanceCore" 'ParlanceCore must not import AppKit'
reset_tree

mv Sources/ParlanceCore Sources/Core
core_imports_appkit Sources/Core
sed -i.bak 's|\.target(name: "ParlanceCore"),|.target(name: "ParlanceCore", path: "Sources/Core"),|' Package.swift && rm -f Package.swift.bak
expect fail "AppKit import under a custom path:" 'Sources/Core/Core\.swift:1: ParlanceCore must not import AppKit'
reset_tree

# The manifest decides which files a target compiles: an AppKit file it keeps out of ParlanceCore is fine, one
# that SwiftPM reaches through a symlinked directory is not.
mkdir -p Sources/ParlanceCore/MacOnly
printf 'import AppKit\n\npublic func beep() {\n  NSSound.beep()\n}\n' > Sources/ParlanceCore/MacOnly/AppBridge.swift
sed -i.bak 's|\.target(name: "ParlanceCore"),|.target(name: "ParlanceCore", exclude: ["MacOnly/AppBridge.swift"]),|' Package.swift && rm -f Package.swift.bak
expect pass "AppKit only in a file ParlanceCore excludes" 'check_swift_invariants: ok'
reset_tree
mv Sources/ParlanceCore Sources/Shared
printf 'import AppKit\n\nNSSound.beep()\n' > Sources/Shared/main.swift
cat > Package.swift <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Probe",
  platforms: [.macOS(.v14)],
  products: [.library(name: "ParlanceCore", targets: ["ParlanceCore"])],
  targets: [
    .target(name: "ParlanceCore", path: "Sources/Shared", sources: ["Core.swift"]),
    .executableTarget(name: "probe-app", path: "Sources/Shared", sources: ["main.swift"]),
    .testTarget(name: "ParlanceCoreTests", dependencies: ["ParlanceCore"]),
  ]
)
EOF
expect pass "AppKit only in another target sharing the path: (disjoint sources:)" 'check_swift_invariants: ok'
reset_tree
mkdir -p Vendor/Bits
printf 'import AppKit\n\npublic func bits() -> Int {\n  1\n}\n' > Vendor/Bits/Bits.swift
ln -s ../../Vendor/Bits Sources/ParlanceCore/Bits
expect fail "AppKit in a symlinked directory under Sources/ParlanceCore" 'Bits\.swift:1: ParlanceCore must not import AppKit'
reset_tree
mkdir -p Sources/ParlanceCore/Impl
printf 'import AppKit\n\npublic func beep() {\n  NSSound.beep()\n}\n' > Sources/ParlanceCore/Impl/AppBridge.swift
ln -s Impl Sources/ParlanceCore/Linked  # SwiftPM skips Impl and compiles the same file as Linked/AppBridge.swift
sed -i.bak 's|\.target(name: "ParlanceCore"),|.target(name: "ParlanceCore", exclude: ["Impl"]),|' Package.swift && rm -f Package.swift.bak
expect fail "AppKit in an excluded directory that a symlink in the target also reaches" 'Linked/AppBridge\.swift:1: ParlanceCore must not import AppKit'
reset_tree

mkdir -p Sources/SystemBits
printf '@_exported import AppKit\n' > Sources/SystemBits/SystemBits.swift
cat > Package.swift <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Probe",
  platforms: [.macOS(.v14)],
  products: [.library(name: "ParlanceCore", targets: ["ParlanceCore"])],
  targets: [
    .target(name: "ParlanceCore", dependencies: ["SystemBits"]),
    .target(name: "SystemBits"),
    .testTarget(name: "ParlanceCoreTests", dependencies: ["ParlanceCore"]),
  ]
)
EOF
expect fail "dependency target re-exports AppKit" "must not import AppKit \(via its dependency 'SystemBits'\)"
reset_tree

# A C-family target in the closure: clang finds a framework header under a quoted name too, so the file below
# compiles and AppKit reaches the core; the quoted include of the target's own header is no finding. The same
# target's C++ source and header include framework headers as well.
mkdir -p Sources/CBits/include
printf 'int cbits(void);\n' > Sources/CBits/include/CBits.h
cat > Sources/CBits/Bits.m <<'EOF'
#include "CBits.h"
#include "AppKit/AppKit.h"

int cbits(void) {
  return (int)NSAppKitVersionNumber;
}
EOF
printf '#include <ApplicationServices/ApplicationServices.h>\n' > Sources/CBits/Extra.hpp
printf '#include "Extra.hpp"\n#include <Carbon/Carbon.h>\n\nextern "C" int cbits_extra(void) { return 0; }\n' > Sources/CBits/Extra.cxx
cat > Package.swift <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Probe",
  platforms: [.macOS(.v14)],
  products: [.library(name: "ParlanceCore", targets: ["ParlanceCore"])],
  targets: [
    .target(name: "ParlanceCore", dependencies: ["CBits"]),
    .target(name: "CBits"),
    .testTarget(name: "ParlanceCoreTests", dependencies: ["ParlanceCore"]),
  ]
)
EOF
expect fail "C-family dependency target includes a quoted AppKit header" "Bits\.m:2: ParlanceCore must not import AppKit \(via its dependency 'CBits'\)"
refute "C-family dependency target includes a quoted AppKit header" 'Bits\.m:1: '
also "C++ header of a dependency target includes a framework header" "Extra\.hpp:1: ParlanceCore must not import ApplicationServices \(via its dependency 'CBits'\)"
also "C++ source of a dependency target includes a framework header" "Extra\.cxx:2: ParlanceCore must not import Carbon \(via its dependency 'CBits'\)"
reset_tree

mv Sources/ParlanceCore Sources/Core
sed -i.bak 's/ParlanceCore/Core/' Tests/ParlanceCoreTests/CoreTests.swift && rm -f Tests/ParlanceCoreTests/CoreTests.swift.bak
cat > Package.swift <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Probe",
  platforms: [.macOS(.v14)],
  products: [.library(name: "Core", targets: ["Core"])],
  targets: [
    .target(name: "Core"),
    .testTarget(name: "ParlanceCoreTests", dependencies: ["Core"]),
  ]
)
EOF
expect fail "no ParlanceCore target" 'no target named ParlanceCore'
reset_tree

rm .swift-format
expect fail "missing .swift-format" '\.swift-format is missing|but \.swift-format'
reset_tree

# pre-commit (`scripts/gate --staged`) once Package.swift exists.
printf '# Probe\n' > README.md
git add README.md
expect pass "--staged docs-only change" 'swift +N/A' --staged
reset_tree
printf 'public func answer() -> Int {\n        42\n}\n' > Sources/ParlanceCore/Core.swift
git add Sources/ParlanceCore/Core.swift
expect fail "--staged badly formatted Swift file" 'swift +FAIL' --staged
reset_tree

# Dependencies. Context.packageDirectory keeps the manifest line short for swift-format.
dep_manifest() {  # dep_manifest <package dependency expression>
  cat > Package.swift <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Probe",
  platforms: [.macOS(.v14)],
  products: [.library(name: "ParlanceCore", targets: ["ParlanceCore"])],
  dependencies: [$1],
  targets: [
    .target(name: "ParlanceCore", dependencies: [.product(name: "Dep", package: "dep")]),
    .testTarget(name: "ParlanceCoreTests", dependencies: ["ParlanceCore"]),
  ]
)
EOF
}
dep_manifest '.package(url: "file://" + Context.packageDirectory + "/../dep", exact: "1.0.0")'
swift_args=(--no-color-diagnostics)
if [ -n "${CODEX_SANDBOX:-}" ] || [ "${PARLANCE_SWIFTPM_DISABLE_SANDBOX:-0}" = "1" ]; then
  swift_args+=(--disable-sandbox)
  export CLANG_MODULE_CACHE_PATH="$PKG/.build/ModuleCache"
fi
swift package "${swift_args[@]}" resolve >"$TMP/resolve.log" 2>&1 || { cat "$TMP/resolve.log"; echo "test-swift-gate: setup failed: swift package resolve"; exit 1; }
mkdir -p scripts
printf '{"dep": {"license": "MIT", "url": "file://%s", "reason": "test dependency"}}\n' "$DEP" > scripts/dependency-licenses.json
git add -A && git commit -q -m "add a dependency"

expect pass "dependency pinned and allowlisted" 'check_swift_invariants: ok'

# The clean pin imports AppKit; removing the import only in its checkout must still fail.
dep_manifest '.package(url: "file://" + Context.packageDirectory + "/../dep", exact: "1.2.0")'
swift package "${swift_args[@]}" resolve >"$TMP/resolve.log" 2>&1 || { cat "$TMP/resolve.log"; exit 1; }
expect fail "external product re-exports AppKit at the pin" "product 'Dep' \(package 'dep'\).*Dep.swift:1:.*AppKit"
chmod u+w .build/checkouts/dep/Sources/Dep/Dep.swift || exit 1
printf 'public let depVersion = 3\n' > .build/checkouts/dep/Sources/Dep/Dep.swift
expect fail "checkout locally removes pinned AppKit import" "checkout of package 'dep' \(product 'Dep'\).*local changes"
git -C .build/checkouts/dep checkout -q -- Sources/Dep/Dep.swift || exit 1
reset_tree
swift package "${swift_args[@]}" resolve >"$TMP/resolve.log" 2>&1 || { cat "$TMP/resolve.log"; exit 1; }

printf 'public let extra = 1\n' > .build/checkouts/dep/Sources/Dep/Extra.swift
expect fail "untracked checkout source" "checkout of package 'dep' \(product 'Dep'\).*local changes"
rm .build/checkouts/dep/Sources/Dep/Extra.swift
printf 'public let generated = 1\n' > .build/checkouts/dep/Sources/Dep/Generated.swift
expect fail "ignored checkout source" "checkout of package 'dep' \(product 'Dep'\).*local changes"
rm .build/checkouts/dep/Sources/Dep/Generated.swift
pinned_revision=$(git -C .build/checkouts/dep rev-parse HEAD) || exit 1
other_revision=$(git -C "$DEP" rev-parse 1.1.0) || exit 1
chmod -R u+w .build/checkouts/dep/.git || exit 1
git -C .build/checkouts/dep checkout -q "$other_revision" || exit 1
expect fail "checkout at another commit" "checkout of package 'dep' \(product 'Dep'\).*not at the pinned revision"
git -C .build/checkouts/dep checkout -q "$pinned_revision" || exit 1
expect pass "clean checkout restored to the pin" 'check_swift_invariants: ok'

for version in 1.3.0 1.4.0 1.5.0; do
  dep_manifest '.package(url: "file://" + Context.packageDirectory + "/../dep", exact: "'"$version"'")'
  swift package "${swift_args[@]}" resolve >"$TMP/resolve.log" 2>&1 || { cat "$TMP/resolve.log"; exit 1; }
  case "$version" in
    1.3.0) expect fail "pinned absolute directory symlink escapes checkout" "product 'Dep'.*package 'dep'.*target 'Dep'.*Linked.*outside" ;;
    1.4.0) expect fail "pinned relative directory symlink escapes checkout" "product 'Dep'.*package 'dep'.*target 'Dep'.*Linked.*outside" ;;
    1.5.0) expect pass "pinned directory symlink inside checkout" 'check_swift_invariants: ok' ;;
  esac
done
reset_tree
swift package "${swift_args[@]}" resolve >"$TMP/resolve.log" 2>&1 || { cat "$TMP/resolve.log"; exit 1; }

# Exercise both supported lockfile shapes and failures without asking SwiftPM to repair the fixture.
if ! python3 -B - "$ROOT/scripts/lib/check_swift_invariants.py" <<'PYCHECKOUT'
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("invariants", sys.argv[1])
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
lockfile = Path("Package.resolved")
original = lockfile.read_bytes()
resolved = json.loads(original)
print("test-swift-gate: pin shape: " + json.dumps({"version": resolved["version"], "pins": resolved["pins"]}))
checkout = ".build/checkouts/dep"
checks, failures = 0, []


def verify(label, message=None):
    global checks
    checks += 1
    try:
        checker.verify_checkout(checkout, "dep", "Dep")
        error = ""
    except ValueError as exc:
        error = str(exc)
    if (message is None and error) or (message is not None and (
            message not in error or "checkout of package 'dep' (product 'Dep')" not in error)):
        failures.append(label)
        print(f"test-swift-gate: FAIL {label}: expected {message!r}, got {error!r}")


try:
    for version in (2, 3):
        data = {"version": version, "pins": resolved["pins"]}
        lockfile.write_text(json.dumps(data))
        verify(f"clean checkout with lockfile v{version}")
    lockfile.write_text(json.dumps({"version": 3, "pins": []}))
    verify("missing pin", "no pinned revision")
    data["pins"][0]["state"].pop("revision")
    lockfile.write_text(json.dumps(data))
    verify("missing revision", "no pinned revision")
    lockfile.unlink()
    verify("missing lockfile", "No such file")
    lockfile.write_bytes(original)
    for command in ("rev-parse", "status"):
        real_run = subprocess.run

        def fail_git(args, **kwargs):
            if command in args:
                return subprocess.CompletedProcess(args, 1, "", "fixture git failure")
            return real_run(args, **kwargs)

        with patch.object(checker.subprocess, "run", side_effect=fail_git):
            verify(f"git {command} failure", f"git {command} failed")
finally:
    lockfile.write_bytes(original)

# Submodules are verified against their gitlinks at every depth, whatever a .gitmodules `ignore` says, and
# index flags that hide a change from git status fail.
here = os.getcwd()
with tempfile.TemporaryDirectory() as scratch:
    git = ["git", "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "protocol.file.allow=always"]

    def run(*args, cwd):
        subprocess.run(git + list(args), cwd=cwd, check=True, capture_output=True)

    def repo(name, files):
        path = Path(scratch, name)
        path.mkdir()
        run("init", "-q", cwd=path)
        for file, text in files.items():
            (path / file).write_text(text)
        return path

    def add_ignored_submodule(parent, source, name):
        run("submodule", "add", "-q", str(source), name, cwd=parent)
        run("config", "-f", ".gitmodules", f"submodule.{name}.ignore", "all", cwd=parent)
        run("add", ".", cwd=parent)
        run("commit", "-qm", name, cwd=parent)

    leaf = repo("leaf", {"Leaf.swift": "public let leaf = 1\n"})
    run("add", ".", cwd=leaf)
    run("commit", "-qm", "leaf", cwd=leaf)
    sub = repo("sub", {"Sub.swift": "public let sub = 1\n", ".gitignore": "Generated.swift\n"})
    run("add", ".", cwd=sub)
    run("commit", "-qm", "sub", cwd=sub)
    add_ignored_submodule(sub, leaf, "Leaf")
    top = repo("top", {"Top.swift": "public let top = 1\n"})
    run("add", ".", cwd=top)
    run("commit", "-qm", "top", cwd=top)
    add_ignored_submodule(top, sub, "Vendor")
    run("submodule", "update", "-q", "--init", "--recursive", cwd=top)
    head = subprocess.run(["git", "-C", str(top), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    Path(scratch, "Package.resolved").write_text(json.dumps({"version": 3, "pins": [{"identity": "dep", "state": {"revision": head}}]}))
    os.chdir(scratch)
    checkout = str(top)
    try:
        verify("clean checkout with ignored nested submodules")
        # A git hook exports GIT_DIR for the repository being pushed.
        with patch.dict(os.environ, {"GIT_DIR": str(sub / ".git"), "GIT_INDEX_FILE": str(sub / ".git/index")}):
            verify("clean checkout under a hook's GIT_DIR")
        for label, path in (("submodule", top / "Vendor/Sub.swift"), ("nested submodule", top / "Vendor/Leaf/Leaf.swift")):
            original_text = path.read_text()
            path.write_text("import AppKit\n" + original_text)
            verify(f"edited {label} hidden by ignore = all", "local changes")
            path.write_text(original_text)
            run("commit", "-qam", "moved", "--allow-empty", cwd=path.parent)
            verify(f"moved {label} HEAD hidden by ignore = all", "not at the pinned revision")
            run("reset", "-q", "--hard", "HEAD~1", cwd=path.parent)
        verify("restored submodules")
        (top / "Vendor/Generated.swift").write_text("import AppKit\n")
        verify("ignored file inside a submodule", "local changes")
        (top / "Vendor/Generated.swift").unlink()
        for flag, tag in (("--assume-unchanged", "assume"), ("--skip-worktree", "skip")):
            run("update-index", flag, "Top.swift", cwd=top)
            verify(f"index entry marked {tag}", "index entries git status does not check")
            run("update-index", flag.replace("--", "--no-"), "Top.swift", cwd=top)
        # A gitlink whose path holds a carriage return: text-mode output would rewrite it to a newline.
        add_ignored_submodule(top, leaf, "Odd\rLib")
        head = subprocess.run(["git", "-C", str(top), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        Path(scratch, "Package.resolved").write_text(json.dumps({"version": 3, "pins": [{"identity": "dep", "state": {"revision": head}}]}))
        verify("clean checkout with a carriage return in a gitlink path")
        (top / "Odd\rLib/Leaf.swift").write_text("import AppKit\n")
        verify("edited submodule at a carriage-return path", "local changes")
        run("checkout", "-q", "--", "Leaf.swift", cwd=top / "Odd\rLib")
        extra = top / "Extra"
        run("clone", "-q", str(leaf), str(extra), cwd=top)
        run("add", "Extra", cwd=top)
        verify("staged gitlink absent from HEAD", "local changes")
        run("reset", "-q", "--", "Extra", cwd=top)
        shutil.rmtree(extra)
        verify("restored after the staged gitlink")
        run("submodule", "deinit", "-q", "-f", "Vendor", cwd=top)
        verify("uninitialized empty submodule", "is not initialized")
        (top / "Vendor").rmdir()
        verify("deleted submodule directory", "local changes")
        (top / "Vendor").write_text("not a directory\n")
        verify("submodule path replaced by a file", "local changes")
        (top / "Vendor").unlink()
        (top / "Vendor").symlink_to(sub, target_is_directory=True)
        verify("submodule path replaced by a symlink to a clean clone", "git status failed")
    finally:
        os.chdir(here)
if failures:
    raise SystemExit(f"test-swift-gate: {len(failures)} of {checks} checkout verification checks failed")
print(f"test-swift-gate: checkout verification checks ok ({checks} cases)")
PYCHECKOUT
then
  failures=$((failures + 1))
fi
cases=$((cases + 1))

# Local header paths keep their restrictions; external C-family targets are rejected entirely.
if ! python3 -B - "$ROOT/scripts/lib/check_swift_invariants.py" "$TMP/header-paths" <<'PYHEADERS'
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import time
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("invariants", sys.argv[1])
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
base = Path(sys.argv[2])
checks, failures = 0, []


def write(root, name, content):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


def manifest(root, body):
    write(root, "Package.swift", '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(' + body + ')\n')


def build():
    args = ["swift", "build"]
    env = dict(os.environ)
    if env.get("CODEX_SANDBOX") or env.get("PARLANCE_SWIFTPM_DISABLE_SANDBOX") == "1":
        args.append("--disable-sandbox")
        env["CLANG_MODULE_CACHE_PATH"] = str(Path.cwd() / ".build/ModuleCache")
    result = subprocess.run(args, env=env, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f"test-swift-gate: setup failed: {' '.join(args)}\n{result.stdout}\n{result.stderr}")


def check(label, want, *messages):
    global checks
    errors = checker.check_core_imports(checker.swift_package(".", "dump-package"))
    checks += 1
    if bool(errors) != want or any(not any(message in error for error in errors) for message in messages):
        failures.append(label)
        print(f"test-swift-gate: FAIL {label}: expected errors={want}, containing {messages}; got {errors}")


for scope in ("external", "local"):
    root = base / scope
    dep = root / "dep" if scope == "external" else root
    write(root, "Sources/ParlanceCore/Core.swift", "public let value = 1\n")
    write(dep, "Sources/Bits/Bits.m", '#include "Bridge.h"\nint bits(void) { return 1; }\n')
    write(dep, "Sources/Bits/include/Bits.h", "int bits(void);\n")
    write(dep, "Sources/Shared/Bridge.h", "#import <AppKit/AppKit.h>\n")
    write(dep, "Sources/Bits/Headers/Bridge.h", "int bridge(void);\n")
    if scope == "external":
        manifest(root, 'name: "Client", dependencies: [.package(path: "dep")], '
                 'targets: [.target(name: "ParlanceCore", dependencies: [.product(name: "Bits", package: "dep")])]')
        prefix = 'name: "Dep", products: [.library(name: "Bits", targets: ["Bits"])], targets: ['
        context = "product 'Bits' (package 'dep')"
    else:
        prefix = 'name: "Local", targets: [.target(name: "ParlanceCore", dependencies: ["Bits"]), '
        context = "ParlanceCore"
    os.chdir(root)

    def set_target(options):
        manifest(dep, prefix + '.target(name: "Bits", ' + options + ')]')

    set_target('cSettings: [.headerSearchPath("../Shared")]')
    build()  # The sibling header is outside the scanner's tree, but SwiftPM compiles it.
    graph = checker.swift_package(".", "--force-resolved-versions", "show-dependencies", "--format", "json")
    real_package = checker.swift_package

    def resolved_graph(directory, *command):
        return graph if "show-dependencies" in command else real_package(directory, *command)

    with patch.object(checker, "swift_package", side_effect=resolved_graph):
        for options in ('cSettings: [.headerSearchPath("../Shared")]',
                        'cxxSettings: [.headerSearchPath("../Shared")]',
                        'publicHeadersPath: "../Shared"'):
            set_target(options)
            if scope == "external":
                check(scope + " C-family target", True, context, "target 'Bits'", "contains C-family sources", "must be pure Swift")
            else:
                check(scope + " sibling header path", True, context, "target 'Bits'", "../Shared", "outside target directory")
        (dep / "Sources/Bits/LinkedHeaders").symlink_to("../Shared", target_is_directory=True)
        set_target('cSettings: [.headerSearchPath("LinkedHeaders")]')
        if scope == "external":
            check(scope + " C-family symlink target", True, context, "contains C-family sources", "must be pure Swift")
        else:
            check(scope + " symlink header path", True, context, "target 'Bits'", "LinkedHeaders", "outside target directory")
        (dep / "Sources/Bits/LinkedHeaders").unlink()
        for options in ('cSettings: [.headerSearchPath("Headers")]',
                        'cxxSettings: [.headerSearchPath("Headers")]',
                        'publicHeadersPath: "include", cSettings: [.headerSearchPath("Headers")]'):
            set_target(options)
            if scope == "external":
                check(scope + " C-family internal headers", True, context, "contains C-family sources", "must be pure Swift")
            else:
                check(scope + " internal header path", False)
        build()
        write(dep, "Sources/Bits/Headers/Bridge.h", "#import <AppKit/AppKit.h>\n")
        if scope == "external":
            check(scope + " C-family AppKit header", True, context, "contains C-family sources", "must be pure Swift")
        else:
            check(scope + " internal header imports AppKit", True, "AppKit", "Headers/Bridge.h")
            # A header declared as a resource is still reachable by a quoted include, so it stays scanned.
            set_target('resources: [.copy("Headers")]')
            check(scope + " resource header imports AppKit", True, "AppKit", "Headers/Bridge.h")
            write(dep, "Sources/Bits/Headers/Bridge.h", "int bridge(void);\n")
            set_target('cSettings: [.headerSearchPath("Headers")]')
            check(scope + " clean C-family target", False)
            # Files the manifest keeps out of a local C-family target are still there for a `#include`, and so is
            # a file with no source extension at all, or an excluded `.swift` (clang includes any text file).
            (dep / "Sources/Bits/Payload.inc").symlink_to("/dev/zero")
            set_target('cSettings: [.headerSearchPath("Headers")]')
            check(scope + " link to a device file", True, "target 'Bits'", "Payload.inc", "outside package root")
            (dep / "Sources/Bits/Payload.inc").unlink()
            for options, name, text, module in (
                    ('exclude: ["Excluded.m"]', "Excluded.m", "#import <AppKit/AppKit.h>\n", "AppKit"),
                    ('sources: ["Bits.m"]', "Unselected.c", '#include "Cocoa/Cocoa.h"\n', "Cocoa"),
                    ('resources: [.copy("Data")]', "Data/snippet.inc", "#include <Carbon/Carbon.h>\n", "Carbon"),
                    ('exclude: ["Notes"]', "Notes/README.md", "@import SwiftUI;\n", "SwiftUI"),
                    ('exclude: ["Hidden.swift"]', "Hidden.swift", "#include <AppKit/AppKit.h>\n", "AppKit"),
                    ('sources: ["Bits.m"]', "Unselected.swift", "@import Cocoa;\n", "Cocoa"),
                    ('resources: [.copy("Hidden.swift")]', "Hidden.swift", "#import <Carbon/Carbon.h>\n", "Carbon")):
                set_target(options)
                write(dep, "Sources/Bits/" + name, text)
                check(scope + " unselected file " + name, True, "must not import " + module, name, "via its dependency 'Bits'")
                (dep / "Sources/Bits" / name).unlink()
            set_target('cSettings: [.headerSearchPath("Headers")]')
            # Includes this check cannot follow: a path that leaves the target, a path from a macro, and in any
            # letter case; nor do the preprocessor's early phases hide a directive (splices, also inside a comment
            # delimiter; comments between the tokens; trigraphs under either standard; a BOM; CRLF; a comment opener
            # inside a string, raw string, character literal, `#warning` line or C++ digit-separated number: nothing
            # is lexed away), and a module import counts wherever it stands.
            escape = ", an absolute or `..` path this check does not resolve"
            for label, text, *messages in (
                    ("relative escape", '#include "Bridge.h"\n#include "../Shared/Bridge.h"\n', 'Bits.m:2: ParlanceCore includes "../Shared/Bridge.h"' + escape),
                    ("bracketed escape", "#include <../../System/Library/Frameworks/AppKit.framework/Headers/AppKit.h>\n",
                     "Bits.m:1: ParlanceCore includes <../../System/Library/Frameworks/AppKit.framework/Headers/AppKit.h>" + escape),
                    ("absolute include", '#import "/Library/Frameworks/Bridge.framework/Headers/Bridge.h"\n', "Bits.m:1:", escape),
                    ("macro include", "#define BRIDGE <Bridge.h>\n#include BRIDGE\n", "Bits.m:2: ParlanceCore holds an include directive whose argument BRIDGE this check cannot resolve"),
                    ("lowercase framework", '#include "appkit/appkit.h"\n', "Bits.m:1: ParlanceCore must not import AppKit"),
                    ("case-folded Unicode framework spelling", '#include <\u017fwiftUI/SwiftUI.h>\n#import <Application\u017fervice\u017f/ApplicationServices.h>\n',
                     "Bits.m:1: ParlanceCore must not import SwiftUI", "Bits.m:2: ParlanceCore must not import ApplicationServices"),
                    ("spliced include", "#include \\\n  <AppKit/AppKit.h>\n", "Bits.m:1: ParlanceCore must not import AppKit"),
                    ("splice with trailing blank", "#include \\ \n  <AppKit/AppKit.h>\n", "Bits.m:1: ParlanceCore must not import AppKit"),
                    ("spliced keyword under CRLF", "#inc\\\r\nlude <AppKit/AppKit.h>\r\n", "Bits.m:1: ParlanceCore must not import AppKit"),
                    ("include_next and digraph", "%:include_next <Vision/Vision.h>\n", "Bits.m:1: ParlanceCore must not import Vision"),
                    ("trigraph directive and continuation", "??=include ??/\n <Carbon/Carbon.h>\n", "Bits.m:1: ParlanceCore must not import Carbon"),
                    ("comment between # and include", '#/**/include "../Shared/Bridge.h"\n', 'Bits.m:1: ParlanceCore includes "../Shared/Bridge.h"' + escape),
                    ("comment spanning lines inside the directive", "#include /* a\n b */ <AppKit/AppKit.h>\nint x;\n#include <Cocoa/Cocoa.h>\n",
                     "Bits.m:1: ParlanceCore must not import AppKit", "Bits.m:4: ParlanceCore must not import Cocoa"),
                    ("comment opener in a string", 'const char *s = "/*";\n#include <AppKit/AppKit.h>\nconst char *t = "*/";\n', "Bits.m:2: ParlanceCore must not import AppKit"),
                    ("BOM before the directive", "\ufeff#include <AppKit/AppKit.h>\n", "Bits.m:1: ParlanceCore must not import AppKit"),
                    ("@import after code", "int x; @import AppKit;\n@ import Cocoa;\n@import/**/Carbon;\n",
                     "Bits.m:1: ParlanceCore must not import AppKit", "Bits.m:2: ParlanceCore must not import Cocoa", "Bits.m:3: ParlanceCore must not import Carbon"),
                    ("pragma module import", '#pragma clang module import AppKit\n_Pragma("clang module import Cocoa")\n#define P(x) _Pragma(#x)\nP(clang module import Vision)\n',
                     "Bits.m:1: ParlanceCore must not import AppKit", "Bits.m:2: ParlanceCore must not import Cocoa", "Bits.m:4: ParlanceCore must not import Vision"),
                    ("splice inside a comment opener", "/\\\n* c */ #import <AppKit/AppKit.h>\nint z;\n#import <Vision/Vision.h>\n",
                     "Bits.m:2: ParlanceCore must not import AppKit", "Bits.m:4: ParlanceCore must not import Vision"),
                    ("splice inside a comment closer", "/* a *\\\n/ #import <AppKit/AppKit.h>\n", "Bits.m:2: ParlanceCore must not import AppKit"),
                    ("trigraph continuation ignored under the GNU standard", "// see ??/\n#import <AppKit/AppKit.h>\n", "Bits.m:2: ParlanceCore must not import AppKit"),
                    ("directive after a multi-line comment", "/* a\n b\n c */ #import <AppKit/AppKit.h>\n", "Bits.m:3: ParlanceCore must not import AppKit"),
                    ("comment opener in a string, comment inside the directive", 'const char *s = "/*";\n#/**/include <AppKit/AppKit.h>\nconst char *t = "*/";\n',
                     "Bits.m:2: ParlanceCore must not import AppKit"),
                    ("comment opener in a raw string", 'const char *s = R"x(" /* )x";\n#/**/include <AppKit/AppKit.h>\nconst char *t = "*/";\n',
                     "Bits.m:2: ParlanceCore must not import AppKit"),
                    ("quote in a character literal", 'char q = \'"\'; const char *s = "/*";\n#/**/include <AppKit/AppKit.h>\nconst char *t = "*/";\n',
                     "Bits.m:2: ParlanceCore must not import AppKit"),
                    ("apostrophe in a directive", "#warning don't\n#/**/include <AppKit/AppKit.h>\n", "Bits.m:2: ParlanceCore must not import AppKit"),
                    ("escaped backslash ending a string", 'const char *s = "a\\\\";\n#/**/include <AppKit/AppKit.h>\n', "Bits.m:2: ParlanceCore must not import AppKit"),
                    ("splice with a form feed after the backslash", "#inc\\\f\nlude <AppKit/AppKit.h>\n", "Bits.m:1: ParlanceCore must not import AppKit"),
                    # clang's escaped newline takes `\n\r` as one break (Python's universal newlines would make it two and break the
                    # splice), while its line numbers count the raw `\n` and `\r` separately, so the later findings sit on lines 7 and 8.
                    ("spliced keyword under LF CR", "#inc\\\n\rlude <AppKit/AppKit.h>\n\r@imp\\\n\rort Cocoa;\n#include <Carbon/Carbon.h>\n",
                     "Bits.m:1: ParlanceCore must not import AppKit", "Bits.m:7: ParlanceCore must not import Cocoa", "Bits.m:8: ParlanceCore must not import Carbon"),
                    # A NUL or a Unicode blank between the backslash and the newline is no splice to clang: the next line stands on its own.
                    ("no splice through a NUL or NBSP after the backslash", "// c \\\0\n#include <AppKit/AppKit.h>\n#define U \\\u00a0\n#import <Cocoa/Cocoa.h>\n",
                     "Bits.m:2: ParlanceCore must not import AppKit", "Bits.m:4: ParlanceCore must not import Cocoa"),
                    ("quoted module name in a pragma", '#pragma clang module import "AppKit"\n_Pragma("clang module import \\"Cocoa\\"")\n',
                     "Bits.m:1: ParlanceCore must not import AppKit", "Bits.m:2: ParlanceCore must not import Cocoa"),
                    ("comment opener in a #warning line", "#warning /* note\n@import AppKit;\n// */\n", "Bits.m:2: ParlanceCore must not import AppKit"),
                    ("raw-string spelling that C reads as a plain string", '#define M R"(a"b)" /*\n@import AppKit;\n// */\n', "Bits.m:2: ParlanceCore must not import AppKit"),
                    ("C++ digit separator before a comment", "int a = 1'000; /*\nR\"x(\n*/\n#/**/include <AppKit/AppKit.h>\n// )x\"\n", "Bits.m:4: ParlanceCore must not import AppKit"),
                    ("splice inside a raw string's terminator", 'const char *s = R"x(\n)x\\\n"\n/*\n)x";\n#/**/include <AppKit/AppKit.h>\n// */\n',
                     "Bits.m:6: ParlanceCore must not import AppKit"),
                    ("module import split by a comment", "#pragma clang module /*x*/ import Vision\n@/*y*/import Carbon;\n",
                     "Bits.m:1: ParlanceCore must not import Vision", "Bits.m:2: ParlanceCore must not import Carbon"),
                    ("inline module map", '#pragma clang module build Shim\nmodule Shim { link framework "appkit.framework" }\n#pragma clang module contents\n#pragma clang module begin Shim\n#pragma clang module end\n#pragma clang module endbuild\n@import Shim;\n',
                     "Bits.m:1: ParlanceCore holds an inline module map", "Bits.m:2: ParlanceCore must not link framework AppKit"),
                    ("module candidate inside the include's comment", "#include /* @import /* */ <AppKit/AppKit.h>\n#import /* module import /* */ <../Shared/Bridge.h>\n",
                     "Bits.m:1: ParlanceCore must not import AppKit", 'Bits.m:2: ParlanceCore includes <../Shared/Bridge.h>'),
                    # clang accepts its Unicode whitespace (NBSP, U+3000, U+180E, ...) between tokens with a warning, at every gap.
                    ("Unicode whitespace between tokens", "@\u00a0import AppKit;\n@import\u3000Cocoa;\n\u2028#\u0085include\u180e<Carbon/Carbon.h>\n#pragma clang module\u202fbuild\u1680M\nmodule M { link\u180eframework\u205f\"ScreenCaptureKit\" }\n@\u2029_Pragma(\"once\") import Vision;\n",
                     "Bits.m:1: ParlanceCore must not import AppKit", "Bits.m:2: ParlanceCore must not import Cocoa", "Bits.m:3: ParlanceCore must not import Carbon",
                     "Bits.m:4: ParlanceCore holds an inline module map", "Bits.m:5: ParlanceCore must not link framework ScreenCaptureKit", "Bits.m:6: ParlanceCore holds a `@`"),
                    # A split beside an unresolved include on the same line: the split is no literal, so both stay.
                    ("split beside an unresolved include", "@\n#include MACRO\n", "Bits.m:2: ParlanceCore holds a `@`", "Bits.m:2: ParlanceCore holds an include directive whose argument MACRO"),
                    # A candidate inside a string literal lands where the real directive expects a different token.
                    ("earlier candidate in a string expects another token", 'const char *s = "@import /*"; @ /* */ import AppKit;\n'
                     'const char *t = "clang module /*";\n#pragma clang /**/ module build Shim\n'
                     'const char *u = "link framework /*"; link /**/ framework "Cocoa";\n'
                     'const char *v = R"(\n#include /*\n)";\n#/**/include <Carbon/Carbon.h>\n',
                     "Bits.m:1: ParlanceCore must not import AppKit", "Bits.m:3: ParlanceCore holds an inline module map",
                     "Bits.m:4: ParlanceCore must not link framework Cocoa", "Bits.m:8: ParlanceCore must not import Carbon"),
                    # clang processes a whole directive line between the tokens of a module import, and a conditional group or an
                    # include there can supply the rest of the import; such a split import is reported, not followed.
                    ("directive line between the tokens of a module import", "@\n#define X 1\nimport AppKit;\n@import\n%:define Y \"/*\"\nCocoa;\n@ /* c */\n# if 0\nzzz\n#endif\n   import Carbon.Core;\n@import\n#include \"name.h\"\n@ _Pragma(\"once\") import AppKit;\n@import _Pragma(\"once\") AppKit;\n// end of module\n_Pragma(\"clang diagnostic push\")\n",
                     "Bits.m:2: ParlanceCore holds a `@` (or `@import`) whose next token stands after a directive line, a `_Pragma` operator or in the file that includes this one", "Bits.m:5: ParlanceCore holds a `@`",
                     "Bits.m:14: ParlanceCore holds a `@`", "Bits.m:15: ParlanceCore holds a `@`",
                     "Bits.m:8: ParlanceCore holds a `@`", "Bits.m:13: ParlanceCore holds a `@`"),
                    ("module import split across lines", "@import\nAppKit;\n@\nimport Cocoa;\n@import // c\nCarbon;\n",
                     "Bits.m:2: ParlanceCore must not import AppKit", "Bits.m:4: ParlanceCore must not import Cocoa", "Bits.m:6: ParlanceCore must not import Carbon"),
                    ("NUL bytes as blanks", "\0#include <AppKit/AppKit.h>\n#\0include <Cocoa/Cocoa.h>\n@\0import Carbon;\n",
                     "Bits.m:1: ParlanceCore must not import AppKit", "Bits.m:2: ParlanceCore must not import Cocoa", "Bits.m:3: ParlanceCore must not import Carbon")):
                write(dep, "Sources/Bits/Bits.m", text)
                check(scope + " " + label, True, *messages)
            # A file ending in `@` or `@import` is continued by the file that includes it: each half is clean on its own.
            write(dep, "Sources/Bits/Tail.h", "@\n")
            write(dep, "Sources/Bits/Bits.m", '#include "Tail.h"\nimport AppKit;\n')
            check(scope + " module import continued across an include", True, "Tail.h:1: ParlanceCore holds a `@` (or `@import`) whose next token stands after a directive line, a `_Pragma` operator or in the file that includes this one")
            (dep / "Sources/Bits/Tail.h").unlink()
            # A long run of comments that no directive follows must scan in linear time (a lazy comment pattern
            # repeated inside the gap backtracks exponentially; ~30 comments already took seconds).
            write(dep, "Sources/Bits/Bits.m", "/*x*/" * 5000 + "int bits(void) { return 1; }\n" + "/* a\n b */" * 5000 + " #include <AppKit/AppKit.h>\n"
                                              + "// @import" + " " * 20000 + "\n// module import" + "\t" * 20000 + "\n"
                                              + "/*\n" + "/* x\n" * 20000 + "@/* y\n" * 20000 + "*/\n" + "// " + "@ // " * 20000 + "\n"
                                              + "/*\n" * 20000 + "*/" + "/**/" * 20000 + " " * 20000 + "\n" + "@/*\n" * 20000 + "*/ " + "/**/" * 20000 + "import Foundation;\n"
                                              + "// see @\n" * 20000 + "// the module\n" * 20000 + "@/*\n" * 20000 + "*/" + "//x\n" * 20000
                                              + "int /*\n" + "@import /*\n" * 20000 + "*/ " + "x" * 20000 + ";\n" + "#include /*\n" * 20000 + "*/ <stddef.h> /*" + "x" * 200000 + "*/\n"
                                              + "/* " + "link /*\n" * 20000 + "*/ framework " + " " * 20000 + "Foundation " + "@import /*\n" * 20000 + "*/ " + '"' * 20000 + "Foundation "
                                              + "@ /*\n" * 20000 + "*/ import" + " " * 20000 + "Foundation; " + "clang /*\n" * 20000 + "*/ module " + " " * 20000 + "import Foundation */\n"
                                              + "int /*\n" + '@import "/*\n' * 50000 + "*/ " + "x" * 50000 + ";\n" + "@\n" * 20000 + "#define X " + "x" * 20000 + "\n" + "#define Y /*\n" * 20000 + "*/\nimport Foundation;\n"
                                              + "/*\n" * 20000 + "*/ #" + " " * 20000 + "include <stddef.h>\n" + "/*\n" * 20000 + "*/ %:" + "\t" * 20000 + "define BITS 1\n")
            started = time.monotonic()
            check(scope + " long comment runs scan in linear time", True, "Bits.m:5002: ParlanceCore must not import AppKit")
            if time.monotonic() - started > 5:
                failures.append(scope + " long comment runs scan in linear time")
                print(f"test-swift-gate: FAIL {scope} long comment runs scan in linear time: took {time.monotonic() - started:.1f}s")
            # The Swift scanner too: `import` words inside one run of line comments converge on one name (and, after a
            # declaration kind, on one blank run); each is read once.
            write(root, "Sources/ParlanceCore/Scan.swift", "// import\n" * 20000 + "class" + " " * 20000 + "Foundation\n" + "// import\n" * 20000 + "x" * 20000 + "\n"
                                                           + "/**/" * 20000 + "\nimport AppKit\n")
            started = time.monotonic()
            check(scope + " comment runs before a Swift import scan in linear time", True, "Scan.swift:40004: ParlanceCore must not import AppKit")
            if time.monotonic() - started > 5:
                failures.append(scope + " comment runs before a Swift import scan in linear time")
                print(f"test-swift-gate: FAIL {scope} comment runs before a Swift import scan in linear time: took {time.monotonic() - started:.1f}s")
            (root / "Sources/ParlanceCore/Scan.swift").unlink()
            # Ordinary includes, comments and a commented-out directive; the `??/` continuation is valid only under an
            # ISO standard and checks that the trigraph reading's literal suppresses the GNU reading's "unresolved".
            write(dep, "Sources/Bits/Bits.m", '#include "Bridge.h"\n#include <Foundation/Foundation.h>\n#include <stdio.h>\n#include /* c */ <os/log.h>\n'
                                              '#if __has_include(<AppKit/AppKit.h>)\n#endif\n// #include <AppKit/AppKit.h>\n/* #include <AppKit/AppKit.h> */\n// c \\\n#include <AppKit/AppKit.h>\n'
                                              '// a \\\nb \\\n#import <AppKit/AppKit.h>\n#include ??/\n <os/lock.h>\n'
                                              '@import Foundation;\n/// See the module build log; link "z"; module import order.\nint bits(void) { return 1; }\n'
                                              # Shapes the module-import rules must leave alone: `@` keywords before a directive line, stringizing
                                              # after `@`, a `module` word before a `_Pragma`, a link to a framework that is allowed.
                                              '@interface Bits : NSObject\n#pragma mark - X\n@end\n#if 1\n#endif\n#define S(x) @#x\n#define T(x) @ #x\n'
                                              '// end of module\n_Pragma("clang diagnostic push")\n// link framework "Foundation.framework"\n')
            check(scope + " own, system, commented and comment-split includes", False)
            # A module map can link a framework or map headers outside the target; the check does not parse it,
            # so any `*.modulemap` under a local target fails, selected or not.
            for name, options in (("include/module.modulemap", 'cSettings: [.headerSearchPath("Headers")]'),
                                  ("include/module.modulemap", 'exclude: ["include/module.modulemap"]'),
                                  ("Maps/bits.private.modulemap", 'exclude: ["Maps"]'),
                                  ("Headers/module.map", 'cSettings: [.headerSearchPath("Headers")]')):
                write(dep, "Sources/Bits/" + name, 'module Bits { header "Bits.h" link framework "AppKit" export * }\n')
                set_target(options)
                check(scope + " module map " + name, True, "target 'Bits'", "holds a module map (" + name + ")", "does not parse module maps")
                (dep / "Sources/Bits" / name).unlink()
if failures:
    raise SystemExit(f"test-swift-gate: {len(failures)} of {checks} header path checks failed")
print(f"test-swift-gate: header path checks ok ({checks} cases)")
PYHEADERS
then
  failures=$((failures + 1))
fi
cases=$((cases + 1))

# Path fixtures exercise the import invariant separately: the license invariant intentionally rejects paths.
if ! python3 -B - "$ROOT/scripts/lib/check_swift_invariants.py" "$TMP/products" <<'PYTEST'
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("invariants", sys.argv[1])
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
base = Path(sys.argv[2])
base.mkdir()


def package(directory, body, files):
    root = base / directory
    root.mkdir(exist_ok=True)
    (root / "Package.swift").write_text(
        '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(' + body + ')\n'
    )
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    return root


root = package("root", 'name: "Probe", dependencies: [.package(path: "../dep-dir")], '
               'targets: [.target(name: "ParlanceCore", dependencies: [.product(name: "Dep", package: "dep-dir")])]',
               {"Sources/ParlanceCore/Core.swift": "public let value = 1\n"})
dep = package("dep-dir", 'name: "ManifestName", products: [.library(name: "Dep", targets: ["Bits"])], '
              'targets: [.target(name: "Bits"), .target(name: "Unused")]',
              {"Sources/Bits/Bits.swift": "import AppKit\n", "Sources/Unused/Unused.swift": "import AppKit\n"})
os.chdir(root)
env = dict(os.environ)
args = ["swift", "package"]
if env.get("CODEX_SANDBOX") or env.get("PARLANCE_SWIFTPM_DISABLE_SANDBOX") == "1":
    args.append("--disable-sandbox")
    env["CLANG_MODULE_CACHE_PATH"] = str(root / ".build/ModuleCache")


def swift_json(*command):
    out = subprocess.run(args + list(command), env=env, capture_output=True, text=True)
    if out.returncode:
        raise SystemExit(f"test-swift-gate: setup failed: {' '.join(args + list(command))}\n{out.stderr}")
    return json.loads(out.stdout)


graph = swift_json("show-dependencies", "--format", "json")
node = graph["dependencies"][0]
assert node["identity"] == "dep-dir" and Path(node["path"]).resolve() == dep.resolve(), node
print("test-swift-gate: resolved path package: " + json.dumps(node))
checks = 0
failed_checks = []


def imports(want, label, *messages):
    global checks
    manifest = swift_json("dump-package")
    errors = checker.check_core_imports(manifest)
    checks += 1
    if bool(errors) != want or any(not any(message in e for e in errors) for message in messages):
        failed_checks.append(label)
        print(f"test-swift-gate: FAIL {label}: expected errors={want}, containing {messages}; got {errors}")


imports(True, "external product", "product 'Dep' (package 'dep-dir')", "imports AppKit")
for label, text, where in (("after a semicolon", "public let marker = 0; import AppKit\n", "Bits.swift:1:"),
                          ("split across lines", "public let marker = 0\n\nimport\n  /* gap */ AppKit\n", "Bits.swift:3:"),
                          ("backticked", "import `SwiftUI`\n", "imports SwiftUI"),
                          ("backticked with no space", "import class`AppKit`.NSView\n", "imports AppKit"),
                          ("after a NUL", "import\0AppKit\n", "imports AppKit"),
                          ("after an NBSP", "import\u00a0AppKit\n", "imports AppKit"),
                          ("after a backticked attribute", "@`_exported`import AppKit\n", "imports AppKit"),
                          ("on a later line among several", "import Foundation\n// import AppKit\n\nimport Cocoa\n", "Bits.swift:4:"),
                          ("after nested comments", "import /* a /* b */ c */ Cocoa\n", "imports Cocoa"),
                          ("after a string holding a comment opener",
                           'let s = "/*"; import AppKit; let t = "*/"\n', "Bits.swift:1:")):
    (dep / "Sources/Bits/Bits.swift").write_text(text)
    imports(True, "external import " + label, "product 'Dep' (package 'dep-dir')", where)
(dep / "Sources/Bits/Bits.swift").write_text("#if canImport(AppKit)\npublic let ui = true\n#endif\nimport VisionKitLike\n"
                                            "import `SwiftUI-Navigation`\nimport " + "/* c */" * 40 + " Foundation\n")
imports(False, "canImport, longer or hyphenated module names and a comment run are not imports")
(dep / "Sources/Bits/Bits.swift").write_text("import AppKit\n")
with patch.object(checker, "declared_dependencies", return_value={"dep-dir": "registry"}):
    imports(True, "registry dependency", "package 'dep-dir'", "registry dependencies are not supported")
(dep / "Sources/Bits/Bits.swift").write_text("public let value = 1\n")
imports(False, "unused external target")
manifest = (dep / "Package.swift").read_text()
(dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")', '.target(name: "Bits", dependencies: ["Unused"])'))
imports(True, "external local target dependency", "Unused.swift", "imports AppKit")
(dep / "Package.swift").write_text(manifest)
root_manifest = (root / "Package.swift").read_text()
(root / "Package.swift").write_text(root_manifest.replace('.package(path:', '.package(name: "Dep", path:').replace('.product(name: "Dep", package: "dep-dir")', '"Dep"'))
imports(False, "byName external product")
(dep / "Sources/Bits/Bits.swift").write_text("@_exported import AppKit\n")
imports(True, "byName re-export", "imports AppKit")
(root / "Package.swift").write_text(root_manifest.replace('.package(path:', '.package(name: "Alias", path:').replace('package: "dep-dir"', 'package: "Alias"'))
imports(True, "explicit package name alias", "package 'dep-dir'", "imports AppKit")
(root / "Package.swift").write_text(root_manifest)
(dep / "Sources/Bits/Bits.swift").write_text("public let value = 1\n")
package("leaf-dir", 'name: "Leaf", products: [.library(name: "LeafProduct", targets: ["LeafBits"])], '
        'targets: [.target(name: "LeafBits")]', {"Sources/LeafBits/Leaf.swift": "import AppKit\n"})
(dep / "Package.swift").write_text(manifest.replace('targets: [.target(name: "Bits")',
    'dependencies: [.package(path: "../leaf-dir")], targets: [.target(name: "Bits", dependencies: [.product(name: "LeafProduct", package: "leaf-dir")])'))
imports(True, "transitive external product", "product 'LeafProduct' (package 'leaf-dir')", "imports AppKit")
(dep / "Package.swift").write_text(manifest)
(dep / "Sources/Bits/Excluded.swift").write_text("import AppKit\n")
(dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")', '.target(name: "Bits", exclude: ["Excluded.swift"])'))
imports(False, "external exclude")
(dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")', '.target(name: "Bits", sources: ["Bits.swift"])'))
imports(False, "external sources")
(dep / "Sources/Bits/Excluded.swift").unlink()
(dep / "Package.swift").write_text(manifest)
(dep / "Linked").mkdir()
(dep / "Linked/Link.swift").write_text("import AppKit\n")
(dep / "Sources/Bits/Linked").symlink_to("../../Linked", target_is_directory=True)
imports(True, "external symlink directory", "Linked/Link.swift", "imports AppKit")
(dep / "Sources/Bits/Linked").unlink()
(dep / "Sources/Bits/Bits.h").write_text('#include "AppKit/AppKit.h"\n#import <Carbon/Carbon.h>\n@import Vision;\n')
imports(True, "external C-family headers", "product 'Dep' (package 'dep-dir')", "target 'Bits'", "contains C-family sources (Sources/Bits/Bits.h)", "must be pure Swift")
(dep / "Sources/Bits/Bits.h").unlink()
(dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")', '.target(name: "Bits", sources: [])'))
imports(True, "empty source selection", "package 'dep-dir'", "no source files")
(dep / "Templates").mkdir()
(dep / "Sources/Bits/Templates").mkdir()
for name in ("Sources/Bits/Templates/Template.swift", "Sources/Bits/Processed.swift", "Sources/Bits/Embedded.swift"):
    (dep / name).write_text("import AppKit\n")
(dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")', '.target(name: "Bits", resources: '
    '[.copy("Templates"), .process("Processed.swift"), .embedInCode("Embedded.swift")])'))
imports(False, "external Swift resources")
(dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")', '.target(name: "Bits", resources: [.copy("Templates")])'))
imports(True, "Swift file outside declared resources", "Processed.swift", "imports AppKit")
for name in ("Sources/Bits/Processed.swift", "Sources/Bits/Embedded.swift"):
    (dep / name).unlink()
(dep / "Sources/Bits/Templates/Template.swift").unlink()
(dep / "Sources/Bits/Templates").rmdir()
(dep / "Templates").rmdir()
(dep / "Plugins/Gen").mkdir(parents=True)
(dep / "Plugins/Gen/Gen.swift").write_text("import PackagePlugin\n")
(dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")',
    '.target(name: "Bits", plugins: ["Gen"]), .plugin(name: "Gen", capability: .buildTool())'))
imports(True, "external build-tool plugin", "product 'Dep' (package 'dep-dir')", "target 'Bits'", "build-tool plugin(s) Gen")
(dep / "Package.swift").write_text(manifest)
shutil.rmtree(dep / "Plugins")
(root / "Plugins/CoreGen").mkdir(parents=True)
(root / "Plugins/CoreGen/CoreGen.swift").write_text("import PackagePlugin\n")
(root / "Package.swift").write_text(root_manifest.replace('package: "dep-dir")])', 'package: "dep-dir")], '
    'plugins: ["CoreGen"]), .plugin(name: "CoreGen", capability: .buildTool())'))
imports(True, "core build-tool plugin", "target 'ParlanceCore'", "build-tool plugin(s) CoreGen")
(root / "Package.swift").write_text(root_manifest)
shutil.rmtree(root / "Plugins")
# Build settings that import or link a module without an import line in the scanned sources.
implicit = '.unsafeFlags(["-Xfrontend", "-import-module", "-Xfrontend", "AppKit"])'
for tool in ("swiftSettings", "cSettings", "linkerSettings"):
    flags = implicit if tool == "swiftSettings" else '.unsafeFlags(["-v"])'
    (dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")', f'.target(name: "Bits", {tool}: [{flags}])'))
    imports(True, "external unsafeFlags in " + tool, "product 'Dep' (package 'dep-dir')", "target 'Bits'", "sets unsafeFlags")
(dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")', '.target(name: "Bits", linkerSettings: [.linkedFramework("AppKit")])'))
imports(True, "external links AppKit", "target 'Bits'", "links framework AppKit")
(dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")', '.target(name: "Bits", linkerSettings: [.linkedFramework("appkit")])'))
imports(True, "external links lowercase appkit", "target 'Bits'", "links framework appkit")
(dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")', '.target(name: "Bits", linkerSettings: [.linkedFramework("Security")])'))
imports(False, "external links an allowed framework")
(dep / "Package.swift").write_text(manifest)
(root / "Package.swift").write_text(root_manifest.replace('package: "dep-dir")])', f'package: "dep-dir")], swiftSettings: [{implicit}])'))
imports(True, "core unsafeFlags", "target 'ParlanceCore'", "sets unsafeFlags")
(root / "Package.swift").write_text(root_manifest)

# Freeze the already resolved graph to test failures after resolution, without SwiftPM repairing a checkout.
graph = swift_json("show-dependencies", "--format", "json")
real_swift_package = checker.swift_package


def resolved_graph(directory, *command):
    if "show-dependencies" in command:
        return graph
    return real_swift_package(directory, *command)


with patch.object(checker, "swift_package", side_effect=resolved_graph):
    # Excluded or unselected C-family files still make the external target non-Swift.
    context = "product 'Dep' (package 'dep-dir')"
    (dep / "Sources/Shared").mkdir()
    (dep / "Sources/Shared/Bridge.h").write_text("#import <AppKit/AppKit.h>\n")
    for filename in ("Interop.c", "Interop.cc", "Interop.cpp", "Interop.cxx", "Interop.m", "Interop.mm",
                     "Interop.h", "Interop.hh", "Interop.hpp", "Interop.hxx", "module.modulemap", "module.map"):
        path = dep / "Sources/Bits" / filename
        path.write_text('module Bridge { header "../Shared/Bridge.h" export * }\n' if filename.startswith("module.")
                        else '#include "../Shared/Bridge.h"\n')
        imports(True, "external non-Swift file " + filename, context, "target 'Bits'",
                f"contains C-family sources (Sources/Bits/{filename})", "must be pure Swift", "Clang header lookup")
        path.unlink()
    path = dep / "Sources/Bits/Ignored.h"
    path.write_text("int ignored_header(void);\n")
    (dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")', '.target(name: "Bits", exclude: ["Ignored.h"])'))
    imports(True, "excluded external header", context, "Ignored.h", "must be pure Swift")
    path.unlink()
    path = dep / "Sources/Bits/Unselected.c"
    path.write_text("int unselected(void) { return 1; }\n")
    (dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")', '.target(name: "Bits", sources: ["Bits.swift"])'))
    imports(True, "unselected external C source", context, "Unselected.c", "must be pure Swift")
    path.unlink()
    (dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")', '.target(name: "Bits", dependencies: ["Unused"])'))
    (dep / "Sources/Unused/Unused.swift").write_text("public let unusedValue = 1\n")
    (dep / "Sources/Unused/Transitive.h").write_text("int transitive(void);\n")
    imports(True, "C header in external local-target closure", context, "target 'Unused'", "Transitive.h", "must be pure Swift")
    (dep / "Package.swift").write_text(manifest)
    imports(False, "C header in unused external target")
    (dep / "Sources/Unused/Transitive.h").unlink()
    outside = base / "outside"
    outside.mkdir()
    (outside / "Safe.swift").write_text("public let outsideValue = 1\n")
    (outside / "Safe.h").write_text("int outside_value(void);\n")
    context = "product 'Dep' (package 'dep-dir')"
    for destination in (str(outside), "../../../outside"):
        link = dep / "Sources/Bits/Escape"
        link.symlink_to(destination, target_is_directory=True)
        imports(True, "escaping directory link", context, "target 'Bits'", "Escape", "outside")
        link.unlink()
    for name, destination in (("Escape.swift", outside / "Safe.swift"),):
        link = dep / "Sources/Bits" / name
        link.symlink_to(destination)
        imports(True, "escaping source link", context, "target 'Bits'", name, "outside")
        link.unlink()
    empty = outside / "Empty"
    empty.mkdir()
    (dep / "Sources/Bits/Empty").symlink_to(empty, target_is_directory=True)
    imports(True, "escaping empty directory link", context, "target 'Bits'", "Empty", "outside")
    (dep / "Sources/Bits/Empty").unlink()
    # Includes a path with the package name as a prefix, which is still outside the package.
    sibling = base / "dep-dir-sibling"
    sibling.mkdir()
    (sibling / "Safe.swift").write_text("public let siblingValue = 1\n")
    for target_path in ("../outside", "../dep-dir-sibling"):
        (dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")',
            f'.target(name: "Bits", path: "{target_path}")'))
        imports(True, "escaping target path", context, "target 'Bits'", target_path, "outside")
    for declaration in ('sources: ["Bits.swift", "../../../outside/Safe.swift"]',):
        (dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")',
            f'.target(name: "Bits", {declaration})'))
        imports(True, "escaping manifest source path", context, "target 'Bits'", "outside")
    (dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")',
        '.target(name: "Bits", sources: ["Bits.swift", "../Unused/Unused.swift"])'))
    imports(True, "sources entry leaves target subtree", context, "target 'Bits'", "outside target directory")
    (dep / "Package.swift").write_text(manifest)
    (dep / "Linked/Link.swift").write_text("public let linkedValue = 1\n")
    (dep / "Sources/Bits/Internal").symlink_to("../../Linked", target_is_directory=True)
    imports(False, "internal directory link remains allowed")
    (dep / "Sources/Bits/Internal").unlink()
    (dep / "Sources/Bits/Bits.swift").unlink()
    (dep / "Sources/Bits/Bits.swift").symlink_to("missing.swift")
    imports(True, "unreadable external source", "product 'Dep' (package 'dep-dir')", "not a regular file")
    (dep / "Sources/Bits/Bits.swift").unlink()
    (dep / "Sources/Bits/Bits.swift").write_text("public let value = 1\n")
    (dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")', '.binaryTarget(name: "Bits", path: "Bits.xcframework")'))
    imports(True, "binary product target", "product 'Dep' (package 'dep-dir')", "binary target", "must be pure Swift")
    (dep / "Package.swift").write_text(manifest.replace('.target(name: "Bits")', '.systemLibrary(name: "Bits")'))
    imports(True, "system product target", "product 'Dep' (package 'dep-dir')", "system target", "must be pure Swift")
    (dep / "Package.swift").write_text(manifest.replace('library(name: "Dep"', 'library(name: "Other"'))
    imports(True, "missing product", "package 'dep-dir' for product 'Dep'", "product not found")
    (dep / "Package.swift").write_text("invalid swift manifest\n")
    imports(True, "manifest dump fails", "package 'dep-dir' for product 'Dep'", "dump-package failed")
    (dep / "Package.swift").unlink()
    imports(True, "missing manifest", "package 'dep-dir' for product 'Dep'", "dump-package failed")
    (dep / "Package.swift").write_text(manifest)
    dep.rename(base / "hidden-dep")
    imports(True, "missing checkout", "package 'dep-dir' for product 'Dep'", "directory is missing")
    (base / "hidden-dep").rename(dep)
    package("duplicate", 'name: "Duplicate", products: [.library(name: "Dep", targets: ["Duplicate"])], '
            'targets: [.target(name: "Duplicate")]', {"Sources/Duplicate/Duplicate.swift": "public let value = 1\n"})
    graph["dependencies"].append({"identity": "duplicate", "path": str(base / "duplicate"), "dependencies": []})
    (root / "Package.swift").write_text(root_manifest.replace('.package(path: "../dep-dir")',
        '.package(path: "../dep-dir"), .package(path: "../duplicate")').replace('.product(name: "Dep", package: "dep-dir")', '"Dep"'))
    imports(True, "ambiguous byName", "package 'dep-dir, duplicate' for product 'Dep'", "ambiguous product")
    (root / "Package.swift").write_text(root_manifest.replace('.product(name: "Dep", package: "dep-dir")', '"Missing"'))
    imports(True, "missing byName", "package 'dep-dir' for product 'Missing'", "product not found")
    (root / "Package.swift").write_text(root_manifest)
if failed_checks:
    raise SystemExit(f"test-swift-gate: {len(failed_checks)} of {checks} external product checks failed")
print(f"test-swift-gate: external product checks ok ({checks} cases)")
PYTEST
then
  failures=$((failures + 1))
fi
cases=$((cases + 1))
printf '{}\n' > scripts/dependency-licenses.json
expect fail "dependency not in the license allowlist" "dependency 'dep' .*is not in scripts/dependency-licenses.json"
reset_tree
allow() {  # allow <key> <url> [more JSON members]: rewrite the allowlist with one entry for the dependency
  printf '{"%s": {"license": "MIT", "url": "%s", "reason": "-"}%s}\n' "$1" "$2" "${3:-}" > scripts/dependency-licenses.json
}
allow dep "file://$DEP" ', "ghost": {"license": "MIT", "url": "-", "reason": "-"}'
expect fail "stale allowlist entry" "stale entry 'ghost'"
refute "stale allowlist entry" "resolves to"
allow dep "file://$TMP/elsewhere/dep"
expect fail "dependency approved for another origin" "dependency 'dep' resolves to .*approved 'file://.*/elsewhere/dep'"
printf '{"dep": {"license": "MIT", "reason": "-"}}\n' > scripts/dependency-licenses.json
expect fail "allowlist entry without a url" "dependency 'dep' resolves to .*approved None"
allow Dep "file://$DEP"
expect fail "mixed-case allowlist key" "key 'Dep' must be the lowercase package identity 'dep'"
refute "mixed-case allowlist key" "stale entry|is not in scripts/dependency-licenses.json"
reset_tree
git rm -q --cached Package.resolved
expect fail "Package.resolved untracked" 'Package.resolved is not tracked'
reset_tree
git rm -q Package.resolved
expect fail "Package.resolved absent" 'Package.resolved is missing'
reset_tree
sed -i.bak 's/exact: "1.0.0"/exact: "1.1.0"/' Package.swift && rm -f Package.swift.bak
expect fail "Package.resolved stale" 'Package.resolved is out of date'
reset_tree
git rm -q Package.resolved
dep_manifest '.package(path: "../dep")'
expect fail "path dependency (never pinned)" "path dependency 'dep'"
reset_tree

if [ "$failures" -gt 0 ]; then
  echo "test-swift-gate: $failures of $cases case(s) failed"
  exit 1
fi
echo "test-swift-gate: ok ($cases cases)"
