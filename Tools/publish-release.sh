#!/bin/bash
set -euo pipefail
release_version=$(python3 - <<'PY'
import hashlib, json, pathlib, re
manifest = json.loads(pathlib.Path('release/latest.json').read_text())
version = manifest['version']
assert re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', version)
package = pathlib.Path('release') / f'FontFinder-macOS-Universal-v{version}.pkg'
assert manifest['downloadURL'] == f'https://github.com/sudazz777/ZiTiJianSuo/releases/download/v{version}/{package.name}'
assert hashlib.sha256(package.read_bytes()).hexdigest() == manifest['sha256']
assert package.stat().st_size == manifest['size']
disk_image = pathlib.Path('release') / f'FontFinder-macOS-Universal-v{version}.dmg'
assert manifest['diskImageURL'] == f'https://github.com/sudazz777/ZiTiJianSuo/releases/download/v{version}/{disk_image.name}'
assert hashlib.sha256(disk_image.read_bytes()).hexdigest() == manifest['diskImageSHA256']
assert disk_image.stat().st_size == manifest['diskImageSize']
print(version)
PY
)
release_tag="v$release_version"
if release_is_draft=$(gh release view "$release_tag" --json isDraft --jq '.isDraft' 2>/dev/null); then
  if [ "$release_is_draft" = "false" ]; then
    echo "Release $release_tag is already published; published assets are preserved."
    exit 0
  fi
else
  gh release create "$release_tag" --draft --target "$GITHUB_SHA" \
    --title "字体检索 $release_tag" --notes-file release/release-notes.md
fi
gh release upload "$release_tag" \
  "release/FontFinder-macOS-Universal-v$release_version.dmg" \
  "release/FontFinder-macOS-Universal-v$release_version.pkg" \
  release/latest.json release/SHA256SUMS.txt --clobber
gh release edit "$release_tag" --draft=false --latest \
  --title "字体检索 $release_tag" --notes-file release/release-notes.md
echo "Published https://github.com/$GH_REPO/releases/tag/$release_tag"
