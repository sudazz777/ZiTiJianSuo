#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/字体检索.app"
release_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
package="$ROOT/release/FontFinder-macOS-Universal-v$release_version.pkg"
disk_image="$ROOT/release/FontFinder-macOS-Universal-v$release_version.dmg"
staging=$(mktemp -d "${TMPDIR:-/tmp}/FontFinder-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/contents"
cp "$package" "$staging/contents/安装字体检索.pkg"
cat > "$staging/contents/安装说明.txt" <<EOF
字体检索 v$release_version

1. 先退出正在运行的旧版「字体检索」。
2. 双击本磁盘中的「安装字体检索.pkg」。
3. 按系统安装向导操作，系统需要时输入管理员密码。
4. 安装器会将软件放入「应用程序」，无需手动拖拽。
5. 从「应用程序」打开「字体检索」，使用完毕后可推出本磁盘。

当前安装器和应用尚未完成 Developer ID 签名及 Apple 公证。
首次打开若提示无法验证开发者，可在确认来源后前往
「系统设置 → 隐私与安全性」选择「仍要打开」。
EOF
cp "$ROOT/AppIcon.icns" "$staging/contents/.VolumeIcon.icns"
hdiutil create -volname "字体检索 v$release_version" -srcfolder "$staging/contents" \
  -fs HFS+ -format UDZO -ov "$disk_image"
hdiutil verify "$disk_image"
echo "Created DMG with an installer targeting /Applications/字体检索.app"
