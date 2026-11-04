import AppKit

@MainActor final class UpdateProgressPanel: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
    private let status = NSTextField(labelWithString: "正在下载更新…")
    private let bar = NSProgressIndicator()
    private let cancel = NSButton(title: "取消更新", target: nil, action: nil)
    var onCancel: (() -> Void)?
    override init() {
        super.init()
        panel.title = "字体检索更新"; panel.isReleasedWhenClosed = false
        let content = panel.contentView!
        status.frame = NSRect(x: 24, y: 102, width: 372, height: 22)
        status.font = .systemFont(ofSize: 13)
        bar.frame = NSRect(x: 24, y: 72, width: 372, height: 16)
        bar.style = .bar; bar.minValue = 0; bar.maxValue = 100; bar.isIndeterminate = false
        cancel.frame = NSRect(x: 282, y: 20, width: 114, height: 32)
        cancel.bezelStyle = .rounded; cancel.target = self; cancel.action = #selector(cancelUpdate)
        content.addSubview(status); content.addSubview(bar); content.addSubview(cancel)
    }
    func show() {
        if let parent = NSApp.mainWindow { parent.beginSheet(panel) }
        else { panel.center(); panel.makeKeyAndOrderFront(nil) }
    }
    func progress(_ fraction: Double) {
        bar.doubleValue = fraction * 100
        status.stringValue = "正在下载更新… \(Int(fraction * 100))%"
    }
    func preparing() {
        status.stringValue = "正在校验并准备安装…"
        bar.isIndeterminate = true; bar.startAnimation(nil)
    }
    func cancelRequested() { status.stringValue = "正在取消更新…"; cancel.isEnabled = false }
    func restarting() { status.stringValue = "即将安装并重新打开软件…"; cancel.isEnabled = false }
    func close() {
        if let parent = panel.sheetParent { parent.endSheet(panel) }
        panel.orderOut(nil)
    }
    @objc private func cancelUpdate() { onCancel?() }
}
