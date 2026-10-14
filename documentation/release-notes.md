# 字体检索 1.4

## 本版本更新

- 读取本机已启用、持久注册且有实际文件的字体，过滤隐藏、未下载和应用临时加载的字体。
- 同一字体家族的不同字重与样式合并成一行，在详情区切换预览。
- 旧版按字重记录的收藏、最近复制和别名迁移到字体家族条目。

## 下载与安装

安装包：`docs/downloads/FontFinder-macOS-Universal-v1.4.zip`。

解压后，将「字体检索.app」拖入 Applications。部署目标 macOS 13+，包含 Apple 芯片与 Intel 两种架构。应用采用本地 ad-hoc 签名，尚未完成 Developer ID 签名及 Apple 公证。

源码包：`docs/downloads/FontFinder-Source-v1.4.zip`。

两个 ZIP 均为上传文件中已有的发布包，未修改其内容。校验值见 `docs/downloads/SHA256SUMS.txt`。

## 本次仓库导入验证

- 下载包的 SHA-256 与随包校验文件一致。
- 两个 ZIP 均通过压缩文件完整性检查。
- 应用主程序为包含 arm64 与 x86_64 的 Universal Mach-O 文件。
- 仓库中的 Swift 源码与随包源码 ZIP 对应文件一致。
- 已检查构建脚本语法；Linux 环境未重新构建或运行 macOS 应用。
