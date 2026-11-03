# 字体检索 · Font Finder

好字体，随手就能找到。

字体检索是一款原生 Mac 字体工具，可离线使用。输入中文、拼音、拼音首字母或英文，查找本机已安装并启用的字体，预览不同字重，并复制中文或英文家族名称。

![字体检索软件界面](docs/assets/app-preview.png)

## 下载 v1.8

| 下载文件 | 用途 |
| --- | --- |
| [下载 macOS 安装包（PKG）](https://github.com/sudazz777/ZiTiJianSuo/raw/refs/heads/main/docs/downloads/FontFinder-macOS-Universal-v1.8.pkg) | Apple 芯片与 Intel Mac，部署目标 macOS 13+ |

v1.8 安装包由 GitHub Actions 在 macOS 上构建，包含 Apple 芯片和 Intel 两种架构。部署目标不代表所有 macOS 版本均已实机验证。旧版下载包与已有字体库文件保留在仓库中。

## 安装

1. 退出正在运行的旧版软件，下载并双击 macOS 通用版 PKG。
2. 按系统安装向导操作；安装器直接将软件放入 `/Applications/字体检索.app`，系统需要时输入管理员密码。
3. 从「应用程序」打开「字体检索」，输入中文、拼音或英文搜索字体。

当前 PKG 未使用 Developer ID Installer 证书签名；应用采用本地 ad-hoc 签名，尚未完成 Apple 公证。如果首次打开提示无法验证开发者，先尝试打开一次，再前往「系统设置 → 隐私与安全性」，对确认来源的应用选择「仍要打开」。参考 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。

## 功能

- 中文、拼音、首字母、英文及 PostScript 名称搜索。
- 同一家族的字重合并，切换样式、文字及字号进行预览。
- 一键复制中英文家族名称，自定义中英文别名。
- 查看字体文件位置，在访达中定位当前预览字重。
- 全部字体、中文字体、收藏及最近复制分类。
- 英文名称、中文拼音及最近复制等六种排序方式。
- 离线运行，收藏、别名和最近复制保存在本机。

安装包不含字体文件；每台 Mac 显示各自安装的字体。复制的是名称文字，当前版本没有直接连接设计软件写入字体的功能。

## v1.8 版本说明

提供 PKG 安装向导，直接安装到「应用程序」，无需手动拖拽。

每张字体卡片右下角新增「查看字体位置」按钮，点击后在访达中选中当前预览字重的字体文件。鼠标悬停显示完整路径。文件已移动或无法访问时提示刷新字体列表。

## 源码构建

在 macOS 上安装 Xcode 或 Apple Command Line Tools，在仓库根目录运行：

```bash
bash build.sh
```

脚本编译 arm64 和 x86_64 两个分支，合并为 `字体检索.app` 并进行本地签名。主要使用 SwiftUI、AppKit 和 CoreText，无需额外运行环境。

构建安装包：

```bash
bash Tools/package-installer.sh
```

在 macOS 上运行内置自测：

```bash
"字体检索.app/Contents/MacOS/FontName" --self-test
```

内置测试需要 macOS 字体服务与剪贴板。GitHub Actions 在 macOS 14 上构建 Universal 应用并运行本机检索测试。

验证记录见 [v1.8 构建测试记录](documentation/v1.8-validation.md)。随原始源码提供的旧记录保存在 [documentation/supplied-validation.txt](documentation/supplied-validation.txt)。

## 发布页面

已发布：[打开字体检索下载页面](https://font-finder-release-sudazz777.meisen7.chatgpt.site)。发布页面当前公开可访问，仓库中的下载链接也可直接使用。

中文发布页面位于 [docs/index.html](docs/index.html)，包含软件实际截图、功能介绍、版本说明、安装指南，以及真实的 macOS 下载按钮。页面无需构建，也没有第三方前端依赖。

本地预览：

```bash
python3 -m http.server 8000 --directory docs
```

访问 `http://localhost:8000`。如需使用 GitHub Pages，在仓库 **Settings → Pages** 中选择 **Deploy from a branch → main → /docs** 并保存。

更多软件操作说明见 [使用说明](documentation/user-guide.md)。推荐使用上述 PKG，直接安装到「应用程序」。
