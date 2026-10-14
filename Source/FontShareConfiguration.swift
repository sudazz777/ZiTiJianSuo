import Foundation

struct FontShareConfiguration: Codable {
    let title: String
    let url: URL
    let extractionCode: String
    static func load() -> FontShareConfiguration? {
        guard let resource = Bundle.main.url(forResource: "FontShare", withExtension: "json"),
              let data = try? Data(contentsOf: resource), let result = try? JSONDecoder().decode(Self.self, from: data),
              result.url.scheme == "https", result.url.host == "pan.baidu.com", result.url.path.hasPrefix("/s/") else { return nil }
        return result
    }
}
