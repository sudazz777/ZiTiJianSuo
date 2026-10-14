import Foundation

final class CloudMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw CloudError.message("No mock response") }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}

enum CloudSelfTest {
    @MainActor static func run() async {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else { fputs("FAIL: \(label)\n", stderr); exit(1) }
            checks += 1; print("PASS: \(label)")
        }
        func rejects(_ label: String, _ operation: () throws -> Void) {
            do { try operation(); check(false, label) } catch { check(true, label) }
        }
        func asyncRejects(_ label: String, _ operation: () async throws -> Void) async {
            do { try await operation(); check(false, label) } catch { check(true, label) }
        }
        func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
        let payload = Data("a test font payload".utf8)
        let hash = CloudChecksum.data(payload)
        func font(data: Data = payload, name: String = "测试字体", fileName: String = "Test.ttf", path: String? = nil) -> CloudFont {
            let digest = CloudChecksum.data(data)
            return CloudFont(id: digest, displayName: name, fileName: fileName, path: path ?? "fonts/files/\(digest).ttf", size: data.count,
                             sha256: digest, postScriptNames: ["Test-Regular"], uploadedAt: "2026-10-14T00:00:00Z")
        }
        let entry = font()
        check(CloudChecksum.data(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 matches independent known vector")
        do {
            let encoded = try CloudCatalog(fonts: [entry]).encoded()
            check(try CloudCatalog.decode(encoded).fonts == [entry], "catalog round trip")
            check(entry.matches("ceshi") && entry.matches("cszt") && entry.matches("Test-Regular"), "cloud search supports pinyin, initials and PostScript names")
            rejects("rejects path traversal") { try font(path: "../../outside.ttf").validate() }
            rejects("rejects remote download URLs") { try font(path: "https://example.com/font.ttf").validate() }
            rejects("rejects traversal filename") { try font(fileName: "../Test.ttf").validate() }
            rejects("rejects unsupported file extension") { try font(fileName: "Test.app").validate() }
            rejects("rejects duplicate font identities") { _ = try CloudCatalog.decode(CloudCatalog(fonts: [entry, entry]).encoded()) }
            rejects("rejects unknown catalog schema") { _ = try CloudCatalog.decode(json(["schemaVersion": 99, "fonts": []])) }
            rejects("rejects oversized catalog") { _ = try CloudCatalog.decode(Data(repeating: 0, count: CloudConfiguration.maximumCatalogSize + 1)) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FontFinder-Test-\(UUID().uuidString)")
            let store = CloudFontStore(directory: directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            try store.prepare()
            let temporary = directory.appendingPathComponent("source")
            try payload.write(to: temporary)
            try store.saveDownload(temporary, font: entry)
            check(store.isValid(entry), "verified download saved")
            try Data("corrupted".utf8).write(to: store.fileURL(entry))
            check(!store.isValid(entry), "corrupt download is eligible for retry")
            try store.saveDownload(temporary, font: entry)
            check(store.isValid(entry), "re-download atomically repairs existing file")
            try Data("invalid".utf8).write(to: temporary)
            rejects("rejects checksum mismatch") { try store.saveDownload(temporary, font: entry) }
            check(store.isValid(entry), "failed download preserves previous valid file")

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [CloudMockProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel(); CloudMockProtocol.handler = nil }
            let client = GitHubFontClient(session: session)
            CloudMockProtocol.handler = { request in
                if request.url!.path == "/user" { return (200, json(["login": "someone-else"])) }
                return (200, json(["private": false, "permissions": ["push": true]]))
            }
            await asyncRejects("non-owner account cannot upload") { _ = try await client.authenticate("test-token") }
            CloudMockProtocol.handler = { request in
                if request.url!.path == "/user" { return (200, json(["login": CloudConfiguration.owner])) }
                return (200, json(["private": false, "permissions": ["push": false]]))
            }
            await asyncRejects("read-only repository access rejected") { _ = try await client.authenticate("test-token") }
            CloudMockProtocol.handler = { _ in (401, Data()) }
            await asyncRejects("expired token rejected") { _ = try await client.authenticate("test-token") }
            CloudMockProtocol.handler = { request in
                check(request.value(forHTTPHeaderField: "Authorization") == nil, "public catalog request has no credential")
                return (200, try CloudCatalog(fonts: [entry]).encoded())
            }
            check(try await client.catalog().fonts == [entry], "reads catalog without admin login")

            let parent = String(repeating: "a", count: 40)
            let old = font(data: Data("older font version".utf8))
            var catalog = CloudCatalog(fonts: [old])
            var treeEntries: [[String: Any]] = []
            var postedCatalog: CloudCatalog?
            var refUpdated = false
            var writes = 0
            var rejectRef = false
            CloudMockProtocol.handler = { request in
                let path = request.url!.path, method = request.httpMethod ?? "GET"
                check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token", "upload API requires credential")
                if method != "GET" { writes += 1 }
                if path == "/user" { return (200, json(["login": CloudConfiguration.owner])) }
                if path.hasSuffix("/ZiTiJianSuo") { return (200, json(["private": false, "permissions": ["push": true]])) }
                if path.hasSuffix("/git/ref/heads/main") { return (200, json(["object": ["sha": parent]])) }
                if path.hasSuffix("/git/commits/\(parent)") { return (200, json(["tree": ["sha": String(repeating: "b", count: 40)]])) }
                if path.hasSuffix("/contents/fonts/index.json") {
                    check(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == parent, "upload reads manifest from parent commit")
                    return (200, json(["content": try catalog.encoded().base64EncodedString()]))
                }
                let body = try CloudMockProtocol.body(request)
                if path.hasSuffix("/git/blobs") {
                    let data = Data(base64Encoded: body["content"] as! String)!
                    if let parsed = try? CloudCatalog.decode(data) { postedCatalog = parsed }
                    return (201, json(["sha": String(repeating: "c", count: 40)]))
                }
                if path.hasSuffix("/git/trees") {
                    treeEntries = body["tree"] as! [[String: Any]]
                    return (201, json(["sha": String(repeating: "d", count: 40)]))
                }
                if path.hasSuffix("/git/commits") {
                    check(body["parents"] as? [String] == [parent], "upload commit preserves current parent")
                    return (201, json(["sha": String(repeating: "e", count: 40)]))
                }
                if path.hasSuffix("/git/refs/heads/main") {
                    check(body["force"] as? Bool == false, "upload never forces a branch update")
                    if rejectRef { return (422, json(["message": "not a fast forward"])) }
                    refUpdated = true; return (200, json(["ok": true]))
                }
                throw CloudError.message("Unexpected mock request: \(path)")
            }
            let uploaded = try await client.upload(data: payload, font: entry, token: "test-token")
            check(refUpdated && uploaded.fonts == [entry], "upload replaces same-name font in catalog")
            check(postedCatalog?.fonts == [entry], "published index describes actual new file")
            check(treeEntries.contains { $0["path"] as? String == entry.path } && treeEntries.contains { $0["path"] as? String == "fonts/index.json" }, "font file and index published in one tree")
            check(treeEntries.contains { $0["path"] as? String == old.path && $0["sha"] is NSNull }, "old same-name version removed from live tree")
            catalog = CloudCatalog(fonts: [entry]); writes = 0
            await asyncRejects("duplicate file rejected") { _ = try await client.upload(data: payload, font: entry, token: "test-token") }
            check(writes == 0, "duplicate upload does not create any remote objects")
            catalog = CloudCatalog(); rejectRef = true; refUpdated = false
            await asyncRejects("concurrent update reported as failure") { _ = try await client.upload(data: payload, font: entry, token: "test-token") }
            check(!refUpdated, "failed ref update never reported as successful upload")
            check(hash == entry.id, "font identity is content checksum")
            print("SUCCESS: \(checks) cloud checks passed")
        } catch { fputs("FAIL: unexpected error: \(error)\n", stderr); exit(1) }
    }
}
