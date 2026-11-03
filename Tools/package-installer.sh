#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/字体检索.app"
OUTPUT="$ROOT/release"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/FontFinder-installer.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/payload" "$OUTPUT"
codesign --verify --deep --strict "$APP"
ditto "$APP" "$STAGING/payload/字体检索.app"
pkgbuild --analyze --root "$STAGING/payload" "$STAGING/components.plist"
python3 - "$STAGING/components.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as source:
    components = plistlib.load(source)
assert len(components) == 1
assert components[0]['RootRelativeBundlePath'] == '字体检索.app'
# Always install in /Applications even if a copy is running from Downloads.
components[0]['BundleIsRelocatable'] = False
components[0]['BundleOverwriteAction'] = 'upgrade'
with open(path, 'wb') as destination:
    plistlib.dump(components, destination)
PY
pkgbuild --root "$STAGING/payload" \
  --component-plist "$STAGING/components.plist" \
  --identifier local.fontname.mac.installer --version "$VERSION" \
  --install-location /Applications --ownership recommended \
  "$OUTPUT/FontFinder-macOS-Universal-v$VERSION.pkg"
echo "Created installer for /Applications/字体检索.app"
