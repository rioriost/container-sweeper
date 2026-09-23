#!/usr/bin/env python3
"""Pinned, fail-closed macOS packaging and Homebrew release workflow."""

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[1]
APP_NAME = "Container Sweeper.app"
RUNNER = "Contents/Helpers/container-sweeper-runner"
RESOURCE_BUNDLE = "ContainerSweeper_ContainerSweeper.bundle"
ARCH = "arm64"


class ReleaseError(Exception):
    pass


@dataclass(frozen=True)
class Settings:
    signing_identity: str
    team_id: str
    notary_profile: str
    release_repository: str
    cask_repository: str

    @classmethod
    def load(cls):
        path = ROOT / "Packaging/release.json"
        values = json.loads(path.read_text())
        expected = set(cls.__dataclass_fields__)
        if not isinstance(values, dict) or set(values) != expected:
            raise ReleaseError(f"{path}: expected exactly {sorted(expected)}")
        if not all(isinstance(value, str) for value in values.values()):
            raise ReleaseError(f"{path}: every value must be a string")
        settings = cls(**values)
        if not re.fullmatch(r"[0-9A-F]{40}", settings.signing_identity):
            raise ReleaseError("signing_identity must be the pinned 40-character uppercase certificate SHA-1.")
        if not re.fullmatch(r"[A-Z0-9]{10}", settings.team_id):
            raise ReleaseError("team_id must be a 10-character Apple Developer Team ID.")
        if not re.fullmatch(r"[A-Za-z0-9._-]+", settings.notary_profile):
            raise ReleaseError("notary_profile must be a nonempty Keychain profile name.")
        for repository in [settings.release_repository, settings.cask_repository]:
            if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
                raise ReleaseError(f"Invalid GitHub repository: {repository}")
        if not settings.cask_repository.split("/")[1].startswith("homebrew-"):
            raise ReleaseError("cask_repository must name a Homebrew tap repository.")
        return settings

    @property
    def tap(self):
        owner, repo = self.cask_repository.split("/")
        return f"{owner}/{repo.removeprefix('homebrew-')}"


def run(arguments, *, capture=False, check=True, cwd=ROOT):
    arguments = [str(argument) for argument in arguments]
    result = subprocess.run(
        arguments, cwd=cwd, text=True, capture_output=capture,
        env={**os.environ, "LC_ALL": "C"},
    )
    if check and result.returncode:
        details = "\n".join(value for value in [result.stdout, result.stderr] if value)
        raise ReleaseError(f"Command failed ({result.returncode}): {shlex.join(arguments)}\n{details}")
    return result


def metadata():
    with (ROOT / "Packaging/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"\d+(?:\.\d+)*", build):
        raise ReleaseError("Info.plist must contain a numeric X.Y.Z version and numeric build number.")
    return info


def archive_name(version):
    return f"container-sweeper-{version}-macos-{ARCH}.zip"


def release_directory():
    return ROOT / "dist/releases" / metadata()["CFBundleShortVersionString"]


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1_048_576), b""):
            digest.update(block)
    return digest.hexdigest()


@contextmanager
def workflow_lock():
    (ROOT / ".build").mkdir(exist_ok=True)
    with (ROOT / ".build/distribution.lock").open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ReleaseError("Another packaging/release operation is running.") from error
        yield


@contextmanager
def staging():
    (ROOT / ".build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="distribution-", dir=ROOT / ".build") as directory:
        yield Path(directory)


def signing_identity(settings):
    result = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"], capture=True)
    for fingerprint, name in re.findall(r'([0-9A-F]{40}) "([^"]+)"', result.stdout):
        if fingerprint != settings.signing_identity:
            continue
        if not name.startswith("Developer ID Application: ") or not name.endswith(f"({settings.team_id})"):
            raise ReleaseError(f"Pinned certificate is not Developer ID Application for the configured team: {name}")
        return name
    raise ReleaseError(
        "The pinned Developer ID Application certificate/private key is unavailable. "
        "Run make signing-info. After certificate renewal, explicitly update Packaging/release.json; "
        "the workflow never falls back to Apple Development or ad-hoc signing."
    )


def check_notary_credentials(settings):
    result = run([
        "/usr/bin/xcrun", "notarytool", "history",
        "--keychain-profile", settings.notary_profile, "--output-format", "json",
    ], capture=True, check=False)
    if result.returncode:
        raise ReleaseError(f"Notarization credentials are unavailable. Run make notary-credentials.\n{result.stderr}")


def build_bundle(directory):
    run(["swift", "build", "-c", "release", "--arch", ARCH])
    binary_directory = Path(run(
        ["swift", "build", "-c", "release", "--arch", ARCH, "--show-bin-path"], capture=True
    ).stdout.strip())
    app = directory / APP_NAME
    for relative in ["Contents/MacOS", "Contents/Helpers", "Contents/Resources"]:
        (app / relative).mkdir(parents=True)
    shutil.copy2(binary_directory / "ContainerSweeper", app / "Contents/MacOS/ContainerSweeper")
    shutil.copy2(binary_directory / "ContainerSweeper", app / RUNNER)
    shutil.copy2(ROOT / "Packaging/Info.plist", app / "Contents/Info.plist")
    shutil.copy2(ROOT / "Packaging/AppIcon.icns", app / "Contents/Resources/AppIcon.icns")
    shutil.copy2(ROOT / "LICENSE", app / "Contents/Resources/LICENSE")
    run(["/usr/bin/ditto", binary_directory / RESOURCE_BUNDLE, app / "Contents/Resources" / RESOURCE_BUNDLE])
    return app


def sign_bundle(app, settings=None):
    identity = settings.signing_identity if settings else "-"
    options = ["--timestamp", "--options", "runtime"] if settings else []
    # Sign nested executable code before sealing the outer app; never use --deep to sign.
    run(["/usr/bin/codesign", "--force", "--sign", identity, *options,
         "--identifier", "dev.containersweeper.runner", app / RUNNER])
    run(["/usr/bin/codesign", "--force", "--sign", identity, *options, app])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    run([app / "Contents/MacOS/ContainerSweeper", "--check-resources"])


def verify_signed(app, settings, *, notarized=False):
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    for path in [app, app / RUNNER]:
        details = run(["/usr/bin/codesign", "--display", "--verbose=4", path], capture=True)
        text = details.stdout + details.stderr
        if f"TeamIdentifier={settings.team_id}" not in text or "Authority=Developer ID Application:" not in text:
            raise ReleaseError(f"Wrong signing team or certificate type: {path}")
        if not re.search(r"flags=.*\bruntime\b", text) or not re.search(r"^Timestamp=", text, re.MULTILINE):
            raise ReleaseError(f"Hardened Runtime or secure timestamp is missing: {path}")
        with staging() as certificates:
            prefix = certificates / "certificate-"
            run(["/usr/bin/codesign", "--display", f"--extract-certificates={prefix}", path], capture=True)
            fingerprint = hashlib.sha1(Path(str(prefix) + "0").read_bytes()).hexdigest().upper()
            if fingerprint != settings.signing_identity:
                raise ReleaseError(f"Certificate does not match the pinned SHA-1: {path}")
        architectures = run(["/usr/bin/lipo", "-archs", path / "Contents/MacOS/ContainerSweeper"
                             if path == app else path], capture=True).stdout.strip()
        if architectures != ARCH:
            raise ReleaseError(f"Expected {ARCH}, found {architectures}: {path}")
    # The installed runner must remain valid when copied out of the app bundle.
    with staging() as temporary:
        standalone = temporary / "container-sweeper-runner"
        shutil.copy2(app / RUNNER, standalone)
        run(["/usr/bin/codesign", "--verify", "--strict", standalone])
        run([standalone, "--help"], capture=True)
    if notarized:
        run(["/usr/bin/xcrun", "stapler", "validate", app])
        run(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", app])


def replace_app(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    backup = destination.with_name(destination.name + ".previous-" + uuid.uuid4().hex)
    had_previous = destination.exists()
    if had_previous:
        destination.rename(backup)
    try:
        source.rename(destination)
    except OSError:
        if had_previous:
            backup.rename(destination)
        raise
    if had_previous:
        shutil.rmtree(backup)


def app_build(settings=None):
    if settings:
        print(f"Signing with {signing_identity(settings)} [{settings.signing_identity}]", flush=True)
    with staging() as directory:
        app = build_bundle(directory)
        sign_bundle(app, settings)
        if settings:
            verify_signed(app, settings)
        destination = ROOT / ("dist/signed" if settings else "dist") / APP_NAME
        replace_app(app, destination)
    print(f"Built: {destination}")
    if settings:
        print("Developer ID signed only; NOT notarized. Use make release for distribution.")


def notarize(app, settings, records):
    records.mkdir(parents=True)
    archive = records / "submission.zip"
    run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive])
    auth = ["--keychain-profile", settings.notary_profile, "--output-format", "json"]
    submitted = run(["/usr/bin/xcrun", "notarytool", "submit", archive, *auth], capture=True, check=False)
    (records / "submission.json").write_text(submitted.stdout)
    (records / "submission.stderr.txt").write_text(submitted.stderr)
    if submitted.returncode:
        raise ReleaseError(f"Notarization upload failed. Details: {records}\n{submitted.stderr}")
    submission = json.loads(submitted.stdout)
    submission_id = str(uuid.UUID(submission["id"]))
    print(f"Notarization submission: {submission_id}; records: {records}", flush=True)
    waited = run([
        "/usr/bin/xcrun", "notarytool", "wait", submission_id, *auth, "--timeout", "30m",
    ], capture=True, check=False)
    (records / "result.json").write_text(waited.stdout)
    (records / "result.stderr.txt").write_text(waited.stderr)
    if waited.returncode:
        raise ReleaseError(
            f"Notarization did not finish successfully. No distribution archive was produced. "
            f"Submission {submission_id} may still be processing; records: {records}\n{waited.stderr}"
        )
    result = json.loads(waited.stdout)
    if result.get("id") != submission_id or result.get("status") != "Accepted":
        log = run([
            "/usr/bin/xcrun", "notarytool", "log", submission_id,
            "--keychain-profile", settings.notary_profile, records / "log.json",
        ], capture=True, check=False)
        if log.returncode:
            (records / "log.stderr.txt").write_text(log.stderr)
        raise ReleaseError(f"Notarization was not Accepted ({result.get('status')}). See {records}.")
    run(["/usr/bin/xcrun", "stapler", "staple", app])
    verify_signed(app, settings, notarized=True)
    return submission_id


def render_cask(settings, version, digest):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ReleaseError("Cask generation requires a concrete version and SHA-256, never :no_check.")
    return f'''cask "container-sweeper" do
  version "{version}"
  sha256 "{digest}"

  url "https://github.com/{settings.release_repository}/releases/download/container-sweeper-v#{{version}}/container-sweeper-#{{version}}-macos-arm64.zip"
  name "Container Sweeper"
  desc "Schedule and deduplicate Apple Container cleanup"
  homepage "https://github.com/{settings.release_repository}"

  depends_on arch: :arm64
  depends_on macos: :tahoe
  depends_on formula: "container"

  app "Container Sweeper.app"

  uninstall launchctl: ["dev.containersweeper.schedule.*", "dev.containersweeper.job.*"],
            quit:      "dev.containersweeper.app",
            delete:    [
              "~/Library/LaunchAgents/dev.containersweeper.schedule.*.plist",
              "~/Library/LaunchAgents/dev.containersweeper.job.*.plist",
            ]

  zap trash: [
    "~/Library/Application Support/ContainerSweeper",
    "~/Library/Logs/ContainerSweeper",
    "~/Library/Preferences/dev.containersweeper.app.plist",
  ]

  caveats <<~EOS
    Open Container Sweeper and choose Save & Apply after installation or upgrade
    to install the current helper and register your cleanup schedules.
    The Apple Container service must already be running at cleanup time.
  EOS
end
'''


def verify_app_icon(app):
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIconFile") != "AppIcon.icns":
        raise ReleaseError("The app must reference its packaged AppIcon.icns.")
    icon = app / "Contents/Resources/AppIcon.icns"
    if not icon.is_file() or sha256(icon) != sha256(ROOT / "Packaging/AppIcon.icns"):
        raise ReleaseError("The packaged app icon is missing or differs from the release source.")


def verify_archive(archive, settings):
    with staging() as directory:
        run(["/usr/bin/ditto", "-x", "-k", archive, directory])
        app = directory / APP_NAME
        verify_signed(app, settings, notarized=True)
        with (app / "Contents/Info.plist").open("rb") as handle:
            packaged_info = plistlib.load(handle)
        expected_info = metadata()
        for key in ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"]:
            if packaged_info.get(key) != expected_info.get(key):
                raise ReleaseError(f"Packaged {key} does not match Packaging/Info.plist.")
        if not (app / "Contents/Resources/LICENSE").is_file():
            raise ReleaseError("The distributed app is missing its MIT license.")
        verify_app_icon(app)


def make_release(settings):
    info = metadata()
    version = info["CFBundleShortVersionString"]
    destination = release_directory()
    if destination.exists():
        raise ReleaseError(f"Release {version} already exists. Bump Info.plist version/build; released artifacts are immutable.")
    print(f"Pinned signer: {signing_identity(settings)}", flush=True)
    check_notary_credentials(settings)
    with staging() as directory:
        app = build_bundle(directory)
        sign_bundle(app, settings)
        verify_signed(app, settings)
        records = ROOT / "dist/notarization" / str(uuid.uuid4())
        submission_id = notarize(app, settings, records)
        output = directory / "output"
        output.mkdir()
        archive = output / archive_name(version)
        run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive])
        verify_archive(archive, settings)
        digest = sha256(archive)
        (output / (archive.name + ".sha256")).write_text(f"{digest}  {archive.name}\n")
        manifest = {
            "version": version, "build": info["CFBundleVersion"], "architecture": ARCH,
            "archive": archive.name, "sha256": digest, "team_id": settings.team_id,
            "signing_identity": settings.signing_identity, "notarization_status": "Accepted",
            "submission_id": submission_id, "release_repository": settings.release_repository,
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        (output / "container-sweeper.rb").write_text(render_cask(settings, version, digest))
        destination.parent.mkdir(parents=True, exist_ok=True)
        output.rename(destination)
    print(f"Verified, notarized release: {destination}\nNo GitHub upload or tap modification has been performed.")


def verified_release(settings):
    directory = release_directory()
    manifest = json.loads((directory / "manifest.json").read_text())
    version = metadata()["CFBundleShortVersionString"]
    expected = {
        "version": version, "build": metadata()["CFBundleVersion"], "architecture": ARCH,
        "archive": archive_name(version), "team_id": settings.team_id,
        "signing_identity": settings.signing_identity, "notarization_status": "Accepted",
        "release_repository": settings.release_repository,
    }
    if any(manifest.get(key) != value for key, value in expected.items()):
        raise ReleaseError("Release manifest does not match the current version, signer, or repository.")
    archive = directory / archive_name(version)
    if sha256(archive) != manifest.get("sha256"):
        raise ReleaseError("Release ZIP checksum does not match the notarized release manifest.")
    checksum = (directory / (archive.name + ".sha256")).read_text()
    if checksum != f"{manifest['sha256']}  {archive.name}\n":
        raise ReleaseError("Release checksum sidecar does not match the verified archive.")
    verify_archive(archive, settings)
    return directory, manifest


def write_cask(settings):
    directory, manifest = verified_release(settings)
    path = directory / "container-sweeper.rb"
    path.write_text(render_cask(settings, manifest["version"], manifest["sha256"]))
    return path


def publish(settings):
    directory, manifest = verified_release(settings)
    tag = "container-sweeper-v" + manifest["version"]
    archive = directory / manifest["archive"]
    run([
        "gh", "release", "create", tag, "--repo", settings.release_repository,
        "--title", "Container Sweeper " + manifest["version"],
        "--notes", f"Developer ID signed and notarized macOS arm64 app.\nInstall: brew install --cask {settings.tap}/container-sweeper",
        archive, directory / (archive.name + ".sha256"), directory / "manifest.json",
    ])


def update_cask(settings):
    source = write_cask(settings)
    result = run(["brew", "--repository", settings.tap], capture=True, check=False)
    if result.returncode or not Path(result.stdout.strip()).is_dir():
        raise ReleaseError(f"Tap is not checked out. Run: brew tap {settings.tap}")
    checkout = Path(result.stdout.strip()).resolve()
    remote = run(["git", "remote", "get-url", "origin"], cwd=checkout, capture=True).stdout.strip()
    allowed = {
        f"https://github.com/{settings.cask_repository}",
        f"https://github.com/{settings.cask_repository}.git",
        f"git@github.com:{settings.cask_repository}.git",
    }
    if remote not in allowed:
        raise ReleaseError(f"Refusing to modify a checkout with unexpected origin: {remote}")
    target = checkout / "Casks/container-sweeper.rb"
    dirty = run(["git", "status", "--porcelain", "--", "Casks/container-sweeper.rb"],
                cwd=checkout, capture=True).stdout.strip()
    if dirty:
        raise ReleaseError(f"{target} has local changes; review them before updating.")
    target.parent.mkdir(exist_ok=True)
    shutil.copy2(source, target)
    print(f"Updated {target}\nReview, commit and push this change in {settings.cask_repository}; no commit or push was performed.")


def main():
    commands = [
        "app", "signing-info", "signing-check", "notary-credentials", "release-check",
        "signed-app", "release", "verify-release", "cask", "publish", "update-cask",
    ]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=commands)
    command = parser.parse_args().command
    try:
        with workflow_lock():
            if command == "app":
                app_build()
                return
            settings = Settings.load()
            if command == "signing-info":
                print(json.dumps(settings.__dict__, indent=2), flush=True)
                run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
            elif command == "signing-check":
                print(signing_identity(settings))
            elif command == "notary-credentials":
                signing_identity(settings)
                if not sys.stdin.isatty():
                    raise ReleaseError("Run make notary-credentials in an interactive terminal. Never put passwords in files or Make variables.")
                run(["/usr/bin/xcrun", "notarytool", "store-credentials", settings.notary_profile,
                     "--team-id", settings.team_id])
            elif command == "release-check":
                print(signing_identity(settings), flush=True)
                check_notary_credentials(settings)
                print("Signing identity and notarization credentials are ready. No upload performed.")
            elif command == "signed-app":
                app_build(settings)
            elif command == "release":
                make_release(settings)
            elif command == "verify-release":
                print(verified_release(settings)[0])
            elif command == "cask":
                print(write_cask(settings))
            elif command == "publish":
                publish(settings)
            elif command == "update-cask":
                update_cask(settings)
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        print(f"Release error: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
