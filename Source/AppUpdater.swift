import AppKit
import Foundation

enum UpdateError: LocalizedError {
    case invalidRelease, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidRelease: return "更新信息不完整，请稍后重试。"
        case .unavailable: return "暂时无法连接 GitHub，请检查网络后重试。"
        }
    }
}

struct UpdateVersion: Comparable {
    let components: [Int]
    init(_ value: String) throws {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), value.count <= 32,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts.allSatisfy({ Int($0) != nil }) else { throw UpdateError.invalidRelease }
        components = parts.map { Int($0)! } + Array(repeating: 0, count: 3 - parts.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

struct AppUpdateRelease: Codable {
    let schemaVersion: Int
    let version: String
    let build: Int
    let releaseNotes: [String]
    let downloadURL: URL
    let sha256: String
    let size: Int
    let diskImageURL: URL?
    let diskImageSHA256: String?
    let diskImageSize: Int?
    var preferredDownloadURL: URL { diskImageURL ?? downloadURL }
    init(schemaVersion: Int, version: String, build: Int, releaseNotes: [String], downloadURL: URL, sha256: String, size: Int,
         diskImageURL: URL? = nil, diskImageSHA256: String? = nil, diskImageSize: Int? = nil) {
        self.schemaVersion = schemaVersion; self.version = version; self.build = build; self.releaseNotes = releaseNotes
        self.downloadURL = downloadURL; self.sha256 = sha256; self.size = size
        self.diskImageURL = diskImageURL; self.diskImageSHA256 = diskImageSHA256; self.diskImageSize = diskImageSize
    }
    var identifier: String { "\(version)+\(build)" }
    static let repository = "sudazz777/ZiTiJianSuo"
    static let metadataURL = URL(string: "https://github.com/\(repository)/releases/latest/download/latest.json")!
    static func packageURL(version: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/v\(version)/FontFinder-macOS-Universal-v\(version).pkg")!
    }
    static func diskImageURL(version: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/v\(version)/FontFinder-macOS-Universal-v\(version).dmg")!
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 else { throw UpdateError.invalidRelease }
        let release = try JSONDecoder().decode(Self.self, from: data)
        _ = try UpdateVersion(release.version)
        guard release.schemaVersion == 1, release.build > 0, release.size > 0,
              release.downloadURL == packageURL(version: release.version),
              release.sha256.count == 64, release.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              release.releaseNotes.count <= 20, release.releaseNotes.allSatisfy({ $0.count <= 500 }) else { throw UpdateError.invalidRelease }
        if release.diskImageURL != nil || release.diskImageSHA256 != nil || release.diskImageSize != nil {
            guard release.diskImageURL == diskImageURL(version: release.version),
                  let hash = release.diskImageSHA256, hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }),
                  let size = release.diskImageSize, size > 0 else { throw UpdateError.invalidRelease }
        }
        return release
    }
    func isNewer(than version: String, build currentBuild: Int) throws -> Bool {
        let remote = try UpdateVersion(self.version), local = try UpdateVersion(version)
        return remote > local || (remote == local && build > currentBuild)
    }
}

struct AppUpdateClient {
    let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }
    func latest() async throws -> AppUpdateRelease {
        var request = URLRequest(url: AppUpdateRelease.metadataURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.unavailable }
        return try AppUpdateRelease.decode(data)
    }
}

struct UpdateCheckPolicy {
    let defaults: UserDefaults
    static let interval: TimeInterval = 24 * 60 * 60
    func isDue(manual: Bool, now: Date) -> Bool {
        if manual { return true }
        guard let last = defaults.object(forKey: "updates.lastAttempt") as? Date else { return true }
        return now < last || now.timeIntervalSince(last) >= Self.interval
    }
    func recordAttempt(now: Date) { defaults.set(now, forKey: "updates.lastAttempt") }
    func skip(_ release: AppUpdateRelease) { defaults.set(release.identifier, forKey: "updates.skippedRelease") }
    func shouldPresent(_ release: AppUpdateRelease, manual: Bool) -> Bool {
        manual || defaults.string(forKey: "updates.skippedRelease") != release.identifier
    }
}

@MainActor final class AppUpdater {
    private let client: AppUpdateClient
    private let policy: UpdateCheckPolicy
    private let version: String
    private let build: Int
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var pendingRelease: AppUpdateRelease?
    private var checking = false
    private var manualRequested = false
    var onCheckingChanged: ((Bool) -> Void)?

    init(defaults: UserDefaults = .standard, client: AppUpdateClient = AppUpdateClient()) {
        self.client = client; policy = UpdateCheckPolicy(defaults: defaults)
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.check(manual: false) }
        }
        timer?.tolerance = 300
        check(manual: false)
    }
    func stop() { timer?.invalidate(); timer = nil; task?.cancel() }
    func didBecomeActive() {
        if let release = pendingRelease {
            pendingRelease = nil
            if policy.shouldPresent(release, manual: false) { present(release) }
        }
        check(manual: false)
    }
    func check(manual: Bool) {
        if checking { manualRequested = manualRequested || manual; return }
        guard policy.isDue(manual: manual, now: Date()) else { return }
        checking = true; manualRequested = manual; onCheckingChanged?(true)
        policy.recordAttempt(now: Date())
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await client.latest()
                guard !Task.isCancelled else { finish(); return }
                let newer = try release.isNewer(than: version, build: build)
                let wasManual = manualRequested
                finish()
                if newer {
                    guard policy.shouldPresent(release, manual: wasManual) else { return }
                    if wasManual || NSApp.isActive { pendingRelease = nil; present(release) }
                    else { pendingRelease = release }
                } else if wasManual {
                    pendingRelease = nil
                    message("已是最新版本", text: "当前版本：\(version)")
                }
            } catch {
                let wasManual = manualRequested
                finish()
                if wasManual && !Task.isCancelled { message("无法检查更新", text: "暂时无法从 GitHub 读取更新信息，请检查网络后重试。") }
            }
        }
    }
    private func finish() { checking = false; manualRequested = false; onCheckingChanged?(false) }
    private func present(_ release: AppUpdateRelease) {
        let alert = NSAlert()
        alert.messageText = "字体检索有新版本 v\(release.version)"
        let notes = release.releaseNotes.prefix(8).map { "• \($0)" }.joined(separator: "\n")
        let instructions = release.diskImageURL == nil ? "下载后运行 PKG 安装包，更新到“应用程序”文件夹。" : "打开下载的 DMG，双击其中的安装器，更新到“应用程序”文件夹。"
        alert.informativeText = "当前版本：\(version)\n\n\(notes)\n\n\(instructions)"
        alert.addButton(withTitle: "下载更新")
        alert.addButton(withTitle: "稍后提醒")
        alert.addButton(withTitle: "跳过此版本")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if !NSWorkspace.shared.open(release.preferredDownloadURL) { message("无法打开下载", text: "请前往 GitHub 仓库的 Releases 下载最新版安装包。") }
        case .alertThirdButtonReturn: policy.skip(release)
        default: break
        }
    }
    private func message(_ title: String, text: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.runModal()
    }
}
