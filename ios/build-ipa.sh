#!/usr/bin/env bash
# Run on the PC. The Mac only gets ios/, never this checkout's .git directory.
set -euo pipefail

usage() {
    cat <<'HELP'
Usage: ios/build-ipa.sh [--host user@addr] [--out DIR] [--test] [--screenshot] [--dry-run]
Build an unsigned IPA on the Mac and publish it for SideStore on the PC.
Defaults: danny@100.64.156.37, ~/photo-culling/trial_out/ios
--test        Run CullingBayCore's Swift tests before archiving.
--screenshot  Also try a simulator build and copy CullingBay.png back.
--dry-run     Print commands and scripts; no remote commands or writes.
HELP
}

host='danny@100.64.156.37'
out="$HOME/photo-culling/trial_out/ios"
test_core=0
screenshot=0
dry_run=0
while (($#)); do
    case "$1" in
        --host|--out)
            [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
            if [[ "$1" == --host ]]; then host=$2; else out=$2; fi
            shift 2 ;;
        --test) test_core=1; shift ;;
        --screenshot) screenshot=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done
# The destination is used by ssh, scp and rsync, including their remote-shell syntax.
[[ "$host" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@-]*$ ]] || {
    printf 'Invalid --host (expected user@addr or a hostname): %s\n' "$host" >&2; exit 2;
}

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
build=$(git --no-optional-locks -C "$repo" rev-list --count HEAD)
revision=$(git --no-optional-locks -C "$repo" rev-parse --short HEAD)
if [[ -n "$(git --no-optional-locks -C "$repo" status --porcelain --untracked-files=normal)" ]]; then
    revision+='-dirty'
fi
ssh_opts=(-o HostKeyAlias=192.168.1.75)

run() {
    if ((dry_run)); then
        printf '+ '; printf '%q ' "$@"; printf '\n'
    else
        "$@"
    fi
}

# Print heredocs too: a dry run shows the actual remote and publishing operations.
run_stdin() {
    local script
    script=$(cat)
    if ((dry_run)); then
        run "$@"
        printf '%s\n' "$script"
    else
        "$@" <<< "$script"
    fi
}

run rsync -az --exclude='.build/' --exclude='build/' --exclude='*.xcodeproj/' \
    --exclude='DerivedData' -e 'ssh -o HostKeyAlias=192.168.1.75' \
    "$repo/ios/" "$host:photo-culling-ios/"

# zsh's login startup loads the Mac environment; bash runs the portable script on stdin.
# Arguments interpolated here are integers generated above, never user shell text.
run_stdin ssh "${ssh_opts[@]}" "$host" \
    "zsh -lc 'exec bash -s -- $build $test_core'" <<'MAC_BUILD'
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"
build=$1
test_core=$2
cd "$HOME/photo-culling-ios"
command -v xcodebuild >/dev/null || { echo 'Missing xcodebuild: install and select full Xcode.' >&2; exit 1; }
xcodebuild -version || { echo 'Xcode is not ready: check xcode-select and the Xcode license.' >&2; exit 1; }
command -v xcodegen >/dev/null || { echo 'Missing xcodegen: run brew install xcodegen on the Mac.' >&2; exit 1; }
xcodegen --version
[[ -f project.yml ]] || { echo 'Missing ios/project.yml: the app scaffold must be present first.' >&2; exit 1; }
if ((test_core)); then
    (cd CullingBayCore && swift test)
fi
xcodegen generate
# Clear only generated output in this dedicated Mac build directory.
rm -rf build/CullingBay.xcarchive build/Payload
rm -f build/CullingBay.ipa
xcodebuild -project CullingBay.xcodeproj -scheme CullingBay -configuration Release \
    -sdk iphoneos -archivePath build/CullingBay.xcarchive archive \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CURRENT_PROJECT_VERSION="$build"
app='build/CullingBay.xcarchive/Products/Applications/CullingBay.app'
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist" > build/version.txt
[[ -s build/version.txt ]] || { echo 'Built app has no marketing version.' >&2; exit 1; }
mkdir -p build/Payload
cp -R "$app" build/Payload/CullingBay.app
(cd build && zip -qry CullingBay.ipa Payload)
MAC_BUILD

run mkdir -p -- "$out"
stage=''
cleanup() {
    if [[ -n "$stage" && "$dry_run" == 0 ]]; then rm -rf -- "$stage"; fi
}
trap cleanup EXIT
if ((dry_run)); then
    run mktemp -d "$out/.delivery.XXXXXX"
    stage="$out/.delivery.DRYRUN"
else
    stage=$(mktemp -d "$out/.delivery.XXXXXX")
fi
run scp "${ssh_opts[@]}" "$host:photo-culling-ios/build/CullingBay.ipa" "$stage/CullingBay.ipa"
run scp "${ssh_opts[@]}" "$host:photo-culling-ios/build/version.txt" "$stage/version.txt"
run_stdin python3 - "$out" "$stage" "$build" "$revision" <<'PUBLISH'
import fcntl
import hashlib
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

out, stage = (Path(p).resolve() for p in sys.argv[1:3])
build = int(sys.argv[3])
version = (stage / "version.txt").read_text().strip()
if not version:
    raise SystemExit("Built app has no marketing version; nothing published")
ipa = stage / "CullingBay.ipa"
digest = hashlib.sha256()
with ipa.open("rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
name = f"CullingBay-{build}.ipa"
metadata = {"version": version, "build": build, "git": sys.argv[4],
            "built_at": datetime.now().astimezone().isoformat(timespec="seconds"),
            "bytes": ipa.stat().st_size, "sha256": digest.hexdigest(), "file": name}
(stage / "latest.json").write_text(json.dumps(metadata, indent=2) + "\n")
# All renames are on the output filesystem. Readers never see a partial IPA or JSON.
with (out / ".publish.lock").open("a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    os.replace(ipa, out / name)
    (stage / "latest.ipa").symlink_to(name)
    os.replace(stage / "latest.ipa", out / "CullingBay.ipa")
    os.replace(stage / "latest.json", out / "latest.json")
    builds = sorted((p for p in out.iterdir() if re.fullmatch(r"CullingBay-[0-9]+\.ipa", p.name)),
                    key=lambda p: int(p.stem.split("-")[1]), reverse=True)
    # Always retain the just-published file, even when building an older checkout.
    keep = {name}
    for path in builds:
        if len(keep) < 5:
            keep.add(path.name)
        if path.name not in keep:
            path.unlink()
print(f"Published {name}: {metadata['bytes']} bytes, SHA-256 {metadata['sha256']}")
PUBLISH

if ((screenshot)); then
    # Failure here must not hide a successful device build and publication.
    if run_stdin ssh "${ssh_opts[@]}" "$host" \
        "zsh -lc 'exec bash -s -- $build'" <<'MAC_SCREENSHOT'
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"
cd "$HOME/photo-culling-ios"
rm -f build/CullingBay.png
xcodebuild -project CullingBay.xcodeproj -scheme CullingBay -configuration Release \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath build/Simulator build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    CURRENT_PROJECT_VERSION="$1"
xcrun simctl list devices available --json > build/simulators.json
simulator=$(python3 - <<'SELECT_SIM'
import json
import re

with open("build/simulators.json") as stream:
    devices = json.load(stream)["devices"]
choices = [(tuple(map(int, re.findall(r"\d+", runtime))), device["name"], device["udid"])
           for runtime, entries in devices.items() if ".iOS-" in runtime
           for device in entries if device.get("isAvailable") and device["name"].startswith("iPhone")]
if not choices:
    raise SystemExit("No available iPhone simulator; install an iOS runtime in Xcode.")
print(max(choices)[2])
SELECT_SIM
)
# Already booted is harmless; bootstatus still fails if the device cannot start.
xcrun simctl boot "$simulator" || true
xcrun simctl bootstatus "$simulator" -b
xcrun simctl install "$simulator" build/Simulator/Build/Products/Release-iphonesimulator/CullingBay.app
xcrun simctl launch "$simulator" co.dannywhite.cullingbay
sleep 3
# Use the selected UUID, because another simulator might already be booted too.
xcrun simctl io "$simulator" screenshot build/CullingBay.png
MAC_SCREENSHOT
    then
        if run scp "${ssh_opts[@]}" "$host:photo-culling-ios/build/CullingBay.png" "$stage/CullingBay.png"; then
            run mv -f -- "$stage/CullingBay.png" "$out/CullingBay.png"
        else
            printf 'Screenshot copy failed; the IPA is ready.\n' >&2
        fi
    else
        printf 'Simulator screenshot failed; the IPA is ready.\n' >&2
    fi
fi
printf 'Phone: http://100.82.57.4:8000/m/ios/\n'
