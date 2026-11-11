#!/usr/bin/env python3
"""License fixtures for private and public layouts; no resolution or network required."""
import json
import os
from pathlib import Path
import tempfile
import unittest

from check_swift_invariants import check_licenses

REPO = Path(__file__).resolve().parents[2]
CORE_LIST = "scripts/dependency-licenses.json"
APP_LIST = "scripts/app-dependency-licenses.json"
APP_LOCK = "App/Parlance.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"


class LicenseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        previous = os.getcwd()
        self.addCleanup(self.directory.cleanup)
        self.addCleanup(os.chdir, previous)
        os.chdir(self.directory.name)
        self.app = Path(APP_LOCK)
        self.app.parent.mkdir(parents=True)
        Path("scripts").mkdir()
        self.root_pin = self.pin("cli", "https://example.invalid/cli")
        self.sparkle = self.pin("sparkle", "https://github.com/sparkle-project/Sparkle")
        self.write_lock(Path("Package.resolved"), [self.root_pin])
        self.write_lock(self.app, [self.root_pin, self.sparkle])
        self.allow = {"cli": self.entry(self.root_pin)}
        self.app_allow = {"sparkle": self.entry(self.sparkle, minimum_version="2.9.6")}

    @staticmethod
    def pin(identity, location):
        return {"identity": identity, "location": location, "state": {"version": "2.10.0"}}

    @staticmethod
    def entry(pin, **extra):
        return {"license": "MIT", "url": pin["location"], "reason": "fixture", **extra}

    @staticmethod
    def write_lock(path, pins):
        path.write_text(json.dumps({"version": 3, "pins": pins}))

    def check(self, manifest=None):
        Path(CORE_LIST).write_text(json.dumps(self.allow))
        if self.app_allow is not None:
            Path(APP_LIST).write_text(json.dumps(self.app_allow))
        else:
            Path(APP_LIST).unlink(missing_ok=True)
        return check_licenses(manifest or {"dependencies": []})

    def assert_error(self, errors, *parts):
        self.assertTrue(any(all(part in error for part in parts) for error in errors), errors)

    def test_public_snapshot_uses_the_repository_core_allowlist(self):
        self.app.unlink()
        self.app_allow = None
        self.allow = json.loads((REPO / CORE_LIST).read_text())
        Path("Package.resolved").write_text((REPO / "Package.resolved").read_text())
        self.assertEqual(self.check(), [])
        self.assertFalse(Path(APP_LIST).exists())

    def test_no_app_lockfile_ignores_even_malformed_app_allowlist(self):
        self.app.unlink()
        self.check()
        Path(APP_LIST).write_text("{")
        self.assertEqual(check_licenses({}), [])

    def test_private_layout_accepts_core_and_app_pins(self):
        self.assertEqual(self.check(), [])

    def test_app_pin_must_be_approved(self):
        self.app_allow = {}
        self.assert_error(self.check(), APP_LOCK, "dependency 'sparkle'", CORE_LIST, APP_LIST)

    def test_missing_app_allowlist_identifies_the_file_to_create(self):
        self.app_allow = None
        self.assert_error(self.check(), APP_LOCK, "sparkle", "create", APP_LIST)
        self.write_lock(self.app, [self.root_pin])
        self.assertEqual(self.check(), [])

    def test_app_allowlist_stale_against_app_pins_only(self):
        self.write_lock(self.app, [self.root_pin])
        self.assert_error(self.check(), APP_LIST, "stale entry 'sparkle'", APP_LOCK)

    def test_duplicate_identity_in_allowlists_is_rejected(self):
        self.app_allow["cli"] = self.allow["cli"]
        self.assert_error(self.check(), "cli", "both", CORE_LIST, APP_LIST)

    def test_core_stale_cannot_be_rescued_by_app_pin(self):
        self.allow["sparkle"] = self.app_allow.pop("sparkle")
        self.assert_error(self.check(), CORE_LIST, "stale entry 'sparkle'", "Package.resolved")

    def test_core_stale_without_app_remains_rejected(self):
        self.app.unlink()
        self.app_allow = None
        self.allow["ghost"] = self.entry(self.root_pin)
        self.assert_error(self.check(), CORE_LIST, "stale entry 'ghost'", "Package.resolved")
        del self.allow["ghost"]
        self.assertEqual(self.check(), [])

    def test_license_and_origin_rules_apply_to_both_allowlists(self):
        for identity, allowlist, lockfile, path in [
            ("cli", self.allow, "Package.resolved", CORE_LIST),
            ("sparkle", self.app_allow, APP_LOCK, APP_LIST),
        ]:
            with self.subTest(identity=identity):
                allowlist[identity]["license"] = "GPL-3.0"
                self.assert_error(self.check(), lockfile, path, "has license")
                allowlist[identity]["license"] = "MIT"
                old_url = allowlist[identity]["url"]
                allowlist[identity]["url"] = "https://example.invalid/fork"
                self.assert_error(self.check(), lockfile, path, "resolves to")
                allowlist[identity]["url"] = old_url

    def test_same_identity_in_both_lockfiles_checks_both_origins(self):
        fork = self.pin("cli", "https://example.invalid/fork")
        self.write_lock(self.app, [self.sparkle, fork])
        self.assert_error(self.check(), APP_LOCK, CORE_LIST, "dependency 'cli' resolves to")

    def test_app_pin_cannot_replace_root_manifest_pin(self):
        self.write_lock(Path("Package.resolved"), [])
        manifest = {"dependencies": [{"sourceControl": [{"identity": "cli"}]}]}
        self.assert_error(self.check(manifest), "Package.swift declares dependency 'cli'")

    def test_minimum_version_for_both_allowlists(self):
        for pin, allow, lockfile, allowfile in [
            (self.root_pin, self.allow, Path("Package.resolved"), CORE_LIST),
            (self.sparkle, self.app_allow, self.app, APP_LIST),
        ]:
            identity = pin["identity"]
            allow[identity]["minimum_version"] = "2.9.6"
            for version, passes in [
                ("2.9.5", False), (None, False), ("2.9.6", True), ("2.10.0", True),
                ("2.9.6-rc.1", False), ("2.9.6+build.1", True), ("garbage", False),
            ]:
                with self.subTest(identity=identity, version=version):
                    pin["state"] = {"revision": "fake-revision"}
                    if version is not None:
                        pin["state"]["version"] = version
                    self.write_lock(lockfile, [pin])
                    errors = self.check()
                    if passes:
                        self.assertEqual(errors, [])
                    else:
                        self.assert_error(errors, str(lockfile), allowfile, identity, "minimum_version")
            pin["state"] = {"version": "2.10.0"}
            self.write_lock(lockfile, [pin])

    def test_prerelease_comparison_and_invalid_minimum(self):
        self.app_allow["sparkle"]["minimum_version"] = "2.10.0-rc.2"
        for version, passes in [("2.10.0-rc.1", False), ("2.10.0-rc.10", True), ("2.10.0", True)]:
            self.sparkle["state"]["version"] = version
            self.write_lock(self.app, [self.sparkle])
            self.assertEqual(not self.check(), passes)
        self.app_allow["sparkle"]["minimum_version"] = "2.09.6"
        self.assert_error(self.check(), APP_LOCK, APP_LIST, "minimum_version")

    def test_missing_core_allowlist_reports_root_lockfile(self):
        self.check()
        Path(CORE_LIST).unlink()
        self.assert_error(check_licenses({}), CORE_LIST, "missing", "Package.resolved", "1 package")

    def test_unreadable_app_lockfile_fails_closed(self):
        self.app.write_text("{")
        self.assert_error(self.check(), "cannot read", APP_LOCK)


if __name__ == "__main__":
    unittest.main()
