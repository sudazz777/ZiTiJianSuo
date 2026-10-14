import AppKit
import SwiftUI
import WebKit

struct NetdiskBrowser: NSViewRepresentable {
    @ObservedObject var model: NetdiskImportModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(WKUserScript(source: NetdiskWebAutomation.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: "fontFinder")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.loadedID != model.refreshID, let share = model.share {
            coordinator.loadedID = model.refreshID; view.load(URLRequest(url: share.url))
        }
        let auto = model.autoDownload && model.activeDownloads < 2 && !model.isInstalling
        view.evaluateJavaScript("window.__fontFinderAuto = \(auto ? "true" : "false");", completionHandler: nil)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "fontFinder")
        view.stopLoading()
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
        let model: NetdiskImportModel
        var loadedID = -1
        struct Context { let download: WKDownload; let job: URL; let file: URL; let observation: NSKeyValueObservation }
        var downloads: [ObjectIdentifier: Context] = [:]
        init(model: NetdiskImportModel) { self.model = model }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.host == "pan.baidu.com",
                  let body = message.body as? [String: Any], body["kind"] as? String == "files", let names = body["names"] as? [String] else { return }
            model.recordNames(names)
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.shouldPerformDownload { decisionHandler(.download); return }
            if let url = action.request.url, !["https", "http", "about", "blob", "data"].contains(url.scheme ?? "") {
                model.status = "百度页面要求使用客户端。可下载后选择“导入下载文件”，后续会自动安装。"
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(response.canShowMIMEType ? .allow : .download)
        }
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.status = "网页已打开。完成登录或验证后，软件会尝试识别并下载可见字体。"
            webView.evaluateJavaScript("window.__fontFinderAuto = \(model.autoDownload ? "true" : "false"); window.fontFinderScan?.();", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { model.errorMessage = "网盘页面未能打开：\(error.localizedDescription)" }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = NSAlert(); alert.messageText = "百度网盘"; alert.informativeText = message; alert.runModal(); completionHandler()
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = NSAlert(); alert.messageText = "百度网盘"; alert.informativeText = message; alert.addButton(withTitle: "确认"); alert.addButton(withTitle: "取消")
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }
        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let ext = (suggestedFilename as NSString).pathExtension.lowercased()
            guard FontInstallEngine.supported.contains(ext), response.expectedContentLength <= Int64(FontInstallEngine.maximumDownloadSize) else {
                model.errorMessage = "下载不是支持的字体/ZIP，或超过 512 MiB；未安装。"; completionHandler(nil); return
            }
            do {
                let job = try model.jobs.create(), file = job.appendingPathComponent("download.\(ext)")
                let observation = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self, weak download] progress, _ in
                    guard progress.completedUnitCount > Int64(FontInstallEngine.maximumDownloadSize) else { return }
                    Task { @MainActor [weak self, weak download] in
                        download?.cancel { _ in }
                        self?.model.errorMessage = "下载超过 512 MiB，已停止。"
                    }
                }
                downloads[ObjectIdentifier(download)] = Context(download: download, job: job, file: file, observation: observation)
                model.retainDownloadDelegate(self)
                model.startDownload(); completionHandler(file)
            } catch { model.errorMessage = error.localizedDescription; completionHandler(nil) }
        }
        func downloadDidFinish(_ download: WKDownload) {
            guard let context = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
            context.observation.invalidate(); model.downloaded(context.file, job: context.job)
            if downloads.isEmpty { model.releaseDownloadDelegate(self) }
        }
        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            guard let context = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
            context.observation.invalidate(); model.failedDownload(context.job, message: "下载未完成：\(error.localizedDescription)。任务文件已保留。")
            if downloads.isEmpty { model.releaseDownloadDelegate(self) }
        }
    }
}
