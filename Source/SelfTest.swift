import Foundation
import AppKit

enum SelfTest {
    @MainActor static func run() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
            checks += 1
            print("PASS: \(label)")
        }
        check(FontNames.entries(Data()).isEmpty, "empty font metadata is safe")
        check(FontNames.entries(Data([0, 0, 255, 255, 0, 0])).isEmpty, "truncated name table is safe")
        let text = "测试字体".data(using: .utf16BigEndian)!
        let table = Data([0, 0, 0, 1, 0, 18, 0, 3, 0, 1, 8, 4, 0, 4, 0, UInt8(text.count), 0, 0]) + text
        check(FontNames.entries(table).first?.text == "测试字体", "UTF-16 Chinese name metadata")
        check(FontNames.entries(table).first?.isChinese == true, "Chinese locale metadata recognized")
        check(FontNames.normalized(FontNames.pinyin("苹方 简体")) == "pingfangjianti", "Chinese transliteration")
        let fixture = FontRecord(id: "PingFangSC-Regular", family: "PingFang SC", english: "PingFang SC Regular", chinese: "苹方-简体 常规体", style: "Regular", aliases: ["苹方"], allNames: [], supportsChinese: true)
        for query in ["苹方", "ping fang", "píngfāng", "PINGFANG", "pf", "PingFangSC-Regular", "pingfang jianti"] {
            check(fixture.matches(query), "multilingual search: \(query)")
        }
        check(!fixture.matches("nonexistent-font"), "unmatched query excluded")
        let fonts = FontRecord.installed()
        check(!fonts.isEmpty, "reads installed fonts")
        check(Set(fonts.map(\.id)).count == fonts.count, "font identities unique")
        let ping = fonts.first { $0.family == "PingFang SC" }
        check(ping != nil, "installed PingFang family found")
        check(ping?.chinese != nil, "official Chinese name decoded from installed font")
        check(ping?.matches("苹方") == true && ping?.matches("pingfang") == true, "real Chinese and pinyin search")
        check(ping?.supportsChinese == true, "real font has Chinese glyphs")
        check(ping?.chinese == "苹方-简" && ping?.english == "PingFang SC", "real family names omit weight suffixes")
        check((ping?.faces.count ?? 0) > 1 && ping?.defaultFace.id == "PingFangSC-Regular", "real weights merge and regular is default")
        check(fonts.filter { $0.family == "Arial" }.count == 1 && (fonts.first { $0.family == "Arial" }?.faces.count ?? 0) >= 4, "real Arial weights and italics merge")
        check(fonts.flatMap(\.faces).allSatisfy { $0.sourceURL.map { FileManager.default.fileExists(atPath: $0.path) && !$0.pathComponents.contains(where: { $0.hasSuffix(".app") }) } ?? false }, "all family faces have local files outside app bundles")
        print("CATALOG: \(fonts.count) fonts, \(fonts.filter { $0.chinese != nil }.count) Chinese names")
        print("PINGFANG: \(ping?.chinese ?? "nil") / \(ping?.english ?? "nil")")
        let suite = "FontName.SelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.fonts = [fixture]
        model.loading = false
        model.filter()
        model.toggleFavorite(fixture.id)
        model.section = .favorites
        check(model.visible.count == 1, "favorites filter")
        model.query = "找不到"
        check(model.visible.isEmpty && model.selection == nil, "no stale selection when search is empty")
        model.query = ""
        model.saveNames(CustomNames(chinese: "我的标题", english: "My Headline"), for: fixture.id)
        for q in ["我的标题", "wodebiaoti", "wdbt", "My Headline"] {
            model.query = q
            check(model.visible.count == 1, "custom alias search: \(q)")
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for (label, value) in [("中文名", model.chineseName(fixture)!), ("英文名", model.englishName(fixture))] {
            check(model.copy(value, font: fixture, label: label, pasteboard: pasteboard), "copy succeeds: \(label)")
            check(pasteboard.string(forType: .string) == value, "clipboard content: \(label)")
        }
        check(model.recent == [fixture.id], "recent copies deduplicate")
        model.query = ""; model.section = .recent
        check(model.visible.map(\.id) == [fixture.id], "recent copies filter")
        let restored = AppModel(defaults: defaults)
        check(restored.favorites.contains(fixture.id) && restored.recent == [fixture.id] && restored.custom[fixture.id]?.chinese == "我的标题", "preferences persist across launches")
        model.saveNames(CustomNames(), for: fixture.id)
        check(model.chineseName(fixture) == fixture.chinese, "restore official name")

        func record(_ id: String, _ english: String, _ chinese: String?) -> FontRecord {
            FontRecord(id: id, family: english, english: english, chinese: chinese, style: "Regular", aliases: [], allNames: [])
        }
        let a = record("A", "alpha 2", "宋体")
        let b = record("B", "Beta", "阿体")
        let c = record("C", "Alpha 10", "楷体")
        let d = record("D", "alpha 2", nil)
        model.fonts = [c, b, d, a]; model.section = .all; model.query = ""
        func ids() -> [String] { model.visible.map(\.id) }
        model.sortOrder = .englishAZ
        check(ids() == ["A", "D", "C", "B"], "A-Z is case insensitive with natural numbers and stable ties")
        model.selection = a.id
        model.sortOrder = .englishZA
        check(ids() == ["B", "C", "D", "A"], "Z-A reverse ordering")
        check(model.selection == a.id, "sorting preserves the selected font")
        model.sortOrder = .pinyinAZ
        check(ids() == ["D", "B", "C", "A"], "Chinese pinyin A-Z with English fallback")
        model.sortOrder = .pinyinZA
        check(ids() == ["A", "C", "B", "D"], "Chinese pinyin Z-A")
        model.sortOrder = .defaultOrder
        check(ids() == ["C", "B", "D", "A"], "default ordering preserves catalog order")
        model.recent = [c.id, a.id]; model.sortOrder = .recentFirst
        check(ids() == ["C", "A", "D", "B"], "recent-first sorts uncopied fonts alphabetically")
        check(model.copy(b.english, font: b, label: "英文名", pasteboard: pasteboard), "copy in recent-first mode succeeds")
        check(ids() == ["B", "C", "A", "D"], "new copy immediately moves to top in recent-first mode")
        model.sortOrder = .englishAZ; model.query = "alpha"
        check(ids() == ["A", "D", "C"], "search results retain chosen sorting")
        model.query = ""; model.favorites = [a.id, c.id]; model.section = .favorites
        check(ids() == ["A", "C"], "favorites retain chosen sorting")
        model.section = .all
        model.saveNames(CustomNames(chinese: "", english: "Aardvark"), for: b.id)
        check(ids() == ["B", "A", "D", "C"], "editing an alias updates sort position")
        model.sortOrder = .pinyinZA
        let sortRestored = AppModel(defaults: defaults)
        check(sortRestored.sortOrder == .pinyinZA, "sort choice persists across launches")

        let localURL = URL(fileURLWithPath: "/Library/Fonts/Probe.ttf")
        func accepted(enabled: Bool = true, scope: Int = 2, priority: Int = 30000, exists: Bool = true, url: URL = localURL, name: String = "Probe") -> Bool {
            FontBookSource.accepts(name: name, family: "Probe", url: url, enabled: enabled, scope: scope, priority: priority, exists: exists)
        }
        check(accepted(), "installed enabled computer font accepted")
        check(!accepted(enabled: false), "disabled font excluded")
        check(!accepted(scope: 1) && !accepted(scope: 3), "process and session fonts excluded")
        check(!accepted(priority: 50000), "dynamic font excluded")
        check(!accepted(exists: false), "missing or undownloaded file excluded")
        check(!accepted(url: URL(fileURLWithPath: "/Applications/Example.app/Contents/Fonts/Probe.ttf")), "app bundled font excluded")
        check(!accepted(name: ".HiddenFont"), "hidden system font excluded")
        check(accepted(priority: 60000, url: URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_Font7/Example.asset/AssetData/Probe.ttf")), "installed system font download retained")

        let regular = FontFace(id: "Probe-Regular", family: "Probe SC", englishFamily: "Probe SC", chineseFamily: "样例-简", style: "Regular", weight: 0, supportsChinese: true, names: ["Probe SC Regular"])
        let light = FontFace(id: "Probe-Light", family: "Probe SC", englishFamily: "Probe SC", chineseFamily: "样例-简", style: "Light", weight: -0.4, supportsChinese: true, names: ["Probe SC Light"])
        let bold = FontFace(id: "Probe-Bold", family: "Probe SC", englishFamily: "Probe SC", chineseFamily: "样例-简", style: "Bold", weight: 0.4, supportsChinese: true, names: ["Probe SC Bold"])
        let traditional = FontFace(id: "ProbeTC-Regular", family: "Probe TC", englishFamily: "Probe TC", chineseFamily: "样例-繁", style: "Regular")
        let condensed = FontFace(id: "ProbeCondensed-Regular", family: "Probe Condensed", englishFamily: "Probe Condensed", chineseFamily: "样例窄体", style: "Regular")
        let merged = FontRecord.merged([light, bold, regular, regular, traditional, condensed])
        check(merged.count == 3, "weights merge but script and width families stay distinct")
        let group = merged.first { $0.family == "Probe SC" }!
        check(group.faces.count == 3, "duplicate face records are removed")
        check(group.english == "Probe SC" && group.chinese == "样例-简", "merged family name has no style suffix")
        check(group.defaultFace.id == regular.id, "regular selected independent of enumeration order")
        check(group.matches("Probe SC Bold") && group.matches("yangli"), "family search covers individual weights and pinyin")

        model.query = ""; model.section = .all
        model.favorites = [light.id, bold.id]
        model.recent = [bold.id, traditional.id, light.id]
        model.custom = [regular.id: CustomNames(chinese: "我的家族", english: "My Family")]
        model.selection = bold.id
        model.applyCatalog(merged)
        check(model.favorites == [group.id], "legacy weight favorites migrate to one family")
        check(model.recent == [group.id, merged.first { $0.family == "Probe TC" }!.id], "legacy recents migrate and deduplicate in order")
        check(model.custom[group.id]?.chinese == "我的家族" && model.custom[regular.id] == nil, "legacy aliases migrate to family")
        check(model.selection == group.id && model.previewFace(group).id == bold.id, "migration preserves selection and preview style")
        model.selectFace(light.id, for: group)
        check(model.previewFace(group).id == light.id && model.englishName(group) == "My Family", "preview weight changes without changing copied family name")
        model.selectFace("NotInFamily", for: group)
        check(model.previewFace(group).id == light.id, "invalid style selection ignored")
        model.saveNames(CustomNames(), for: group.id)
        model.applyCatalog(merged)
        check(model.chineseName(group) == "样例-简", "restored names stay restored after catalog refresh")
        model.sortOrder = .englishAZ; model.query = "Probe SC Bold"
        check(model.visible.map(\.id) == [group.id], "searching a weight yields one merged family row")
        let familyRestored = AppModel(defaults: defaults)
        check(familyRestored.favorites == [group.id] && familyRestored.recent.first == group.id, "migrated favorites and recents persist")
        check(model.copy(model.englishName(group), font: group, label: "英文名", pasteboard: pasteboard) && pasteboard.string(forType: .string) == "Probe SC", "clipboard contains family name without weight")
        print("SUCCESS: \(checks) checks passed")
    }
}
