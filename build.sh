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
  xcrun clang -I "$ROOT/Tools/libarchive" -O2 -arch "$ARCH" -mmacosx-version-min=13.0 -c "$ROOT/Tools/FontArchiveBridge.c" -o "$BUILD/FontArchive-$ARCH.o"
  xcrun swiftc -swift-version 5 -O -module-cache-path "$BUILD/cache" \
    -target "$ARCH-apple-macosx13.0" -import-objc-header "$ROOT/Tools/FontArchiveBridge.h" "$ROOT"/Source/*.swift "$BUILD/FontArchive-$ARCH.o" \
    -o "$BUILD/FontName-$ARCH" -framework AppKit -framework SwiftUI -framework CoreText -framework WebKit -larchive
done
xcrun lipo -create "$BUILD/FontName-arm64" "$BUILD/FontName-x86_64" -output "$APP/Contents/MacOS/FontName"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/AppIcon.icns" ]; then cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/"; fi
codesign --force --sign - "$APP"
echo "Built $APP"
