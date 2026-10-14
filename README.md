# 字体检索 · Font Finder

好字体，随手就能找到。

字体检索是一款原生 Mac 字体工具，本机检索可离线使用，网盘入口支持下载后查重安装。输入中文、拼音、拼音首字母或英文，查找本机已安装并启用的字体，预览不同字重，并复制中文或英文家族名称。

![字体检索软件界面](docs/assets/app-preview.png)

## 下载 v1.6

| 下载文件 | 用途 |
| --- | --- |
| [下载 macOS 通用版](https://github.com/sudazz777/ZiTiJianSuo/raw/refs/heads/main/docs/downloads/FontFinder-macOS-Universal-v1.6.zip) | Apple 芯片与 Intel Mac，部署目标 macOS 13+ |

v1.6 安装包由 GitHub Actions 在 macOS 上构建，包含 Apple 芯片和 Intel 两种架构。部署目标不代表所有 macOS 版本均已实机验证。v1.4、v1.5 下载包与已有 GitHub 字体库文件保留在仓库中。

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

## 百度网盘字体安装

选择左侧「网盘字体安装」，粘贴分享链接或分享文字。软件识别提取码，打开百度页面，必要时在软件内登录或验证，不需要 GitHub 令牌或后台配置。

软件尝试下载当前网页可见的字体与 ZIP；下载后根据内部 PostScript 名称准确查重，缺失字体安装到当前用户的 `~/Library/Fonts`。macOS 确认安装成功或所有字体已存在后，自动删除本次临时下载和解压文件。失败任务保留，已安装字体不删除。

百度可能要求客户端、手动点击或额外验证，网页自动下载不能保证适用于所有分享。如果网页不能直接下载，可以用网盘客户端下载，再点击「导入下载文件」；后续查重、安装和临时清理自动完成。文件夹需在网页中打开；ZIP 内容与准确字体身份需下载后识别。

导入本地文件默认保留原件，勾选对应选项后，成功处理的单独选择文件会移到废纸篓。导入文件夹始终保留原文件夹及其内容。本版本没有邮箱账号或用户云端记录。

完整流程和限制见 [网盘字体安装说明](documentation/netdisk-installation.md)。

## 源码构建

在 macOS 上安装 Xcode 或 Apple Command Line Tools，在仓库根目录运行：

```bash
bash build.sh
```

脚本编译 arm64 和 x86_64 两个分支，合并为 `字体检索.app` 并进行本地签名。主要使用 SwiftUI、AppKit、CoreText、WebKit 和系统 libarchive，无需额外运行环境。libarchive API 头文件及其版权声明保存在 `Tools/libarchive`。

在 macOS 上运行内置自测：

```bash
"字体检索.app/Contents/MacOS/FontName" --self-test
```

内置测试需要 macOS 字体服务与剪贴板。构建流程还运行网盘安装测试，覆盖真实字体持久安装、查重、嵌套 ZIP、成功清理与失败保留，以及 WebKit 本地页面的识别和下载按钮操作。百度实际登录、验证码与分享下载尚未实测，这些测试不代表所有百度分享均可自动下载。

验证记录见 [v1.6 构建测试记录](documentation/v1.6-validation.md)。随原始源码提供的旧记录保存在 [documentation/supplied-validation.txt](documentation/supplied-validation.txt)。

## 发布页面

已发布：[打开字体检索下载页面](https://font-finder-release-sudazz777.meisen111.chatgpt.site)。Sites 当前使用默认私有访问设置，仅网站所有者可访问；仓库中的下载链接也可直接使用。

中文发布页面位于 [docs/index.html](docs/index.html)，包含软件实际截图、功能介绍、版本说明、安装指南，以及真实的 macOS 下载按钮。页面无需构建，也没有第三方前端依赖。

本地预览：

```bash
python3 -m http.server 8000 --directory docs
```

访问 `http://localhost:8000`。如需使用 GitHub Pages，在仓库 **Settings → Pages** 中选择 **Deploy from a branch → main → /docs** 并保存。

更多软件操作说明见 [使用说明](documentation/user-guide.md)。原说明中的 DMG 未包含在本次交付中，请使用上述 ZIP 安装方式。
