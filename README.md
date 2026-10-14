# 字体检索 · Font Finder

好字体，随手就能找到。

字体检索是一款离线运行的原生 Mac 字体工具。输入中文、拼音、拼音首字母或英文，查找本机已安装并启用的字体，预览不同字重，并复制中文或英文家族名称。

![字体检索软件界面](docs/assets/app-preview.png)

## 下载 v1.4

| 下载文件 | 用途 |
| --- | --- |
| [下载 macOS 通用版](https://github.com/sudazz777/ZiTiJianSuo/raw/refs/heads/main/docs/downloads/FontFinder-macOS-Universal-v1.4.zip) | Apple 芯片与 Intel Mac，部署目标 macOS 13+ |
| [下载源码](https://github.com/sudazz777/ZiTiJianSuo/raw/refs/heads/main/docs/downloads/FontFinder-Source-v1.4.zip) | Swift 源码、构建脚本和说明文档 |
| [SHA-256 校验文件](docs/downloads/SHA256SUMS.txt) | 检查下载文件完整性 |

安装包和源码下载包来自上传的 v1.4 交付文件，保持原始内容与校验值。部署目标不代表所有 macOS 版本均已实机验证。

## 安装

1. 下载并解压 macOS 通用版 ZIP。
2. 将「字体检索.app」拖入 Applications（应用程序）文件夹。
3. 双击应用，输入中文、拼音或英文搜索字体。

当前应用采用本地 ad-hoc 签名，尚未完成 Developer ID 签名或 Apple 公证。如果首次打开提示无法验证开发者，先尝试打开一次，再前往「系统设置 → 隐私与安全性」，对确认来源的应用选择「仍要打开」。参考 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。

## 功能

- 中文、拼音、首字母、英文及 PostScript 名称搜索。
- 同一家族的字重合并，切换样式、文字及字号进行预览。
- 一键复制中英文家族名称，自定义中英文别名。
- 全部字体、中文字体、收藏及最近复制分类。
- 英文名称、中文拼音及最近复制等六种排序方式。
- 离线运行，收藏、别名和最近复制保存在本机。

安装包不含字体文件；每台 Mac 显示各自安装的字体。复制的是名称文字，当前版本没有直接连接设计软件写入字体的功能。

## 源码构建

在 macOS 上安装 Xcode 或 Apple Command Line Tools，在仓库根目录运行：

```bash
bash build.sh
```

脚本编译 arm64 和 x86_64 两个分支，合并为 `字体检索.app` 并进行本地签名。主要使用 SwiftUI、AppKit、CoreText 和 Foundation，无第三方运行时依赖。

在 macOS 上运行内置自测：

```bash
"字体检索.app/Contents/MacOS/FontName" --self-test
```

内置测试需要 macOS 字体服务与剪贴板。本次导入环境为 Linux，没有重新运行 macOS 构建和应用自测。随包提供的测试记录保存在 [documentation/supplied-validation.txt](documentation/supplied-validation.txt)，作为原始交付记录保留。

## 发布页面

中文发布页面位于 [docs/index.html](docs/index.html)，包含软件实际截图、功能介绍、版本说明、安装指南，以及真实的 macOS 和源码下载按钮。页面无需构建，也没有第三方前端依赖。

本地预览：

```bash
python3 -m http.server 8000 --directory docs
```

访问 `http://localhost:8000`。如需使用 GitHub Pages，在仓库 **Settings → Pages** 中选择 **Deploy from a branch → main → /docs** 并保存。

更多软件操作说明见 [使用说明](documentation/user-guide.md)。原说明中的 DMG 未包含在本次交付中，请使用上述 ZIP 安装方式。
