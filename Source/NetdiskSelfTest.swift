import AppKit
import CoreText
import WebKit

enum NetdiskSelfTest {
    @MainActor static func run() async {
        setbuf(stdout, nil)
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else { fputs("FAIL: \(label)\n", stderr); exit(1) }
            checks += 1; print("PASS: \(label)")
        }
        func rejects(_ label: String, _ operation: () throws -> Void) {
            do { try operation(); check(false, label) } catch { check(true, label) }
        }
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--netdisk-self-test"), flag + 1 < arguments.count else {
            fputs("Provide the test fixture directory after --netdisk-self-test\n", stderr); exit(1)
        }
        let fixtures = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FontFinder-Test-\(UUID().uuidString)")
        let jobs = FontDownloadJobs(root: root.appendingPathComponent("Jobs"))
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let share = try NetdiskShare.parse("通过网盘分享的文件：字体\n链接: https://pan.baidu.com/s/test 提取码: aB12")
            check(share.extractionCode == "aB12" && share.url.query?.contains("pwd=aB12") == true, "parses pasted share text and extraction code")
            check(try NetdiskShare.parse(NetdiskShare.initialText).extractionCode == "4n5y", "parses provided share URL")
            rejects("rejects unrelated download domains") { _ = try NetdiskShare.parse("https://pan.baidu.com.example.com/s/test") }
            rejects("rejects invalid extraction code") { _ = try NetdiskShare.parse("https://pan.baidu.com/s/test?pwd=secret-long") }
            let foreign = root.appendingPathComponent("Unrelated")
            try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
            rejects("cleanup refuses unrelated directories") { try jobs.remove(foreign) }
            check(FileManager.default.fileExists(atPath: foreign.path), "foreign directory survives refused cleanup")
            let job = try jobs.create()
            try jobs.remove(job)
            check(!FileManager.default.fileExists(atPath: job.path), "owned completed job is deleted")

            let source = fixtures.appendingPathComponent("sample.ttf")
            let names = try FontInstallEngine.names(source)
            check(!names.isEmpty, "reads actual fixture font metadata")
            check(names.isDisjoint(with: FontInstallEngine.availableNames()), "fixture font starts uninstalled")
            let engine = FontInstallEngine()
            let first = engine.install(source)
            check(first.status == "已安装", "registers font persistently for current macOS user")
            guard let installed = first.installedURL else { throw CloudError.message("Missing installed fixture") }
            defer {
                var ignored: Unmanaged<CFError>?
                CTFontManagerUnregisterFontsForURL(installed as CFURL, .persistent, &ignored)
                try? FileManager.default.removeItem(at: installed)
            }
            check(FileManager.default.fileExists(atPath: installed.path), "installed font is stored in user Library/Fonts")
            check(names.isSubset(of: FontInstallEngine.availableNames()), "macOS confirms installed PostScript names")
            check(engine.install(source).status == "已存在，已跳过", "already-installed font is skipped")
            let nestedJob = try jobs.create()
            let nested = try engine.process(fixtures.appendingPathComponent("nested.zip"), job: nestedJob)
            check(nested.success && nested.skipped == 1, "nested ZIP font is detected and deduplicated")
            try jobs.remove(nestedJob)
            check(FileManager.default.fileExists(atPath: installed.path), "download cleanup preserves installed font")
            let damagedJob = try jobs.create()
            rejects("rejects unsafe ZIP traversal") { _ = try engine.process(fixtures.appendingPathComponent("traversal.zip"), job: damagedJob) }
            check(FileManager.default.fileExists(atPath: damagedJob.path), "failed job remains available for recovery")
            let linkJob = try jobs.create()
            rejects("rejects archive symbolic links") { _ = try engine.process(fixtures.appendingPathComponent("symlink.zip"), job: linkJob) }
            let invalid = engine.install(fixtures.appendingPathComponent("invalid.ttf"))
            check(!invalid.success && invalid.installedURL == nil, "invalid fonts never report successful install")

            _ = NSApplication.shared
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
            view.loadHTMLString("<html><body><table><tr><td><input id='choose-font' type='checkbox'><span title='Test.ttf'>Test.ttf</span></td></tr></table><button onclick='window.downloadClicks=(window.downloadClicks||0)+1'>下载</button><span title='README.txt'>README.txt</span><span title='Pack.zip'>Pack.zip</span><input type='password' value='private-login-value'></body></html>", baseURL: nil)
            var loaded = false
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if (try? await view.evaluateJavaScript("document.readyState === 'complete' && document.querySelectorAll('[title]').length === 3")) as? Bool == true { loaded = true; break }
            }
            check(loaded, "WebKit loads local DOM test fixture")
            let script = NetdiskWebAutomation.script.replacingOccurrences(of: "if (location.hostname !== 'pan.baidu.com') return [];", with: "")
            _ = try await view.evaluateJavaScript(script)
            let identified = try await view.evaluateJavaScript("window.fontFinderScan()") as? [String] ?? []
            check(Set(identified) == ["Test.ttf", "Pack.zip"], "DOM scanner identifies font and ZIP names only")
            check(!identified.contains("private-login-value"), "DOM scanner does not extract login fields")
            check((try await view.evaluateJavaScript("window.downloadClicks || 0")) as? Int == 0, "scanner respects disabled automatic download")
            _ = try await view.evaluateJavaScript("window.__fontFinderAuto = true; window.fontFinderScan(); true")
            try await Task.sleep(nanoseconds: 500_000_000)
            check((try await view.evaluateJavaScript("document.querySelector('#choose-font').checked && window.downloadClicks === 1")) as? Bool == true, "automatic scanner selects font and clicks visible download button")
            _ = try await view.evaluateJavaScript("window.fontFinderScan(); true")
            try await Task.sleep(nanoseconds: 500_000_000)
            check((try await view.evaluateJavaScript("window.downloadClicks")) as? Int == 1, "scanner avoids repeating the same attempted download")
            view.stopLoading()
            print("SUCCESS: \(checks) netdisk importer checks passed")
        } catch { fputs("FAIL: unexpected importer error: \(error)\n", stderr); exit(1) }
    }
}
