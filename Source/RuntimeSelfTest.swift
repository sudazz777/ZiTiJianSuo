import AppKit
import Foundation

enum RuntimeSelfTest {
    @MainActor static func run() {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { fputs("FAIL: \(label)\n", stderr); exit(1) }
            checks += 1; print("PASS: \(label)")
        }
        let suite = "FontFinder.RuntimeTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        let records = (0..<480).map { index in
            FontRecord(id: "runtime-\(index)", family: "Font \(index)", english: "Font \(index)",
                       chinese: index % 3 == 0 ? "样例字体\(index)" : nil, style: "Regular",
                       aliases: ["测试\(index)"], allNames: ["Font \(index)", "Font \(index)"], supportsChinese: index % 3 == 0)
        }
        model.fonts = records
        model.loading = false
        model.custom = [records[0].id: CustomNames(chinese: "我的正文", english: "Headline"), records[7].id: CustomNames(chinese: "阿体", english: "Alpha")]
        model.favorites = Set(stride(from: 0, to: records.count, by: 7).map { records[$0].id })
        model.recent = [records[80].id, records[7].id, records[0].id]

        // Retain the previous algorithm as a reference for both correctness and a same-process benchmark.
        func reference(_ query: String) -> [FontRecord] {
            let byID = Dictionary(uniqueKeysWithValues: model.fonts.map { ($0.id, $0) })
            var source = model.section == .recent ? model.recent.compactMap { byID[$0] } : model.fonts
            if model.section == .favorites { source = source.filter { model.favorites.contains($0.id) } }
            if model.section == .chinese { source = source.filter(\.supportsChinese) }
            source = source.filter { font in
                let key = FontNames.normalized(query)
                guard !key.isEmpty else { return true }
                let names = model.custom[font.id]
                let extra = [names?.chinese ?? "", names?.english ?? ""].flatMap {
                    [FontNames.normalized($0), FontNames.normalized(FontNames.pinyin($0)), FontNames.initials($0)]
                }
                return (font.searchIndex + extra).contains { $0.contains(key) }
            }
            guard model.sortOrder != .defaultOrder else { return source }
            let pinyin = model.sortOrder == .pinyinAZ || model.sortOrder == .pinyinZA
            let descending = model.sortOrder == .englishZA || model.sortOrder == .pinyinZA
            let ranks = Dictionary(uniqueKeysWithValues: model.recent.enumerated().map { ($0.element, $0.offset) })
            let keyed = source.map { font -> (FontRecord, String) in
                let name = pinyin ? (model.chineseName(font) ?? model.englishName(font)) : model.englishName(font)
                return (font, FontNames.normalized(FontNames.hasHan(name) ? FontNames.pinyin(name) : name))
            }
            return keyed.sorted { a, b in
                if model.sortOrder == .recentFirst {
                    let ra = ranks[a.0.id] ?? Int.max, rb = ranks[b.0.id] ?? Int.max
                    if ra != rb { return ra < rb }
                }
                let comparison = a.1.compare(b.1, options: [.numeric, .caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                if comparison == .orderedSame { return descending ? a.0.id > b.0.id : a.0.id < b.0.id }
                return descending ? comparison == .orderedDescending : comparison == .orderedAscending
            }.map(\.0)
        }

        let terms = ["思源黑体", "Source Han Sans", "思源黑体", "Ａｌｐｈａ", "Álpha Font", "", "Test Regular"]
        let originalIndex = Set(terms.flatMap { [FontNames.normalized($0), FontNames.normalized(FontNames.pinyin($0)), FontNames.initials($0)] }.filter { !$0.isEmpty })
        check(Set(FontNames.searchTerms(terms)) == originalIndex, "deduplicated indexing preserves Chinese, pinyin, initials, width and accent searches")
        let queries = ["Font", "字", "测试", "font1", "", "wode", "Headline", "no-match"]
        var comparisons = 0
        for section in [LibrarySection.all, .chinese, .favorites, .recent] {
            model.section = section
            for order in FontSortOrder.allCases {
                model.sortOrder = order
                for query in queries {
                    model.query = query
                    guard model.visible.map(\.id) == reference(query).map(\.id) else {
                        check(false, "reference agreement for \(section.rawValue)/\(order.rawValue)/\(query)"); return
                    }
                    comparisons += 1
                }
            }
        }
        check(comparisons == 192, "cached results match the previous implementation in 192 section, sorting and search combinations")
        model.section = .all; model.query = ""; model.sortOrder = .englishAZ
        let replacement = FontRecord(id: records[1].id, family: "New", english: "000 New", chinese: "新字体", style: "Regular", aliases: [], allNames: [])
        model.fonts = [replacement] + Array(records.dropFirst(2))
        model.filter()
        check(model.visible.map(\.id) == reference("").map(\.id) && model.visible.first?.id == replacement.id, "catalog replacement invalidates sort and font lookup caches")
        model.custom[replacement.id] = CustomNames(chinese: "新别名", english: "ZZZ Last")
        model.filter()
        check(model.visible.map(\.id) == reference("").map(\.id), "legacy name changes invalidate cached sort keys")
        model.query = "xinbieming"
        check(model.visible.map(\.id) == [replacement.id], "legacy name index refreshes when existing metadata changes")
        model.custom.removeValue(forKey: replacement.id); model.filter()
        check(model.visible.isEmpty, "removed legacy names no longer match a cached search")
        model.query = ""; model.sortOrder = .recentFirst
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let copied = records[9]
        check(model.copy(copied.english, font: copied, label: "英文名", pasteboard: pasteboard) && model.visible.first?.id == copied.id,
              "copying invalidates recent-first ordering immediately")
        model.recent = ["missing-font", records[5].id, records[2].id]
        model.section = .recent; model.sortOrder = .defaultOrder
        check(model.visible.map(\.id) == [records[5].id, records[2].id], "recent default order preserves history while excluding missing fonts")

        model.fonts = records; model.section = .all; model.query = ""; model.sortOrder = .pinyinAZ
        let iterations = 12
        var referenceSink = 0, optimizedSink = 0
        let referenceStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations { for query in queries {
            let found = reference(query)
            referenceSink &+= found.count + (found.first?.id.count ?? 0)
        } }
        let referenceMS = (ProcessInfo.processInfo.systemUptime - referenceStart) * 1000
        let optimizedStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations { for query in queries {
            model.query = query
            optimizedSink &+= model.visible.count + (model.visible.first?.id.count ?? 0)
        } }
        let optimizedMS = (ProcessInfo.processInfo.systemUptime - optimizedStart) * 1000
        check(referenceSink == optimizedSink, "performance measurements consume the same search results")
        print(String(format: "PERF: 480 fonts / 96 pinyin-sorted queries; reference %.2f ms; cached %.2f ms; ratio %.2fx", referenceMS, optimizedMS, referenceMS / max(optimizedMS, 0.001)))
        print("SUCCESS: \(checks) runtime checks passed")
    }
}
