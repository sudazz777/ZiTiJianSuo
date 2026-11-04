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
    var identifier: String { "\(version)+\(build)" }
    static let repository = "sudazz777/ZiTiJianSuo"
    static let metadataURL = URL(string: "https://github.com/\(repository)/releases/latest/download/latest.json")!
    static func packageURL(version: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/v\(version)/FontFinder-macOS-Universal-v\(version).dmg")!
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 else { throw UpdateError.invalidRelease }
        let release = try JSONDecoder().decode(Self.self, from: data)
        _ = try UpdateVersion(release.version)
        guard release.schemaVersion == 1, release.build > 0, release.size > 0, release.size <= AppUpdateDownload.maximumSize,
              release.downloadURL == packageURL(version: release.version),
              release.sha256.count == 64, release.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              release.releaseNotes.count <= 20, release.releaseNotes.allSatisfy({ $0.count <= 500 }) else { throw UpdateError.invalidRelease }
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
    func shouldCheck(manual: Bool, startup: Bool) -> Bool { manual || startup }
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
    private var started = false
    private var task: Task<Void, Never>?
    private var pendingRelease: AppUpdateRelease?
    private var checking = false
    private var manualRequested = false
    private var installationTask: Task<Void, Never>?
    private var progressPanel: UpdateProgressPanel?
    private(set) var isUpdating = false
    private(set) var restarting = false
    var canInstall: () -> Bool = { true }
    var onCheckingChanged: ((Bool) -> Void)?

    init(defaults: UserDefaults = .standard, client: AppUpdateClient = AppUpdateClient()) {
        self.client = client; policy = UpdateCheckPolicy(defaults: defaults)
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }
    func start() {
        guard !started else { return }
        started = true
        check(manual: false, startup: true)
    }
    func stop() { task?.cancel(); installationTask?.cancel(); task = nil; started = false }
    func didBecomeActive() {
        if let release = pendingRelease {
            pendingRelease = nil
            if policy.shouldPresent(release, manual: false) { present(release) }
        }
    }
    func check(manual: Bool, startup: Bool = false) {
        guard !isUpdating else { return }
        if checking { manualRequested = manualRequested || manual; return }
        guard policy.shouldCheck(manual: manual, startup: startup) else { return }
        checking = true; manualRequested = manual; onCheckingChanged?(true)
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
        alert.informativeText = "当前版本：\(version)\n\n\(notes)\n\n软件将自动下载并校验更新，然后退出、安装并重新打开。下载期间可以取消。"
        alert.addButton(withTitle: "更新并重启")
        alert.addButton(withTitle: "稍后提醒")
        alert.addButton(withTitle: "跳过此版本")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            install(release)
        case .alertThirdButtonReturn: policy.skip(release)
        default: break
        }
    }

    private func install(_ release: AppUpdateRelease) {
        guard !isUpdating else { return }
        guard canInstall() else {
            message("请先等待字体处理完成", text: "字体批量操作完成后，再检查更新即可。")
            return
        }
        isUpdating = true; onCheckingChanged?(true)
        let panel = UpdateProgressPanel(); progressPanel = panel
        panel.onCancel = { [weak self] in self?.installationTask?.cancel(); self?.progressPanel?.cancelRequested() }
        panel.show()
        installationTask = Task { [weak self] in
            guard let self else { return }
            var download: URL?
            var prepared: PreparedAppUpdate?
            var handedOff = false
            defer {
                if !handedOff, let prepared { AppUpdateInstallation.discard(prepared) }
                if let download { try? FileManager.default.removeItem(at: download.deletingLastPathComponent()) }
                progressPanel?.close(); progressPanel = nil
                if !handedOff { isUpdating = false; restarting = false; onCheckingChanged?(false) }
            }
            do {
                let package = try await AppUpdateDownload.fetch(release) { [weak self] fraction in
                    Task { @MainActor in self?.progressPanel?.progress(fraction) }
                }
                download = package
                try Task.checkCancellation()
                progressPanel?.preparing()
                let ready = try await Task.detached(priority: .userInitiated) {
                    try AppUpdateInstallation.prepare(dmg: package, release: release)
                }.value
                prepared = ready
                try Task.checkCancellation()
                guard canInstall() else { throw NSError(domain: "FontFinder.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: "字体仍在处理中，请完成后再重试更新。"] ) }
                progressPanel?.restarting()
                try await Task.detached(priority: .userInitiated) { try AppUpdateInstallation.launch(ready) }.value
                try Task.checkCancellation()
                guard canInstall() else { throw NSError(domain: "FontFinder.Update", code: 2, userInfo: [NSLocalizedDescriptionKey: "字体仍在处理中，已取消重启。"] ) }
                try AppUpdateInstallation.commit(ready)
                handedOff = true; restarting = true
                try? FileManager.default.removeItem(at: package.deletingLastPathComponent())
                download = nil
                progressPanel?.close()
                NSApp.terminate(nil)
            } catch {
                progressPanel?.close()
                if !Task.isCancelled { installFailed(release, reason: error.localizedDescription) }
            }
        }
    }

    private func installFailed(_ release: AppUpdateRelease, reason: String) {
        let alert = NSAlert()
        alert.messageText = "自动更新未完成"
        alert.informativeText = "\(reason)\n\n当前软件保持原样。可以稍后重试，或手动下载安装。"
        alert.addButton(withTitle: "关闭")
        alert.addButton(withTitle: "手动下载安装包")
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(release.downloadURL) }
    }
    private func message(_ title: String, text: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.runModal()
    }
}
