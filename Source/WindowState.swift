import AppKit

@MainActor enum MainWindowState {
    static func configure(_ window: NSWindow, name: String = "FontName.main", capture: Bool = false) {
        if capture {
            window.center()
            return
        }
        if !window.setFrameUsingName(name) { window.center() }
        window.setFrameAutosaveName(name)
    }
}
