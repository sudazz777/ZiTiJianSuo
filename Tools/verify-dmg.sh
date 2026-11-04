#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
release_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/字体检索.app/Contents/Info.plist")
disk_image="$ROOT/release/FontFinder-macOS-Universal-v$release_version.dmg"
staging=$(mktemp -d "${TMPDIR:-/tmp}/FontFinder-dmg-test.XXXXXX")
mountpoint="$staging/volume"
mounted=false
cleanup() {
  if [ "$mounted" = true ]; then
    hdiutil detach "$mountpoint" || hdiutil detach -force "$mountpoint" || return 1
  fi
  rm -rf "$staging"
}
trap cleanup EXIT
mkdir -p "$mountpoint"
hdiutil attach "$disk_image" -readonly -nobrowse -mountpoint "$mountpoint"
mounted=true
cmp "$mountpoint/安装字体检索.pkg" "$ROOT/release/FontFinder-macOS-Universal-v$release_version.pkg"
test -s "$mountpoint/安装说明.txt"
sudo installer -pkg "$mountpoint/安装字体检索.pkg" -target /
python3 "$ROOT/Tools/verify-installed-app.py"
echo "SUCCESS: DMG mounted, embedded installer verified and app installed in /Applications"
