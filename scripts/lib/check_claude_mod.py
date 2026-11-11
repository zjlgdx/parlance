#!/usr/bin/env python3
"""Structural check of the Claude Code mod and its marketplace (run by `scripts/gate harness`).

Users install the mod from the public repository's marketplace, so a broken manifest, a module path that
moved, or a marketplace entry that no longer points at the plugin breaks every install. `claude plugin
validate` reads these files the same way, but neither CI image has `claude`, and the public repository runs
this same gate; so the gate checks the structure itself and leaves the hooks module's code to `claude plugin
validate` and `claude plugin test` (run by hand, see integrations/claude-code/README.md).

The marketplace is `public/.claude-plugin/marketplace.json` in the private repository and
`.claude-plugin/marketplace.json` in the exported public snapshot; exactly one of them must exist. Its plugin
sources are read relative to the public repository's root, which is this repository's root in both layouts
(scripts/export-public keeps `integrations/claude-code/` at the same path).

Checks, each fail-closed:
- the marketplace is a JSON object with a `name`, an `owner.name` and a non-empty `plugins` list, and lists
  the plugin `parlance`;
- each entry's `source` is a relative `./` path, without `..`, to a folder holding
  `.claude-plugin/plugin.json`, whose `name` equals the entry's name;
- plugin.json is a JSON object with a lowercase `name` (letters, digits, `-`; at most 64), a `version` and a
  `description`; a `types` path, when given, names an existing file inside the plugin;
- `hooks/hooks.json` is a JSON object whose `modules` lists exactly one relative path to an existing module
  file inside `hooks/`, with a suffix the engine loads, that exports `register`.

A folder reached through a symbolic link is a known limit: the check reads paths, not where links lead.

Usage: check_claude_mod.py [root]  |  check_claude_mod.py --self-test
Exit codes: 0 ok, 1 problems or a wrong self-test verdict, 2 usage error.
"""
import json
import os
import posixpath
import re
import shutil
import sys
import tempfile

MARKETPLACES = ("public/.claude-plugin/marketplace.json", ".claude-plugin/marketplace.json")
PLUGIN = "parlance"
NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
MODULE_SUFFIXES = (".ts", ".tsx", ".jsx", ".js", ".mjs", ".cjs", ".mts", ".cts")
REGISTER = re.compile(r"^\s*export\s+(?:const|let|var|(?:async\s+)?function)\s+register\b", re.M)


def load(root, path, problems):
    """The JSON object at root/path, or None after reporting why not."""
    try:
        with open(os.path.join(root, path), encoding="utf-8") as fh:
            value = json.load(fh)
    except FileNotFoundError:
        problems.append(f"{path}: missing")
        return None
    except (OSError, ValueError) as exc:
        problems.append(f"{path}: not valid JSON ({exc})")
        return None
    if not isinstance(value, dict):
        problems.append(f"{path}: not a JSON object")
        return None
    return value


def text(value):
    return isinstance(value, str) and value.strip() != ""


def relative(path):
    """`path` normalised under its base, or None when it is absolute or climbs out with `..`."""
    if not isinstance(path, str) or path.startswith("/") or "\\" in path or ".." in path.split("/"):
        return None
    return posixpath.normpath(path)


def check_plugin(root, folder, name, problems):
    manifest_path = posixpath.join(folder, ".claude-plugin/plugin.json")
    manifest = load(root, manifest_path, problems)
    if manifest is None:
        return
    if not (isinstance(manifest.get("name"), str) and NAME.match(manifest["name"])):
        problems.append(f"{manifest_path}: `name` must be lowercase letters, digits and `-`, at most 64")
    elif manifest["name"] != name:
        problems.append(f"{manifest_path}: `name` is {manifest['name']!r}, the marketplace lists {name!r}")
    for key in ("version", "description"):
        if not text(manifest.get(key)):
            problems.append(f"{manifest_path}: `{key}` must be a non-empty string")
    if "types" in manifest:
        types = relative(manifest["types"])
        if types is None or not os.path.isfile(os.path.join(root, folder, types)):
            problems.append(f"{manifest_path}: `types` must name a file inside the plugin")

    hooks_path = posixpath.join(folder, "hooks/hooks.json")
    hooks = load(root, hooks_path, problems)
    if hooks is None:
        return
    modules = hooks.get("modules")
    if not (isinstance(modules, list) and len(modules) == 1):
        problems.append(f"{hooks_path}: `modules` must list exactly one hooks module")
        return
    module = relative(modules[0])
    if module is None:
        problems.append(f"{hooks_path}: the module path must be relative to hooks/, without `..`")
        return
    module_path = posixpath.join(folder, "hooks", module)
    if not module_path.endswith(MODULE_SUFFIXES):
        problems.append(f"{module_path}: a hooks module is named {', '.join(MODULE_SUFFIXES)}")
    try:
        with open(os.path.join(root, module_path), encoding="utf-8") as fh:
            source = fh.read()
    except OSError:
        problems.append(f"{module_path}: missing (named by {hooks_path})")
        return
    if not REGISTER.search(source):
        problems.append(f"{module_path}: does not export `register`")


def check(root):
    problems = []
    found = [path for path in MARKETPLACES if os.path.exists(os.path.join(root, path))]
    if len(found) != 1:
        problems.append(
            "expected exactly one marketplace, " + " or ".join(MARKETPLACES) + f"; found {len(found)}"
        )
        return problems
    path = found[0]
    market = load(root, path, problems)
    if market is None:
        return problems
    if not text(market.get("name")):
        problems.append(f"{path}: `name` must be a non-empty string")
    owner = market.get("owner")
    if not (isinstance(owner, dict) and text(owner.get("name"))):
        problems.append(f"{path}: `owner.name` must be a non-empty string")
    plugins = market.get("plugins")
    if not (isinstance(plugins, list) and plugins):
        problems.append(f"{path}: `plugins` must be a non-empty list")
        return problems
    names = []
    for index, entry in enumerate(plugins):
        where = f"{path}: plugins[{index}]"
        if not (isinstance(entry, dict) and text(entry.get("name"))):
            problems.append(f"{where}: needs a `name`")
            continue
        names.append(entry["name"])
        source = entry.get("source")
        folder = relative(source) if isinstance(source, str) and source.startswith("./") else None
        if folder is None or folder == ".":
            problems.append(f"{where}: `source` must be a ./ path to the plugin's folder, without `..`")
            continue
        if not os.path.isfile(os.path.join(root, folder, ".claude-plugin/plugin.json")):
            problems.append(f"{where}: `source` {source!r} is not a plugin folder (no .claude-plugin/plugin.json)")
            continue
        check_plugin(root, folder, entry["name"], problems)
    if PLUGIN not in names:
        problems.append(f"{path}: does not list the plugin {PLUGIN!r}")
    return problems


# --- self-test: a complete mod in both layouts must pass, each mutant must fail -----------------------------

MARKET = {"name": "parlance", "owner": {"name": "zjlgdx"}, "plugins": [{"name": "parlance", "source": "./integrations/claude-code"}]}
MANIFEST = {"name": "parlance", "version": "0.1.0", "description": "Explains replies.", "types": "./types/index.d.ts"}
FILES = {
    "integrations/claude-code/.claude-plugin/plugin.json": MANIFEST,
    "integrations/claude-code/hooks/hooks.json": {"modules": ["./register.tsx"]},
    "integrations/claude-code/hooks/register.tsx": "export const register: Register = on => {}\n",
    "integrations/claude-code/types/index.d.ts": "export type ParlanceView = {}\n",
}


def build(root, layout, change=None):
    files = dict(FILES)
    files[layout] = MARKET
    if change:
        change(files)
    for path, body in files.items():
        if body is None:
            continue
        full = os.path.join(root, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as fh:
            fh.write(body if isinstance(body, str) else json.dumps(body))


def edit(path, **fields):
    def change(files):
        files[path] = {**files[path], **fields}
    return change


def setting(path, body):
    def change(files):
        files[path] = body
    return change


def self_test():
    private, public = MARKETPLACES
    plugin_json = "integrations/claude-code/.claude-plugin/plugin.json"
    hooks_json = "integrations/claude-code/hooks/hooks.json"
    module = "integrations/claude-code/hooks/register.tsx"
    cases = [
        ("private layout", private, None, None),
        ("public layout", public, None, None),
        ("register as a function", private, setting(module, "export async function register(on) {}\n"), None),
        ("no marketplace", private, setting(private, None), "found 0"),
        ("both marketplaces", private, setting(public, MARKET), "found 2"),
        ("marketplace not JSON", private, setting(private, "{ nope"), "not valid JSON"),
        ("marketplace a list", private, setting(private, []), "not a JSON object"),
        ("marketplace without owner", private, setting(private, {k: v for k, v in MARKET.items() if k != "owner"}), "owner.name"),
        ("no plugins", private, edit(private, plugins=[]), "non-empty list"),
        ("parlance not listed", private, edit(private, plugins=[{"name": "other", "source": "./integrations/claude-code"}]), "does not list"),
        ("source at the parent folder", private, edit(private, plugins=[{"name": "parlance", "source": "./integrations"}]), "not a plugin folder"),
        ("source climbing out", private, edit(private, plugins=[{"name": "parlance", "source": "./x/../../claude-code"}]), "without `..`"),
        ("source absolute", private, edit(private, plugins=[{"name": "parlance", "source": "/integrations/claude-code"}]), "./ path"),
        ("source a GitHub object", private, edit(private, plugins=[{"name": "parlance", "source": {"source": "github"}}]), "./ path"),
        ("plugin.json missing", private, setting(plugin_json, None), "not a plugin folder"),
        ("plugin.json not JSON", private, setting(plugin_json, "{"), "not valid JSON"),
        ("plugin name mismatch", private, edit(plugin_json, name="parlance-mod"), "the marketplace lists"),
        ("plugin name not lowercase", private, edit(plugin_json, name="Parlance"), "lowercase"),
        ("plugin without version", private, edit(plugin_json, version=""), "`version`"),
        ("types file missing", private, edit(plugin_json, types="./types/gone.d.ts"), "`types`"),
        ("hooks.json missing", private, setting(hooks_json, None), "hooks.json: missing"),
        ("hooks.json not JSON", private, setting(hooks_json, "modules"), "not valid JSON"),
        ("no modules", private, setting(hooks_json, {}), "exactly one"),
        ("two modules", private, setting(hooks_json, {"modules": ["./register.tsx", "./more.tsx"]}), "exactly one"),
        ("module missing", private, setting(hooks_json, {"modules": ["./gone.tsx"]}), "missing (named by"),
        ("module outside hooks", private, setting(hooks_json, {"modules": ["../types/index.d.ts"]}), "without `..`"),
        ("module of another kind", private, setting(hooks_json, {"modules": ["./register.json"]}), "a hooks module is named"),
        ("module without register", private, setting(module, "export const other = 1\n"), "does not export `register`"),
    ]
    failures = 0
    for name, layout, change, why in cases:
        root = tempfile.mkdtemp(prefix="pl-claude-mod.")
        try:
            build(root, layout, change)
            problems = check(root)
        finally:
            shutil.rmtree(root)
        ok = not problems if why is None else any(why in p for p in problems)
        if not ok:
            failures += 1
            wanted = "no problem" if why is None else f"a problem containing {why!r}"
            print(f"check_claude_mod: FAIL self-test {name}: expected {wanted}, got {problems}")
    if failures:
        print(f"check_claude_mod: self-test: {failures} wrong verdict(s) of {len(cases)} cases")
        return 1
    print(f"check_claude_mod: self-test ok ({len(cases)} cases)")
    return 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    if len(argv) > 1 or (argv and argv[0].startswith("-")):
        print("usage: check_claude_mod.py [root] | --self-test", file=sys.stderr)
        return 2
    problems = check(argv[0] if argv else ".")
    for problem in problems:
        print(f"❌ {problem}")
    if problems:
        print(f"check_claude_mod: {len(problems)} problem(s)")
        return 1
    print("check_claude_mod: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
