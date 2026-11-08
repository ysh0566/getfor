#!/usr/bin/env python3
"""Read the app version and publish complete, immutable GitHub Releases."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


VERSION = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([1-9]\d*))?$"
)


def read_version(text, run_number="1"):
    lines = re.findall(r"^version:\s*([^\s#]+)\s*(?:#.*)?$", text, re.MULTILINE)
    if len(lines) != 1 or not (match := VERSION.fullmatch(lines[0])):
        raise ValueError("pubspec.yaml must contain one SemVer version, optionally followed by +build")
    version = lines[0].split("+")[0]
    build = match[5] or run_number
    if not build.isdecimal() or not 0 < int(build) <= 2_100_000_000:
        raise ValueError("Android build number must be between 1 and 2100000000")
    return {
        "version": version,
        "build_name": ".".join(match.group(i) for i in (1, 2, 3)),
        "build_number": str(int(build)),
        "tag": f"v{version}",
        "prerelease": str(match[4] is not None).lower(),
    }


def release_event(event, ref, tag):
    if event == "pull_request":
        return False
    if ref.startswith("refs/tags/"):
        if ref != f"refs/tags/{tag}":
            raise ValueError("Git tag must match the version in pubspec.yaml")
        return True
    return event in ("push", "workflow_dispatch") and ref == "refs/heads/main"


def api(path):
    result = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if result.returncode:
        if "HTTP 404" in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout)


def metadata():
    values = read_version(Path("pubspec.yaml").read_text(), os.getenv("GITHUB_RUN_NUMBER", "1"))
    publish = release_event(os.getenv("GITHUB_EVENT_NAME", ""), os.getenv("GITHUB_REF", ""), values["tag"])
    if publish:
        release = api(f"repos/{os.environ['GITHUB_REPOSITORY']}/releases/tags/{values['tag']}")
        publish = release is None or release["draft"]
    values["publish"] = str(publish).lower()
    output = "".join(f"{key}={value}\n" for key, value in values.items())
    if destination := os.getenv("GITHUB_OUTPUT"):
        with open(destination, "a") as stream:
            stream.write(output)
    print(output, end="")


def publish():
    values = read_version(Path("pubspec.yaml").read_text(), os.environ["GITHUB_RUN_NUMBER"])
    tag, repository, commit = values["tag"], os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"]
    if not release_event(os.environ["GITHUB_EVENT_NAME"], os.environ["GITHUB_REF"], tag):
        raise ValueError("Only main or a matching version tag may publish")
    existing = api(f"repos/{repository}/releases/tags/{tag}")
    if existing and not existing["draft"]:
        print(f"{tag} is already published; its assets will not be changed")
        return
    ref = api(f"repos/{repository}/git/ref/tags/{tag}")
    if ref:
        target = ref["object"]
        while target["type"] == "tag":
            target = api(f"repos/{repository}/git/tags/{target['sha']}")["object"]
        if target["type"] != "commit" or target["sha"] != commit:
            raise ValueError("The version tag points to another commit; bump the app version")

    folder = Path("dist")
    names = [f"getfor-{values['version']}-android.apk"] + [
        f"getfor-{values['version']}-macos-unnotarized-universal.{suffix}" for suffix in ("zip", "dmg")
    ]
    assets = [folder / name for name in names]
    if not all(path.is_file() and path.stat().st_size for path in assets):
        raise ValueError("Both platform packages must exist before publishing")
    checksums = folder / "SHA256SUMS.txt"
    checksums.write_text("".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in assets
    ))
    assets.append(checksums)
    if not existing:
        notes = folder / "release-notes.md"
        notes.write_text(
            "Android: signed APK for Arm64 and x86_64.\n\n"
            "macOS 26+: universal (Apple Silicon + Intel), ad-hoc signed and **not notarized**. "
            "If blocked, allow it in System Settings > Privacy & Security. "
            "This community package omits the system AutoFill extension; "
            "Developer ID signing and provisioning are required for that integration.\n\n"
            "Use SHA256SUMS.txt to verify downloads.\n"
        )
        subprocess.run([
            "gh", "release", "create", tag, "--repo", repository, "--target", commit,
            "--title", f"Getfor {values['version']}", "--draft", "--generate-notes", "--notes-file", str(notes),
        ], check=True)
    # Keep the release in draft until every asset and checksum has been uploaded successfully.
    subprocess.run(["gh", "release", "upload", tag, "--repo", repository, "--clobber", *map(str, assets)], check=True)
    subprocess.run([
        "gh", "release", "edit", tag, "--repo", repository, "--draft=false",
        f"--prerelease={values['prerelease']}", f"--latest={str(values['prerelease'] == 'false').lower()}",
    ], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("metadata", "publish"))
    arguments = parser.parse_args()
    metadata() if arguments.command == "metadata" else publish()
