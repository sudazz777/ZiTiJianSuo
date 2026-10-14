#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${FONTNAME_BUILD_DIR:-$ROOT/.build}"
APP="$ROOT/字体检索.app"
mkdir -p "$BUILD/cache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ ! -f "$ROOT/AppIcon.icns" ]; then
  swift -module-cache-path "$BUILD/cache" "$ROOT/Tools/AppIcon.swift" "$BUILD"
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$ROOT/AppIcon.icns"
fi
for ARCH in arm64 x86_64; do
  echo "Building $ARCH (macOS 13+)…"
  xcrun swiftc -swift-version 5 -O -module-cache-path "$BUILD/cache" \
    -target "$ARCH-apple-macosx13.0" "$ROOT"/Source/*.swift \
    -o "$BUILD/FontName-$ARCH" -framework AppKit -framework SwiftUI -framework CoreText
done
xcrun lipo -create "$BUILD/FontName-arm64" "$BUILD/FontName-x86_64" -output "$APP/Contents/MacOS/FontName"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/AppIcon.icns" ]; then cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/"; fi
codesign --force --sign - "$APP"
echo "Built $APP"
