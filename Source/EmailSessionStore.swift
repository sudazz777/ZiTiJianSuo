import Foundation
import Security

enum EmailSessionStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.fontname.mac.email-session",
         kSecAttrAccount as String: "supabase-account"]
    }
    private struct Stored: Codable { let project: String; let session: EmailAccountSession }
    static func read(project: URL) throws -> EmailAccountSession? {
        var query = self.query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CloudError.message("无法读取钥匙串账号，请重新登录。") }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        return stored.project == project.absoluteString ? stored.session : nil
    }
    static func save(_ session: EmailAccountSession, project: URL) throws {
        let data = try JSONEncoder().encode(Stored(project: project.absoluteString, session: session))
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CloudError.message("无法保存账号到钥匙串。") }
        var item = query; item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CloudError.message("无法保存账号到钥匙串。") }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudError.message("无法移除本机账号，请重试。") }
    }
}
