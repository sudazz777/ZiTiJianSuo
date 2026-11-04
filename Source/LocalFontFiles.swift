import Foundation
import CoreText

enum FontFileError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

struct LocalFontFile: Identifiable {
    let url: URL
    let families: [String]
    let faceCount: Int
    let unavailableReason: String?
    var id: String { url.standardizedFileURL.path }
    var title: String { families.joined(separator: " / ") }
    var canTrash: Bool { unavailableReason == nil }

    static func catalog(_ fonts: [FontRecord], store: FontTrashStore = FontTrashStore()) -> [Self] {
        var files: [String: (URL, Set<String>, Set<String>)] = [:]
        for font in fonts {
            for face in font.faces {
                guard let url = face.sourceURL, url.isFileURL else { continue }
                let key = url.standardizedFileURL.path
                var entry = files[key] ?? (url, [], [])
                entry.1.insert(font.chinese ?? font.english); entry.2.insert(face.id)
                files[key] = entry
            }
        }
        return files.values.map {
            Self(url: $0.0, families: $0.1.sorted(), faceCount: $0.2.count, unavailableReason: store.unavailableReason($0.0))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

struct LocalFontFamily: Identifiable {
    let font: FontRecord
    let files: [LocalFontFile]
    let unavailableReason: String?
    var id: String { font.id }
    var fileIDs: Set<String> { Set(files.map(\.id)) }
    var canTrash: Bool { unavailableReason == nil }

    static func catalog(_ fonts: [FontRecord], files: [LocalFontFile]) -> [Self] {
        let indexed = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        return fonts.map { font in
            let paths = Set(font.faces.compactMap { $0.sourceURL?.standardizedFileURL.path })
            let members = paths.sorted().compactMap { indexed[$0] }
            let missing = font.faces.contains { $0.sourceURL == nil } || members.isEmpty || members.count != paths.count
            return Self(font: font, files: members,
                        unavailableReason: missing ? "字体文件不可用" : members.compactMap(\.unavailableReason).first)
        }.sorted { $0.font.english.localizedStandardCompare($1.font.english) == .orderedAscending }
    }

    static func selectedFiles(in families: [Self], selected: Set<String>) -> [LocalFontFile] {
        let chosen = families.filter { selected.contains($0.id) }.flatMap(\.files)
        return Dictionary(grouping: chosen, by: \.id).values.compactMap(\.first).sorted { $0.id < $1.id }
    }
}

struct FontFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modified: Date
    static func read(_ url: URL) throws -> Self {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = values[.systemNumber] as? NSNumber, let inode = values[.systemFileNumber] as? NSNumber,
              let size = values[.size] as? NSNumber, let modified = values[.modificationDate] as? Date else {
            throw FontFileError.message("无法确认字体文件状态，未删除。")
        }
        return Self(device: device.uint64Value, inode: inode.uint64Value, size: size.uint64Value, modified: modified)
    }
}

struct FontTrashSelection {
    let file: LocalFontFile
    let identity: FontFileIdentity
}

struct FontTrashResult: Identifiable {
    let id = UUID()
    let file: LocalFontFile
    let trashURL: URL?
    let message: String
    let success: Bool
}

struct FontTrashStore {
    let roots: [URL]
    let moveToTrash: (URL) throws -> URL?
    init(roots: [URL]? = nil, moveToTrash: ((URL) throws -> URL?)? = nil) {
        self.roots = roots ?? [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts"), URL(fileURLWithPath: "/Library/Fonts")]
        self.moveToTrash = moveToTrash ?? { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            return result as URL?
        }
    }
    func unavailableReason(_ url: URL) -> String? {
        guard url.isFileURL else { return "不是本地字体文件" }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        func protected(_ path: String) -> Bool {
            (path == "/System" || (path.hasPrefix("/System/") && !path.hasPrefix("/System/Volumes/Data/"))) || path.hasPrefix("/Library/Apple/") || path.hasPrefix("/System/Volumes/Data/Library/Apple/")
        }
        if protected(url.standardizedFileURL.path) || protected(resolved) { return "系统字体受保护" }
        guard ["ttf", "otf", "ttc", "otc", "dfont"].contains(url.pathExtension.lowercased()) else { return "此格式请在访达中管理" }
        guard roots.contains(where: { resolved.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/") }) else {
            return "此位置请在访达中管理"
        }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return "文件不可用或为链接" }
        guard FileManager.default.isDeletableFile(atPath: url.path),
              FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else { return "没有移到废纸篓的权限" }
        return nil
    }
    func selection(_ file: LocalFontFile) throws -> FontTrashSelection {
        if let reason = unavailableReason(file.url) { throw FontFileError.message(reason) }
        return FontTrashSelection(file: file, identity: try FontFileIdentity.read(file.url))
    }
    static func names(_ url: URL) throws -> Set<String> {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], !descriptors.isEmpty else {
            throw FontFileError.message("文件不是可读取的字体，未移动。")
        }
        return Set(descriptors.map { CTFontCopyPostScriptName(CTFontCreateWithFontDescriptor($0, 12, nil)) as String })
    }
    private func verify(_ selection: FontTrashSelection) throws {
        if let reason = unavailableReason(selection.file.url) { throw FontFileError.message(reason) }
        guard try FontFileIdentity.read(selection.file.url) == selection.identity else {
            throw FontFileError.message("字体文件已变化，请刷新后重新选择。")
        }
    }
    func trash(_ selection: FontTrashSelection) -> FontTrashResult {
        let file = selection.file
        var unregistered = false
        var inUse = false
        do {
            try verify(selection)
            _ = try Self.names(file.url)
            var error: Unmanaged<CFError>?
            unregistered = CTFontManagerUnregisterFontsForURL(file.url as CFURL, .persistent, &error)
            let failure = error?.takeRetainedValue()
            if !unregistered, let failure {
                let code = CFErrorGetCode(failure)
                inUse = code == Int(CTFontManagerError.inUse.rawValue)
                guard inUse || code == Int(CTFontManagerError.notRegistered.rawValue) else {
                    throw FontFileError.message("macOS 未允许停用此字体：\((failure as Error).localizedDescription)")
                }
            } else if !unregistered {
                throw FontFileError.message("macOS 未确认停用字体，文件未移动。")
            }
            try verify(selection)
            let destination = try moveToTrash(file.url)
            return FontTrashResult(file: file, trashURL: destination,
                                   message: inUse ? "已移到废纸篓，正在使用它的软件需重新打开" : "已移到废纸篓", success: true)
        } catch {
            var note = ""
            if unregistered, (try? FontFileIdentity.read(file.url)) == selection.identity {
                var restoreError: Unmanaged<CFError>?
                let restored = CTFontManagerRegisterFontsForURL(file.url as CFURL, .persistent, &restoreError)
                _ = restoreError?.takeRetainedValue()
                if !restored { note = "；文件已保留，如字体未显示，请在字体册中重新启用" }
            }
            return FontTrashResult(file: file, trashURL: nil, message: error.localizedDescription + note, success: false)
        }
    }
}
