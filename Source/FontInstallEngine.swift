import Foundation
import CoreText

struct FontInstallResult: Identifiable {
    let id = UUID()
    let name: String
    let status: String
    let installedURL: URL?
    var success: Bool { status == "已安装" || status == "已存在，已跳过" }
}

struct FontInstallBatch {
    let results: [FontInstallResult]
    var success: Bool { !results.isEmpty && results.allSatisfy(\.success) }
    var installed: Int { results.filter { $0.status == "已安装" }.count }
    var skipped: Int { results.filter { $0.status == "已存在，已跳过" }.count }
}

struct FontInstallEngine {
    static let supported = ["ttf", "otf", "ttc", "zip"]
    static let maximumDownloadSize = 512 * 1024 * 1024
    let fontsDirectory: URL
    let scope: CTFontManagerScope
    init(fontsDirectory: URL? = nil, scope: CTFontManagerScope = .persistent) {
        self.fontsDirectory = fontsDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts", isDirectory: true)
        self.scope = scope
    }
    static func names(_ url: URL) throws -> Set<String> {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], !descriptors.isEmpty else {
            throw CloudError.message("文件不是可读取的字体。")
        }
        let names = Set(descriptors.map { CTFontCopyPostScriptName(CTFontCreateWithFontDescriptor($0, 12, nil)) as String })
        guard !names.isEmpty, names.allSatisfy({ !$0.isEmpty }) else { throw CloudError.message("字体名称信息无效。") }
        return names
    }
    static func availableNames() -> Set<String> { Set(CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? []) }
    func install(_ source: URL) -> FontInstallResult {
        do {
            let names = try Self.names(source)
            let available = Self.availableNames()
            let title = names.sorted().joined(separator: " / ")
            if names.isSubset(of: available) { return FontInstallResult(name: title, status: "已存在，已跳过", installedURL: nil) }
            guard names.isDisjoint(with: available) else {
                return FontInstallResult(name: title, status: "字库中部分字体已安装，保留文件供手动处理", installedURL: nil)
            }
            let hash = try CloudChecksum.file(source)
            let target = fontsDirectory.appendingPathComponent("FontFinder-\(hash).\(source.pathExtension.lowercased())")
            try FileManager.default.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)
            var created = false
            if FileManager.default.fileExists(atPath: target.path) {
                guard try CloudChecksum.file(target) == hash else { throw CloudError.message("安装目标已存在且内容不同，未覆盖。") }
            } else { try FileManager.default.copyItem(at: source, to: target); created = true }
            var error: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(target as CFURL, scope, &error)
            // Registration can race with macOS noticing the newly copied file.
            // Verify actual availability instead of trusting either return value.
            var verified = false
            for _ in 0..<6 {
                if names.isSubset(of: Self.availableNames()) { verified = true; break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard verified else {
                if created {
                    var ignored: Unmanaged<CFError>?
                    if registered { CTFontManagerUnregisterFontsForURL(target as CFURL, scope, &ignored) }
                    try? FileManager.default.removeItem(at: target)
                }
                throw CloudError.message("macOS 未确认字体安装成功，下载文件已保留。")
            }
            return FontInstallResult(name: title, status: "已安装", installedURL: target)
        } catch { return FontInstallResult(name: source.lastPathComponent, status: error.localizedDescription, installedURL: nil) }
    }
    func process(_ source: URL, job: URL) throws -> FontInstallBatch {
        var entries: Int = 10_000
        var bytes: UInt64 = 1024 * 1024 * 1024
        var candidates: [URL] = []
        try collect(source, job: job, depth: 0, entries: &entries, bytes: &bytes, candidates: &candidates)
        guard !candidates.isEmpty else { throw CloudError.message("下载中没有找到 TTF、OTF 或 TTC 字体。") }
        return FontInstallBatch(results: candidates.map(install))
    }
    private func collect(_ source: URL, job: URL, depth: Int, entries: inout Int, bytes: inout UInt64, candidates: inout [URL]) throws {
        guard depth <= 3 else { throw CloudError.message("ZIP 嵌套超过三层，已保留下载文件。") }
        let ext = source.pathExtension.lowercased()
        if ["ttf", "otf", "ttc"].contains(ext) {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 256 * 1024 * 1024 else { throw CloudError.message("字体文件无效或超过 256 MiB。") }
            candidates.append(source); return
        }
        guard ext == "zip" else { throw CloudError.message("仅支持 TTF、OTF、TTC 和 ZIP。") }
        let output = job.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var message = [CChar](repeating: 0, count: 512)
        let messageCapacity = message.count
        let result = source.path.withCString { archive in output.path.withCString { destination in
            fontfinder_extract_archive(archive, destination, &entries, &bytes, &message, messageCapacity)
        } }
        guard result == 0 else { throw CloudError.message("ZIP 无法处理：\(String(cString: message))。下载文件已保留。") }
        for child in try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
            try collect(child, job: job, depth: depth + 1, entries: &entries, bytes: &bytes, candidates: &candidates)
        }
    }
}

struct FontDownloadJobs {
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FontFinder/DownloadJobs", isDirectory: true)
    }
    func create() throws -> URL {
        let job = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return job
    }
    func remove(_ job: URL) throws {
        guard job.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              UUID(uuidString: job.lastPathComponent) != nil,
              job.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else {
            throw CloudError.message("无法清理：该目录不属于软件创建的下载任务。")
        }
        try FileManager.default.removeItem(at: job)
    }
}
