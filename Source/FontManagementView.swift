import AppKit
import SwiftUI

@MainActor final class FontManagementModel: ObservableObject {
    @Published var files: [LocalFontFile] = []
    @Published var selected: Set<String> = []
    @Published var query = ""
    @Published var onlyDeletable = false
    @Published var isProcessing = false
    @Published var status = "选择字体文件后，可批量移到电脑废纸篓。"
    @Published var results: [FontTrashResult] = []
    let store = FontTrashStore()
    var visible: [LocalFontFile] {
        files.filter { file in
            (!onlyDeletable || file.canTrash) && (query.isEmpty || file.title.localizedCaseInsensitiveContains(query) || file.url.path.localizedCaseInsensitiveContains(query))
        }
    }
    func refresh(_ fonts: [FontRecord]) {
        guard !isProcessing else { return }
        files = LocalFontFile.catalog(fonts, store: store)
        selected.formIntersection(Set(files.filter(\.canTrash).map(\.id)))
    }
    func selectVisible() { selected.formUnion(visible.filter(\.canTrash).map(\.id)) }
    func requestDeletion(appModel: AppModel) {
        guard !isProcessing else { return }
        let chosen = files.filter { selected.contains($0.id) }
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

        isProcessing = true; results = []; status = "正在处理 \(snapshots.count) 个字体文件…"
        Task {
            let store = self.store
            let batch = await Task.detached(priority: .userInitiated) { snapshots.map(store.trash) }.value
            results = batch
            let removed = Set(batch.filter(\.success).map { $0.file.id })
            selected.subtract(removed); files.removeAll { removed.contains($0.id) }
            let failed = batch.count - removed.count
            status = "已移到废纸篓 \(removed.count) 个文件" + (failed > 0 ? "；\(failed) 个未完成，文件已保留，请查看结果。" : "。")
            isProcessing = false
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
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("本地字体管理").font(.system(size: 24, weight: .semibold))
                    Text("管理已安装并启用的字体；同一文件内的字体和字重会一起移动。").font(.system(size: 11)).foregroundColor(Palette.muted)
                }
                Spacer()
                Button("刷新") { appModel.reload() }.buttonStyle(QuietButton()).disabled(manager.isProcessing || appModel.loading)
                Button("打开废纸篓") { manager.openTrash() }.buttonStyle(QuietButton())
            }
            HStack(spacing: 12) {
                TextField("搜索字体名称、文件名或路径", text: $manager.query).textFieldStyle(.roundedBorder).focused($searchFocused)
                Toggle("只看可删除字体", isOn: $manager.onlyDeletable).font(.system(size: 11))
            }
            HStack {
                Button("全选可删除项") { manager.selectVisible() }.buttonStyle(QuietButton())
                Button("取消选择") { manager.selected = [] }.buttonStyle(QuietButton())
                Text("\(manager.visible.count) 个文件 · 已选 \(manager.selected.count)").font(.system(size: 11)).foregroundColor(Palette.muted)
                Spacer()
                Button(role: .destructive) { manager.requestDeletion(appModel: appModel) } label: {
                    Label("删除已选（\(manager.selected.count)）…", systemImage: "trash")
                }.buttonStyle(.bordered).disabled(manager.selected.isEmpty)
            }.disabled(manager.isProcessing)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(manager.visible) { file in
                        HStack(spacing: 12) {
                            Toggle(isOn: Binding(get: { manager.selected.contains(file.id) }, set: { chosen in
                                if chosen { manager.selected.insert(file.id) } else { manager.selected.remove(file.id) }
                            })) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(file.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                    Text("\(file.url.lastPathComponent) · \(file.faceCount) 种样式").font(.system(size: 10)).foregroundColor(Palette.muted)
                                    Text(file.url.path).font(.system(size: 10)).foregroundColor(Palette.muted).lineLimit(1).truncationMode(.middle).help(file.url.path)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.toggleStyle(.checkbox).disabled(!file.canTrash || manager.isProcessing)
                            if let reason = file.unavailableReason { Text(reason).font(.system(size: 10)).foregroundColor(Palette.muted).frame(maxWidth: 150) }
                            Button("查看位置") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }.buttonStyle(QuietButton())
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(manager.selected.contains(file.id) ? Palette.mint : Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())

                    }
                    if manager.visible.isEmpty { Text("没有符合条件的字体文件").foregroundColor(Palette.muted).frame(maxWidth: .infinity).padding(40) }
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
    }
}
