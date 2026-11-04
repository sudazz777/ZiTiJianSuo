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
layout_python="${FONTFINDER_LAYOUT_PYTHON:-$ROOT/.build/dmg-layout/bin/python}"
"$layout_python" "$ROOT/Tools/dmg-layout.py" --verify "$mountpoint"
test "$(readlink "$mountpoint/应用程序")" = /Applications
codesign --verify --deep --strict "$mountpoint/字体检索.app"
sudo ditto "$mountpoint/字体检索.app" /Applications/字体检索.app
python3 "$ROOT/Tools/verify-installed-app.py"
echo "SUCCESS: DMG mounted, Applications shortcut verified and app copied into /Applications"
