import SwiftUI
import AppKit

struct CloudLibraryView: View {
    @ObservedObject var model: CloudFontModel
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundColor(Palette.muted)
                TextField("搜索云端字体：中文 / 拼音 / English", text: $model.query)
                    .textFieldStyle(.plain).focused($searchFocused)
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(model.controlsDisabled).help("刷新公开字体清单")
            }.font(.system(size: 12)).padding(24).background(Color.white.opacity(0.8))
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("云端字体").font(.system(size: 25, weight: .semibold))
                    Text("\(model.fonts.count) 个字体文件 · 已下载 \(model.downloaded.count) 个 · 下载无需登录")
                        .font(.system(size: 11)).foregroundColor(Palette.muted)
                }
                Spacer()
                if model.adminLogin != nil {
                    Button { Task { await model.chooseUpload() } } label: { Label("上传字体", systemImage: "icloud.and.arrow.up") }
                        .buttonStyle(QuietButton()).disabled(model.controlsDisabled)
                }
                Button { Task { await model.syncMissing() } } label: { Label("下载未同步（\(model.missing.count)）", systemImage: "icloud.and.arrow.down") }
                    .buttonStyle(QuietButton(active: true)).disabled(model.controlsDisabled || model.missing.isEmpty)
            }.padding(24)
            if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.font(.system(size: 11)).foregroundColor(Color(red: 0.55, green: 0.24, blue: 0.13))
                    .padding(12).background(Color(red: 0.99, green: 0.94, blue: 0.88)).cornerRadius(8).padding(.horizontal, 24).padding(.bottom, 12)
            }
            if model.visible.isEmpty {
                Spacer()
                VStack(spacing: 13) {
                    Image(systemName: "icloud").font(.system(size: 38, weight: .light)).foregroundColor(Palette.green)
                    Text(model.query.isEmpty ? "字体库还没有字体" : "没有找到匹配字体").font(.system(size: 18, weight: .medium))
                    Text(model.query.isEmpty ? "维护者上传后，刷新即可下载。\n换电脑时，在这里恢复需要的字体。" : "试试中文、拼音或英文名称。")
                        .font(.system(size: 12)).foregroundColor(Palette.muted).multilineTextAlignment(.center).lineSpacing(5)
                    if model.isLoading { ProgressView().controlSize(.small) }
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.visible) { font in CloudFontRow(model: model, font: font) }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
            HStack(spacing: 9) {
                if model.controlsDisabled { ProgressView().controlSize(.small).scaleEffect(0.7) }
                Text(model.status).lineLimit(2)
                Spacer()
                Button("打开下载文件夹") { model.revealFolder() }.buttonStyle(.plain).foregroundColor(Palette.green)
                Button(model.adminLogin.map { "管理员：\($0)" } ?? "管理员连接") { model.errorMessage = nil; model.showAdmin = true }
                    .buttonStyle(.plain).foregroundColor(Palette.green).disabled(model.controlsDisabled)
            }.font(.system(size: 10)).foregroundColor(Palette.muted).padding(.horizontal, 24).frame(height: 45)
                .background(Color.white.opacity(0.6))
        }.task { await model.open() }
            .onReceive(NotificationCenter.default.publisher(for: .refreshCloudFonts)) { _ in Task { await model.refresh() } }
            .onReceive(NotificationCenter.default.publisher(for: .focusFontSearch)) { _ in searchFocused = true }
            .sheet(isPresented: $model.showAdmin) { GitHubAdminView(model: model) }
            .sheet(isPresented: $model.showUpload, onDismiss: { model.pending = nil }) {
                if let pending = model.pending { CloudUploadView(model: model, pending: pending) }
            }
    }
}

struct CloudFontRow: View {
    @ObservedObject var model: CloudFontModel
    let font: CloudFont
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "character.book.closed").font(.system(size: 25, weight: .light)).foregroundColor(Palette.green).frame(width: 38)
            VStack(alignment: .leading, spacing: 7) {
                Text(font.displayName).font(.system(size: 16, weight: .semibold))
                Text("\(font.fileName) · \(font.formattedSize) · \(font.uploadedDate)").font(.system(size: 10)).foregroundColor(Palette.muted)
                if !font.postScriptNames.isEmpty {
                    Text(font.postScriptNames.joined(separator: " / ")).font(.system(size: 10)).foregroundColor(Palette.muted).lineLimit(2)
                }
            }
            Spacer()
            if model.downloaded.contains(font.id) {
                Text("已下载").font(.system(size: 10)).foregroundColor(Palette.green)
                Button("在 Finder 中显示") { model.reveal(font) }.buttonStyle(QuietButton()).disabled(model.controlsDisabled)
                Button("安装字体") { Task { await model.install(font) } }.buttonStyle(QuietButton(active: true)).disabled(model.controlsDisabled)
            } else {
                Button { Task { await model.download(font) } } label: { Label("下载", systemImage: "arrow.down.to.line") }
                    .buttonStyle(QuietButton(active: true)).disabled(model.controlsDisabled)
            }
        }.padding(18).background(Color.white.opacity(0.8)).cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
    }
}

struct GitHubAdminView: View {
    @ObservedObject var model: CloudFontModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var token = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("连接字体库管理员").font(.system(size: 21, weight: .semibold))
            Text("只有 \(CloudConfiguration.owner) 可以上传；其他用户下载无需登录。")
                .font(.system(size: 12)).foregroundColor(Palette.muted)
            if let login = model.adminLogin {
                Label("已连接：\(login)", systemImage: "checkmark.shield").foregroundColor(Palette.green)
                Text("令牌仅保存在当前 Mac 的钥匙串中，不会上传到仓库。换电脑需要重新连接。")
                    .font(.system(size: 12)).foregroundColor(Palette.muted)
            } else {
                Text("创建细粒度访问令牌，选择 ZiTiJianSuo 仓库，并授予 Contents（内容）读写权限。")
                    .font(.system(size: 12)).foregroundColor(Palette.muted).fixedSize(horizontal: false, vertical: true)
                Link("前往 GitHub 创建访问令牌 ↗", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    .font(.system(size: 12)).foregroundColor(Palette.green)
                SecureField("粘贴 GitHub 访问令牌", text: $token).textFieldStyle(.roundedBorder).disabled(model.isConnecting)
                Text("连接时验证账号和仓库权限。验证通过后，令牌保存在 Mac 钥匙串中。")
                    .font(.system(size: 11)).foregroundColor(Palette.muted)
            }
            if let error = model.errorMessage { Text(error).font(.system(size: 11)).foregroundColor(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if model.adminLogin != nil { Button("断开并移除凭证") { model.disconnect() }.buttonStyle(QuietButton()).disabled(model.controlsDisabled) }
                if model.isConnecting { ProgressView().controlSize(.small) }
                Spacer()
                Button("关闭") { token = ""; dismiss() }.buttonStyle(QuietButton()).disabled(model.isConnecting)
                if model.adminLogin == nil {
                    Button("连接") { Task { if await model.connect(token) { token = ""; dismiss() } } }
                        .buttonStyle(QuietButton(active: true)).disabled(token.isEmpty || model.controlsDisabled)
                }
            }
        }.padding(28).frame(width: 480).background(Palette.canvas).foregroundColor(Palette.ink)
            .interactiveDismissDisabled(model.isConnecting).onDisappear { token = "" }
    }
}

struct CloudUploadView: View {
    @ObservedObject var model: CloudFontModel
    let pending: PendingCloudFont
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var authorized = false
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("上传到公开字体库").font(.system(size: 21, weight: .semibold))
            Text("\(pending.fileName) · \(ByteCountFormatter.string(fromByteCount: Int64(pending.data.count), countStyle: .file))")
                .font(.system(size: 12)).foregroundColor(Palette.muted)
            TextField("字体显示名称", text: $name).textFieldStyle(.roundedBorder).disabled(model.isBusy)
            Text("上传后所有人都能查看和下载。相同内容不会重复上传；同名文件的新版本会更新云端清单。")
                .font(.system(size: 12)).foregroundColor(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Toggle("我确认有权公开分发这份字体", isOn: $authorized).font(.system(size: 12)).disabled(model.isBusy)
            if let error = model.errorMessage { Text(error).font(.system(size: 11)).foregroundColor(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if model.isBusy { ProgressView().controlSize(.small); Text("正在上传…").font(.system(size: 11)).foregroundColor(Palette.muted) }
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(QuietButton()).disabled(model.isBusy)
                Button("公开上传") { Task { if await model.uploadPending(name: name) { dismiss() } } }
                    .buttonStyle(QuietButton(active: true)).disabled(!authorized || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.controlsDisabled)
            }
        }.padding(28).frame(width: 470).background(Palette.canvas).foregroundColor(Palette.ink)
            .onAppear { name = pending.suggestedName }.interactiveDismissDisabled(model.isBusy)
    }
}
