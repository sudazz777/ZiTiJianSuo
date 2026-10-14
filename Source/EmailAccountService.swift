import Foundation

struct EmailAccountConfiguration: Codable {
    let projectURL: URL
    let publishableKey: String
    static let maximumUploadSize = 10 * 1024 * 1024
    func validate() throws {
        guard projectURL.scheme == "https", projectURL.host != nil, !publishableKey.isEmpty,
              !publishableKey.hasPrefix("sb_secret_") else { throw CloudError.message("账号配置无效，客户端只能使用公开 API key。") }
        if publishableKey.hasPrefix("eyJ") {
            let parts = publishableKey.split(separator: ".")
            guard parts.count == 3 else { throw CloudError.message("账号 API key 无效。") }
            var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let data = Data(base64Encoded: payload), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["role"] as? String == "anon" else { throw CloudError.message("不能把后台服务密钥放入客户端配置。") }
        }
    }
    static func load() -> EmailAccountConfiguration? {
        guard let url = Bundle.main.url(forResource: "CloudAccount", withExtension: "json"),
              let data = try? Data(contentsOf: url), let result = try? JSONDecoder().decode(Self.self, from: data),
              result.projectURL.scheme == "https", !result.publishableKey.isEmpty,
              !result.publishableKey.contains("YOUR_"), (try? result.validate()) != nil else { return nil }
        return result
    }
}

struct EmailAccountUser: Codable, Equatable {
    let id: String
    let email: String?
}

struct EmailAccountSession: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: TimeInterval
    let user: EmailAccountUser
    enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresAt = "expires_at", expiresIn = "expires_in", user }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try values.decode(String.self, forKey: .accessToken)
        refreshToken = try values.decode(String.self, forKey: .refreshToken)
        expiresAt = try values.decodeIfPresent(TimeInterval.self, forKey: .expiresAt) ?? Date().timeIntervalSince1970 + (values.decodeIfPresent(TimeInterval.self, forKey: .expiresIn) ?? 3600)
        user = try values.decode(EmailAccountUser.self, forKey: .user)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(accessToken, forKey: .accessToken); try values.encode(refreshToken, forKey: .refreshToken)
        try values.encode(expiresAt, forKey: .expiresAt); try values.encode(user, forKey: .user)
    }
}

struct AccountFontID: Decodable { let font_id: String }
struct AccountDownloadRecord: Codable {
    let font_id: String
    let file_name: String
    let downloaded_at: String
}
struct AccountDownloadDraft: Codable { let fontID: String; let fileName: String }
struct AccountUploadResult: Decodable { let catalog: CloudCatalog; let auditRecorded: Bool }
struct AccountBaiduAuthorization: Decodable { let authorizationURL: URL; let state: String }

struct EmailAccountService {
    let configuration: EmailAccountConfiguration
    let session: URLSession
    init(configuration: EmailAccountConfiguration, session: URLSession = .shared) { self.configuration = configuration; self.session = session }
    private func call(_ path: String, method: String = "GET", credential: String? = nil, body: Any? = nil, prefer: String? = nil) async throws -> Data {
        let url = URL(string: path, relativeTo: configuration.projectURL)!.absoluteURL
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: path.contains("functions/") ? 180 : 30)
        request.httpMethod = method
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        if let credential { request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.message("账号服务响应无效。") }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if path.contains("functions/"), let error = object?["error"] as? String { throw CloudError.message(error) }
            if object?["error_code"] as? String == "email_not_confirmed" { throw CloudError.message("请先输入邮件验证码验证邮箱。") }
            switch http.statusCode {
            case 400, 401: throw CloudError.message("邮箱、密码或验证码无效，或登录已过期，请检查后重试。")
            case 403: throw CloudError.message("当前账号没有此操作权限。")
            case 429: throw CloudError.message("请求过于频繁，请稍后重试。")
            default: throw CloudError.message("账号服务暂时不可用（\(http.statusCode)），请稍后重试。")
            }
        }
        return data
    }
    func signIn(email: String, password: String) async throws -> EmailAccountSession {
        let data = try await call("/auth/v1/token?grant_type=password", method: "POST", body: ["email": email, "password": password])
        return try JSONDecoder().decode(EmailAccountSession.self, from: data)
    }
    func signUp(email: String, password: String) async throws {
        _ = try await call("/auth/v1/signup", method: "POST", body: ["email": email, "password": password])
    }
    func verify(email: String, code: String, type: String) async throws -> EmailAccountSession {
        let data = try await call("/auth/v1/verify", method: "POST", body: ["email": email, "token": code, "type": type])
        return try JSONDecoder().decode(EmailAccountSession.self, from: data)
    }
    func sendRecovery(email: String) async throws { _ = try await call("/auth/v1/recover", method: "POST", body: ["email": email]) }
    func updatePassword(_ password: String, credential: String) async throws {
        _ = try await call("/auth/v1/user", method: "PUT", credential: credential, body: ["password": password])
    }
    func refresh(_ session: EmailAccountSession) async throws -> EmailAccountSession {
        let data = try await call("/auth/v1/token?grant_type=refresh_token", method: "POST", body: ["refresh_token": session.refreshToken])
        let result = try JSONDecoder().decode(EmailAccountSession.self, from: data)
        guard result.user.id == session.user.id else { throw CloudError.message("账号会话不一致，请重新登录。") }
        return result
    }
    func user(credential: String) async throws -> EmailAccountUser {
        let data = try await call("/auth/v1/user", credential: credential)
        return try JSONDecoder().decode(EmailAccountUser.self, from: data)
    }
    func signOut(credential: String) async throws { _ = try await call("/auth/v1/logout?scope=local", method: "POST", credential: credential) }
    func catalog() async throws -> CloudCatalog { try CloudCatalog.decode(await call("/functions/v1/font-library")) }
    func download(_ font: CloudFont, store: CloudFontStore) async throws {
        try font.validate()
        let url = URL(string: "/functions/v1/font-download?id=\(font.id)", relativeTo: configuration.projectURL)!.absoluteURL
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CloudError.message("百度网盘字体下载失败，请稍后重试。") }
        try await Task.detached(priority: .userInitiated) { try store.saveDownload(temporary, font: font) }.value
    }
    func startBaiduConnection(credential: String) async throws -> AccountBaiduAuthorization {
        let data = try await call("/functions/v1/font-baidu-connect", method: "POST", credential: credential, body: ["action": "start"])
        let result = try JSONDecoder().decode(AccountBaiduAuthorization.self, from: data)
        guard result.authorizationURL.scheme == "https", result.authorizationURL.host == "openapi.baidu.com", UUID(uuidString: result.state) != nil else {
            throw CloudError.message("后台返回了无效授权地址。")
        }
        return result
    }
    func completeBaiduConnection(state: String, code: String, credential: String) async throws {
        _ = try await call("/functions/v1/font-baidu-connect", method: "POST", credential: credential,
                           body: ["action": "complete", "state": state, "code": code])
    }
    func isAdmin(credential: String, userID: String) async throws -> Bool {
        let data = try await call("/rest/v1/font_admins?select=user_id", credential: credential)
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return rows.contains { $0["user_id"] as? String == userID }
    }
    func favorites(credential: String) async throws -> Set<String> {
        let data = try await call("/rest/v1/font_favorites?select=font_id", credential: credential)
        return Set(try JSONDecoder().decode([AccountFontID].self, from: data).map(\.font_id))
    }
    func downloads(credential: String) async throws -> [AccountDownloadRecord] {
        let data = try await call("/rest/v1/font_downloads?select=font_id,file_name,downloaded_at&order=downloaded_at.desc", credential: credential)
        return try JSONDecoder().decode([AccountDownloadRecord].self, from: data)
    }
    func setFavorite(_ fontID: String, enabled: Bool, account: EmailAccountSession) async throws {
        if enabled {
            _ = try await call("/rest/v1/font_favorites?on_conflict=user_id,font_id", method: "POST", credential: account.accessToken,
                               body: ["user_id": account.user.id, "font_id": fontID], prefer: "resolution=ignore-duplicates")
        } else {
            _ = try await call("/rest/v1/font_favorites?font_id=eq.\(fontID)", method: "DELETE", credential: account.accessToken)
        }
    }
    func recordDownload(_ draft: AccountDownloadDraft, account: EmailAccountSession) async throws {
        _ = try await call("/rest/v1/font_downloads?on_conflict=user_id,font_id", method: "POST", credential: account.accessToken,
                           body: ["user_id": account.user.id, "font_id": draft.fontID, "file_name": draft.fileName, "downloaded_at": ISO8601DateFormatter().string(from: Date())],
                           prefer: "resolution=merge-duplicates")
    }
    func upload(data: Data, font: CloudFont, credential: String) async throws -> AccountUploadResult {
        guard data.count <= EmailAccountConfiguration.maximumUploadSize else { throw CloudError.message("邮箱账号版单个上传文件上限为 10 MiB。") }
        let body: [String: Any] = ["fileName": font.fileName, "displayName": font.displayName, "postScriptNames": font.postScriptNames, "content": data.base64EncodedString()]
        let response = try await call("/functions/v1/font-admin-upload", method: "POST", credential: credential, body: body)
        let result = try JSONDecoder().decode(AccountUploadResult.self, from: response)
        _ = try CloudCatalog.decode(result.catalog.encoded())
        guard result.catalog.fonts.contains(where: { $0.id == font.id }) else { throw CloudError.message("后台上传结果与字体文件不一致，请刷新清单。") }
        return result
    }
}
