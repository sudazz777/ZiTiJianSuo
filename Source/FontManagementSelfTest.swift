import Foundation
import CoreText

enum FontManagementSelfTest {
    @MainActor static func run() {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { fputs("FAIL: \(label)\n", stderr); exit(1) }
            checks += 1; print("PASS: \(label)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FontManager-Test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ url: URL) -> LocalFontFile { LocalFontFile(url: url, families: ["Test font"], faceCount: 1, unavailableReason: nil) }
        func available() -> Set<String> { Set(CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? []) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = FontTrashStore(roots: [root])
            check(store.unavailableReason(URL(fileURLWithPath: "/System/Library/Fonts/SFNS.ttf")) != nil, "system fonts are protected")
            check(store.unavailableReason(URL(fileURLWithPath: "/Library/Apple/System/Library/Fonts/Example.ttf")) != nil, "Apple shared system fonts are protected")
            check(store.unavailableReason(URL(string: "https://example.com/font.ttf")!) != nil, "remote URLs cannot be trashed")
            let outside = root.deletingLastPathComponent().appendingPathComponent("outside.ttf")
            check(store.unavailableReason(outside) != nil, "unapproved directories cannot be deleted")
            let sample = root.appendingPathComponent("样例 字体.ttf")
            try Data("invalid font".utf8).write(to: sample)
            check(store.unavailableReason(sample) == nil, "regular files in approved font folders can be selected")
            let alias = root.appendingPathComponent("alias.ttf")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sample)
            check(store.unavailableReason(alias) != nil, "symbolic links cannot be deleted through font management")
            let directory = root.appendingPathComponent("directory.ttf")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            check(store.unavailableReason(directory) != nil, "directories cannot be selected as font files")
            let invalid = store.trash(try store.selection(file(sample)))
            check(!invalid.success && FileManager.default.fileExists(atPath: sample.path), "invalid font data is retained")
            let stale = try store.selection(file(sample))
            try Data("changed font data".utf8).write(to: sample)
            let changed = store.trash(stale)
            check(!changed.success && FileManager.default.fileExists(atPath: sample.path), "file changes after selection cancel deletion")

            let faces = [
                FontFace(id: "Test-Regular", family: "Test", englishFamily: "Test", chineseFamily: nil, style: "Regular", sourceURL: sample),
                FontFace(id: "Test-Bold", family: "Test", englishFamily: "Test", chineseFamily: nil, style: "Bold", sourceURL: sample),
            ]
            let family = FontRecord(id: "Test", family: "Test", english: "Test", chinese: nil, style: "Regular", aliases: [], allNames: [], faces: faces)
            let catalog = LocalFontFile.catalog([family], store: store)
            check(catalog.count == 1 && catalog[0].faceCount == 2, "font styles sharing a file are grouped into one deletion item")

            guard let flag = CommandLine.arguments.firstIndex(of: "--font-management-self-test"), flag + 1 < CommandLine.arguments.count else {
                throw FontFileError.message("Provide the font fixture directory")
            }
            let fixtures = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            guard let fixture = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil).first(where: { $0.pathExtension.lowercased() == "ttf" }) else {
                throw FontFileError.message("Missing real font fixture")
            }
            let names = try FontTrashStore.names(fixture)
            check(names.isDisjoint(with: available()), "fixture font starts unregistered")
            let fontsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts")
            try FileManager.default.createDirectory(at: fontsRoot, withIntermediateDirectories: true)
            let owned = fontsRoot.appendingPathComponent("FontFinder-Management-Test-\(UUID().uuidString).ttf")
            try FileManager.default.copyItem(at: fixture, to: owned)
            var trashURL: URL?
            defer {
                var ignored: Unmanaged<CFError>?
                CTFontManagerUnregisterFontsForURL(owned as CFURL, .persistent, &ignored)
                _ = ignored?.takeRetainedValue()
                try? FileManager.default.removeItem(at: owned)
                if let url = trashURL, url.lastPathComponent.hasPrefix("FontFinder-Management-Test-") {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            var error: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(owned as CFURL, .persistent, &error)
            _ = error?.takeRetainedValue()
            check(registered && names.isSubset(of: available()), "real fixture font is installed for the current user")
            let actual = FontTrashStore()
            check(actual.unavailableReason(owned) == nil, "installed user font is eligible for Trash")
            let beforeConfirm = try actual.selection(file(owned))
            check(FileManager.default.fileExists(atPath: owned.path) && names.isSubset(of: available()), "preparing confirmation does not alter font or file")

            let failing = FontTrashStore(moveToTrash: { _ in throw FontFileError.message("Test: Trash unavailable") })
            let failed = failing.trash(beforeConfirm)
            check(!failed.success && FileManager.default.fileExists(atPath: owned.path), "failed Trash move preserves original font file")
            for _ in 0..<10 { if names.isSubset(of: available()) { break }; Thread.sleep(forTimeInterval: 0.1) }
            check(names.isSubset(of: available()), "failed Trash move restores font registration")

            let result = actual.trash(try actual.selection(file(owned)))
            trashURL = result.trashURL
            check(result.success, "real font moves to the macOS Trash")
            check(!FileManager.default.fileExists(atPath: owned.path), "original font is removed from Library/Fonts")
            check(result.trashURL.map { FileManager.default.fileExists(atPath: $0.path) } == true, "trashed font still exists and is recoverable")
            check(result.trashURL.map { (try? Data(contentsOf: $0)) == (try? Data(contentsOf: fixture)) } == true, "Trash preserves exact font contents")
            print("SUCCESS: \(checks) font management checks passed")
        } catch { fputs("FAIL: unexpected font management error: \(error)\n", stderr); exit(1) }
    }
}
