#!/usr/bin/env python3
"""Merge-time CLA checks over API data and raw git objects; never execute the head.

This detects missing provenance, not forged commit authorship. The authenticated PR
submitter's signature carries responsibility for the contribution. Deliberate bypasses
by a trusted maintainer (including crafted filesystem aliases) are outside this gate.
"""

import datetime
import json
import re
import subprocess
import sys
import unicodedata


class CheckError(Exception):
    pass


def run(*args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise CheckError(f"{args[0]} {' '.join(args[1:])} failed (exit {result.returncode})")
    return result.stdout


def records(data, source):
    if data and not data.endswith(b"\0"):
        raise CheckError(f"malformed {source}: truncated -z record")
    return data[:-1].split(b"\0") if data else []


def path_ok(path):
    return bool(path) and all(p not in (b"", b".", b"..") for p in path.split(b"/"))


def tree(ref):
    entries = {}
    for record in records(run("git", "ls-tree", "-r", "-z", ref), "ls-tree"):
        match = re.fullmatch(rb"(100644|100755|120000|160000) (blob|commit) ([0-9a-f]{40})\t(.+)", record, re.S)
        if not match:
            raise CheckError("malformed ls-tree -z record")
        mode, kind, oid, path = match.groups()
        if not path_ok(path) or path in entries or (mode == b"160000") != (kind == b"commit"):
            raise CheckError(f"malformed ls-tree entry: {path!r}")
        entries[path] = (mode, oid.decode("ascii"))
    return entries


def blob(entries, path):
    entry = entries.get(path)
    if entry is None or entry[0] not in (b"100644", b"100755"):
        raise CheckError(f"missing regular file {path!r}")
    return run("git", "cat-file", "blob", entry[1])


def changed_paths(base, head):
    parts = records(run("git", "diff", "--name-status", "-M", "-z", base, head), "diff")
    paths, i = [], 0
    while i < len(parts):
        status = parts[i]
        i += 1
        if not re.fullmatch(rb"[ADMT]|[RC](?:100|[0-9]{1,2})|M(?:100|[0-9]{1,2})", status):
            raise CheckError(f"malformed diff status: {status!r}")
        count = 2 if status[:1] in (b"R", b"C") else 1
        if i + count > len(parts) or any(not path_ok(p) for p in parts[i:i + count]):
            raise CheckError("malformed diff -z path record")
        paths.extend(parts[i:i + count])
        i += count
    return paths


def lists(entries):
    maintainers, bots, emails = set(), set(), set()
    for path, is_bot in ((b"cla/maintainers", False), (b"cla/bots", True)):
        for number, line in enumerate(blob(entries, path).decode("utf-8").splitlines(), 1):
            fields = line.split("#", 1)[0].split()
            if not fields:
                continue
            if not is_bot and len(fields) == 1 and re.fullmatch(r"[1-9][0-9]*", fields[0]):
                maintainers.add(int(fields[0]))
            elif is_bot and len(fields) == 3 and fields[0] == "account" and re.fullmatch(r"[1-9][0-9]*", fields[1]):
                bots.add(int(fields[1]))
            elif is_bot and len(fields) == 2 and fields[0] == "email" and re.fullmatch(r"[^\s<>@]+@[^\s<>@]+", fields[1]):
                emails.add(fields[1].casefold())
            else:
                raise CheckError(f"invalid {path.decode()} line {number}")
    return maintainers, bots, emails


def declaration(entries):
    cla = blob(entries, b"CLA.md")
    versions = re.findall(rb"^Version: ([^\r\n]+)$", cla, re.M)
    sections = cla.split(b"## How to sign\n")
    if len(versions) != 1 or len(sections) != 2:
        raise CheckError("CLA.md has no unambiguous Version / How to sign")
    templates = re.findall(rb"^```\n(.*?)^```[ \t]*$", sections[1], re.M | re.S)
    if len(templates) != 1:
        raise CheckError("CLA.md has no unambiguous fixed signing statement")
    template = templates[0]
    fields = {
        b"[FULL NAME]": rb"(?P<name>[^\r\n]+)",
        b"[GITHUB USER ID]": rb"(?P<id>[1-9][0-9]*)",
        b"[GITHUB LOGIN]": rb"(?P<login>[A-Za-z0-9][A-Za-z0-9-]*)",
        b"[CLA VERSION]": rb"(?P<version>[^\r\n]+)",
        b"[YYYY-MM-DD]": rb"(?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2})",
    }
    pattern = re.escape(template)
    for token, replacement in fields.items():
        if template.count(token) != 1:
            raise CheckError(f"CLA.md signing statement must contain exactly one {token!r}")
        pattern = pattern.replace(re.escape(token), replacement)
    return versions[0], re.compile(pattern)


def signature(entries, uid, version, statement):
    path = f"cla/signatures/{uid}.md".encode()
    entry = entries.get(path)
    if entry is None or entry[0] not in (b"100644", b"100755"):
        return "missing regular signature file"
    # An object read failure is fatal, never converted to an absent signature.
    # An editor that drops the final newline changes nothing the signer agreed to.
    match = statement.fullmatch(blob(entries, path).rstrip(b"\n") + b"\n")
    if not match:
        return "statement differs from CLA.md (only the five fields may change; use LF line endings)"
    if match["id"] != str(uid).encode():
        return "id inside signature differs from filename"
    if match["version"] != version:
        return f"CLA version differs from head Version: {version.decode()}"
    if not match["name"].strip() or match["name"].startswith(b"["):
        return "full name is empty or still a placeholder"
    try:
        datetime.date.fromisoformat(match["date"].decode())
    except ValueError:
        return "invalid signing date"
    return None


def collisions(entries):
    seen, errors = {}, []
    for path in entries:
        pieces = path.split(b"/")
        for depth in range(1, len(pieces) + 1):
            prefix = b"/".join(pieces[:depth])
            key = unicodedata.normalize("NFD", prefix.decode("utf-8")).casefold()
            previous = seen.setdefault(key, prefix)
            if previous != prefix:
                errors.append(f"⑤ conflicting head paths: {previous!r} / {prefix!r}")
    return sorted(set(errors))


def user_id(value):
    return value if type(value) is int and value > 0 else None


def api(endpoint, paginated=False):
    args = ["gh", "api"]
    if paginated:
        args += ["--paginate", "--slurp"]
    return json.loads(run(*args, endpoint))


def check(repo, pr, base, head):
    if not all(re.fullmatch(r"[0-9a-f]{40}", ref) for ref in (base, head)):
        raise CheckError("base and head must be pinned full commit ids")
    meta = api(f"repos/{repo}/pulls/{pr}")
    submitter = user_id(meta["user"]["id"])
    if submitter is None or meta["head"]["sha"] != head or meta["base"]["ref"] != "main":
        raise CheckError("PR metadata has no account id, head moved, or base is not main")
    count = meta["commits"]
    if type(count) is not int or count < 1 or count >= 250:
        raise CheckError(f"PR commits={count}: require a complete list below the API limit of 250")
    pages = api(f"repos/{repo}/pulls/{pr}/commits?per_page=100", paginated=True)
    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        raise CheckError("malformed paginated commit list")
    commits = [commit for page in pages for commit in page]
    if len(commits) != count:
        raise CheckError(f"PR commits={count}, API returned {len(commits)}: incomplete commit list")
    shas = [c["sha"] for c in commits]
    if any(not re.fullmatch(r"[0-9a-f]{40}", sha) for sha in shas) or len(set(shas)) != count or head not in shas:
        raise CheckError("commit list has invalid/duplicate ids or does not contain the pinned head")
    main_tree, head_tree = tree(base), tree(head)
    maintainers, bots, emails = lists(main_tree)
    # Exemptions come from main only, but a head list that would not parse would make every later
    # check fail, including the PR that repairs it.
    try:
        head_maintainers = lists(head_tree)[0]
    except CheckError as exc:
        raise CheckError(f"head allowlist would break later checks: {exc}")
    # Only a maintainer may change cla/maintainers, so a list without any current maintainer
    # would leave no account able to repair it.
    if not head_maintainers & maintainers:
        raise CheckError("head cla/maintainers keeps none of the current maintainers")
    version, statement = declaration(head_tree)
    paths = changed_paths(base, head)
    errors = []
    exempt = maintainers | bots
    cache = {}

    def signed(uid, other):
        for label, entries in (("main", main_tree), ("head", head_tree)) if other else (("head", head_tree),):
            key = (label, uid)
            if key not in cache:
                cache[key] = signature(entries, uid, version, statement)
            if cache[key]:
                return f"{label} cla/signatures/{uid}.md: {cache[key]}"
        return None

    # ① GitHub authenticates this id; logins are informational, never identity keys.
    if submitter not in exempt:
        reason = signed(submitter, False)
        if reason:
            errors.append(f"① PR account {meta['user'].get('login', '?')} (id {submitter}) lacks valid signature: {reason}")
    if submitter not in maintainers:
        own = f"cla/signatures/{submitter}.md".encode()
        protected = {b"CLA.md", b"cla/maintainers", b"cla/bots", b"scripts/cla-check", b"scripts/land"}
        for path in sorted(set(paths)):
            # ② Renames contribute both paths, and type changes are changes too.
            if path.startswith(b"cla/signatures/") and path != own:
                errors.append(f"② account id {submitter} changed another signature: {path!r}")
            # ④ Bots are not maintainers; new allowlist entries cannot authorize this PR.
            if path in protected or path.startswith(b"scripts/lib/"):
                errors.append(f"④ non-maintainer id {submitter} changed protected path: {path!r}")

    def contributor(uid, context):
        if uid is None:
            errors.append(f"③ {context}: cannot map to a GitHub account; use a GitHub-linked author email / <id>+<login>@users.noreply.github.com coauthor email, or remove the attribution")
        elif uid not in exempt:
            reason = signed(uid, uid != submitter)
            if reason:
                errors.append(f"③ {context} (id {uid}) lacks valid signature: {reason}")

    # ③ Even a maintainer or bot PR must account for every author and coauthor.
    for commit in commits:
        sha = commit["sha"]
        author = commit["author"]
        contributor(user_id(author.get("id")) if isinstance(author, dict) else None, f"commit {sha} author")
        message = commit["commit"]["message"]
        if not isinstance(message, str):
            raise CheckError(f"commit {sha} has no readable message")
        # As git interpret-trailers reads them: the last paragraph before a `---` patch separator,
        # so a quoted line earlier in the body is not one.
        body = re.split(r"^---(?:[ \t].*)?$", message, maxsplit=1, flags=re.M)[0]
        for line in body.strip().split("\n\n")[-1].splitlines():
            trailer = re.match(r"\s*co-authored-by\s*:(.*)$", line, re.I)
            if not trailer:
                continue
            attribution = trailer[1].strip()
            address = re.fullmatch(r".+?\s*<([^<>\s]+)>\s*", attribution)
            email = address[1] if address else ""
            if email.casefold() in emails:
                continue
            mapped = re.fullmatch(r"([1-9][0-9]*)\+[A-Za-z0-9][A-Za-z0-9-]*(?:\[bot\])?@users\.noreply\.github\.com", email, re.I)
            contributor(int(mapped[1]) if mapped else None, f"commit {sha} Co-authored-by {attribution!r}")
    # ⑤ Use the entire head tree, including every directory prefix.
    errors.extend(collisions(head_tree))
    return errors


def main():
    if len(sys.argv) != 5:
        print("usage: scripts/cla-check <repo> <pr> <base-sha> <head-sha>", file=sys.stderr)
        return 2
    try:
        errors = check(*sys.argv[1:])
    except (CheckError, OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        errors = [str(exc)]
    for error in errors:
        print(f"cla-check: FAIL {error}")
    if errors:
        return 1
    print(f"cla-check: ok checks ①–⑤ on {sys.argv[4]} (base {sys.argv[3]})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
