import AppKit
import Foundation
import SwiftUI

private final class SidebarLoadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: Int] = [:]
    private var mainThread = false
    private let gates = ["old": DispatchSemaphore(value: 0), "new": DispatchSemaphore(value: 0)]
    func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return calls[key] ?? 0 }
    var ranOnMain: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
    func release(_ key: String) { gates[key]?.signal() }
    func read(_ fonts: [FontRecord]) -> FontManagementSnapshot {
        let key = fonts.first?.id ?? "old"
        lock.lock(); calls[key, default: 0] += 1; mainThread = mainThread || Thread.isMainThread; lock.unlock()
        _ = gates[key]?.wait(timeout: .now() + 5)
        return FontManagementSnapshot(files: [], families: fonts.map { LocalFontFamily(font: $0, files: [], unavailableReason: "测试目录") })
    }
}

enum SidebarSelfTest {
    @MainActor static func run() async {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { fputs("FAIL: \(label)\n", stderr); exit(1) }
            checks += 1; print("PASS: \(label)")
        }
        func waitUntil(_ predicate: () -> Bool) async -> Bool {
            for _ in 0..<400 {
                if predicate() { return true }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return predicate()
        }
        func record(_ id: String) -> FontRecord {
            FontRecord(id: id, family: id, english: id, chinese: nil, style: "Regular", aliases: [], allNames: [])
        }
        let suite = "FontFinder.SidebarTest.\(UUID().uuidString)"
        let modelDefaults = UserDefaults(suiteName: suite)!
        defer { modelDefaults.removePersistentDomain(forName: suite) }
        let probe = SidebarLoadProbe()
        let manager = FontManagementModel(catalogLoader: probe.read)
        let old = record("old"), new = record("new")
        manager.prepare([old], revision: 1)
        check(manager.isRefreshing && manager.families.isEmpty, "sidebar preparation returns before file information has been read")
        let started = await waitUntil { probe.count("old") == 1 }
        check(started && !probe.ranOnMain, "management file information is read off the main thread")
        let model = AppModel(defaults: modelDefaults)
        model.fonts = [old, new]; model.loading = false
        for _ in 0..<100 { manager.prepare([old], revision: 1); model.section = .favorites; model.section = .all }
        check(probe.count("old") == 1 && manager.isRefreshing && model.section == .all,
              "repeated sidebar switches remain responsive and do not duplicate an in-flight read")
        manager.prepare([new], revision: 2)
        let replacementStarted = await waitUntil { probe.count("new") == 1 }
        check(replacementStarted, "a newer catalog can replace an older request without waiting for its file read")
        probe.release("new")
        let latestReady = await waitUntil { manager.loadedRevision == 2 && !manager.isRefreshing }
        check(latestReady && manager.families.map(\.id) == [new.id], "the newest catalog becomes visible when its background read finishes")
        probe.release("old")
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(manager.families.map(\.id) == [new.id] && manager.loadedRevision == 2, "a late obsolete result cannot replace the current catalog")
        for _ in 0..<100 { manager.prepare([new], revision: 2) }
        check(probe.count("new") == 1 && !manager.isRefreshing, "returning to a loaded sidebar category reuses its cached file information")
        manager.prepare([new], revision: 2, force: true)
        let manualStarted = await waitUntil { probe.count("new") == 2 }
        check(manualStarted, "an explicit refresh can rebuild file information")
        probe.release("new")
        _ = await waitUntil { !manager.isRefreshing }

        let scanProbe = SidebarLoadProbe()
        let scanned = AppModel(defaults: modelDefaults, catalogProvider: { _ = scanProbe.read([old]); return [old, new] })
        scanned.reload(); scanned.reload()
        _ = await waitUntil { scanProbe.count("old") == 1 }
        scanProbe.release("old")
        let loaded = await waitUntil { !scanned.loading }
        let revision = scanned.catalogRevision
        for _ in 0..<20 { for section in LibrarySection.allCases { scanned.section = section } }
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(loaded && scanProbe.count("old") == 1 && scanned.catalogRevision == revision,
              "startup reads fonts once and subsequent category switches never scan the font registry")
        scanned.reload(); _ = await waitUntil { scanProbe.count("old") == 2 }; scanProbe.release("old")
        let refreshed = await waitUntil { !scanned.loading }
        check(refreshed && scanned.catalogRevision == revision + 1, "only an explicit refresh performs another font registry read")

        model.fonts = [old, new]; model.favorites = [old.id]; model.section = .all; model.selection = old.id
        let stableRow = FontRow(model: model, font: old)
        model.section = .favorites
        check(stableRow == FontRow(model: model, font: old), "unchanged font cards do not need to redraw for a sidebar category change")
        model.toggleFavorite(old.id)
        check(stableRow != FontRow(model: model, font: old), "favorite and selection changes still update font cards")
        let beforePreview = FontRow(model: model, font: old, grid: true)
        model.preview = "New preview"; model.size = 32
        check(beforePreview != FontRow(model: model, font: old, grid: true), "preview text and size changes still invalidate card rendering")

        let first = FontFace(id: "Regular-File", family: "File Family", englishFamily: "File Family", chineseFamily: nil, style: "Regular", sourceURL: URL(fileURLWithPath: "/tmp/sidebar-regular.ttf"))
        let second = FontFace(id: "Bold-File", family: "File Family", englishFamily: "File Family", chineseFamily: nil, style: "Bold", sourceURL: URL(fileURLWithPath: "/tmp/sidebar-bold.ttf"))
        let family = FontRecord(id: "File Family", family: "File Family", english: "File Family", chinese: nil, style: "Regular", aliases: [], allNames: [first.id, second.id], faces: [first, second])
        model.fonts = [family]; model.section = .all; model.selectFace(second.id, for: family)
        model.removeFontFiles([second.sourceURL!.standardizedFileURL.path])
        check(model.fonts.first?.faces.map(\.id) == [first.id] && model.previewFace(model.fonts[0]).id == first.id,
              "successful font removal updates remaining styles directly without scanning")
        check(!model.fonts[0].matches(second.id), "removed styles no longer appear in the cached search index")
        model.removeFontFiles([first.sourceURL!.standardizedFileURL.path])
        check(model.fonts.isEmpty && model.visible.isEmpty && model.selection == nil, "removing the last style clears the cached family and stale selection")

        // Force actual AppKit/SwiftUI frames while cycling all sidebar sections.
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let fonts = FontRecord.installed()
        let uiModel = AppModel(defaults: modelDefaults)
        uiModel.fonts = fonts; uiModel.loading = false; uiModel.section = .all
        uiModel.favorites = Set(fonts.prefix(3).map(\.id)); uiModel.recent = Array(fonts.prefix(4).map(\.id))
        let uiManager = FontManagementModel()
        let hosting = NSHostingView(rootView: ContentView(model: uiModel, fontManager: uiManager))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 810), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        uiManager.prepare(fonts, revision: uiModel.catalogRevision)
        let prepared = await waitUntil { !uiManager.isRefreshing }
        check(prepared, "the real font catalog is ready for repeated sidebar frame rendering")
        var durations: [Double] = []
        for _ in 0..<3 { for section in LibrarySection.allCases {
            let start = ProcessInfo.processInfo.systemUptime
            uiModel.section = section
            try? await Task.sleep(nanoseconds: 5_000_000)
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { check(false, "sidebar frame allocation"); return }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        } }
        check(uiManager.loadedRevision == uiModel.catalogRevision && !uiManager.isRefreshing, "rendering repeated sidebar switches does not restart file inspection")
        print(String(format: "SIDEBAR PERF: %d real fonts / 15 rendered category switches; mean %.2f ms; max %.2f ms", fonts.count, durations.reduce(0, +) / Double(durations.count), durations.max() ?? 0))
        print("SUCCESS: \(checks) sidebar checks passed")
    }
}
