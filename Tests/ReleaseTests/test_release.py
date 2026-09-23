import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import release


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.root_patch = patch.object(release, "ROOT", self.root)
        self.root_patch.start()
        (self.root / "Packaging").mkdir()
        self.settings = release.Settings(
            signing_identity="A" * 40, team_id="TEAM123456", notary_profile="test-notary",
            release_repository="rioriost/homebrew-cask", cask_repository="rioriost/homebrew-cask",
        )
        (self.root / "Packaging/release.json").write_text(json.dumps(self.settings.__dict__))
        with (self.root / "Packaging/Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "4"}, handle)

    def tearDown(self):
        self.root_patch.stop()
        self.temporary.cleanup()

    def result(self, stdout="", stderr="", code=0):
        return subprocess.CompletedProcess([], code, stdout, stderr)

    def test_configuration_is_pinned_and_rejects_unsafe_or_missing_fields(self):
        self.assertEqual(release.Settings.load(), self.settings)
        self.assertEqual(self.settings.tap, "rioriost/cask")
        for key, value in [
            ("signing_identity", "-"), ("team_id", ""), ("notary_profile", ""),
            ("release_repository", 'owner/repo"; system("oops")'), ("password", "not-allowed"),
        ]:
            data = {**self.settings.__dict__, key: value}
            (self.root / "Packaging/release.json").write_text(json.dumps(data))
            with self.assertRaises(release.ReleaseError):
                release.Settings.load()

    def test_certificate_selection_never_uses_a_different_type_team_or_fingerprint(self):
        correct = f'  1) {"A" * 40} "Developer ID Application: Test ({self.settings.team_id})"'
        with patch.object(release, "run", return_value=self.result(stdout=correct)):
            self.assertIn("Developer ID Application:", release.signing_identity(self.settings))
        for output in [
            correct.replace("Developer ID Application", "Apple Development"),
            correct.replace(self.settings.team_id, "OTHER12345"),
            correct.replace("A" * 40, "B" * 40),
            "0 valid identities found",
        ]:
            with patch.object(release, "run", return_value=self.result(stdout=output)):
                with self.assertRaises(release.ReleaseError):
                    release.signing_identity(self.settings)

    def test_missing_notarization_profile_fails_with_setup_command(self):
        with patch.object(release, "run", return_value=self.result(code=69, stderr="Profile missing")):
            with self.assertRaisesRegex(release.ReleaseError, "make notary-credentials"):
                release.check_notary_credentials(self.settings)

    def test_signs_nested_runner_first_with_hardened_runtime_and_timestamp(self):
        app = self.root / release.APP_NAME
        with patch.object(release, "run", return_value=self.result()) as run:
            release.sign_bundle(app, self.settings)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(commands[0][-1], app / release.RUNNER)
        self.assertEqual(commands[1][-1], app)
        for command in commands[:2]:
            self.assertIn(self.settings.signing_identity, command)
            self.assertIn("--timestamp", command)
            self.assertIn("runtime", command)
            self.assertNotIn("--deep", command)
            self.assertNotIn("-", command)
        self.assertIn("--verify", commands[2])

    def test_verification_rejects_wrong_team_missing_timestamp_and_missing_runtime(self):
        valid = (
            f"TeamIdentifier={self.settings.team_id}\nAuthority=Developer ID Application: Test\n"
            "CodeDirectory flags=0x10000(runtime)\nTimestamp=Sep 20, 2026\n"
        )
        for invalid in [valid.replace(self.settings.team_id, "OTHER12345"),
                        valid.replace("Timestamp=", "Signed Time="), valid.replace("runtime", "adhoc")]:
            with patch.object(release, "run", return_value=self.result(stderr=invalid)):
                with self.assertRaises(release.ReleaseError):
                    release.verify_signed(self.root / release.APP_NAME, self.settings)

    def test_notarization_acceptance_precedes_stapling_and_gatekeeper_verification(self):
        submission_id = "00000000-0000-4000-8000-000000000001"
        commands = []

        def command(arguments, **kwargs):
            commands.append(arguments)
            if "submit" in arguments:
                return self.result(stdout=json.dumps({"id": submission_id}))
            if "wait" in arguments:
                return self.result(stdout=json.dumps({"id": submission_id, "status": "Accepted"}))
            return self.result()

        with patch.object(release, "run", side_effect=command), patch.object(release, "verify_signed") as verify:
            result = release.notarize(self.root / release.APP_NAME, self.settings, self.root / "records")
        self.assertEqual(result, submission_id)
        waited = next(index for index, args in enumerate(commands) if "wait" in args)
        stapled = next(index for index, args in enumerate(commands) if "staple" in args)
        self.assertLess(waited, stapled)
        verify.assert_called_once_with(self.root / release.APP_NAME, self.settings, notarized=True)
        self.assertTrue((self.root / "records/submission.json").exists())
        self.assertTrue((self.root / "records/result.json").exists())

    def test_invalid_or_pending_notarization_never_staples_or_verifies_success(self):
        submission_id = "00000000-0000-4000-8000-000000000001"
        for status, code in [("Invalid", 0), ("In Progress", 1)]:
            commands = []

            def command(arguments, **kwargs):
                commands.append(arguments)
                if "submit" in arguments:
                    return self.result(stdout=json.dumps({"id": submission_id}))
                if "wait" in arguments:
                    return self.result(stdout=json.dumps({"id": submission_id, "status": status}), code=code)
                return self.result()

            records = self.root / status.replace(" ", "-")
            with patch.object(release, "run", side_effect=command), patch.object(release, "verify_signed") as verify:
                with self.assertRaises(release.ReleaseError):
                    release.notarize(self.root / release.APP_NAME, self.settings, records)
            self.assertFalse(any("staple" in args for args in commands))
            verify.assert_not_called()
            self.assertTrue((records / "result.json").exists())

    def test_final_artifacts_are_created_only_after_success(self):
        events = []

        def build(directory):
            app = directory / release.APP_NAME
            app.mkdir()
            return app

        def command(arguments, **kwargs):
            if "-c" in arguments and "-k" in arguments:
                events.append("final-zip")
                Path(arguments[-1]).write_bytes(b"final stapled app")
            return self.result()

        def notarize(*args):
            events.append("accepted-and-stapled")
            return "00000000-0000-4000-8000-000000000001"

        with patch.object(release, "signing_identity", return_value="Pinned signer"), \
                patch.object(release, "check_notary_credentials"), \
                patch.object(release, "build_bundle", side_effect=build), \
                patch.object(release, "sign_bundle"), patch.object(release, "verify_signed"), \
                patch.object(release, "notarize", side_effect=notarize), \
                patch.object(release, "verify_archive"), patch.object(release, "run", side_effect=command):
            release.make_release(self.settings)
        self.assertEqual(events, ["accepted-and-stapled", "final-zip"])
        output = release.release_directory()
        manifest = json.loads((output / "manifest.json").read_text())
        self.assertEqual(manifest["sha256"], release.sha256(output / manifest["archive"]))
        self.assertIn(manifest["sha256"], (output / "container-sweeper.rb").read_text())
        with patch.object(release, "signing_identity") as signer:
            with self.assertRaisesRegex(release.ReleaseError, "already exists"):
                release.make_release(self.settings)
            signer.assert_not_called()

    def test_failed_release_does_not_leave_distribution_artifacts(self):
        with patch.object(release, "signing_identity", return_value="Pinned signer"), \
                patch.object(release, "check_notary_credentials"), \
                patch.object(release, "build_bundle", return_value=self.root / release.APP_NAME), \
                patch.object(release, "sign_bundle"), patch.object(release, "verify_signed"), \
                patch.object(release, "notarize", side_effect=release.ReleaseError("Rejected")):
            with self.assertRaisesRegex(release.ReleaseError, "Rejected"):
                release.make_release(self.settings)
        self.assertFalse(release.release_directory().exists())

    def test_tampered_release_is_rejected_before_publishing(self):
        output = release.release_directory()
        output.mkdir(parents=True)
        name = release.archive_name("1.2.3")
        (output / name).write_bytes(b"tampered")
        manifest = {
            "version": "1.2.3", "build": "4", "architecture": "arm64", "archive": name,
            "team_id": self.settings.team_id, "signing_identity": self.settings.signing_identity,
            "notarization_status": "Accepted", "release_repository": self.settings.release_repository,
            "sha256": "0" * 64,
        }
        (output / "manifest.json").write_text(json.dumps(manifest))
        with patch.object(release, "run") as command:
            with self.assertRaisesRegex(release.ReleaseError, "checksum"):
                release.publish(self.settings)
            command.assert_not_called()

    def test_cask_targets_existing_cask_repo_and_uninstalls_owned_jobs(self):
        cask = release.render_cask(self.settings, "1.2.3", "a" * 64)
        self.assertIn("rioriost/homebrew-cask/releases/download/container-sweeper-v#{version}", cask)
        self.assertIn('sha256 "' + "a" * 64 + '"', cask)
        self.assertIn('app "Container Sweeper.app"', cask)
        self.assertIn('depends_on formula: "container"', cask)
        self.assertIn("depends_on macos: :tahoe", cask)
        self.assertIn("dev.containersweeper.schedule.*", cask)
        self.assertIn("dev.containersweeper.job.*", cask)
        self.assertNotIn("no_check", cask)
        self.assertNotIn("quarantine", cask)
        for version, digest in [("1.2.3", "no_check"), ('1.2.3";oops', "a" * 64)]:
            with self.assertRaises(release.ReleaseError):
                release.render_cask(self.settings, version, digest)

    def test_local_cask_changes_are_not_overwritten(self):
        checkout = self.root / "tap"
        (checkout / "Casks").mkdir(parents=True)
        target = checkout / "Casks/container-sweeper.rb"
        target.write_text("user changes")
        source = self.root / "generated.rb"
        source.write_text("generated")

        def command(arguments, **kwargs):
            if arguments[0] == "brew":
                return self.result(stdout=str(checkout))
            if arguments[1] == "remote":
                return self.result(stdout="https://github.com/rioriost/homebrew-cask")
            return self.result(stdout=" M Casks/container-sweeper.rb")

        with patch.object(release, "write_cask", return_value=source), patch.object(release, "run", side_effect=command):
            with self.assertRaisesRegex(release.ReleaseError, "local changes"):
                release.update_cask(self.settings)
        self.assertEqual(target.read_text(), "user changes")

    def test_packaged_icon_must_match_its_reference_and_release_source(self):
        app = self.root / release.APP_NAME
        resources = app / "Contents/Resources"
        resources.mkdir(parents=True)
        info = app / "Contents/Info.plist"
        icon = resources / "AppIcon.icns"
        source = self.root / "Packaging/AppIcon.icns"
        source.write_bytes(b"icon fixture")
        info.write_bytes(plistlib.dumps({"CFBundleIconFile": "AppIcon.icns"}))
        with self.assertRaisesRegex(release.ReleaseError, "missing"):
            release.verify_app_icon(app)
        icon.write_bytes(source.read_bytes())
        release.verify_app_icon(app)
        icon.write_bytes(b"unexpected old icon")
        with self.assertRaisesRegex(release.ReleaseError, "differs"):
            release.verify_app_icon(app)
        info.write_bytes(plistlib.dumps({"CFBundleIconFile": "Other.icns"}))
        with self.assertRaisesRegex(release.ReleaseError, "reference"):
            release.verify_app_icon(app)


if __name__ == "__main__":
    unittest.main()
