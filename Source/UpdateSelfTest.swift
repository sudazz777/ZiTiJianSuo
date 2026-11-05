import Foundation
import CryptoKit

final class UpdateMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw UpdateError.unavailable }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

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
            for (field, value) in [("downloadURL", latest.downloadURL.absoluteString.replacingOccurrences(of: ".dmg", with: ".pkg") as Any), ("downloadURL", "https://example.com/app.dmg" as Any), ("downloadURL", "https://github.com/other/repo/releases/download/v1.9/app.dmg" as Any), ("downloadURL", latest.downloadURL.absoluteString.replacingOccurrences(of: "https:", with: "http:") as Any), ("schemaVersion", 2 as Any), ("sha256", "bad" as Any), ("size", 0 as Any), ("build", 0 as Any)] {
                var invalid = base; invalid[field] = value
                let data = try JSONSerialization.data(withJSONObject: invalid)
                rejects("rejects invalid metadata field \(field)") { _ = try AppUpdateRelease.decode(data) }
            }
            rejects("rejects oversized metadata") { _ = try AppUpdateRelease.decode(Data(repeating: 32, count: 65537)) }
            rejects("rejects malformed metadata") { _ = try AppUpdateRelease.decode(Data("<html>Error</html>".utf8)) }
            var oversized = base; oversized["size"] = AppUpdateDownload.maximumSize + 1
            rejects("rejects oversized installer metadata") { _ = try AppUpdateRelease.decode(JSONSerialization.data(withJSONObject: oversized)) }
            check(AppUpdateDownload.allowed(URL(string: "https://release-assets.githubusercontent.com/file.dmg")), "allows GitHub HTTPS release asset redirects")
            for address in ["http://github.com/file.dmg", "https://github.com.example.com/file.dmg", "https://user@github.com/file.dmg", "https://github.com:444/file.dmg", "https://example.com/file.dmg"] {
                check(!AppUpdateDownload.allowed(URL(string: address)), "rejects untrusted download redirect \(address)")
            }
            let fixture = Data("verified installer bytes".utf8)
            let digest = SHA256.hash(data: fixture).map { String(format: "%02x", $0) }.joined()
            let package = AppUpdateRelease(schemaVersion: 1, version: "1.14", build: 15, releaseNotes: [], downloadURL: AppUpdateRelease.packageURL(version: "1.14"), sha256: digest, size: fixture.count)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("FontFinder-Download-Test-\(UUID().uuidString).dmg")
            defer { try? FileManager.default.removeItem(at: file) }
            try fixture.write(to: file)
            try AppUpdateDownload.verify(file, release: package)
            check(true, "accepts exact installer bytes with matching size and SHA-256")
            try Data(repeating: 0, count: fixture.count).write(to: file)
            rejects("rejects same-size corrupted installer") { try AppUpdateDownload.verify(file, release: package) }
            try Data([1]).write(to: file)
            rejects("rejects truncated installer") { try AppUpdateDownload.verify(file, release: package) }

            let suite = "FontFinder.Updates.Test.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let policy = UpdateCheckPolicy(defaults: defaults)
            check(policy.shouldCheck(manual: false, startup: true), "every startup checks for updates")
            check(policy.shouldCheck(manual: true, startup: false), "manual update check remains available")
            check(!policy.shouldCheck(manual: false, startup: false), "background activity does not trigger update checks")
            policy.skip(latest)
            check(!policy.shouldPresent(latest, manual: false), "skipped version is not announced automatically")
            check(policy.shouldPresent(latest, manual: true), "manual check still offers skipped release")
            check(policy.shouldPresent(release(version: "1.10", build: 11), manual: false), "future release is still announced")
            check(!UpdateCheckPolicy(defaults: UserDefaults(suiteName: suite)!).shouldPresent(latest, manual: false), "skip selection persists")

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [UpdateMockProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel(); UpdateMockProtocol.handler = nil }
            let client = AppUpdateClient(session: session)
            UpdateMockProtocol.handler = { request in
                guard request.url == AppUpdateRelease.metadataURL, request.value(forHTTPHeaderField: "Authorization") == nil,
                      request.httpBody == nil, request.httpMethod == "GET", request.timeoutInterval <= 15 else { throw UpdateError.invalidRelease }
                return (200, encoded)
            }
            check(try await client.latest().identifier == latest.identifier, "public update fetch uses no credential or font payload")
            UpdateMockProtocol.handler = { _ in (404, Data()) }
            do { _ = try await client.latest(); check(false, "missing release fails gracefully") }
            catch { check(true, "missing release fails gracefully") }
            UpdateMockProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
            do { _ = try await client.latest(); check(false, "offline update check fails gracefully") }
            catch { check(true, "offline update check fails gracefully") }
            let downloadConfig = URLSessionConfiguration.ephemeral
            downloadConfig.protocolClasses = [UpdateMockProtocol.self]
            UpdateMockProtocol.handler = { request in
                guard request.url == package.downloadURL, request.value(forHTTPHeaderField: "Authorization") == nil else { throw UpdateError.invalidRelease }
                return (200, fixture)
            }
            let downloaded = try await AppUpdateDownload.fetch(package, session: URLSession(configuration: downloadConfig)) { _ in }
            defer { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) }
            check(try Data(contentsOf: downloaded) == fixture, "downloads and verifies a release to a private temporary file")
            UpdateMockProtocol.handler = { _ in (200, Data(repeating: 0, count: fixture.count)) }
            do {
                _ = try await AppUpdateDownload.fetch(package, session: URLSession(configuration: downloadConfig)) { _ in }
                check(false, "download corruption fails before installation")
            } catch { check(true, "download corruption fails before installation") }
            print("SUCCESS: \(checks) update checks passed")
        } catch { fputs("FAIL: unexpected update test error: \(error)\n", stderr); exit(1) }
    }
}
