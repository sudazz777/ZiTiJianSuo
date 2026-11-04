#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
staging=$(mktemp -d "${TMPDIR:-/tmp}/FontFinder-legacy-update.XXXXXX")
trap 'rm -rf "$staging"' EXIT
if ! git -C "$ROOT" cat-file -e v1.9:Source/AppUpdater.swift 2>/dev/null; then
  git -C "$ROOT" fetch --depth=1 origin refs/tags/v1.9:refs/tags/v1.9
fi
git -C "$ROOT" show v1.9:Source/AppUpdater.swift > "$staging/LegacyUpdater.swift"
xcrun swiftc -swift-version 5 -parse-as-library "$staging/LegacyUpdater.swift" \
  "$ROOT/Tools/LegacyUpdateProbe.swift" -o "$staging/check"
"$staging/check" "$ROOT/release/latest.json"
