import AppKit
import SwiftUI

@MainActor final class FontManagementModel: ObservableObject {
    @Published var files: [LocalFontFile] = []
    @Published var families: [LocalFontFamily] = []
    @Published var selected: Set<String> = []
    @Published var query = ""
    @Published var onlyDeletable = false
    @Published var isProcessing = false
    @Published var status = "选择字体后，可批量移到电脑废纸篓。"
    @Published var results: [FontTrashResult] = []
    let store = FontTrashStore()
    var selectedFiles: [LocalFontFile] { LocalFontFamily.selectedFiles(in: families, selected: selected) }
    func visibleFamilies(appModel: AppModel) -> [LocalFontFamily] {
        let byID = Dictionary(uniqueKeysWithValues: families.map { ($0.id, $0) })
        let matching = appModel.fonts.compactMap { byID[$0.id] }.filter { item in
            (!onlyDeletable || item.canTrash) &&
            (item.font.matches(query, custom: appModel.custom[item.id]) ||
             item.files.contains { $0.url.path.localizedCaseInsensitiveContains(query) })
        }
        return appModel.sortedFonts(matching.map(\.font)).compactMap { byID[$0.id] }
    }
    func refresh(_ fonts: [FontRecord]) {
        guard !isProcessing else { return }
        files = LocalFontFile.catalog(fonts, store: store)
        families = LocalFontFamily.catalog(fonts, files: files)
        selected.formIntersection(Set(families.filter(\.canTrash).map(\.id)))
    }
    func selectVisible(_ visible: [LocalFontFamily]) { selected.formUnion(visible.filter(\.canTrash).map(\.id)) }
    func requestDeletion(appModel: AppModel) {
        guard !isProcessing else { return }
        let chosen = selectedFiles
        guard !chosen.isEmpty else { return }
        let snapshots: [FontTrashSelection]
        do { snapshots = try chosen.map(store.selection) }
        catch { status = "未执行删除：\(error.localizedDescription)"; refresh(appModel.fonts); return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "确认将 \(chosen.count) 个字体文件移到废纸篓？"
        alert.informativeText = "请核对下方文件。共用同一文件的字重或字体会一起移除；正在使用这些字体的软件可能需要重新打开。共享字体的移除可能影响其他用户。文件可从废纸篓还原，并在字体册中重新启用。"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: CGFloat(min(280, max(100, chosen.count * 52)))))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        text.isEditable = false; text.isSelectable = true; text.font = .systemFont(ofSize: 11)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.string = chosen.map { "\($0.title) · \($0.faceCount) 种样式\n\($0.url.path)" }.joined(separator: "\n\n")
        text.sizeToFit(); scroll.documentView = text; alert.accessoryView = scroll
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "移到废纸篓")
        alert.buttons[1].hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        isProcessing = true; appModel.fontOperationInProgress = true
        results = []; status = "正在处理 \(snapshots.count) 个字体文件…"
        Task {
            defer { isProcessing = false; appModel.fontOperationInProgress = false }
            let store = self.store
            let batch = await Task.detached(priority: .userInitiated) { snapshots.map(store.trash) }.value
            results = batch
            let removed = Set(batch.filter(\.success).map { $0.file.id })
            selected.subtract(families.filter { !$0.fileIDs.isDisjoint(with: removed) }.map(\.id))
            files.removeAll { removed.contains($0.id) }
            families.removeAll { $0.fileIDs.isSubset(of: removed) }
            let failed = batch.count - removed.count
            status = "已移到废纸篓 \(removed.count) 个文件" + (failed > 0 ? "；\(failed) 个未完成，文件已保留，请查看结果。" : "。")
            appModel.reload()
        }
    }
    func openTrash() {
        do {
            let url = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            if !NSWorkspace.shared.open(url) { status = "无法打开废纸篓，请从程序坞打开。" }
        } catch { status = "请从程序坞打开废纸篓。" }
    }
}

struct FontManagementView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var manager: FontManagementModel
    @FocusState private var searchFocused: Bool
    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 14, alignment: .top)]
    private var visible: [LocalFontFamily] { manager.visibleFamilies(appModel: appModel) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("本地字体管理").font(.system(size: 24, weight: .semibold))
                    Text("字体册已启用字体 · 字重样式已合并 · 点击卡片多选")
                        .font(.system(size: 11)).foregroundColor(Palette.muted)
                }
                Spacer()
                sortMenu
                Button("刷新") { appModel.reload() }.buttonStyle(QuietButton()).disabled(manager.isProcessing || appModel.loading)
                Button("打开废纸篓") { manager.openTrash() }.buttonStyle(QuietButton())
            }
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(Palette.muted)
                    TextField("搜索字体：中文 / 拼音 / English / 文件名", text: $manager.query)
                        .textFieldStyle(.plain).focused($searchFocused)
                    if !manager.query.isEmpty {
                        Button { manager.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("清空搜索")
                    }
                }.padding(10).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 9))
                Toggle("只看可删除字体", isOn: $manager.onlyDeletable).font(.system(size: 11)).fixedSize()
            }
            HStack(spacing: 12) {
                TextField("输入预览文字", text: $appModel.preview).textFieldStyle(.roundedBorder)
                Text("\(Int(appModel.size)) pt").font(.system(size: 10, design: .monospaced)).foregroundColor(Palette.muted).fixedSize()
                Slider(value: $appModel.size, in: 18...60).tint(Palette.green).frame(width: 120)
            }
            HStack {
                Button("全选可删除项") { manager.selectVisible(visible) }.buttonStyle(QuietButton())
                Button("取消选择") { manager.selected = [] }.buttonStyle(QuietButton())
                Text("\(visible.count) 个字体家族 · 已选 \(manager.selected.count) 个 / \(manager.selectedFiles.count) 个文件")
                    .font(.system(size: 11)).foregroundColor(Palette.muted).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Button(role: .destructive) { manager.requestDeletion(appModel: appModel) } label: {
                    Label("删除已选…", systemImage: "trash")
                }.buttonStyle(.bordered).fixedSize().disabled(manager.selected.isEmpty)
            }.disabled(manager.isProcessing)
            if appModel.loading && manager.families.isEmpty {
                ProgressView("正在读取字体册中的字体…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(visible) { item in
                            FontManagementCard(appModel: appModel, manager: manager, item: item)
                        }
                    }.padding(1)
                    if visible.isEmpty {
                        Text("没有符合条件的字体").foregroundColor(Palette.muted).frame(maxWidth: .infinity).padding(40)
                    }
                }
            }
            if !manager.results.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(manager.results) { result in
                            Text("\(result.file.url.lastPathComponent)：\(result.message)").font(.system(size: 10)).foregroundColor(result.success ? Palette.green : .red).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 90)
            }
            HStack {
                if manager.isProcessing { ProgressView().controlSize(.small) }
                Text(manager.status).font(.system(size: 11)).foregroundColor(Palette.muted).textSelection(.enabled)
            }
        }.padding(24).background(Palette.canvas)
            .onReceive(NotificationCenter.default.publisher(for: .focusFontSearch)) { _ in searchFocused = true }
            .onReceive(NotificationCenter.default.publisher(for: .dismissTextFocus)) { _ in searchFocused = false }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(FontSortOrder.allCases) { order in
                Button { appModel.sortOrder = order } label: {
                    if appModel.sortOrder == order {
                        Label(order.title, systemImage: "checkmark")
                    } else {
                        Text(order.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 11))
                Text(appModel.sortOrder.title).font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.foregroundColor(Palette.green).padding(.horizontal, 12).frame(height: 32)
                .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(manager.isProcessing || appModel.loading)
            .help("选择字体排序方式，与全部字体共用并保存设置")
            .accessibilityLabel("排序方式：\(appModel.sortOrder.title)")
    }
}

private struct FontManagementCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundColor(Palette.ink).opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private struct FontManagementCard: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var manager: FontManagementModel
    let item: LocalFontFamily
    private var chosen: Bool { manager.selected.contains(item.id) }
    private var face: FontFace { appModel.previewFace(item.font) }
    private var preview: String {
        let text = appModel.preview.isEmpty ? "把灵感，写成日常。" : appModel.preview
        return !face.supportsChinese && FontNames.hasHan(text) ? "The quick brown fox" : text
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if chosen { manager.selected.remove(item.id) } else { manager.selected.insert(item.id) }
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(appModel.chineseName(item.font) ?? appModel.englishName(item.font))
                            .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: chosen ? "checkmark.square.fill" : "square")
                            .font(.system(size: 16)).foregroundColor(item.canTrash ? Palette.green : Palette.muted.opacity(0.5))
                    }
                    Text(appModel.englishName(item.font)).font(.system(size: 10)).foregroundColor(Palette.muted).lineLimit(1)
                    Text("\(item.font.faces.count) 种样式 · \(item.files.count) 个文件")
                        .font(.system(size: 10)).foregroundColor(Palette.muted)
                    Text(preview).font(.custom(face.id, size: appModel.size))
                        .lineLimit(2).frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72, alignment: .leading)
                        .clipped().padding(.top, 5)
                    Text("Aa Bb Cc 0123456789").font(.custom(face.id, size: 14))
                        .lineLimit(1).frame(height: 22, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16).contentShape(Rectangle())
            }.buttonStyle(FontManagementCardButtonStyle()).disabled(!item.canTrash || manager.isProcessing)
                .accessibilityLabel("\(item.font.english)，\(chosen ? "已选择" : "未选择")")
                .help(item.unavailableReason ?? "选择此家族的全部字体文件；共用文件的其他字体也会一起移除")
            HStack(spacing: 6) {
                Text(item.unavailableReason ?? (chosen ? "已选择" : "可移到废纸篓"))
                    .font(.system(size: 9)).foregroundColor(Palette.muted).lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    if let url = face.sourceURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } label: {
                    Label("查看位置", systemImage: "folder").font(.system(size: 10))
                }.buttonStyle(.plain).foregroundColor(Palette.green).disabled(face.sourceURL == nil)
                    .help(face.sourceURL?.path ?? "字体文件不可用")
            }.padding(.horizontal, 16).padding(.bottom, 14)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .background(chosen ? Palette.mint : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(chosen ? Palette.green : Palette.line.opacity(0.6), lineWidth: 1))
    }
}
