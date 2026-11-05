import AppKit
import SwiftUI

extension Notification.Name {
    static let dismissTextFocus = Notification.Name("FontName.dismissTextFocus")
}

@MainActor enum TextFocusClickPolicy {
    static func isEditableText(_ view: NSView?) -> Bool {
        var ancestor = view
        while let current = ancestor {
            if let field = current as? NSTextField, field.isEditable && field.isEnabled { return true }
            if let text = current as? NSTextView, text.isEditable { return true }
            ancestor = current.superview
        }
        return false
    }

    static func dismissIfNeeded(for event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .leftMouseDown, event.window === window,
              let editor = window.firstResponder as? NSView, isEditableText(editor),
              let content = window.contentView else { return false }
        let local = content.convert(event.locationInWindow, from: nil)
        guard content.bounds.contains(local) else { return false }
        // NSView.hitTest expects its argument in the receiver's superview coordinates.
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard !isEditableText(content.hitTest(point)) else { return false }
        return window.makeFirstResponder(nil)
    }
}

/// An invisible window observer. It never takes part in hit testing and never
/// consumes the mouse event, so the target control still receives its first click.
struct DismissTextFocusOnClick: NSViewRepresentable {
    let onDismiss: () -> Void
    func makeNSView(context: Context) -> TextFocusMonitorView {
        let view = TextFocusMonitorView()
        view.onDismiss = onDismiss
        return view
    }
    func updateNSView(_ view: TextFocusMonitorView, context: Context) { view.onDismiss = onDismiss }
    static func dismantleNSView(_ view: TextFocusMonitorView, coordinator: ()) { view.stopMonitoring() }
}

@MainActor final class TextFocusMonitorView: NSView {
    var onDismiss: () -> Void = {}
    private var monitor: Any?
    var isMonitoring: Bool { monitor != nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.process(event) ?? event
        }
    }
    func process(_ event: NSEvent) -> NSEvent {
        if let window, TextFocusClickPolicy.dismissIfNeeded(for: event, in: window) {
            onDismiss()
            NotificationCenter.default.post(name: .dismissTextFocus, object: window)
        }
        return event
    }
    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

enum TextFocusSelfTest {
    @MainActor static func run() {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { fputs("FAIL: \(label)\n", stderr); exit(1) }
            checks += 1; print("PASS: \(label)")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let frameName = "FontName.FrameTest.\(UUID().uuidString)"
        let savedWindow = NSWindow(contentRect: NSRect(x: 60, y: 80, width: 500, height: 260), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let restoredWindow = NSWindow(contentRect: NSRect(x: 60, y: 80, width: 500, height: 260), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let captureWindow = NSWindow(contentRect: NSRect(x: 60, y: 80, width: 500, height: 260), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        for window in [savedWindow, restoredWindow, captureWindow] { window.isReleasedWhenClosed = false }
        defer {
            restoredWindow.setFrameAutosaveName("")
            savedWindow.close(); restoredWindow.close(); captureWindow.close()
            NSWindow.removeFrame(usingName: frameName)
        }
        savedWindow.setFrame(NSRect(x: 60, y: 80, width: 760, height: 500), display: false)
        savedWindow.saveFrame(usingName: frameName)
        MainWindowState.configure(restoredWindow, name: frameName)
        check(restoredWindow.frame.size == savedWindow.frame.size, "a new application window restores the previously saved dimensions")
        let captureSize = captureWindow.frame.size
        MainWindowState.configure(captureWindow, name: frameName, capture: true)
        check(captureWindow.frame.size == captureSize && captureWindow.frameAutosaveName.isEmpty,
              "screenshot windows keep their specified size and do not overwrite the saved application frame")
        func makeWindow() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 260),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 260))
            return window
        }
        let window = makeWindow(), other = makeWindow()
        defer { window.close(); other.close() }
        let content = window.contentView!
        let search = NSTextField(frame: NSRect(x: 20, y: 180, width: 200, height: 26))
        let preview = NSTextField(frame: NSRect(x: 260, y: 180, width: 200, height: 26))
        let button = NSButton(title: "Test action", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 80, width: 140, height: 30)
        content.addSubview(search); content.addSubview(preview); content.addSubview(button)
        let monitor = TextFocusMonitorView(frame: .zero)
        content.addSubview(monitor)
        var dismissals = 0
        monitor.onDismiss = { dismissals += 1 }
        other.orderFront(nil)
        window.makeKeyAndOrderFront(nil)
        func click(_ point: NSPoint, in target: NSWindow? = nil) -> NSEvent {
            let target = target ?? window
            return NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                     windowNumber: target.windowNumber, context: nil, eventNumber: 1,
                                     clickCount: 1, pressure: 1)!
        }
        func focusSearch() {
            check(window.makeFirstResponder(search) && search.currentEditor() != nil, "real search field acquires its AppKit field editor")
        }
        check(monitor.isMonitoring, "mouse observer attaches to its window")
        focusSearch()
        let original = window.firstResponder
        let inside = click(NSPoint(x: 80, y: 192))
        check(monitor.process(inside) === inside && window.firstResponder === original && dismissals == 0,
              "clicking inside the search editor keeps focus and returns the original event")
        let anotherField = click(NSPoint(x: 320, y: 192))
        check(monitor.process(anotherField) === anotherField && window.firstResponder === original,
              "clicking a different editable field leaves normal AppKit focus transfer intact")
        let mouseUp = NSEvent.mouseEvent(with: .leftMouseUp, location: anotherField.locationInWindow,
                                         modifierFlags: [], timestamp: 0.01, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        app.postEvent(mouseUp, atStart: true)
        window.sendEvent(anotherField)
        check(preview.currentEditor() != nil && window.firstResponder === preview.currentEditor(),
              "the preview text field receives the first click and can be edited")
        focusSearch()
        let unrelated = click(NSPoint(x: 80, y: 192), in: other)
        let searchEditor = window.firstResponder
        check(unrelated.window === other && monitor.process(unrelated) === unrelated && window.firstResponder === searchEditor && dismissals == 0,
              "events in a different window do not change this window's editor")
        let outside = click(NSPoint(x: 90, y: 90))
        check(monitor.process(outside) === outside && search.currentEditor() == nil && dismissals == 1,
              "clicking a button dismisses editing without consuming its mouse event")
        focusSearch()
        let blank = click(NSPoint(x: 350, y: 60))
        check(monitor.process(blank) === blank && search.currentEditor() == nil && dismissals == 2,
              "clicking empty content dismisses the search caret")
        focusSearch()
        check(search.currentEditor() != nil, "search can acquire focus again after dismissal")
        monitor.removeFromSuperview()
        check(!monitor.isMonitoring, "mouse observer is removed when detached from its window")
        print("SUCCESS: \(checks) focus checks passed")
    }
}
