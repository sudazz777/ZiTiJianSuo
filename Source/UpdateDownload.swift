import Foundation
import CryptoKit

enum UpdateDownloadError: LocalizedError {
    case invalidSize, invalidChecksum, invalidHost
    var errorDescription: String? {
        switch self {
        case .invalidSize: return "下载文件大小不符，未安装。请重试。"
        case .invalidChecksum: return "安装包校验失败，未安装。请重试。"
        case .invalidHost: return "安装包来源无效，未安装。"
        }
    }
}

enum AppUpdateDownload {
    static let maximumSize = 512 * 1024 * 1024
    static func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return ["github.com", "release-assets.githubusercontent.com"].contains(url.host?.lowercased() ?? "")
    }
    static func verify(_ file: URL, release: AppUpdateRelease) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard release.size > 0, release.size <= maximumSize, size == release.size else { throw UpdateDownloadError.invalidSize }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256 else { throw UpdateDownloadError.invalidChecksum }
    }
    static func fetch(_ release: AppUpdateRelease, session suppliedSession: URLSession? = nil, progress: @escaping (Double) -> Void) async throws -> URL {
        _ = try AppUpdateRelease.decode(JSONEncoder().encode(release))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FontFinder-Download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: root) } }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 15 * 60
        let session = suppliedSession ?? URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let delegate = UpdateDownloadDelegate(size: release.size, progress: progress)
        let request = URLRequest(url: release.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData)
        let (temporary, response) = try await session.download(for: request, delegate: delegate)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200, allowed(response.url) else { throw UpdateDownloadError.invalidHost }
        let package = root.appendingPathComponent("update.dmg")
        try FileManager.default.moveItem(at: temporary, to: package)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: package.path)
        try verify(package, release: release)
        try Task.checkCancellation()
        retained = true
        return package
    }
}

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let size: Int
    let progress: (Double) -> Void
    init(size: Int, progress: @escaping (Double) -> Void) { self.size = size; self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(AppUpdateDownload.allowed(request.url) ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= Int64(size), totalBytesExpectedToWrite <= Int64(size) else { downloadTask.cancel(); return }
        progress(min(1, Double(totalBytesWritten) / Double(size)))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

