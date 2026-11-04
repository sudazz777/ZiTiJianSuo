import Foundation

enum UpdateSelfTest {
    @MainActor static func run() async {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { fputs("FAIL: \(label)\n", stderr); exit(1) }
            checks += 1; print("PASS: \(label)")
        }
        func rejects(_ label: String, _ action: () throws -> Void) {
            do { try action(); check(false, label) } catch { check(true, label) }
        }
        func release(version: String = "1.9", build: Int = 10) -> AppUpdateRelease {
            AppUpdateRelease(schemaVersion: 1, version: version, build: build, releaseNotes: ["排序菜单一步展开", "检查更新"], downloadURL: AppUpdateRelease.packageURL(version: version), sha256: String(repeating: "a", count: 64), size: 100)
        }
        do {
            check(try UpdateVersion("1.10") > UpdateVersion("1.9"), "version comparison is numeric")
            check(try UpdateVersion("1.9") == UpdateVersion("1.9.0"), "missing patch number is normalized")
            check(try UpdateVersion("2.0") > UpdateVersion("1.99.99"), "major version takes priority")
            for invalid in ["v1.9", "1..9", "1.9-beta", "1.2.3.4", "1.9/../../bad", "1.９"] {
                rejects("rejects invalid version \(invalid)") { _ = try UpdateVersion(invalid) }
            }
            let latest = release(), encoded = try JSONEncoder().encode(latest)
            check(try AppUpdateRelease.decode(encoded).identifier == "1.9+10", "decodes generated release metadata")
            check(try latest.isNewer(than: "1.8", build: 999), "newer version is offered")
            check(try latest.isNewer(than: "1.9", build: 9), "newer build is offered")
            check(try !latest.isNewer(than: "1.9", build: 10), "current release is not offered")
            check(try !latest.isNewer(than: "2.0", build: 1), "older release is not offered")
            let base = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            for (field, value) in [("downloadURL", "https://example.com/app.dmg" as Any), ("downloadURL", "https://github.com/other/repo/releases/download/v1.9/app.dmg" as Any), ("downloadURL", latest.downloadURL.absoluteString.replacingOccurrences(of: "https:", with: "http:") as Any), ("schemaVersion", 2 as Any), ("sha256", "bad" as Any), ("size", 0 as Any), ("build", 0 as Any)] {
                var invalid = base; invalid[field] = value
                let data = try JSONSerialization.data(withJSONObject: invalid)
                rejects("rejects invalid metadata field \(field)") { _ = try AppUpdateRelease.decode(data) }
            }
            rejects("rejects oversized metadata") { _ = try AppUpdateRelease.decode(Data(repeating: 32, count: 65537)) }
            rejects("rejects malformed metadata") { _ = try AppUpdateRelease.decode(Data("<html>Error</html>".utf8)) }

            let suite = "FontFinder.Updates.Test.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let policy = UpdateCheckPolicy(defaults: defaults), now = Date(timeIntervalSince1970: 1_700_000_000)
            check(policy.isDue(manual: false, now: now), "first automatic check is due")
            policy.recordAttempt(now: now)
            check(!policy.isDue(manual: false, now: now.addingTimeInterval(3600)), "automatic checks are limited to daily")
            check(policy.isDue(manual: true, now: now), "manual check bypasses daily interval")
            check(policy.isDue(manual: false, now: now.addingTimeInterval(86400)), "automatic check is due after a day")
            check(policy.isDue(manual: false, now: now.addingTimeInterval(-10)), "clock rollback does not suppress updates forever")
            policy.skip(latest)
            check(!policy.shouldPresent(latest, manual: false), "skipped version is not announced automatically")
            check(policy.shouldPresent(latest, manual: true), "manual check still offers skipped release")
            check(policy.shouldPresent(release(version: "1.10", build: 11), manual: false), "future release is still announced")
            check(!UpdateCheckPolicy(defaults: UserDefaults(suiteName: suite)!).shouldPresent(latest, manual: false), "skip selection persists")

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CloudMockProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel(); CloudMockProtocol.handler = nil }
            let client = AppUpdateClient(session: session)
            CloudMockProtocol.handler = { request in
                guard request.url == AppUpdateRelease.metadataURL, request.value(forHTTPHeaderField: "Authorization") == nil,
                      request.httpBody == nil, request.httpMethod == "GET", request.timeoutInterval <= 15 else { throw UpdateError.invalidRelease }
                return (200, encoded)
            }
            check(try await client.latest().identifier == latest.identifier, "public update fetch uses no credential or font payload")
            CloudMockProtocol.handler = { _ in (404, Data()) }
            do { _ = try await client.latest(); check(false, "missing release fails gracefully") }
            catch { check(true, "missing release fails gracefully") }
            CloudMockProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
            do { _ = try await client.latest(); check(false, "offline update check fails gracefully") }
            catch { check(true, "offline update check fails gracefully") }
            print("SUCCESS: \(checks) update checks passed")
        } catch { fputs("FAIL: unexpected update test error: \(error)\n", stderr); exit(1) }
    }
}
