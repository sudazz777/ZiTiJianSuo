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
            let client = EmailAccountService(configuration: EmailAccountConfiguration(projectURL: URL(string: "https://test.supabase.co")!, publishableKey: "sb_publishable_test"), session: session)
            CloudMockProtocol.handler = { request in
                check(request.value(forHTTPHeaderField: "Authorization") == nil, "public catalog request has no credential")
                return (200, try CloudCatalog(fonts: [entry]).encoded())
            }
            check(try await client.catalog().fonts == [entry], "reads public catalog without admin login")

            print("SUCCESS: \(checks) cloud checks passed")
        } catch { fputs("FAIL: unexpected error: \(error)\n", stderr); exit(1) }
    }
}
