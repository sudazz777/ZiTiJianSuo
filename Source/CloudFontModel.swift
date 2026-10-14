import AppKit
import CoreText
import SwiftUI
import UniformTypeIdentifiers
import Combine

struct PendingCloudFont {
    let data: Data
    let fileName: String
    let postScriptNames: [String]
    let suggestedName: String
}

@MainActor final class CloudFontModel: ObservableObject {
    @Published var fonts: [CloudFont] = []
    @Published var query = ""
    @Published var downloaded: Set<String> = []
    @Published var isLoading = false
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var status = "公开字体库 · 下载无需登录"
    @Published var pending: PendingCloudFont?
    @Published var showUpload = false
    @Published var showAccount = false
    @Published var accountFilter = "全部字体"
    let account = EmailAccountModel()
    let share = FontShareConfiguration.load()
    private var accountObservation: AnyCancellable?
    let store: CloudFontStore

    init(store: CloudFontStore = CloudFontStore()) {
        self.store = store
        accountObservation = account.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if let data = try? Data(contentsOf: store.catalogURL), let catalog = try? CloudCatalog.decode(data) { fonts = catalog.fonts }
    }
    var visible: [CloudFont] {
        fonts.filter { font in
            let permitted = account.user == nil || accountFilter == "全部字体" ||
                (accountFilter == "我的收藏" ? account.favorites.contains(font.id) : account.recordedFontIDs.contains(font.id))
            return permitted && font.matches(query)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    var missing: [CloudFont] { fonts.filter { !downloaded.contains($0.id) } }
    var controlsDisabled: Bool { isBusy || isLoading || account.isWorking }

    func open() async {
        await refresh()
        await account.restore()
    }
    func refresh() async {
        guard !controlsDisabled else { return }
        guard account.configured else { status = "邮箱账号与百度网盘后台尚未配置"; return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let catalog = try await account.catalog()
            fonts = catalog.fonts
            downloaded.formIntersection(Set(fonts.map(\.id)))
            do { try store.prepare(); try catalog.encoded().write(to: store.catalogURL, options: .atomic) }
            catch { errorMessage = "已读取云端清单，但无法保存离线缓存：\(error.localizedDescription)" }
            status = "已更新清单 · \(fonts.count) 个字体文件"
        } catch {
            errorMessage = error.localizedDescription
            status = fonts.isEmpty ? "暂时无法连接字体库" : "正在显示上次保存的字体清单"
        }
        await scanDownloads()
    }
    private func scanDownloads() async {
        let fonts = self.fonts, store = self.store
        downloaded = await Task.detached(priority: .utility) {
            Set(fonts.filter { store.isValid($0) }.map(\.id))
        }.value
    }
    func download(_ font: CloudFont) async {
        guard !controlsDisabled else { return }
        isBusy = true; errorMessage = nil; status = "正在下载：\(font.displayName)"
        defer { isBusy = false }
        do {
            try await account.download(font, store: store)
            downloaded.insert(font.id); status = "下载完成：\(font.displayName) · 点击安装打开字体册"
            await account.recordDownload(font)
        } catch { errorMessage = error.localizedDescription; status = "下载未完成" }
    }
    func syncMissing() async {
        guard !controlsDisabled else { return }
        let targets = missing
        guard !targets.isEmpty else { status = "云端字体已全部下载"; return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        var completed = 0
        for font in targets {
            status = "正在下载 \(completed + 1)/\(targets.count)：\(font.displayName)"
            do {
                try await account.download(font, store: store)
                downloaded.insert(font.id); completed += 1
                await account.recordDownload(font)
            } catch {
                errorMessage = "\(font.displayName)：\(error.localizedDescription)"; break
            }
        }
        status = "本次下载完成 \(completed)/\(targets.count) · 未完成文件可重试"
    }
    func install(_ font: CloudFont) async {
        guard !controlsDisabled else { return }
        isBusy = true; errorMessage = nil
        let store = self.store
        let valid = await Task.detached { store.isValid(font) }.value
        isBusy = false
        guard valid else { downloaded.remove(font.id); errorMessage = "本机文件不存在或校验失败，请重新下载。"; return }
        if !NSWorkspace.shared.open(store.fileURL(font)) { errorMessage = "无法打开字体文件，请在 Finder 中手动安装。" }
    }
    func reveal(_ font: CloudFont) { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(font)]) }
    func revealFolder() {
        do { try store.prepare(); NSWorkspace.shared.open(store.directory) }
        catch { errorMessage = error.localizedDescription }
    }
    func restoreAccountFonts() async {
        guard account.user != nil, !controlsDisabled else { return }
        await account.refreshRecords()
        let wanted = account.recordedFontIDs.union(account.favorites)
        for font in fonts where wanted.contains(font.id) && !downloaded.contains(font.id) { await download(font) }
    }
    func chooseUpload() async {
        guard !controlsDisabled, account.isAdmin else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要公开上传的字体"
        panel.prompt = "选择字体"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = CloudConfiguration.extensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            let prepared = try await Task.detached(priority: .userInitiated) { () throws -> PendingCloudFont in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize, size > 0,
                      size <= EmailAccountConfiguration.maximumUploadSize,
                      CloudConfiguration.extensions.contains(url.pathExtension.lowercased()) else {
                    throw CloudError.message("请选择不超过 10 MiB 的 TTF、OTF 或 TTC 字体文件。")
                }
                let data = try Data(contentsOf: url)
                guard data.count <= EmailAccountConfiguration.maximumUploadSize,
                      let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
                      !descriptors.isEmpty else { throw CloudError.message("此文件不是可读取的字体。") }
                let fonts = descriptors.map { CTFontCreateWithFontDescriptor($0, 12, nil) }
                let names = Array(Set(fonts.map { CTFontCopyPostScriptName($0) as String })).sorted()
                return PendingCloudFont(data: data, fileName: url.lastPathComponent, postScriptNames: names,
                                        suggestedName: CTFontCopyFullName(fonts[0]) as String)
            }.value
            pending = prepared; showUpload = true
        } catch { errorMessage = error.localizedDescription }
    }
    func uploadPending(name: String) async -> Bool {
        guard !controlsDisabled, let pending, account.isAdmin else { return false }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { errorMessage = "请填写字体名称。"; return false }
        isBusy = true; errorMessage = nil; status = "正在上传：\(title)"
        defer { isBusy = false }
        do {
            let hash = CloudChecksum.data(pending.data)
            let ext = (pending.fileName as NSString).pathExtension.lowercased()
            let font = CloudFont(id: hash, displayName: title, fileName: pending.fileName,
                                 path: "fonts/files/\(hash).\(ext)", size: pending.data.count, sha256: hash,
                                 postScriptNames: pending.postScriptNames, uploadedAt: ISO8601DateFormatter().string(from: Date()))
            let result = try await account.upload(data: pending.data, font: font)
            let catalog = result.catalog
            fonts = catalog.fonts
            downloaded.formIntersection(Set(fonts.map(\.id)))
            do {
                try store.prepare(); try catalog.encoded().write(to: store.catalogURL, options: .atomic)
                let staged = store.directory.appendingPathComponent(".\(UUID().uuidString).upload")
                try pending.data.write(to: staged, options: .atomic)
                defer { try? FileManager.default.removeItem(at: staged) }
                try store.saveDownload(staged, font: font)
                downloaded.insert(font.id)
            } catch { errorMessage = "已上传成功，但本机缓存未保存：\(error.localizedDescription)" }
            if !result.auditRecorded { errorMessage = "字体已上传成功，但账号上传记录未保存，请维护者检查后台。" }
            self.pending = nil; showUpload = false; status = "已公开上传：\(title) · 用户刷新后即可下载"
            return true
        } catch { errorMessage = error.localizedDescription; status = "上传未完成"; return false }
    }
}
