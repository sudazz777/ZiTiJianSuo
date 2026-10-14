# 云端字体 · v1.5

字体由维护者 `sudazz777` 上传到 `sudazz777/ZiTiJianSuo`。其他用户无需登录，直接下载公开字体；下载后可离线使用。本功能没有用户账号、个人私有备份或收藏跨设备同步。

## 维护者连接

1. 用 `sudazz777` 登录 GitHub，进入 [细粒度访问令牌创建页面](https://github.com/settings/personal-access-tokens/new)。
2. Resource owner 选择 `sudazz777`。
3. Repository access 选择 Only select repositories，勾选 `ZiTiJianSuo`。
4. Repository permissions 中，将 **Contents** 设置为 **Read and write**。Metadata 的读取权限由 GitHub 自动提供，不需要账户级管理权限。
5. 设置合适的有效期并生成令牌。不要将令牌放入仓库、发给其他用户或粘贴到聊天中。
6. 软件左侧选择「云端字体」，点击底部「管理员连接」，在软件的密码输入框粘贴令牌并连接。

软件验证登录账号、仓库可见性和写入权限，通过后将令牌保存到当前 Mac 的钥匙串。令牌不保存在配置文件中，不包含在分发安装包中。换电脑或令牌过期后重新连接；「断开并移除凭证」会删除本机保存的令牌。

仓库必须为 Public 才能向普通用户提供匿名下载。如果仍为 Private，前往仓库 Settings → General → Danger Zone → Change repository visibility，修改为 Public。当前实现不会通过软件修改仓库权限。

## 上传字体

连接管理员后，点击「上传字体」，选择一个 TTF、OTF 或 TTC 文件。每个文件上限为 50 MiB。软件验证实际字体内容，读取名称并允许修改显示名称。

确认具有公开分发权限后，点击「公开上传」。文件与清单通过一次 Git 提交同时发布。同一内容的文件不会重复上传；同名文件内容改变时更新清单，并从当前目录移除旧文件。旧内容仍可能保留在 Git 历史中。

上传过程中如果仓库被其他操作修改，软件会报告冲突，不会强制覆盖仓库。刷新后重试即可。

## 下载与换电脑恢复

1. 点击「云端字体」，刷新清单。
2. 点击某款字体的「下载」，或「下载未同步」批量下载尚未保存到当前 Mac 的文件。
3. 软件核对文件大小及 SHA-256。完成后点击「安装字体」，在 macOS 字体册中确认安装。
4. 安装完成后回到本机字体分类，刷新字体即可检索和预览。

下载目录：`~/Library/Application Support/FontFinder/CloudFonts/`。点击「打开下载文件夹」或「在 Finder 中显示」可查看文件。

断网时显示上次保存的清单。已下载文件可以继续安装；无法下载新文件。同步不会自动删除本机字体，也不会把本机系统字体自动上传。

## 仓库结构

- `fonts/index.json`：版本化字体清单，初始为空。
- `fonts/files/<sha256>.<扩展名>`：字体文件，内容校验值作为文件名。
- 每条清单记录包含显示名称、原文件名、文件路径、大小、SHA-256、PostScript 名称及上传时间。

只有你通过软件选择并上传的字体才会进入公开字体库。安装包没有预置或代为上传任何字体。

## 构建和验证

```bash
bash build.sh
"字体检索.app/Contents/MacOS/FontName" --self-test
"字体检索.app/Contents/MacOS/FontName" --cloud-self-test
```

GitHub Actions 在 macOS 上构建 Apple 芯片与 Intel 通用应用，运行本机字体测试和云端功能测试，成功后生成 ZIP 安装包。云端测试通过模拟 GitHub 响应验证权限、清单、重复上传、并发冲突和下载校验，不使用真实访问令牌或上传字体。
