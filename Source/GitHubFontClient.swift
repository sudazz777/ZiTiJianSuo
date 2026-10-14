import Foundation

struct GitHubIdentity: Decodable {
    let login: String
}

struct GitHubFontClient {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    private var base: String { "repos/\(CloudConfiguration.owner)/\(CloudConfiguration.repository)" }
    private func request(_ path: String, token: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard !token.isEmpty else { throw CloudError.message("请先连接管理员 GitHub 账号。") }
        let url = URL(string: "https://api.github.com/\(path)")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("FontFinder/1.5", forHTTPHeaderField: "User-Agent")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.message("GitHub 响应无效。") }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw CloudError.message("访问令牌无效或已过期，请重新连接。")
            case 403, 429: throw CloudError.message("GitHub 拒绝请求：请检查令牌权限、请求频率或网络访问情况。")
            case 404: throw CloudError.message("仓库或字体清单不存在，或令牌未授权访问当前仓库。")
            case 409, 422: throw CloudError.message("仓库在上传时发生变化；本次未覆盖他人修改，请刷新后重新上传。")
            default: throw CloudError.message("GitHub 请求失败（\(http.statusCode)），请稍后重试。")
            }
        }
        return data
    }
    private func object(_ path: String, token: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await request(path, token: token, method: method, body: body)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.message("GitHub 返回了无法识别的数据。")
        }
        return value
    }
    func authenticate(_ token: String) async throws -> String {
        let userData = try await request("user", token: token)
        let user = try JSONDecoder().decode(GitHubIdentity.self, from: userData)
        guard user.login.lowercased() == CloudConfiguration.owner.lowercased() else {
            throw CloudError.message("只有字体库维护者 \(CloudConfiguration.owner) 可以上传。")
        }
        let repository = try await object(base, token: token)
        guard repository["private"] as? Bool == false,
              let permissions = repository["permissions"] as? [String: Any], permissions["push"] as? Bool == true else {
            throw CloudError.message("需要公开仓库的写入权限，请检查令牌是否授权当前仓库。")
        }
        return user.login
    }
    func catalog() async throws -> CloudCatalog {
        let request = URLRequest(url: CloudConfiguration.rawURL(path: "fonts/index.json"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CloudError.message("暂时无法读取公开字体库，请检查网络后重试。")
        }
        return try CloudCatalog.decode(data)
    }
    func download(_ font: CloudFont, store: CloudFontStore) async throws {
        try font.validate()
        let request = URLRequest(url: CloudConfiguration.rawURL(path: font.path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CloudError.message("字体下载失败，请刷新清单后重试。")
        }
        try await Task.detached(priority: .userInitiated) { try store.saveDownload(temporary, font: font) }.value
    }
    func upload(data: Data, font: CloudFont, token: String) async throws -> CloudCatalog {
        try font.validate()
        guard data.count == font.size, CloudChecksum.data(data) == font.sha256 else {
            throw CloudError.message("待上传字体发生变化，请重新选择文件。")
        }
        _ = try await authenticate(token)
        // Read the index from the exact commit used as the new commit's parent.
        // A non-forced ref update rejects concurrent changes instead of losing them.
        let ref = try await object("\(base)/git/ref/heads/\(CloudConfiguration.branch)", token: token)
        guard let head = (ref["object"] as? [String: Any])?["sha"] as? String else { throw CloudError.message("无法读取仓库版本。") }
        let commit = try await object("\(base)/git/commits/\(head)", token: token)
        guard let treeSHA = (commit["tree"] as? [String: Any])?["sha"] as? String else { throw CloudError.message("无法读取仓库目录。") }
        let index = try await object("\(base)/contents/fonts/index.json?ref=\(head)", token: token)
        guard let encoded = index["content"] as? String,
              let indexData = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw CloudError.message("字体清单无法读取，请先初始化 fonts/index.json。")
        }
        var catalog = try CloudCatalog.decode(indexData)
        guard !catalog.fonts.contains(where: { $0.id == font.id }) else {
            throw CloudError.message("同一字体文件已经在云端，无需重复上传。")
        }
        let previous = catalog.fonts.filter { $0.fileName.caseInsensitiveCompare(font.fileName) == .orderedSame }
        catalog.fonts.removeAll { $0.fileName.caseInsensitiveCompare(font.fileName) == .orderedSame }
        catalog.fonts.append(font)
        let fontBlob = try await object("\(base)/git/blobs", token: token, method: "POST", body: ["content": data.base64EncodedString(), "encoding": "base64"])
        let catalogData = try catalog.encoded()
        let indexBlob = try await object("\(base)/git/blobs", token: token, method: "POST", body: ["content": catalogData.base64EncodedString(), "encoding": "base64"])
        guard let fontSHA = fontBlob["sha"] as? String, let indexSHA = indexBlob["sha"] as? String else { throw CloudError.message("GitHub 未能保存文件。") }
        var entries: [[String: Any]] = [
            ["path": font.path, "mode": "100644", "type": "blob", "sha": fontSHA],
            ["path": "fonts/index.json", "mode": "100644", "type": "blob", "sha": indexSHA]
        ]
        for old in previous where old.path != font.path {
            entries.append(["path": old.path, "mode": "100644", "type": "blob", "sha": NSNull()])
        }
        let tree = try await object("\(base)/git/trees", token: token, method: "POST", body: ["base_tree": treeSHA, "tree": entries])
        guard let newTree = tree["sha"] as? String else { throw CloudError.message("GitHub 未能生成文件目录。") }
        let result = try await object("\(base)/git/commits", token: token, method: "POST", body: ["message": "Upload font: \(font.displayName)", "tree": newTree, "parents": [head]])
        guard let newCommit = result["sha"] as? String else { throw CloudError.message("GitHub 未能生成上传记录。") }
        _ = try await object("\(base)/git/refs/heads/\(CloudConfiguration.branch)", token: token, method: "PATCH", body: ["sha": newCommit, "force": false])
        return catalog
    }
}
