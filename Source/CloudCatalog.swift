import Foundation
import CryptoKit

enum CloudConfiguration {
    static let owner = "sudazz777"
    static let repository = "ZiTiJianSuo"
    static let branch = "main"
    static let maximumFontSize = 50 * 1024 * 1024
    static let maximumCatalogSize = 2 * 1024 * 1024
    static let extensions = ["ttf", "otf", "ttc"]
    static let repositoryURL = URL(string: "https://github.com/\(owner)/\(repository)")!
    static func rawURL(path: String, revision: String = branch) -> URL {
        var url = URL(string: "https://raw.githubusercontent.com")!
        for component in [owner, repository, revision] + path.split(separator: "/").map(String.init) {
            url.appendPathComponent(component)
        }
        return url
    }
}

enum CloudError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct CloudFont: Codable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let fileName: String
    let path: String
    let size: Int
    let sha256: String
    let postScriptNames: [String]
    let uploadedAt: String

    var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
    var uploadedDate: String {
        guard let date = ISO8601DateFormatter().date(from: uploadedAt) else { return uploadedAt }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    func validate() throws {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard sha256.count == 64, sha256.unicodeScalars.allSatisfy(hex.contains), id == sha256,
              size > 0, size <= CloudConfiguration.maximumFontSize,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !fileName.isEmpty, fileName.count <= 240,
              !fileName.contains("/"), !fileName.contains("\\"), !fileName.contains("\0"),
              CloudConfiguration.extensions.contains(fileExtension),
              path == "fonts/files/\(sha256).\(fileExtension)" else {
            throw CloudError.message("云端字体清单含有无效文件信息，请联系维护者。")
        }
    }
    func matches(_ query: String) -> Bool {
        let needle = FontNames.normalized(query)
        guard !needle.isEmpty else { return true }
        let names = [displayName, fileName] + postScriptNames
        return names.contains { name in
            FontNames.normalized(name).contains(needle) ||
            FontNames.normalized(FontNames.pinyin(name)).contains(needle) ||
            FontNames.normalized(FontNames.initials(name)).contains(needle)
        }
    }
}

struct CloudCatalog: Codable {
    var schemaVersion = 1
    var fonts: [CloudFont] = []

    static func decode(_ data: Data) throws -> CloudCatalog {
        guard data.count <= CloudConfiguration.maximumCatalogSize else {
            throw CloudError.message("云端清单过大，无法读取。")
        }
        let result = try JSONDecoder().decode(CloudCatalog.self, from: data)
        guard result.schemaVersion == 1, result.fonts.count <= 10_000,
              Set(result.fonts.map(\.id)).count == result.fonts.count else {
            throw CloudError.message("云端字体清单版本不支持，或包含重复条目。")
        }
        for font in result.fonts { try font.validate() }
        return result
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= CloudConfiguration.maximumCatalogSize else {
            throw CloudError.message("字体清单已达到容量上限，请联系维护者。")
        }
        return data
    }
}

enum CloudChecksum {
    static func data(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func file(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty { digest.update(data: block) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct CloudFontStore {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FontFinder/CloudFonts", isDirectory: true)
    }
    var catalogURL: URL { directory.appendingPathComponent("catalog.json") }
    func fileURL(_ font: CloudFont) -> URL { directory.appendingPathComponent("\(font.id).\(font.fileExtension)") }
    func prepare() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    func isValid(_ font: CloudFont) -> Bool {
        let url = fileURL(font)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.intValue == font.size else { return false }
        return (try? CloudChecksum.file(url)) == font.sha256
    }
    func saveDownload(_ temporary: URL, font: CloudFont) throws {
        try font.validate()
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        guard (attributes[.size] as? NSNumber)?.intValue == font.size,
              try CloudChecksum.file(temporary) == font.sha256 else {
            throw CloudError.message("下载文件校验失败，请刷新清单后重试。")
        }
        try prepare()
        let target = fileURL(font)
        let staged = directory.appendingPathComponent(".\(UUID().uuidString).download")
        try FileManager.default.copyItem(at: temporary, to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } else { try FileManager.default.moveItem(at: staged, to: target) }
    }
}
