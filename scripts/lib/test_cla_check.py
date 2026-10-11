#!/usr/bin/env python3
"""Drive the real checker with strict gh/git stubs, including malformed raw -z data.

No git repository is created or modified. A --checker override is only for running
mutation checks on temporary copies of the toolchain, not a production bypass.
"""

import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts/cla-check"
if len(sys.argv) > 1 and sys.argv[1] == "--checker":
    CHECKER = Path(sys.argv[2]).resolve()
    del sys.argv[1:3]
BASE, HEAD = "a" * 40, "b" * 40
OWNER, USER, OTHER, BOT = 1209636, 123, 456, 49699333
CLA = (ROOT / "CLA.md").read_bytes()
TEMPLATE = re.search(rb"^```\n(.*?)^```", CLA.split(b"## How to sign\n")[1], re.M | re.S)[1]
VERSION = re.search(rb"^Version: (.+)$", CLA, re.M)[1]


def signature(uid=USER, **overrides):
    fields = {"FULL NAME": "Test Person", "GITHUB USER ID": str(uid),
              "GITHUB LOGIN": "someone", "CLA VERSION": VERSION.decode(), "YYYY-MM-DD": "2026-10-11"}
    fields.update(overrides)
    result = TEMPLATE
    for field, value in fields.items():
        result = result.replace(f"[{field}]".encode(), value.encode())
    return result


def sigpath(uid):
    return f"cla/signatures/{uid}.md".encode()


class Fixture:
    def __init__(self):
        self.main = {b"CLA.md": CLA, b"cla/maintainers": b"1209636 # owner\n",
                     b"cla/bots": (ROOT / "cla/bots").read_bytes(), b"cla/signatures/.gitkeep": b"",
                     b"scripts/land": b"trusted entry", b"scripts/lib/helper.py": b"trusted helper"}
        self.head = {**self.main, sigpath(USER): signature()}
        self.meta = {"user": {"id": USER, "login": "renamed-login"}, "head": {"sha": HEAD},
                     "base": {"ref": "main"}, "commits": 1}
        self.commits = [{"sha": HEAD, "author": {"id": USER}, "commit": {"message": "A contribution"}}]
        self.pages = None
        self.diff = b"A\0" + sigpath(USER) + b"\0"
        self.overrides = {}

    def author(self, uid):
        self.commits[0]["author"] = {"id": uid} if uid else None

    def submitter(self, uid):
        self.meta["user"]["id"] = uid
        self.author(uid)

    def coauthor(self, attribution, spelling="Co-authored-by"):
        # Consecutive trailers form one block, as git writes them.
        message = self.commits[0]["commit"]["message"]
        separator = "\n" if "\n\n" in message else "\n\n"
        self.commits[0]["commit"]["message"] = f"{message}{separator}{spelling}: {attribution}"

    def signed_other(self):
        self.main[sigpath(OTHER)] = self.head[sigpath(OTHER)] = signature(OTHER)

    def commands(self):
        commands = {}

        def put(args, content):
            commands[json.dumps(args)] = [0, base64.b64encode(content).decode()]

        for ref, entries in ((BASE, self.main), (HEAD, self.head)):
            rows = []
            for path, content in entries.items():
                mode, content = content if isinstance(content, tuple) else (b"100644", content)
                oid = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
                rows.append(mode + b" blob " + oid.encode() + b"\t" + path + b"\0")
                put(["git", "cat-file", "blob", oid], content)
            put(["git", "ls-tree", "-r", "-z", ref], b"".join(rows))
        put(["git", "diff", "--name-status", "-M", "-z", BASE, HEAD], self.diff)
        put(["gh", "api", "repos/owner/parlance/pulls/7"], json.dumps(self.meta).encode())
        put(["gh", "api", "--paginate", "--slurp", "repos/owner/parlance/pulls/7/commits?per_page=100"],
            json.dumps(self.pages if self.pages is not None else [self.commits]).encode())
        commands.update(self.overrides)
        return commands

    def override(self, args, data=b"", rc=0):
        self.overrides[json.dumps(args)] = [rc, base64.b64encode(data).decode()]


STUB = '''#!/usr/bin/env python3
import base64, json, os, pathlib, sys
args = [pathlib.Path(sys.argv[0]).name, *sys.argv[1:]]
with open(os.environ["CLA_TEST_CALLS"], "a") as log:
    log.write(json.dumps(args) + "\\n")
commands = json.loads(pathlib.Path(os.environ["CLA_TEST_COMMANDS"]).read_text())
key = json.dumps(args)
if key not in commands:
    sys.exit("unexpected stub command: " + key)
rc, data = commands[key]
sys.stdout.buffer.write(base64.b64decode(data))
sys.exit(rc)
'''


class CheckTests(unittest.TestCase):
    def run_fixture(self, fixture, expected=None, command=None, env_extra=None):
        with tempfile.TemporaryDirectory(prefix="pl-cla-test.") as temp:
            directory = Path(temp)
            for name in ("gh", "git"):
                p = directory / name
                p.write_text(STUB)
                p.chmod(0o755)
            (directory / "commands.json").write_text(json.dumps(fixture.commands()))
            env = dict(os.environ, PATH=f"{temp}:{os.environ['PATH']}",
                       CLA_TEST_COMMANDS=str(directory / "commands.json"), CLA_TEST_CALLS=str(directory / "calls"),
                       TMPDIR=temp)
            env.update(env_extra or {})
            result = subprocess.run(command or ["/bin/bash", str(CHECKER), "owner/parlance", "7", BASE, HEAD],
                                    capture_output=True, text=True, env=env)
            output = result.stdout + result.stderr
            if expected is None:
                self.assertEqual(result.returncode, 0, output)
                self.assertIn("cla-check: ok", output)
            else:
                self.assertNotEqual(result.returncode, 0, output)
                self.assertIn(expected, output)
            calls = (directory / "calls").read_text() if (directory / "calls").exists() else ""
            self.assertFalse(list(directory.glob("pl-land.*")), "trusted temporary directory leaked")
            return calls, output

    def test_valid_signature_and_renamed_login(self):
        self.run_fixture(Fixture())
        f = Fixture(); f.head[sigpath(USER)] = signature().rstrip(b"\n")
        self.run_fixture(f)

    def test_signature_failures(self):
        for label, content, reason in [
            ("word", signature().replace(b"agree", b"agreed"), "statement differs"),
            ("id", signature(OTHER), "id inside signature"),
            ("version", signature(**{"CLA VERSION": "0.0"}), "CLA version differs"),
            ("date", signature(**{"YYYY-MM-DD": "2026-02-30"}), "invalid signing date"),
            ("extra", signature() + b"extra\n", "statement differs"),
            ("crlf", signature().replace(b"\n", b"\r\n"), "use LF line endings"),
            ("symlink", (b"120000", b"../../CLA.md"), "missing regular signature"),
        ]:
            with self.subTest(label=label):
                f = Fixture(); f.head[sigpath(USER)] = content
                self.run_fixture(f, reason)
        f = Fixture(); del f.head[sigpath(USER)]
        self.run_fixture(f, "① PR account renamed-login (id 123)")
        f = Fixture(); f.meta["user"]["id"] = OTHER; f.author(OTHER)
        self.run_fixture(f, "① PR account renamed-login (id 456)")

    def test_exempt_submitters_and_authors(self):
        for uid in (OWNER, BOT, 199175422, 41898282):
            with self.subTest(uid=uid):
                f = Fixture(); f.submitter(uid); f.diff = b""; f.head.pop(sigpath(USER))
                self.run_fixture(f)
                f = Fixture(); f.author(uid)
                self.run_fixture(f)

    def test_other_signature_changes(self):
        for status in (b"A", b"M", b"D", b"T", b"R100"):
            with self.subTest(status=status):
                f = Fixture(); f.diff = status + b"\0" + sigpath(OTHER) + b"\0"
                if status == b"R100":
                    f.diff += sigpath(USER) + b"\0"
                self.run_fixture(f, "② account id 123 changed another signature")
                f.submitter(OWNER)
                self.run_fixture(f)
        f = Fixture(); f.diff = b"R100\0" + sigpath(USER) + b"\0" + sigpath(OTHER) + b"\0"
        self.run_fixture(f, "②")

    def test_author_signatures_in_both_trees(self):
        for submitter in (USER, OWNER, BOT):
            with self.subTest(submitter=submitter):
                f = Fixture(); f.submitter(submitter); f.author(OTHER); f.diff = b""
                self.run_fixture(f, "③ commit " + HEAD + " author (id 456)")
                f.head[sigpath(OTHER)] = signature(OTHER)
                self.run_fixture(f, "main cla/signatures/456.md")
                f.signed_other()
                self.run_fixture(f)
                del f.head[sigpath(OTHER)]
                self.run_fixture(f, "head cla/signatures/456.md")
                f.head[sigpath(OTHER)] = signature(OTHER).replace(b"agree", b"agreed")
                self.run_fixture(f, "head cla/signatures/456.md: statement differs")

    def test_version_upgrade_and_multiple_coauthors(self):
        f = Fixture(); f.submitter(OWNER); f.diff = b"M\0CLA.md\0"
        f.head[b"CLA.md"] = CLA.replace(b"Version: " + VERSION, b"Version: 2.0")
        self.run_fixture(f)
        f.signed_other(); f.author(OTHER)
        self.run_fixture(f, "main cla/signatures/456.md: CLA version differs")
        f.main[sigpath(OTHER)] = f.head[sigpath(OTHER)] = signature(OTHER, **{"CLA VERSION": "2.0"})
        self.run_fixture(f)
        f = Fixture(); f.coauthor("Claude <noreply@anthropic.com>")
        f.coauthor("Someone <456+login@users.noreply.github.com>")
        self.run_fixture(f, "③")
        f.signed_other(); self.run_fixture(f)

    def test_unmapped_author(self):
        f = Fixture(); f.author(None)
        self.run_fixture(f, "cannot map to a GitHub account")

    def test_coauthor_mapping(self):
        for spelling in ("Co-authored-by", "Co-Authored-By", "CO-AUTHORED-BY"):
            with self.subTest(spelling=spelling):
                f = Fixture(); f.coauthor("Someone <456+old-login@users.noreply.github.com>", spelling)
                self.run_fixture(f, "Co-authored-by 'Someone <456+old-login@users.noreply.github.com>' (id 456)")
                f.head[sigpath(OTHER)] = signature(OTHER)
                self.run_fixture(f, "main cla/signatures/456.md")
                f.signed_other()
                self.run_fixture(f)
                f.head.pop(sigpath(OTHER))
                self.run_fixture(f, "head cla/signatures/456.md")
        for attribution in ("Someone <personal@example.com>", "Someone <login@users.noreply.github.com>", "broken"):
            f = Fixture(); f.coauthor(attribution)
            self.run_fixture(f, "cannot map to a GitHub account")
        for uid in (USER, OWNER):
            f = Fixture(); f.coauthor(f"Someone <{uid}+login@users.noreply.github.com>")
            self.run_fixture(f)
        # GitHub's own form for a bot co-author, as "Commit suggestion" writes it.
        f = Fixture(); f.coauthor(f"dependabot[bot] <{BOT}+dependabot[bot]@users.noreply.github.com>")
        self.run_fixture(f)

    def test_head_allowlists_must_parse(self):
        f = Fixture(); f.submitter(OWNER); f.diff = b""; f.head.pop(sigpath(USER))
        f.head[b"cla/maintainers"] = b"not-an-id\n"
        self.run_fixture(f, "head allowlist would break later checks")
        f = Fixture(); f.submitter(OWNER); f.diff = b""; f.head.pop(sigpath(USER))
        del f.head[b"cla/bots"]
        self.run_fixture(f, "head allowlist would break later checks")
        for content in (b"", b"1209637 # typo\n"):
            f = Fixture(); f.submitter(OWNER); f.diff = b""; f.head.pop(sigpath(USER))
            f.head[b"cla/maintainers"] = content
            self.run_fixture(f, "keeps none of the current maintainers")

    def test_only_the_trailer_block_counts(self):
        f = Fixture()
        f.commits[0]["commit"]["message"] = "Quote\n\nCo-authored-by: Someone <personal@example.com>\n\nMore text"
        self.run_fixture(f)
        f = Fixture(); f.coauthor("Someone <personal@example.com>")
        self.run_fixture(f, "cannot map to a GitHub account")
        f = Fixture(); f.coauthor("Someone <personal@example.com>")
        f.commits[0]["commit"]["message"] += "\n\n---\nNotes after the patch separator"
        self.run_fixture(f, "cannot map to a GitHub account")

    def test_bot_email_from_main_only(self):
        for submitter in (USER, OWNER, BOT):
            f = Fixture(); f.submitter(submitter); f.diff = b""
            f.coauthor("Claude <NOREPLY@ANTHROPIC.COM>", "Co-Authored-By")
            self.run_fixture(f)
            f.main[b"cla/bots"] = b""
            # Bot still needs exemption as submitter to isolate the email check.
            if submitter == BOT:
                f.main[b"cla/bots"] = b"account 49699333 dependabot[bot]\n"
            self.run_fixture(f, "cannot map to a GitHub account")
        f = Fixture(); f.submitter(OWNER); f.diff = b""
        f.head[b"cla/bots"] += b"email new@example.com\n"
        f.coauthor("New AI <new@example.com>")
        self.run_fixture(f, "cannot map")

    def test_head_lists_cannot_exempt_accounts(self):
        for path, extra in ((b"cla/maintainers", b"123\n"), (b"cla/bots", b"account 123 new-bot\n")):
            f = Fixture(); f.head[path] += extra; del f.head[sigpath(USER)]
            self.run_fixture(f, "①")

    def test_protected_paths(self):
        paths = [b"CLA.md", b"cla/maintainers", b"cla/bots", b"scripts/land", b"scripts/cla-check",
                 b"scripts/lib/a.py", 'scripts/lib/含 空格".py'.encode()]
        for path in paths:
            for status in (b"A", b"M", b"D", b"T", b"R100"):
                with self.subTest(path=path, status=status):
                    f = Fixture(); f.diff = status + b"\0" + path + b"\0"
                    if status == b"R100":
                        f.diff += b"elsewhere\0"
                    self.run_fixture(f, "④ non-maintainer id 123 changed protected path: " + repr(path))
                    f.submitter(OWNER)
                    self.run_fixture(f)
        f = Fixture(); f.submitter(BOT); f.diff = b"M\0cla/maintainers\0"
        self.run_fixture(f, "④ non-maintainer id 49699333")
        f = Fixture(); f.diff = b"A\0ordinary\0" * 3001 + b"T\0scripts/land\0"
        self.run_fixture(f, "④")
        f = Fixture(); f.diff = b"R100\0old\0scripts/land\0"
        self.run_fixture(f, "④")

    def test_full_tree_unicode_and_directory_conflicts(self):
        for path in ("scripts/Land", "Scripts/lib/other.py", "Scripts", "ſcripts/land", "cla/Signatures/456.md"):
            for uid in (USER, OWNER):
                with self.subTest(path=path, uid=uid):
                    f = Fixture(); f.submitter(uid); f.diff = b""
                    f.head[path.encode()] = (b"120000", b"anything") if path == "Scripts" else b"new"
                    self.run_fixture(f, "⑤ conflicting head paths")
        for pair in (("café", "cafe\u0301"), ("café/a", "cafe\u0301/b"), ("Straße/x", "STRASSE/y")):
            f = Fixture(); f.head.update({p.encode(): b"new" for p in pair})
            self.run_fixture(f, "⑤ conflicting head paths")
        f = Fixture(); f.head[b"scripts/library/x"] = b"new"
        self.run_fixture(f)

    def test_api_pagination_and_failure(self):
        f = Fixture()
        f.commits = [{"sha": f"{i:040x}", "author": {"id": OWNER}, "commit": {"message": "x"}} for i in range(1, 102)] + f.commits
        f.meta["commits"] = len(f.commits)
        f.pages = [f.commits[:100], f.commits[100:]]
        self.run_fixture(f)
        f.commits[0]["author"] = {"id": OTHER}
        self.run_fixture(f, "③ commit " + f.commits[0]["sha"])
        f.commits[0]["author"] = {"id": OWNER}
        f.meta["commits"] += 1
        self.run_fixture(f, "incomplete commit list")
        f.meta["commits"] = 250
        self.run_fixture(f, "API limit of 250")
        for args in (["gh", "api", "repos/owner/parlance/pulls/7"],
                     ["gh", "api", "--paginate", "--slurp", "repos/owner/parlance/pulls/7/commits?per_page=100"]):
            f = Fixture(); f.override(args, rc=1)
            self.run_fixture(f, "failed (exit 1)")
            f.override(args, b"{bad json")
            self.run_fixture(f, "cla-check: FAIL")
        f = Fixture(); f.meta["head"]["sha"] = "c" * 40
        self.run_fixture(f, "head moved")
        f = Fixture(); f.pages = [f.commits, f.commits]; f.meta["commits"] = 2
        self.run_fixture(f, "duplicate ids")
        f = Fixture(); f.commits[0]["sha"] = "d" * 40
        self.run_fixture(f, "does not contain the pinned head")
        # GitHub does not document the list's order: the head need not come last.
        f = Fixture(); f.meta["commits"] = 2
        f.commits.append({"sha": "e" * 40, "author": {"id": OWNER}, "commit": {"message": "Earlier"}})
        self.run_fixture(f)
        f = Fixture(); f.pages = [{}]
        self.run_fixture(f, "malformed paginated")

    def test_git_reads_and_malformed_records(self):
        diff = ["git", "diff", "--name-status", "-M", "-z", BASE, HEAD]
        tree = ["git", "ls-tree", "-r", "-z", HEAD]
        for args in (diff, tree, ["git", "ls-tree", "-r", "-z", BASE]):
            f = Fixture(); f.override(args, rc=128)
            self.run_fixture(f, "failed (exit 128)")
        for data in (b"R100\0old\0", b"M\0truncated", b"M\0\0", b"X\0path\0", b"R101\0old\0new\0"):
            f = Fixture(); f.override(diff, data)
            self.run_fixture(f, "malformed diff")
        for data in (b"100644 blob " + b"c" * 40 + b"\tfile", b"bad\0", b"100644 blob " + b"c" * 40 + b"\t\0"):
            f = Fixture(); f.override(tree, data)
            self.run_fixture(f, "malformed ls-tree")
        f = Fixture()
        cat = next(json.loads(k) for k in f.commands() if 'cat-file' in k)
        f.override(cat, rc=128)
        self.run_fixture(f, "failed (exit 128)")

    def test_raw_bootstrap_and_argument_marker(self):
        # A base toolchain with a tiny land delegate proves that only extracted bytes run.
        # Local helpers are never imported by the entry bootstrap. No archive/checkout is stubbed.
        with tempfile.TemporaryDirectory(prefix="pl-cla-entry.") as temp:
            local = Path(temp) / "scripts"
            local.mkdir(); (local / "lib").mkdir()
            (local / "land").write_bytes((ROOT / "scripts/land").read_bytes())
            (local / "cla-check").write_text("exit 0 # untrusted local replacement\n")
            (local / "lib/cla_check.py").write_text("raise Exception('untrusted helper ran')\n")
            f = Fixture()
            delegate = b'''#!/bin/bash
[ "$1" = --land-from-base ] && [ "$2" = ''' + BASE.encode() + b''' ] || exit 99
shift 2
[ "$*" = '7 --dry-run' ] || exit 98
here=$(cd "$(dirname "$0")" && pwd)
/bin/bash "$here/cla-check" owner/parlance 7 ''' + BASE.encode() + b" " + HEAD.encode() + b"\n"
            tool_files = {"scripts/land": delegate, "scripts/cla-check": CHECKER.read_bytes(),
                          "scripts/lib/cla_check.py": (CHECKER.parent / "lib/cla_check.py").read_bytes(),
                          "scripts/lib/pr_refs.py": b"# fixture\n", "scripts/lib/check_pr_title.py": b"# fixture\n"}
            rows = []
            for path, content in tool_files.items():
                oid = hashlib.sha1(content).hexdigest()
                rows.append(f"100644 blob {oid}\t{path}".encode() + b"\0")
                f.override(["git", "cat-file", "blob", oid], content)
            fetch = ["git", "fetch", "-q", "origin", "+refs/heads/main:refs/remotes/origin/main"]
            listing = ["git", "ls-tree", "-r", "-z", BASE, "--", "scripts/land", "scripts/cla-check", "scripts/lib/"]
            f.override(["git", "rev-parse", "--show-toplevel"], temp.encode() + b"\n")
            f.override(fetch)
            f.override(["git", "rev-parse", "--verify", "refs/remotes/origin/main"], BASE.encode() + b"\n")
            f.override(listing, b"".join(rows))
            command = ["/bin/bash", str(local / "land"), "7", "--dry-run"]
            calls, _ = self.run_fixture(f, command=command,
                                        env_extra={"BASE_TIP": BASE, "LAND_FROM_BASE": "1", "PARLANCE_LAND_FROM_BASE": "1"})
            self.assertEqual(calls.count(json.dumps(fetch)), 1)
            f.author(OTHER)
            self.run_fixture(f, "③", command=command)
            f.override(listing, b"".join(rows[:-1]))
            self.run_fixture(f, "base toolchain is incomplete", command=command)
            f.override(listing, b"".join(rows)[:-1])
            self.run_fixture(f, "truncated tool tree", command=command)
            f.override(listing, rc=128)
            self.run_fixture(f, "cannot load complete raw base toolchain", command=command)
            f.override(listing, b"".join(rows))
            f.override(["git", "cat-file", "blob", hashlib.sha1(delegate).hexdigest()], rc=128)
            self.run_fixture(f, "cannot load complete raw base toolchain", command=command)
            f.override(fetch, rc=128)
            self.run_fixture(f, "cannot fetch main", command=command)


if __name__ == "__main__":
    unittest.main()
