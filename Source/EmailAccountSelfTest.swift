import Foundation

enum EmailAccountSelfTest {
    @MainActor static func run() async {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else { fputs("FAIL: \(label)\n", stderr); exit(1) }
            checks += 1; print("PASS: \(label)")
        }
        func rejects(_ label: String, _ operation: () async throws -> Void) async {
            do { try await operation(); check(false, label) } catch { check(true, label) }
        }
        func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
        let config = EmailAccountConfiguration(projectURL: URL(string: "https://account-test.supabase.co")!, publishableKey: "sb_publishable_test")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudMockProtocol.self]
        let network = URLSession(configuration: configuration)
        defer { network.invalidateAndCancel(); CloudMockProtocol.handler = nil }
        let service = EmailAccountService(configuration: config, session: network)
        let id = "11111111-1111-1111-1111-111111111111"
        func sessionData(userID: String = id, access: String = "account-access", refresh: String = "account-refresh") -> Data {
            json(["access_token": access, "refresh_token": refresh, "expires_in": 3600, "user": ["id": userID, "email": "test@example.com"]])
        }
        do {
            try config.validate(); check(true, "accepts public client configuration")
            await rejects("rejects secret Supabase key in client") {
                try EmailAccountConfiguration(projectURL: config.projectURL, publishableKey: "sb_secret_test").validate()
            }
            let privileged = "eyJ0eXAiOiJKV1QifQ." + json(["role": "service_role"]).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
            await rejects("rejects service-role JWT in client configuration") {
                try EmailAccountConfiguration(projectURL: config.projectURL, publishableKey: privileged).validate()
            }
            CloudMockProtocol.handler = { request in
                check(request.url?.host == config.projectURL.host, "account requests stay on configured project")
                check(request.value(forHTTPHeaderField: "apikey") == config.publishableKey, "account requests use public API key")
                check(request.value(forHTTPHeaderField: "Authorization") == nil, "password login does not use a GitHub credential")
                let body = try CloudMockProtocol.body(request)
                check(body["email"] as? String == "test@example.com", "password login supplies requested email")
                return (200, sessionData())
            }
            let signedIn = try await service.signIn(email: "test@example.com", password: "test-password")
            check(signedIn.user.id == id && signedIn.expiresAt > Date().timeIntervalSince1970, "password login decodes identity and expiry")
            let restored = try JSONDecoder().decode(EmailAccountSession.self, from: JSONEncoder().encode(signedIn))
            check(restored.refreshToken == signedIn.refreshToken && restored.user == signedIn.user, "login session can be persisted without password")
            CloudMockProtocol.handler = { request in
                let body = try CloudMockProtocol.body(request)
                check(body["refresh_token"] as? String == signedIn.refreshToken, "refresh uses current refresh credential")
                return (200, sessionData(access: "rotated-access", refresh: "rotated-refresh"))
            }
            let refreshed = try await service.refresh(signedIn)
            check(refreshed.accessToken == "rotated-access" && refreshed.refreshToken == "rotated-refresh", "refresh preserves rotated credentials")
            CloudMockProtocol.handler = { _ in (200, sessionData(userID: "22222222-2222-2222-2222-222222222222")) }
            await rejects("rejects refresh that switches account identity") { _ = try await service.refresh(signedIn) }
            CloudMockProtocol.handler = { _ in (401, json(["error_code": "invalid_credentials"])) }
            await rejects("invalid login is not accepted") { _ = try await service.signIn(email: "test@example.com", password: "wrong") }
            CloudMockProtocol.handler = { _ in (200, json([])) }
            check(try await !service.isAdmin(credential: "account-access", userID: id), "normal user has no administrator role")
            CloudMockProtocol.handler = { _ in (200, json([["user_id": "22222222-2222-2222-2222-222222222222"]])) }
            check(try await !service.isAdmin(credential: "account-access", userID: id), "someone else's admin row does not grant upload")
            let fontID = String(repeating: "a", count: 64)
            CloudMockProtocol.handler = { request in
                check(request.value(forHTTPHeaderField: "Authorization") == "Bearer account-access", "personal records require account session")
                return (200, json([["font_id": fontID]]))
            }
            check(try await service.favorites(credential: "account-access") == [fontID], "reads per-account favorites")
            CloudMockProtocol.handler = { request in
                let body = try CloudMockProtocol.body(request)
                check(body["user_id"] as? String == id && body["font_id"] as? String == fontID, "download record is associated with initiating user")
                return (201, Data())
            }
            try await service.recordDownload(AccountDownloadDraft(fontID: fontID, fileName: "Test.ttf"), account: signedIn)
            CloudMockProtocol.handler = { request in
                let body = try CloudMockProtocol.body(request)
                check(body["type"] as? String == "recovery" && body["token"] as? String == "123456", "recovery code uses recovery verification flow")
                return (200, sessionData())
            }
            _ = try await service.verify(email: "test@example.com", code: "123456", type: "recovery")
            CloudMockProtocol.handler = { request in
                check(request.httpMethod == "PUT" && request.value(forHTTPHeaderField: "Authorization") == "Bearer account-access", "password change requires verified session")
                return (200, json(["id": id]))
            }
            try await service.updatePassword("new-test-password", credential: "account-access")
            print("SUCCESS: \(checks) email account checks passed")
        } catch { fputs("FAIL: unexpected email-account error: \(error)\n", stderr); exit(1) }
    }
}
