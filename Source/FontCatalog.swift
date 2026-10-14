import Foundation
import CoreText

struct NameEntry {
    let id: Int
    let language: Int
    let platform: Int
    let text: String
    var isChinese: Bool { platform == 3 && language & 0x3ff == 4 }
    var isEnglish: Bool { platform == 3 && language & 0x3ff == 9 }
}

enum FontNames {
    static func entries(_ data: Data) -> [NameEntry] {
        let bytes = [UInt8](data)
        func word(_ i: Int) -> Int? {
            guard i >= 0, i + 1 < bytes.count else { return nil }
            return Int(bytes[i]) << 8 | Int(bytes[i + 1])
        }
        guard let count = word(2), let storage = word(4),
              6 + count * 12 <= bytes.count, storage <= bytes.count else { return [] }
        var result: [NameEntry] = []
        for i in 0..<count {
            let p = 6 + i * 12
            guard let platform = word(p), let encoding = word(p + 2),
                  let language = word(p + 4), let id = word(p + 6),
                  let length = word(p + 8), let offset = word(p + 10) else { continue }
            let start = storage + offset
            guard start + length <= bytes.count else { continue }
            let slice = Data(bytes[start..<(start + length)])
            let text: String?
            if platform == 0 || (platform == 3 && [0, 1, 10].contains(encoding)) {
                text = String(data: slice, encoding: .utf16BigEndian)
            } else if platform == 1 && encoding == 0 {
                text = String(data: slice, encoding: .macOSRoman)
            } else { text = nil }
            if let text = text?.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                result.append(NameEntry(id: id, language: language, platform: platform, text: text))
            }
        }
        return result
    }

    static func hasHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) || (0x20000...0x3134f).contains($0.value) }
    }

    static func pinyin(_ text: String) -> String {
        (text.applyingTransform(.mandarinToLatin, reverse: false) ?? text)
            .applyingTransform(.stripDiacritics, reverse: false) ?? text
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func initials(_ text: String) -> String {
        pinyin(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .compactMap(\.first).map(String.init).joined().lowercased()
    }

    // Search aliases supplement the metadata; they are never presented as official names.
    static let aliases: [(String, [String])] = [
        ("PingFang SC", ["苹方", "苹方简体", "平方"]), ("PingFang TC", ["苹方", "苹方繁体"]),
        ("PingFang HK", ["苹方", "苹方香港"]), ("Songti", ["宋体"]), ("Heiti", ["黑体"]),
        ("Kaiti", ["楷体"]), ("STSong", ["华文宋体", "宋体"]), ("STHeiti", ["华文黑体", "黑体"]),
        ("STKaiti", ["华文楷体", "楷体"]), ("STFangsong", ["华文仿宋", "仿宋"]),
        ("Hiragino Sans GB", ["冬青黑体"]), ("Microsoft YaHei", ["微软雅黑"]),
        ("Microsoft JhengHei", ["微软正黑体"]), ("SimSun", ["宋体", "中易宋体"]),
        ("SimHei", ["黑体", "中易黑体"]), ("FangSong", ["仿宋"]), ("KaiTi", ["楷体"]),
        ("Noto Sans CJK SC", ["思源黑体"]), ("Noto Serif CJK SC", ["思源宋体"]),
        ("Source Han Sans", ["思源黑体"]), ("Source Han Serif", ["思源宋体"]),
        ("Arial", ["阿里尔"]), ("Helvetica", ["赫尔维蒂卡"]), ("Times New Roman", ["新罗马"])
    ]
}

enum FontBookSource {
    static func accepts(name: String, family: String, url: URL?, enabled: Bool, scope: Int, priority: Int, exists: Bool) -> Bool {
        guard enabled, scope == Int(CTFontManagerScope.persistent.rawValue), exists,
              let url = url, url.isFileURL, !name.isEmpty, !family.isEmpty,
              !name.hasPrefix("."), !family.hasPrefix("."),
              !url.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) else { return false }
        let standardPriorities = [Int(kCTFontPrioritySystem), Int(kCTFontPriorityNetwork), Int(kCTFontPriorityComputer), Int(kCTFontPriorityUser)]
        let downloadedSystemFont = url.path.hasPrefix("/System/Library/Assets") && url.pathComponents.contains { $0.hasPrefix("com_apple_MobileAsset_Font") }
        return standardPriorities.contains(priority) || downloadedSystemFont
    }

    static func descriptors() -> [CTFontDescriptor] {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let available = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        return available.filter { descriptor in
            let url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL
            return accepts(
                name: CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String ?? "",
                family: CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String ?? "",
                url: url,
                enabled: (CTFontDescriptorCopyAttribute(descriptor, kCTFontEnabledAttribute) as? NSNumber)?.boolValue ?? false,
                scope: (CTFontDescriptorCopyAttribute(descriptor, kCTFontRegistrationScopeAttribute) as? NSNumber)?.intValue ?? 0,
                priority: (CTFontDescriptorCopyAttribute(descriptor, kCTFontPriorityAttribute) as? NSNumber)?.intValue ?? 0,
                exists: url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        }.sorted { a, b in
            let pa = (CTFontDescriptorCopyAttribute(a, kCTFontPriorityAttribute) as? NSNumber)?.intValue ?? 0
            let pb = (CTFontDescriptorCopyAttribute(b, kCTFontPriorityAttribute) as? NSNumber)?.intValue ?? 0
            if pa != pb { return pa > pb }
            let ua = (CTFontDescriptorCopyAttribute(a, kCTFontURLAttribute) as? URL)?.path ?? ""
            let ub = (CTFontDescriptorCopyAttribute(b, kCTFontURLAttribute) as? URL)?.path ?? ""
            return ua < ub
        }
    }
}

struct FontFace: Identifiable {
    let id: String
    let family: String
    let englishFamily: String
    let chineseFamily: String?
    let style: String
    let localizedStyle: String?
    let weight: Double
    let italic: Bool
    let sourceURL: URL?
    let supportsChinese: Bool
    let names: [String]
    var label: String { localizedStyle ?? style }

    init(id: String, family: String, englishFamily: String, chineseFamily: String?, style: String,
         localizedStyle: String? = nil, weight: Double = 0, italic: Bool = false,
         sourceURL: URL? = nil, supportsChinese: Bool = false, names: [String] = []) {
        self.id = id; self.family = family; self.englishFamily = englishFamily; self.chineseFamily = chineseFamily
        self.style = style; self.localizedStyle = localizedStyle; self.weight = weight; self.italic = italic
        self.sourceURL = sourceURL; self.supportsChinese = supportsChinese; self.names = names
    }

    static func preferred(_ a: FontFace, _ b: FontFace) -> Bool {
        if a.italic != b.italic { return !a.italic }
        let regularNames = ["regular", "normal", "book", "roman"]
        let ar = regularNames.contains(FontNames.normalized(a.style))
        let br = regularNames.contains(FontNames.normalized(b.style))
        if ar != br { return ar }
        if abs(a.weight) != abs(b.weight) { return abs(a.weight) < abs(b.weight) }
        return a.id < b.id
    }

    static func read(_ descriptor: CTFontDescriptor) -> FontFace? {
        let font = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
        let name = CTFontCopyPostScriptName(font) as String
        let entries = (CTFontCopyTable(font, CTFontTableTag(0x6e616d65), []) as Data?).map(FontNames.entries) ?? []
        let englishEntries = entries.filter(\.isEnglish)
        let chineseEntries = entries.filter(\.isChinese).sorted { ($0.language == 0x804 ? 0 : 1) < ($1.language == 0x804 ? 0 : 1) }
        func first(_ list: [NameEntry], _ ids: [Int]) -> String? {
            for id in ids { if let value = list.first(where: { $0.id == id })?.text { return value } }
            return nil
        }
        let chinese = first(chineseEntries, [16, 1]).flatMap { FontNames.hasHan($0) ? $0 : nil }
        let rawFamily = first(englishEntries, [16, 1]) ?? (CTFontCopyFamilyName(font) as String)
        let family = rawFamily.contains("?") ? (chinese ?? rawFamily) : rawFamily
        guard !name.hasPrefix("."), !family.hasPrefix("."), !(CTFontCopyFullName(font) as String).hasPrefix(".") else { return nil }
        let style = first(englishEntries, [17, 2]) ?? (CTFontCopyName(font, kCTFontSubFamilyNameKey) as String?) ?? "Regular"
        let traits = CTFontCopyTraits(font) as NSDictionary
        let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        let italic = CTFontGetSymbolicTraits(font).contains(.traitItalic)
        var characters: [UniChar] = [0x4e2d, 0x6587]
        var glyphs: [CGGlyph] = [0, 0]
        let supportsChinese = CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 2)
        return FontFace(id: name, family: family, englishFamily: family, chineseFamily: chinese, style: style,
                        localizedStyle: first(chineseEntries, [17, 2]), weight: weight, italic: italic,
                        sourceURL: CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL,
                        supportsChinese: supportsChinese, names: entries.filter { [1, 2, 4, 6, 16, 17].contains($0.id) }.map(\.text))
    }
}

struct FontRecord: Identifiable {
    let id: String
    let family: String
    let english: String
    let chinese: String?
    let style: String
    let aliases: [String]
    let allNames: [String]
    let supportsChinese: Bool
    let searchIndex: [String]
    let faces: [FontFace]
    var defaultFace: FontFace { faces.sorted(by: FontFace.preferred).first! }

    init(id: String, family: String, english: String, chinese: String?, style: String, aliases: [String], allNames: [String], supportsChinese: Bool = false, faces: [FontFace]? = nil) {
        self.id = id; self.family = family; self.english = english; self.chinese = chinese
        self.style = style; self.aliases = aliases; self.allNames = allNames
        self.supportsChinese = supportsChinese
        self.faces = faces.flatMap { $0.isEmpty ? nil : $0 } ?? [FontFace(id: id, family: family, englishFamily: english, chineseFamily: chinese, style: style, supportsChinese: supportsChinese)]
        let terms = [id, family, english, chinese ?? "", style] + aliases + allNames
        self.searchIndex = Array(Set(terms.flatMap { [FontNames.normalized($0), FontNames.normalized(FontNames.pinyin($0)), FontNames.initials($0)] }.filter { !$0.isEmpty }))
    }

    func matches(_ query: String, custom: CustomNames? = nil) -> Bool {
        let q = FontNames.normalized(query)
        guard !q.isEmpty else { return true }
        let extras = [custom?.chinese ?? "", custom?.english ?? ""].flatMap {
            [FontNames.normalized($0), FontNames.normalized(FontNames.pinyin($0)), FontNames.initials($0)]
        }
        return (searchIndex + extras).contains { $0.contains(q) }
    }

    static func familyKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func merged(_ input: [FontFace]) -> [FontRecord] {
        var seen = Set<String>()
        let faces = input.filter { seen.insert($0.id).inserted }
        let groups = Dictionary(grouping: faces) { familyKey($0.family) }
        return groups.map { key, members in
            let ordered = members.sorted { a, b in
                if a.weight != b.weight { return a.weight < b.weight }
                if a.italic != b.italic { return !a.italic }
                return a.id < b.id
            }
            let preferred = members.sorted(by: FontFace.preferred)
            let representative = preferred[0]
            let chinese = preferred.compactMap(\.chineseFamily).first
            let family = representative.englishFamily
            let aliases = FontNames.aliases.filter { FontNames.normalized(family).contains(FontNames.normalized($0.0)) }.flatMap(\.1)
            let all = Array(Set(members.flatMap { [$0.id, $0.family, $0.style, $0.label] + $0.names }))
            return FontRecord(id: "family:" + key, family: family, english: family, chinese: chinese,
                              style: representative.style, aliases: aliases, allNames: all,
                              supportsChinese: members.contains(where: \.supportsChinese), faces: ordered)
        }.sorted { a, b in
            let preferred = ["PingFang SC", "Songti SC", "Kaiti SC", "Helvetica", "Arial"]
            let pa = preferred.firstIndex(of: a.family) ?? 100
            let pb = preferred.firstIndex(of: b.family) ?? 100
            if pa != pb { return pa < pb }
            let order = a.english.localizedStandardCompare(b.english)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }

    static func installed() -> [FontRecord] {
        merged(FontBookSource.descriptors().compactMap(FontFace.read))
    }
}

struct CustomNames: Codable, Equatable {
    var chinese = ""
    var english = ""
}
