import Foundation
import SwiftUI

@MainActor final class EmailAccountModel: ObservableObject {
    @Published private(set) var user: EmailAccountUser?
    @Published private(set) var isAdmin = false
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var downloads: [AccountDownloadRecord] = []
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var message: String?
    private var session: EmailAccountSession?
    private let service: EmailAccountService?
    private var restored = false
    private let defaults: UserDefaults
    var configured: Bool { service != nil }
    var recordedFontIDs: Set<String> { Set(downloads.map(\.font_id)) }

    init(configuration: EmailAccountConfiguration? = EmailAccountConfiguration.load(), defaults: UserDefaults = .standard) {
        service = configuration.map { EmailAccountService(configuration: $0) }; self.defaults = defaults
    }
    private func requireService() throws -> EmailAccountService {
        guard let service else { throw CloudError.message("邮箱账号服务尚未配置。请由维护者按部署说明连接账号后台；本机字体检索仍可使用。") }
        return service
    }
    private func saveSession(_ value: EmailAccountSession) throws {
        let service = try requireService()
        try EmailSessionStore.save(value, project: service.configuration.projectURL)
        session = value; user = value.user
    }
    private func authorized() async throws -> EmailAccountSession {
        guard var value = session else { throw CloudError.message("请先登录邮箱账号。") }
        if value.expiresAt < Date().timeIntervalSince1970 + 60 {
            value = try await requireService().refresh(value)
            try saveSession(value)
        }
        return value
    }
    func restore() async {
        guard !restored, configured else { return }; restored = true
        do {
            let service = try requireService()
            guard let saved = try EmailSessionStore.read(project: service.configuration.projectURL) else { return }
            session = saved
            let value = try await authorized()
            let checked = try await service.user(credential: value.accessToken)
            guard checked.id == value.user.id else { throw CloudError.message("账号会话不一致，请重新登录。") }
            user = checked; await refreshRecords()
        } catch { session = nil; user = nil; isAdmin = false; errorMessage = "无法恢复登录，请重新登录。" }
    }
    func signIn(email: String, password: String) async -> Bool {
        guard !isWorking else { return false }; isWorking = true; errorMessage = nil; message = nil
        defer { isWorking = false }
        do {
            let value = try await requireService().signIn(email: email, password: password)
            try saveSession(value); try await loadRecords(); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func signUp(email: String, password: String) async -> Bool {
        guard !isWorking else { return false }; isWorking = true; errorMessage = nil; message = nil
        defer { isWorking = false }
        do { try await requireService().signUp(email: email, password: password); message = "请查看邮箱，输入邮件中的验证码完成注册。"; return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
    func verifySignup(email: String, code: String) async -> Bool {
        guard !isWorking else { return false }; isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do { try saveSession(await requireService().verify(email: email, code: code, type: "signup")); try await loadRecords(); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
    func sendRecovery(email: String) async {
        guard !isWorking else { return }; isWorking = true; errorMessage = nil; message = nil
        defer { isWorking = false }
        do { try await requireService().sendRecovery(email: email); message = "如果邮箱已注册，会收到密码重置验证码。" }
        catch { errorMessage = error.localizedDescription }
    }
    func resetPassword(email: String, code: String, password: String) async -> Bool {
        guard !isWorking else { return false }; isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do {
            let service = try requireService()
            let value = try await service.verify(email: email, code: code, type: "recovery")
            try await service.updatePassword(password, credential: value.accessToken)
            try saveSession(value); try await loadRecords(); message = "密码已更新。"; return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func signOut() async {
        guard !isWorking else { return }; isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do {
            if let value = session { try? await requireService().signOut(credential: value.accessToken) }
            try EmailSessionStore.remove()
            session = nil; user = nil; isAdmin = false; favorites = []; downloads = []; message = "已退出当前设备。"
        } catch { errorMessage = error.localizedDescription }
    }
    private func loadRecords() async throws {
        let service = try requireService(), value = try await authorized()
        // Clear the previous account's data before requesting the new account.
        favorites = []; downloads = []; isAdmin = false
        isAdmin = try await service.isAdmin(credential: value.accessToken, userID: value.user.id)
        async let favoriteRows = service.favorites(credential: value.accessToken)
        async let downloadRows = service.downloads(credential: value.accessToken)
        favorites = try await favoriteRows; downloads = try await downloadRows
        await retryDownloads()
    }
    func refreshRecords() async {
        guard !isWorking, user != nil else { return }; isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do { try await loadRecords() } catch { errorMessage = "用户记录同步失败：\(error.localizedDescription)" }
    }
    func toggleFavorite(_ font: CloudFont) async {
        guard !isWorking else { return }; isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do {
            let value = try await authorized(), next = !favorites.contains(font.id)
            try await requireService().setFavorite(font.id, enabled: next, account: value)
            if next { favorites.insert(font.id) } else { favorites.remove(font.id) }
        } catch { errorMessage = error.localizedDescription }
    }
    private var queued: [String: [AccountDownloadDraft]] {
        get { defaults.data(forKey: "pendingAccountDownloads").flatMap { try? JSONDecoder().decode([String: [AccountDownloadDraft]].self, from: $0) } ?? [:] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "pendingAccountDownloads") }
    }
    func recordDownload(_ font: CloudFont) async {
        guard let user else { return }
        let draft = AccountDownloadDraft(fontID: font.id, fileName: font.fileName)
        var pending = queued; var rows = pending[user.id] ?? []; rows.removeAll { $0.fontID == font.id }; rows.append(draft)
        pending[user.id] = rows; queued = pending
        await retryDownloads()
    }
    private func retryDownloads() async {
        guard let user else { return }
        do {
            let value = try await authorized(), service = try requireService()
            for draft in queued[user.id] ?? [] {
                try await service.recordDownload(draft, account: value)
                var pending = queued; pending[user.id]?.removeAll { $0.fontID == draft.fontID }; queued = pending
                downloads.removeAll { $0.font_id == draft.fontID }
                downloads.insert(AccountDownloadRecord(font_id: draft.fontID, file_name: draft.fileName, downloaded_at: ISO8601DateFormatter().string(from: Date())), at: 0)
            }
        } catch { errorMessage = "文件已下载，账号记录稍后同步。可在账号页点击刷新记录重试。" }
    }
    func upload(data: Data, font: CloudFont) async throws -> AccountUploadResult {
        guard isAdmin else { throw CloudError.message("只有管理员账号可以上传。") }
        let value = try await authorized()
        return try await requireService().upload(data: data, font: font, credential: value.accessToken)
    }
    func catalog() async throws -> CloudCatalog { try await requireService().catalog() }
    func download(_ font: CloudFont, store: CloudFontStore) async throws { try await requireService().download(font, store: store) }
    func startBaiduConnection() async -> AccountBaiduAuthorization? {
        guard isAdmin, !isWorking else { return nil }; isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do { let value = try await authorized(); return try await requireService().startBaiduConnection(credential: value.accessToken) }
        catch { errorMessage = error.localizedDescription; return nil }
    }
    func completeBaiduConnection(state: String, code: String) async -> Bool {
        guard isAdmin, !isWorking else { return false }; isWorking = true; errorMessage = nil
        defer { isWorking = false }
        do {
            let value = try await authorized()
            try await requireService().completeBaiduConnection(state: state, code: code, credential: value.accessToken)
            message = "百度网盘已连接，可以上传字体。"; return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}
