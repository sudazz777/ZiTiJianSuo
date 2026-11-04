#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/字体检索.app"
release_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
disk_image="$ROOT/release/FontFinder-macOS-Universal-v$release_version.dmg"
staging=$(mktemp -d "${TMPDIR:-/tmp}/FontFinder-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/contents" "$ROOT/release"
codesign --verify --deep --strict "$APP"
ditto "$APP" "$staging/contents/字体检索.app"
ln -s /Applications "$staging/contents/应用程序"
cp "$ROOT/AppIcon.icns" "$staging/contents/.VolumeIcon.icns"
hdiutil create -volname "字体检索 v$release_version" -srcfolder "$staging/contents" \
  -fs HFS+ -format UDZO -ov "$disk_image"
hdiutil verify "$disk_image"
echo "Created drag-to-install DMG with an Applications shortcut"
