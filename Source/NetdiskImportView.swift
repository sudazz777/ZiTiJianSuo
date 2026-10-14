import SwiftUI

struct NetdiskImportView: View {
    @ObservedObject var model: NetdiskImportModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("网盘字体安装").font(.system(size: 24, weight: .semibold))
                    Text("下载后识别字体 → 本机查重 → 安装验证 → 自动清理临时文件").font(.system(size: 11)).foregroundColor(Palette.muted)
                }
                Spacer()
                Button("导入下载文件") { model.importFiles() }.buttonStyle(QuietButton(active: true))
            }
            HStack {
                TextField("粘贴百度网盘分享链接和提取码", text: $model.shareText).textFieldStyle(.roundedBorder).onSubmit { model.openShare() }
                Button("打开分享") { model.openShare() }.buttonStyle(QuietButton(active: true))
                Button { model.reloadPage() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).disabled(model.share == nil)
            }
            HStack(spacing: 16) {
                Toggle("自动尝试下载网页中的字体", isOn: $model.autoDownload).font(.system(size: 11))
                Toggle("本地导入成功后将原文件移到废纸篓", isOn: $model.trashImportedOriginals).font(.system(size: 11))
            }
            if let error = model.errorMessage {
                HStack {
                    Text(error).font(.system(size: 11)).foregroundColor(.red).textSelection(.enabled)
                    Spacer(); Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(10).background(Color.white).cornerRadius(7)
            }
            HStack {
                Text("网页识别 \(model.remoteNames.count) 项 · 本次已安装 \(model.installedCount) · 已跳过 \(model.skippedCount)")
                Spacer()
                if !model.failedJobs.isEmpty { Button("查看保留的任务文件") { model.revealFailedJobs() }.buttonStyle(.plain).foregroundColor(Palette.green) }
            }.font(.system(size: 10)).foregroundColor(Palette.muted)
            if model.share != nil {
                NetdiskBrowser(model: model).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
            } else {
                Spacer()
                VStack(spacing: 13) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 38, weight: .light)).foregroundColor(Palette.green)
                    Text("打开分享，在百度页面完成登录或验证").font(.system(size: 16, weight: .medium))
                    Text("软件尝试下载网页中可见的字体或 ZIP。\n如果百度要求客户端，可下载后导入，安装和临时清理仍会自动完成。")
                        .font(.system(size: 12)).foregroundColor(Palette.muted).multilineTextAlignment(.center).lineSpacing(5)
                    Button("打开已提供的字体分享") { model.openShare() }.buttonStyle(QuietButton(active: true))
                }.frame(maxWidth: .infinity)
                Spacer()
            }
            if !model.results.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.results.suffix(20)) { result in
                            HStack { Text(result.name).lineLimit(1); Spacer(); Text(result.status).foregroundColor(result.success ? Palette.green : .red) }
                                .font(.system(size: 10))
                        }
                    }
                }.frame(height: 100)
            }
            HStack(spacing: 8) {
                if model.isInstalling || model.activeDownloads > 0 { ProgressView().controlSize(.small) }
                Text(model.status).font(.system(size: 10)).foregroundColor(Palette.muted).lineLimit(2)
                Spacer()
            }
        }.padding(24).background(Palette.canvas)
            .onReceive(NotificationCenter.default.publisher(for: .refreshCloudFonts)) { _ in model.reloadPage() }
    }
}
