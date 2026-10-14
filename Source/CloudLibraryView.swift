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
                if model.account.isAdmin {
                    Button { Task { await model.chooseUpload() } } label: { Label("上传字体", systemImage: "icloud.and.arrow.up") }
                        .buttonStyle(QuietButton()).disabled(model.controlsDisabled)
                }
                Button { Task { await model.syncMissing() } } label: { Label("下载未同步（\(model.missing.count)）", systemImage: "icloud.and.arrow.down") }
                    .buttonStyle(QuietButton(active: true)).disabled(model.controlsDisabled || model.missing.isEmpty)
            }.padding(24)
            if model.account.user != nil {
                HStack {
                    Picker("字体分类", selection: $model.accountFilter) { Text("全部字体").tag("全部字体"); Text("我的收藏").tag("我的收藏"); Text("我的下载记录").tag("我的下载记录") }
                        .pickerStyle(.segmented).frame(maxWidth: 420)
                    Spacer()
                    Button("按账号记录恢复") { Task { await model.restoreAccountFonts() } }.buttonStyle(QuietButton()).disabled(model.controlsDisabled)
                }.padding(.horizontal, 24).padding(.bottom, 15)
            }
            if let error = model.errorMessage ?? model.account.errorMessage {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button { model.errorMessage = nil; model.account.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.font(.system(size: 11)).foregroundColor(Color(red: 0.55, green: 0.24, blue: 0.13))
                    .padding(12).background(Color(red: 0.99, green: 0.94, blue: 0.88)).cornerRadius(8).padding(.horizontal, 24).padding(.bottom, 12)
            }
            if model.visible.isEmpty {
                Spacer()
                VStack(spacing: 13) {
                    Image(systemName: "icloud").font(.system(size: 38, weight: .light)).foregroundColor(Palette.green)
                    Text(!model.account.configured ? "自动同步服务尚未配置" : model.query.isEmpty ? "字体库还没有字体" : "没有找到匹配字体").font(.system(size: 18, weight: .medium))
                    Text(!model.account.configured ? "可先打开百度网盘分享下载字体。\n后台配置完成后，这里会显示可自动同步的字体。" : model.query.isEmpty ? "维护者上传后，刷新即可下载。\n换电脑时，在这里恢复需要的字体。" : "试试中文、拼音或英文名称。")
                        .font(.system(size: 12)).foregroundColor(Palette.muted).multilineTextAlignment(.center).lineSpacing(5)
                    if model.isLoading { ProgressView().controlSize(.small) }
                    if let share = model.share {
                        Button("打开百度网盘字体分享") { NSWorkspace.shared.open(share.url) }.buttonStyle(QuietButton(active: true))
                        HStack(spacing: 9) {
                            Text("提取码：\(share.extractionCode)").font(.system(size: 11)).foregroundColor(Palette.muted)
                            Button("复制提取码") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(share.extractionCode, forType: .string) }
                                .buttonStyle(QuietButton())
                        }
                    }
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
                if let share = model.share {
                    Button("网盘分享下载") { NSWorkspace.shared.open(share.url) }.buttonStyle(.plain).foregroundColor(Palette.green)
                }
                Button("打开下载文件夹") { model.revealFolder() }.buttonStyle(.plain).foregroundColor(Palette.green)
                Button(model.account.user?.email ?? "邮箱登录 / 注册") { model.account.errorMessage = nil; model.showAccount = true }
                    .buttonStyle(.plain).foregroundColor(Palette.green).disabled(model.controlsDisabled)
            }.font(.system(size: 10)).foregroundColor(Palette.muted).padding(.horizontal, 24).frame(height: 45)
                .background(Color.white.opacity(0.6))
        }.task { await model.open() }
            .onReceive(NotificationCenter.default.publisher(for: .refreshCloudFonts)) { _ in Task { await model.refresh() } }
            .onReceive(NotificationCenter.default.publisher(for: .focusFontSearch)) { _ in searchFocused = true }
            .sheet(isPresented: $model.showAccount) { EmailAccountView(account: model.account) }
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
            if model.account.user != nil {
                Button { Task { await model.account.toggleFavorite(font) } } label: {
                    Image(systemName: model.account.favorites.contains(font.id) ? "star.fill" : "star").foregroundColor(Palette.green)
                }.buttonStyle(.plain).disabled(model.controlsDisabled).help("收藏到当前邮箱账号")
            }
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
