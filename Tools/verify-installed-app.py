"""Verify a DMG app copied into Applications."""
import hashlib
from pathlib import Path
import plistlib
import subprocess

source = Path(__file__).resolve().parents[1] / '字体检索.app'
installed = Path('/Applications/字体检索.app')
assert installed.is_dir(), 'App was not installed in /Applications'
with (source / 'Contents/Info.plist').open('rb') as handle:
    expected = plistlib.load(handle)
with (installed / 'Contents/Info.plist').open('rb') as handle:
    actual = plistlib.load(handle)
for key in ['CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString']:
    assert actual[key] == expected[key], f'Installed app differs: {key}'
source_files = {p.relative_to(source) for p in source.rglob('*') if p.is_file()}
installed_files = {p.relative_to(installed) for p in installed.rglob('*') if p.is_file()}
assert source_files == installed_files, 'Installed bundle contents differ'
for relative in source_files:
    assert hashlib.sha256((source / relative).read_bytes()).digest() == hashlib.sha256((installed / relative).read_bytes()).digest(), f'Installed file differs: {relative}'
subprocess.run(['xcrun', 'lipo', str(installed / 'Contents/MacOS/FontName'), '-verify_arch', 'arm64', 'x86_64'], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(installed)], check=True)
print('SUCCESS: DMG app was copied intact to /Applications with its code signature preserved')
