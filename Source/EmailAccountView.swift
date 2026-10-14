import SwiftUI
import AppKit

struct EmailAccountView: View {
    @ObservedObject var account: EmailAccountModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var mode = "登录"
    @ViewState private var email = ""
    @ViewState private var password = ""
    @ViewState private var code = ""
    @ViewState private var verifyingSignup = false
    @ViewState private var baiduState: String?
    @ViewState private var baiduCode = ""
    private var validEmail: Bool { email.contains("@") && email.contains(".") && !email.contains(where: { $0.isWhitespace }) }
    private var validCode: Bool { code.count == 6 && code.allSatisfy(\.isNumber) }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(account.user == nil ? "邮箱账号" : "我的账号").font(.system(size: 21, weight: .semibold))
            if !account.configured {
                Text("邮箱账号服务尚未配置").font(.system(size: 15, weight: .medium))
                Text("维护者需要先部署账号后台。配置完成后，可用邮箱注册、登录，并跨电脑查看自己的收藏和下载记录。")
                    .font(.system(size: 12)).foregroundColor(Palette.muted).fixedSize(horizontal: false, vertical: true)
            } else if let user = account.user {
                Label(user.email ?? "已登录用户", systemImage: "person.crop.circle").font(.system(size: 15))
                Text(account.isAdmin ? "字体库管理员 · 可以上传字体" : "普通用户 · 可以下载和收藏字体")
                    .font(.system(size: 12)).foregroundColor(Palette.green)
                Text("我的收藏：\(account.favorites.count) · 我的下载记录：\(account.downloads.count)")
                    .font(.system(size: 12)).foregroundColor(Palette.muted)
                Text("个人记录与账号关联。换电脑后登录同一邮箱，可按记录恢复字体；公开字体文件仍可由所有人下载。")
                    .font(.system(size: 12)).foregroundColor(Palette.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("刷新记录") { Task { await account.refreshRecords() } }.buttonStyle(QuietButton()).disabled(account.isWorking)
                    Button("退出当前设备") { Task { await account.signOut() } }.buttonStyle(QuietButton()).disabled(account.isWorking)
                }
                if account.isAdmin {
                    Divider()
                    Button("连接百度网盘") {
                        Task {
                            if let authorization = await account.startBaiduConnection() {
                                baiduState = authorization.state
                                NSWorkspace.shared.open(authorization.authorizationURL)
                            }
                        }
                    }.buttonStyle(QuietButton()).disabled(account.isWorking)
                    if let state = baiduState {
                        Text("在浏览器登录并授权你的百度网盘，将页面显示的一次性授权码填入下方。")
                            .font(.system(size: 11)).foregroundColor(Palette.muted)
                        SecureField("百度网盘一次性授权码", text: $baiduCode).textFieldStyle(.roundedBorder)
                        Button("完成网盘连接") {
                            Task {
                                if await account.completeBaiduConnection(state: state, code: baiduCode) { baiduCode = ""; baiduState = nil }
                            }
                        }.buttonStyle(QuietButton(active: true)).disabled(account.isWorking || baiduCode.isEmpty)
                    }
                }
            } else {
                Picker("账号操作", selection: $mode) { Text("登录").tag("登录"); Text("注册").tag("注册"); Text("找回密码").tag("找回密码") }
                    .pickerStyle(.segmented).disabled(account.isWorking)
                    .onChange(of: mode) { _ in password = ""; code = ""; verifyingSignup = false; account.errorMessage = nil; account.message = nil }
                TextField("邮箱地址", text: $email).textFieldStyle(.roundedBorder).disabled(account.isWorking)
                if mode == "登录" || mode == "注册" {
                    SecureField("密码（至少 8 位）", text: $password).textFieldStyle(.roundedBorder).disabled(account.isWorking)
                    if verifyingSignup {
                        TextField("邮件中的 6 位验证码", text: $code).textFieldStyle(.roundedBorder).disabled(account.isWorking)
                    }
                    Button(verifyingSignup ? "验证邮箱并登录" : mode) {
                        Task {
                            let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
                            if mode == "登录" {
                                if await account.signIn(email: address, password: password) { password = ""; dismiss() }
                            } else if verifyingSignup {
                                if await account.verifySignup(email: address, code: code) { password = ""; code = ""; dismiss() }
                            } else if await account.signUp(email: address, password: password) { verifyingSignup = true }
                        }
                    }.buttonStyle(QuietButton(active: true))
                        .disabled(account.isWorking || !validEmail || (verifyingSignup ? !validCode : password.count < 8))
                } else {
                    Button("发送重置验证码") { Task { await account.sendRecovery(email: email.trimmingCharacters(in: .whitespacesAndNewlines)) } }
                        .buttonStyle(QuietButton()).disabled(account.isWorking || !validEmail)
                    TextField("邮件中的 6 位验证码", text: $code).textFieldStyle(.roundedBorder).disabled(account.isWorking)
                    SecureField("新密码（至少 8 位）", text: $password).textFieldStyle(.roundedBorder).disabled(account.isWorking)
                    Button("验证并更新密码") {
                        Task {
                            if await account.resetPassword(email: email.trimmingCharacters(in: .whitespacesAndNewlines), code: code, password: password) { password = ""; code = ""; dismiss() }
                        }
                    }.buttonStyle(QuietButton(active: true)).disabled(account.isWorking || !validEmail || !validCode || password.count < 8)
                }
                Text("密码由账号服务处理。软件只在 Mac 钥匙串中保存登录会话，无需填写 GitHub 令牌。")
                    .font(.system(size: 11)).foregroundColor(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let message = account.message { Text(message).font(.system(size: 11)).foregroundColor(Palette.green).fixedSize(horizontal: false, vertical: true) }
            if let error = account.errorMessage { Text(error).font(.system(size: 11)).foregroundColor(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if account.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("关闭") { password = ""; code = ""; dismiss() }.buttonStyle(QuietButton()).disabled(account.isWorking)
            }
        }.padding(28).frame(width: 470).background(Palette.canvas).foregroundColor(Palette.ink)
            .interactiveDismissDisabled(account.isWorking).onDisappear { password = ""; code = ""; baiduCode = ""; baiduState = nil }
    }
}
