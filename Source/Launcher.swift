import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let captureSuite: String? = CommandLine.arguments.contains("--capture") ? "FontFinder.Capture.\(UUID().uuidString)" : nil
    let model = AppModel(defaults: AppDelegate.captureSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard)
    let updater = AppUpdater()
    private var updateMenuItem: NSMenuItem?
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        makeMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 810),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "字体检索 · Font Finder"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 1060, height: 670)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model).padding(.top, 28).background(Palette.canvas).ignoresSafeArea(.container, edges: .top))
        MainWindowState.configure(window, capture: CommandLine.arguments.contains("--capture"))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.reload()
        if CommandLine.arguments.contains("--capture-management") { model.section = .management }
        let recovery = CommandLine.arguments.firstIndex(of: "--update-install-failed").flatMap { index in
            index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
        }
        if !CommandLine.arguments.contains("--capture") {
            updater.canInstall = { [weak self] in self?.model.fontOperationInProgress == false }
            updater.onCheckingChanged = { [weak self] checking in
                self?.updateMenuItem?.title = checking ? (self?.updater.isUpdating == true ? "正在更新…" : "正在检查更新…") : "检查更新…"
                self?.updateMenuItem?.isEnabled = !checking
            }
            if recovery == nil { updater.start() }
        }
        if let recovery {
            let alert = NSAlert(); alert.messageText = "自动更新未完成"
            alert.informativeText = "\(recovery)\n\n已尝试恢复原版。可通过「检查更新」重试，或从 GitHub 下载 DMG 手动安装。"
            alert.runModal()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--capture"), index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            waitThenCapture(path, attempts: 40)
        }
    }

    private func waitThenCapture(_ path: String, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if self.model.loading && attempts > 0 { self.waitThenCapture(path, attempts: attempts - 1); return }
            guard !self.model.loading else { fputs("Font loading timed out\n", stderr); exit(1) }
            if let view = self.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.layoutSubtreeIfNeeded()
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    do { try data.write(to: URL(fileURLWithPath: path)); print("Saved preview: \(path); fonts: \(self.model.fonts.count)") }
                    catch { fputs("Capture failed: \(error)\n", stderr); exit(1) }
                }
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.fontOperationInProgress, !updater.isUpdating || updater.restarting else {
            let alert = NSAlert(); alert.messageText = "请先完成当前操作"
            alert.informativeText = model.fontOperationInProgress ? "字体文件正在处理中，完成后即可退出。" : "正在准备更新。要退出，请先在更新窗口取消更新。"
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !CommandLine.arguments.contains("--capture") { updater.didBecomeActive() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updater.stop()
        if let suite = Self.captureSuite { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    private func makeMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(item("关于字体检索", #selector(about), ""))
        let updateItem = item("检查更新…", #selector(checkUpdates), "")
        updateMenuItem = updateItem; appMenu.addItem(updateItem)
        appMenu.addItem(.separator())
        appMenu.addItem(item("隐藏字体检索", #selector(NSApplication.hide(_:)), "h", target: NSApp))
        appMenu.addItem(.separator())
        appMenu.addItem(item("退出字体检索", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        bar.addItem(appItem)

        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            let mi = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
            editMenu.addItem(mi)
        }
        edit.submenu = editMenu; bar.addItem(edit)

        let fonts = NSMenuItem(title: "字体", action: nil, keyEquivalent: "")
        let fontMenu = NSMenu(title: "字体")
        fontMenu.addItem(item("搜索字体", #selector(focusSearch), "f"))
        fontMenu.addItem(item("刷新字体", #selector(refresh), "r"))
        fontMenu.addItem(item("收藏 / 取消收藏", #selector(favorite), "d"))
        fontMenu.addItem(.separator())
        for (i, title) in ["复制中文名", "复制英文名"].enumerated() {
            let mi = item(title, #selector(copyName(_:)), "\(i + 1)"); mi.tag = i; fontMenu.addItem(mi)
        }
        fonts.submenu = fontMenu; bar.addItem(fonts)

        let winItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let winMenu = NSMenu(title: "窗口")
        winMenu.addItem(item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil))
        winMenu.addItem(item("缩放", #selector(NSWindow.performZoom(_:)), "", target: nil))
        winItem.submenu = winMenu; bar.addItem(winItem)
        NSApp.windowsMenu = winMenu
        NSApp.mainMenu = bar
    }

    private func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        if action == #selector(NSWindow.performMiniaturize(_:)) || action == #selector(NSWindow.performZoom(_:)) { item.target = nil }
        return item
    }
    @objc func focusSearch() { NotificationCenter.default.post(name: .focusFontSearch, object: nil) }
    @objc func refresh() { model.reload() }
    @objc func checkUpdates() { updater.check(manual: true) }
    @objc func favorite() { if model.section != .management, let f = model.selected { model.toggleFavorite(f.id) } }
    @objc func copyName(_ sender: NSMenuItem) {
        guard model.section != .management, let font = model.selected else { return }
        switch sender.tag {
        case 0:
            if let c = model.chineseName(font) { model.copy(c, font: font, label: "中文名") }
            else { model.notify("该字体没有中文名") }
        case 1: model.copy(model.englishName(font), font: font, label: "英文名")
        default: break
        }
    }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "字体检索 Font Finder", .applicationVersion: "1.20",
            .credits: NSAttributedString(string: "好字体，随手就能找到。\n本机字体检索 · 离线使用\n中文、拼音、英文搜索\nApple 芯片与 Intel 通用")
        ])
    }
}

@main enum Launcher {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--update-relaunch-probe"), index + 1 < CommandLine.arguments.count {
            let report = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
            let root = report.deletingLastPathComponent().resolvingSymlinksInPath()
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            guard root.path.hasPrefix(temporary + "/"), root.lastPathComponent.hasPrefix("FontFinder-Install-Test-"),
                  report.lastPathComponent.hasPrefix("relaunch-"), report.pathExtension == "json",
                  !FileManager.default.fileExists(atPath: report.path) else { exit(2) }
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            DispatchQueue.main.async {
                let result = ["bundlePath": Bundle.main.bundleURL.path, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""]
                do { try JSONSerialization.data(withJSONObject: result).write(to: report, options: .atomic) }
                catch { exit(2) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { app.terminate(nil) }
            app.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--install-update-helper"), index + 1 < CommandLine.arguments.count {
            exit(AppUpdateInstallation.runHelper(jobURL: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
        }
        if CommandLine.arguments.contains("--installation-self-test") { UpdateInstallationSelfTest.run(); return }
        if CommandLine.arguments.contains("--focus-self-test") { TextFocusSelfTest.run(); return }
        if CommandLine.arguments.contains("--self-test") { SelfTest.run(); return }
        if CommandLine.arguments.contains("--runtime-self-test") { RuntimeSelfTest.run(); return }
        if CommandLine.arguments.contains("--font-management-self-test") { FontManagementSelfTest.run(); return }
        if CommandLine.arguments.contains("--update-self-test") {
            Task { @MainActor in await UpdateSelfTest.run(); exit(0) }
            RunLoop.main.run(); return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
