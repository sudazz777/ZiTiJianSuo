import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class NetdiskImportModel: ObservableObject {
    @Published var shareText = NetdiskShare.initialText
    @Published var share: NetdiskShare?
    @Published var remoteNames: [String] = []
    @Published var autoDownload = true
    @Published var trashImportedOriginals = false
    @Published var isInstalling = false
    @Published var activeDownloads = 0
    @Published var status = "粘贴分享链接，必要时在百度页面登录或验证。"
    @Published var errorMessage: String?
    @Published var results: [FontInstallResult] = []
    @Published var failedJobs: [URL] = []
    @Published var installedCount = 0
    @Published var skippedCount = 0
    @Published var refreshID = 0
    let jobs = FontDownloadJobs()
    private var queue: [(URL, URL, URL?, Bool)] = []
    private var downloadRetainers: [ObjectIdentifier: AnyObject] = [:]
    func retainDownloadDelegate(_ delegate: AnyObject) { downloadRetainers[ObjectIdentifier(delegate)] = delegate }
    func releaseDownloadDelegate(_ delegate: AnyObject) { downloadRetainers.removeValue(forKey: ObjectIdentifier(delegate)) }

    func openShare() {
        do {
            share = try NetdiskShare.parse(shareText); remoteNames = []; errorMessage = nil; refreshID += 1
            status = "正在打开百度网盘。请完成页面要求的登录、提取码或验证。"
        } catch { errorMessage = error.localizedDescription }
    }
    func reloadPage() { refreshID += 1 }
    func recordNames(_ names: [String]) {
        remoteNames = Array(Set(names.filter { $0.count <= 240 && FontInstallEngine.supported.contains(($0 as NSString).pathExtension.lowercased()) })).sorted()
    }
    func startDownload() { activeDownloads += 1; status = "正在下载，完成后自动查重并安装。" }
    func failedDownload(_ job: URL?, message: String) {
        activeDownloads = max(0, activeDownloads - 1)
        errorMessage = message
        if let job, !failedJobs.contains(job) { failedJobs.append(job) }
    }
    func downloaded(_ url: URL, job: URL) {
        activeDownloads = max(0, activeDownloads - 1)
        enqueue(url, job: job, original: nil, trash: false)
    }
    private func enqueue(_ source: URL, job: URL, original: URL?, trash: Bool) {
        queue.append((source, job, original, trash))
        if !isInstalling { Task { await processQueue() } }
    }
    private func processQueue() async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        while !queue.isEmpty {
            let (source, job, original, trash) = queue.removeFirst()
            status = "正在识别字体、检查本机并安装…"
            do {
                let batch = try await Task.detached(priority: .userInitiated) { () throws -> FontInstallBatch in
                    let values = try source.resourceValues(forKeys: [.fileSizeKey])
                    guard (values.fileSize ?? 0) <= FontInstallEngine.maximumDownloadSize else { throw CloudError.message("单次下载超过 512 MiB，文件已保留供手动处理。") }
                    return try FontInstallEngine().process(source, job: job)
                }.value
                results.append(contentsOf: batch.results); results = Array(results.suffix(1000))
                installedCount += batch.installed; skippedCount += batch.skipped
                if batch.success {
                    try jobs.remove(job)
                    if trash, let original {
                        do { try FileManager.default.trashItem(at: original, resultingItemURL: nil) }
                        catch { errorMessage = "字体已处理成功，但原下载文件未能移到废纸篓：\(error.localizedDescription)" }
                    }
                    status = "处理完成：安装 \(batch.installed)，跳过 \(batch.skipped) · 临时下载文件已清理"
                } else {
                    if !failedJobs.contains(job) { failedJobs.append(job) }
                    status = "部分字体未安装成功，下载文件已保留。"
                }
            } catch {
                if !failedJobs.contains(job) { failedJobs.append(job) }
                errorMessage = error.localizedDescription; status = "处理未完成，下载文件已保留。"
            }
        }
    }
    func importFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择已下载的字体、ZIP 或字体文件夹"
        panel.prompt = "自动安装"
        panel.allowedContentTypes = FontInstallEngine.supported.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        for selected in panel.urls {
            let access = selected.startAccessingSecurityScopedResource()
            defer { if access { selected.stopAccessingSecurityScopedResource() } }
            do {
                let values = try selected.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw CloudError.message("不能导入符号链接。") }
                let files: [URL]
                if values.isDirectory == true {
                    guard let walker = FileManager.default.enumerator(at: selected, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                    var found: [URL] = []
                    for case let file as URL in walker {
                        if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { walker.skipDescendants(); continue }
                        if FontInstallEngine.supported.contains(file.pathExtension.lowercased()) { found.append(file) }
                        if found.count >= 1000 { break }
                    }
                    files = found
                } else { files = [selected] }
                guard !files.isEmpty else { throw CloudError.message("所选文件夹中没有找到字体或 ZIP。") }
                for file in files {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true, (values.fileSize ?? 0) <= FontInstallEngine.maximumDownloadSize else { throw CloudError.message("文件不是普通文件或超过 512 MiB。") }
                    let job = try jobs.create()
                    let copy = job.appendingPathComponent("download.\(file.pathExtension.lowercased())")
                    do { try FileManager.default.copyItem(at: file, to: copy) }
                    catch { try? jobs.remove(job); throw error }
                    // Folder imports never move the user's original folder or
                    // its contents to Trash. Explicitly selected files can opt in.
                    enqueue(copy, job: job, original: values.isDirectory == true ? nil : file,
                            trash: trashImportedOriginals && files.count == 1 && selected == file)
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func revealFailedJobs() {
        do { try FileManager.default.createDirectory(at: jobs.root, withIntermediateDirectories: true); NSWorkspace.shared.open(jobs.root) }
        catch { errorMessage = error.localizedDescription }
    }
}
