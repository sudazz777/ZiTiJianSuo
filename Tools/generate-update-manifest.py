"""Generate GitHub release metadata from the PKG that was actually built."""
import hashlib
import json
from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[1]
with (root / '字体检索.app/Contents/Info.plist').open('rb') as source:
    info = plistlib.load(source)
version = info['CFBundleShortVersionString']
assert re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', version)
build = int(info['CFBundleVersion'])
package = root / 'release' / f'FontFinder-macOS-Universal-v{version}.pkg'
notes = json.loads((root / 'updates/release-notes.json').read_text())
assert isinstance(notes, list) and 0 < len(notes) <= 20
assert all(isinstance(note, str) and len(note) <= 500 for note in notes)
manifest = {
    'schemaVersion': 1, 'version': version, 'build': build,
    'releaseNotes': notes,
    'downloadURL': f'https://github.com/sudazz777/ZiTiJianSuo/releases/download/v{version}/{package.name}',
    'sha256': hashlib.sha256(package.read_bytes()).hexdigest(),
    'size': package.stat().st_size,
}
(root / 'release/latest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
body = '\n'.join(f'- {note}' for note in notes)
(root / 'release/release-notes.md').write_text(
    f'{body}\n\n下载 PKG，退出旧版后按安装向导更新到「应用程序」。\n\n'
    '安装包尚未签名公证，首次打开可能需要在「隐私与安全性」中确认。\n'
)
print(f'Generated update metadata for v{version} build {build}')
