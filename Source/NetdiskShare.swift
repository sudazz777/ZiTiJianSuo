import Foundation

struct NetdiskShare {
    let url: URL
    let extractionCode: String?
    static let initialText = "https://pan.baidu.com/s/15fDbk7XGVjsMmKqgF0b0zg?pwd=4n5y"
    static func parse(_ text: String) throws -> NetdiskShare {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let link = matches.compactMap(\.url).first(where: { $0.host == "pan.baidu.com" && $0.path.hasPrefix("/s/") }),
              ["https", "http"].contains(link.scheme ?? ""), link.user == nil, link.password == nil,
              var components = URLComponents(url: link, resolvingAgainstBaseURL: false) else {
            throw CloudError.message("请粘贴百度网盘分享链接，可包含提取码。")
        }
        components.scheme = "https"
        let queryCode = components.queryItems?.first { $0.name == "pwd" }?.value
        let regex = try NSRegularExpression(pattern: "(?:提取码|提取碼|密码|密碼)\\s*[:：]?\\s*([A-Za-z0-9]{4})")
        let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        let pastedCode = match.flatMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
        let code = queryCode ?? pastedCode
        if let code {
            guard code.count == 4, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw CloudError.message("提取码格式无效。") }
            var items = components.queryItems?.filter { $0.name != "pwd" } ?? []
            items.append(URLQueryItem(name: "pwd", value: code)); components.queryItems = items
        }
        guard let url = components.url else { throw CloudError.message("分享链接无效。") }
        return NetdiskShare(url: url, extractionCode: code)
    }
}
