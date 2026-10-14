import AppKit
import SwiftUI
import CoreText

enum LibrarySection: String, CaseIterable {
    case all = "全部字体", chinese = "中文字体", favorites = "我的收藏", recent = "最近复制"
    var icon: String {
        switch self { case .all: return "square.grid.2x2"; case .chinese: return "character.book.closed"; case .favorites: return "star"; case .recent: return "clock" }
    }
}

enum FontSortOrder: String, CaseIterable, Identifiable {
    case englishAZ, englishZA, pinyinAZ, pinyinZA, recentFirst, defaultOrder
    var id: String { rawValue }
    var title: String {
        switch self {
        case .englishAZ: return "英文名 A–Z"
        case .englishZA: return "英文名 Z–A"
        case .pinyinAZ: return "中文拼音 A–Z"
        case .pinyinZA: return "中文拼音 Z–A"
        case .recentFirst: return "最近复制优先"
        case .defaultOrder: return "默认排序"
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var fonts: [FontRecord] = []
    @Published var query = "" { didSet { filter() } }
    @Published var section: LibrarySection = .all { didSet { filter() } }
    @Published var sortOrder: FontSortOrder {
        didSet {
            defaults.set(sortOrder.rawValue, forKey: "sortOrder")
            filter()
        }
    }
    @Published var visible: [FontRecord] = []
    @Published var selection: String?
    @Published var loading = true
    @Published var toast: String?
    @Published var preview = "把灵感，写成日常。"
    @Published var size: Double = 26
    @Published var favorites: Set<String>
    @Published var recent: [String]
    @Published var custom: [String: CustomNames]
    @Published var showEditor = false
    @Published var faceSelections: [String: String] = [:]
    private let defaults: UserDefaults
    private var toastWork: DispatchWorkItem?
    private var fontObserver: NSObjectProtocol?
    private var scanning = false
    private var reloadPending = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sortOrder = defaults.string(forKey: "sortOrder").flatMap(FontSortOrder.init(rawValue:)) ?? .englishAZ
        favorites = Set(defaults.stringArray(forKey: "favorites") ?? [])
        recent = defaults.stringArray(forKey: "recent") ?? []
        custom = defaults.data(forKey: "customNames").flatMap { try? JSONDecoder().decode([String: CustomNames].self, from: $0) } ?? [:]
        fontObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(kCTFontManagerRegisteredFontsChangedNotification as String), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        guard !scanning else { reloadPending = true; return }
        scanning = true
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let records = FontRecord.installed()
            DispatchQueue.main.async {
                self.applyCatalog(records)
                self.scanning = false
                self.loading = false
                if self.reloadPending { self.reloadPending = false; self.reload() }
            }
        }
    }

    func applyCatalog(_ records: [FontRecord]) {
        var lookup: [String: String] = [:]
        for font in records {
            lookup[font.id] = font.id
            for face in font.faces { lookup[face.id] = font.id }
        }
        if let old = selection, let family = lookup[old] {
            selection = family
            if old != family { faceSelections[family] = old }
        }
        favorites = Set(favorites.map { lookup[$0] ?? $0 })
        var seen = Set<String>()
        recent = recent.map { lookup[$0] ?? $0 }.filter { seen.insert($0).inserted }
        let previous = custom
        var migrated = custom
        for font in records {
            if migrated[font.id] == nil {
                for face in font.faces.sorted(by: FontFace.preferred) {
                    if let names = previous[face.id] { migrated[font.id] = names; break }
                }
            }
            for face in font.faces where face.id != font.id { migrated.removeValue(forKey: face.id) }
        }
        custom = migrated
        defaults.set(Array(favorites), forKey: "favorites")
        defaults.set(recent, forKey: "recent")
        defaults.set(try? JSONEncoder().encode(custom), forKey: "customNames")
        fonts = records
        filter()
    }

    func previewFace(_ font: FontRecord) -> FontFace {
        font.faces.first { $0.id == faceSelections[font.id] } ?? font.defaultFace
    }
    func selectFace(_ id: String, for font: FontRecord) {
        guard font.faces.contains(where: { $0.id == id }) else { return }
        faceSelections[font.id] = id
    }

    func filter() {
        let byID = Dictionary(uniqueKeysWithValues: fonts.map { ($0.id, $0) })
        var source = section == .recent ? recent.compactMap { byID[$0] } : fonts
        if section == .favorites { source = source.filter { favorites.contains($0.id) } }
        if section == .chinese { source = source.filter(\.supportsChinese) }
        visible = sorted(source.filter { $0.matches(query, custom: custom[$0.id]) })
        if !visible.contains(where: { $0.id == selection }) { selection = visible.first?.id }
    }

    private func sorted(_ records: [FontRecord]) -> [FontRecord] {
        guard sortOrder != .defaultOrder else { return records }
        let pinyin = sortOrder == .pinyinAZ || sortOrder == .pinyinZA
        let descending = sortOrder == .englishZA || sortOrder == .pinyinZA
        let ranks = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($0.element, $0.offset) })
        let keyed = records.map { font -> (font: FontRecord, key: String) in
            let name = pinyin ? (chineseName(font) ?? englishName(font)) : englishName(font)
            let key = FontNames.normalized(FontNames.hasHan(name) ? FontNames.pinyin(name) : name)
            return (font, key)
        }
        return keyed.sorted { a, b in
            if sortOrder == .recentFirst {
                let ra = ranks[a.font.id] ?? Int.max
                let rb = ranks[b.font.id] ?? Int.max
                if ra != rb { return ra < rb }
            }
            let comparison = a.key.compare(b.key, options: [.numeric, .caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if comparison == .orderedSame { return descending ? a.font.id > b.font.id : a.font.id < b.font.id }
            return descending ? comparison == .orderedDescending : comparison == .orderedAscending
        }.map(\.font)
    }

    var selected: FontRecord? { fonts.first { $0.id == selection } }
    func chineseName(_ font: FontRecord) -> String? {
        let c = custom[font.id]?.chinese.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return c.isEmpty ? font.chinese : c
    }
    func englishName(_ font: FontRecord) -> String {
        let e = custom[font.id]?.english.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return e.isEmpty ? font.english : e
    }
    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        defaults.set(Array(favorites), forKey: "favorites")
        filter()
    }
    func saveNames(_ names: CustomNames, for id: String) {
        let clean = CustomNames(chinese: names.chinese.trimmingCharacters(in: .whitespacesAndNewlines), english: names.english.trimmingCharacters(in: .whitespacesAndNewlines))
        if clean == CustomNames() { custom.removeValue(forKey: id) } else { custom[id] = clean }
        defaults.set(try? JSONEncoder().encode(custom), forKey: "customNames")
        filter()
    }
    @discardableResult func copy(_ value: String, font: FontRecord, label: String, pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else {
            notify("复制失败，请重试")
            return false
        }
        recent.removeAll { $0 == font.id }
        recent.insert(font.id, at: 0)
        recent = Array(recent.prefix(50))
        defaults.set(recent, forKey: "recent")
        if section == .recent || sortOrder == .recentFirst { filter() }
        notify("已复制\(label) · \(value)")
        return true
    }
    func notify(_ text: String) {
        toastWork?.cancel()
        withAnimation(.easeOut(duration: 0.18)) { toast = text }
        let work = DispatchWorkItem { [weak self] in withAnimation { self?.toast = nil } }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }
}
