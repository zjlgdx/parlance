#!/usr/bin/env python3
"""Turn `swift test` output into a fail-closed verdict.

`swift test` exits 0 when zero tests ran (empty targets, a --filter that matches nothing, every test skipped,
disabled or cancelled), so the exit code alone is a false green. This parser requires at least one executed
test and no failure. Executed = tests counted by the run summaries minus the skipped ones:
- Swift Testing: "Test run with N tests in M suites passed|failed", minus one per "➜ Test <name> skipped"
  line (`.disabled`, a false `.enabled(if:)` such as the live-test switch, or a test in a skipped suite)
  and one per "➜ Test <name> was cancelled" line (`try Test.cancel(...)`, the runtime skip). Both count
  as skipped; the comment after either may run on to further lines. A "Test case ..." line is not
  subtracted: it is one case of a parameterized test, which the run summary counts once;
- XCTest: the "Executed N tests, with K tests skipped and F failures" summary of the top-level suite
  ('All tests' or 'Selected tests'); the per-bundle and per-class summaries repeat the same tests.

Not visible here: a parameterized test whose every case calls `Test.cancel`. Swift Testing logs it as passed
("Test f(x:) with 2 test cases passed"; --verbose and --xunit-output say the same), so it counts as executed.
A live test's switch therefore goes in an `.enabled(if:)` trait, whose skip is logged (docs/development.md).

Usage: swift_test_summary.py [--brief] <swift-test.log>
Exit codes: 0 ok, 1 zero executed tests / failures / unmatched filter, 2 usage error.
"""
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
SWIFT_TESTING = re.compile(r"Test run with (\d+) tests? in (\d+) suites? (passed|failed)")
# The quoted comment may hold a line break, which puts its closing quote on a later line: match only its start.
SWIFT_TESTING_SKIPPED = re.compile(r'^\s*\S+ Test .+ skipped(?:\.|: ".*)?\s*$', re.M)
SWIFT_TESTING_CANCELLED = re.compile(
    r'^\s*\S+ Test (?!case\b).+ was cancelled(?: after [0-9.]+ seconds?)?(?:\.|: ".*)?\s*$', re.M
)
XCTEST_TOP = re.compile(
    r"Test Suite '(?:All tests|Selected tests)' (?:passed|failed) at [^\n]*\n"
    r"\s*Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?"
)
NO_MATCH = "No matching test cases were run"


def summarize(text):
    text = ANSI.sub("", text)
    st_total = st_failed = st_runs = 0
    for m in SWIFT_TESTING.finditer(text):
        st_runs += 1
        st_total += int(m.group(1))
        if m.group(3) == "failed":
            st_failed += 1
    st_skipped = len(SWIFT_TESTING_SKIPPED.findall(text)) + len(SWIFT_TESTING_CANCELLED.findall(text)) if st_runs else 0
    xc_total = xc_skipped = xc_failures = 0
    for m in XCTEST_TOP.finditer(text):
        xc_total += int(m.group(1))
        xc_skipped += int(m.group(2) or 0)
        xc_failures += int(m.group(3))
    return {
        "swift_testing_runs": st_runs,
        "swift_testing_tests": st_total,
        "swift_testing_skipped": st_skipped,
        "swift_testing_failed_runs": st_failed,
        "xctest_tests": xc_total,
        "xctest_skipped": xc_skipped,
        "xctest_failures": xc_failures,
        "no_match": NO_MATCH in text,
    }


def main(argv):
    brief = False
    if argv and argv[0] == "--brief":
        brief, argv = True, argv[1:]
    if len(argv) != 1:
        print("usage: swift_test_summary.py [--brief] <swift-test.log>", file=sys.stderr)
        return 2
    with open(argv[0], encoding="utf-8", errors="replace") as fh:
        s = summarize(fh.read())
    skipped = s["swift_testing_skipped"] + s["xctest_skipped"]
    executed = max(0, s["swift_testing_tests"] + s["xctest_tests"] - skipped)
    problems = []
    if s["no_match"]:
        problems.append("filter matched no tests ('No matching test cases were run')")
    if executed == 0:
        problems.append("zero tests executed (swift test exits 0 in this case; skipped and cancelled tests do not count)")
    if s["swift_testing_failed_runs"] or s["xctest_failures"]:
        problems.append("test failures reported")
    if brief:
        print(f"tests={executed} skipped={skipped}")
        return 0 if not problems else 1
    for p in problems:
        print(f"swift_test_summary: FAIL: {p}")
    print(
        "swift_test_summary: tests={} skipped={} (swift-testing={} in {} run(s), {} skipped; xctest={}, {} skipped)".format(
            executed, skipped, s["swift_testing_tests"], s["swift_testing_runs"], s["swift_testing_skipped"],
            s["xctest_tests"], s["xctest_skipped"],
        )
    )
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
