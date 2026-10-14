import AppKit
import CoreText
import SwiftUI
import UniformTypeIdentifiers

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
    @Published var isConnecting = false
    @Published var adminLogin: String?
    @Published var errorMessage: String?
    @Published var status = "公开字体库 · 下载无需登录"
    @Published var pending: PendingCloudFont?
    @Published var showUpload = false
    @Published var showAdmin = false
    private var token: String?
    private var restoredCredential = false
    private let client: GitHubFontClient
    let store: CloudFontStore

    init(client: GitHubFontClient = GitHubFontClient(), store: CloudFontStore = CloudFontStore()) {
        self.client = client; self.store = store
        if let data = try? Data(contentsOf: store.catalogURL), let catalog = try? CloudCatalog.decode(data) { fonts = catalog.fonts }
    }
    var visible: [CloudFont] {
        fonts.filter { $0.matches(query) }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    var missing: [CloudFont] { fonts.filter { !downloaded.contains($0.id) } }
    var controlsDisabled: Bool { isBusy || isLoading || isConnecting }

    func open() async {
        await refresh()
        if !restoredCredential {
            restoredCredential = true
            do { if let stored = try GitHubCredentialStore.read() { try await authenticate(stored) } }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func refresh() async {
        guard !controlsDisabled else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let catalog = try await client.catalog()
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
    private func authenticate(_ candidate: String) async throws {
        isConnecting = true
        defer { isConnecting = false }
        let login = try await client.authenticate(candidate)
        token = candidate; adminLogin = login
    }
    func connect(_ candidate: String) async -> Bool {
        guard !controlsDisabled else { return false }
        errorMessage = nil
        let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains(where: { $0.isWhitespace }) else {
            errorMessage = "请输入有效的 GitHub 访问令牌。"; return false
        }
        do {
            try await authenticate(cleaned)
            do { try GitHubCredentialStore.save(cleaned) }
            catch { token = nil; adminLogin = nil; throw error }
            status = "管理员 \(adminLogin ?? "") 已连接"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func disconnect() {
        guard !controlsDisabled else { return }
        do {
            try GitHubCredentialStore.remove()
            token = nil; adminLogin = nil; status = "已断开管理员连接 · 下载无需登录"
        } catch { errorMessage = error.localizedDescription }
    }
    func download(_ font: CloudFont) async {
        guard !controlsDisabled else { return }
        isBusy = true; errorMessage = nil; status = "正在下载：\(font.displayName)"
        defer { isBusy = false }
        do {
            try await client.download(font, store: store)
            downloaded.insert(font.id); status = "下载完成：\(font.displayName) · 点击安装打开字体册"
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
                try await client.download(font, store: store)
                downloaded.insert(font.id); completed += 1
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
    func chooseUpload() async {
        guard !controlsDisabled, token != nil, adminLogin != nil else { return }
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
                      size <= CloudConfiguration.maximumFontSize,
                      CloudConfiguration.extensions.contains(url.pathExtension.lowercased()) else {
                    throw CloudError.message("请选择不超过 50 MB 的 TTF、OTF 或 TTC 字体文件。")
                }
                let data = try Data(contentsOf: url)
                guard data.count <= CloudConfiguration.maximumFontSize,
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
        guard !controlsDisabled, let pending, let token, adminLogin != nil else { return false }
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
            let catalog = try await client.upload(data: pending.data, font: font, token: token)
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
            self.pending = nil; showUpload = false; status = "已公开上传：\(title) · 用户刷新后即可下载"
            return true
        } catch { errorMessage = error.localizedDescription; status = "上传未完成"; return false }
    }
}
