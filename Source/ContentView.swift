import SwiftUI
import AppKit

// Explicitly selects the property wrapper when building with SDKs that also
// define a State macro. This keeps the source compatible with Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>

enum Palette {
    static let ink = Color(red: 0.13, green: 0.18, blue: 0.16)
    static let green = Color(red: 0.16, green: 0.36, blue: 0.29)
    static let canvas = Color(red: 0.965, green: 0.962, blue: 0.944)
    static let line = Color(red: 0.88, green: 0.89, blue: 0.86)
    static let muted = Color(red: 0.46, green: 0.50, blue: 0.46)
    static let mint = Color(red: 0.91, green: 0.95, blue: 0.91)
}

struct QuietButton: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .foregroundColor(active ? .white : Palette.green)
            .background(active ? Palette.green : Palette.mint)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            VStack(spacing: 0) {
                topbar
                Rectangle().fill(Palette.line).frame(height: 1)
                HStack(spacing: 0) {
                    library.frame(maxWidth: .infinity)
                    Rectangle().fill(Palette.line).frame(width: 1)
                    inspector.frame(width: 330)
                }
            }
        }
        .foregroundColor(Palette.ink).background(Palette.canvas)
        .preferredColorScheme(.light)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(toast).lineLimit(2)
                }
                .font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Palette.green).clipShape(Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.bottom, 22).padding(.horizontal, 220)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $model.showEditor) {
            if let font = model.selected { NameEditor(model: model, font: font) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusFontSearch)) { _ in searchFocused = true }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable()
                    .interpolation(.high).frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("字体检索").font(.system(size: 18, weight: .semibold))
                    Text("FONT FINDER").font(.system(size: 8, weight: .medium)).tracking(1.3).foregroundColor(Palette.muted)
                }
            }.padding(.top, 34).padding(.bottom, 36)
            Text("你的字体资料库").font(.system(size: 10, weight: .medium)).foregroundColor(Palette.muted).padding(.bottom, 12)
            ForEach(LibrarySection.allCases, id: \.self) { section in
                Button { model.section = section } label: {
                    HStack(spacing: 11) {
                        Image(systemName: section.icon).font(.system(size: 15)).frame(width: 18)
                        Text(section.rawValue).font(.system(size: 12, weight: model.section == section ? .semibold : .regular))
                        Spacer(minLength: 0)
                        Text(count(section)).font(.system(size: 10, design: .monospaced)).opacity(0.7)
                    }.padding(.horizontal, 12).frame(height: 43)
                    .foregroundColor(model.section == section ? Palette.green : Palette.muted)
                    .background(model.section == section ? Palette.mint : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).padding(.bottom, 5)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "character.cursor.ibeam").font(.system(size: 25, weight: .light)).foregroundColor(Palette.green)
                Text("好字体，\n随手就能找到。").font(.system(size: 16, weight: .medium)).lineSpacing(5)
                Text("中文 · 拼音 · English\n一个名字，多种找法。")
                    .font(.system(size: 10)).foregroundColor(Palette.muted).lineSpacing(5)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 5) {
                Circle().fill(Palette.green).frame(width: 5, height: 5)
                Text("字体册来源 · 离线可用").font(.system(size: 10)).foregroundColor(Palette.muted)
            }.padding(.top, 20).padding(.bottom, 24)
        }.padding(.horizontal, 20)
            .background(Color(red: 0.94, green: 0.945, blue: 0.92))
    }

    private func count(_ section: LibrarySection) -> String {
        switch section {
        case .all: return "\(model.fonts.count)"
        case .chinese: return "\(model.fonts.filter(\.supportsChinese).count)"
        case .favorites: return "\(model.fonts.filter { model.favorites.contains($0.id) }.count)"
        case .recent: return "\(model.fonts.filter { model.recent.contains($0.id) }.count)"
        }
    }

    private var topbar: some View {
        HStack(spacing: 13) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundColor(Palette.muted)
                TextField("搜索字体：苹方 / pingfang / PingFang", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused)
                    .onSubmit { if let f = model.selected { model.copy(model.englishName(f), font: f, label: "英文名") } }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Palette.muted) }.buttonStyle(.plain).help("清空搜索")
                } else {
                    Text("⌘ F").font(.system(size: 10, design: .monospaced)).foregroundColor(Palette.muted)
                }
            }.padding(.horizontal, 13).frame(height: 37).background(Palette.canvas).clipShape(RoundedRectangle(cornerRadius: 9))
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 14)) }
                .buttonStyle(.plain).disabled(model.loading).help("重新读取已安装字体（⌘R）")
        }.padding(.horizontal, 24).frame(height: 70).background(Color.white.opacity(0.8))
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.section.rawValue).font(.system(size: 25, weight: .semibold))
                    Text(model.loading ? "正在读取字体册中的字体…" : "\(model.visible.count) 个字体家族 · 粗细样式已合并")
                        .font(.system(size: 11)).foregroundColor(Palette.muted)
                }
                Spacer()
                Menu {
                    Picker("排序方式", selection: $model.sortOrder) {
                        ForEach(FontSortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 11))
                        Text(model.sortOrder.title).font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }.foregroundColor(Palette.green).padding(.horizontal, 12).frame(height: 32)
                        .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(model.loading).help("选择字体排序方式，设置会自动保存")
                    .accessibilityLabel("排序方式：\(model.sortOrder.title)")
            }.padding(.horizontal, 25).padding(.top, 25).padding(.bottom, 22)
            if model.loading && model.fonts.isEmpty {
                Spacer(); ProgressView().frame(maxWidth: .infinity); Spacer()
            } else if model.visible.isEmpty {
                Spacer()
                VStack(spacing: 13) {
                    Image(systemName: model.section == .favorites ? "star" : "magnifyingglass").font(.system(size: 32, weight: .light)).foregroundColor(Palette.green)
                    Text(model.query.isEmpty ? emptyText : "没有找到匹配字体").font(.system(size: 16, weight: .medium))
                    Text(model.query.isEmpty ? "选择字体后，点击星标或复制名称。" : "试试中文、拼音、拼音首字母或英文名称。\n也可以为字体添加自己的别名。")
                        .font(.system(size: 11)).foregroundColor(Palette.muted).multilineTextAlignment(.center).lineSpacing(5)
                    if !model.query.isEmpty { Button("清空搜索") { model.query = "" }.buttonStyle(QuietButton()) }
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.visible) { font in FontRow(model: model, font: font) }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
            HStack {
                Text("字体册已启用字体 · 复制家族名称").font(.system(size: 9)).foregroundColor(Palette.muted)
                Spacer()
                Text("v1.7").font(.system(size: 9, design: .monospaced)).foregroundColor(Palette.muted)
            }.padding(.horizontal, 25).frame(height: 35)
        }
    }

    private var emptyText: String { model.section == .favorites ? "把喜欢的字体收藏在这里" : "这里还没有字体记录" }

    @ViewBuilder private var inspector: some View {
        if let font = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("字体详情").font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.muted)
                        Spacer()
                        Button { model.toggleFavorite(font.id) } label: {
                            Image(systemName: model.favorites.contains(font.id) ? "star.fill" : "star").foregroundColor(Palette.green)
                        }.buttonStyle(.plain).help("收藏 / 取消收藏（⌘D）")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.chineseName(font) ?? model.englishName(font)).font(.system(size: 23, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(model.englishName(font)).font(.system(size: 11)).foregroundColor(Palette.muted).textSelection(.enabled)
                        HStack(spacing: 6) {
                            tag("\(font.faces.count) 种样式")
                            tag(font.supportsChinese ? "支持中文" : "西文字体")
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("字体预览").font(.system(size: 10, weight: .medium)).foregroundColor(Palette.muted)
                            Spacer()
                            Text("\(Int(model.size)) pt").font(.system(size: 10, design: .monospaced)).foregroundColor(Palette.muted)
                        }
                        HStack(spacing: 8) {
                            Text("字重 / 样式").font(.system(size: 10)).foregroundColor(Palette.muted)
                            Picker("字重 / 样式", selection: Binding(get: { model.previewFace(font).id }, set: { model.selectFace($0, for: font) })) {
                                ForEach(font.faces) { face in Text(face.label).tag(face.id) }
                            }.labelsHidden().pickerStyle(.menu).controlSize(.small)
                                .disabled(font.faces.count == 1)
                                .help("切换粗细或斜体进行预览，复制的仍是字体家族名称")
                        }
                        Text("Aa 字").font(.custom(model.previewFace(font).id, size: 40)).foregroundColor(Palette.green)
                        Text(model.preview.isEmpty ? "把灵感，写成日常。" : model.preview)
                            .font(.custom(model.previewFace(font).id, size: model.size)).lineSpacing(7)
                            .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("The quick brown fox 0123456789").font(.custom(model.previewFace(font).id, size: 11)).foregroundColor(Palette.muted)
                        Slider(value: $model.size, in: 18...60).tint(Palette.green)
                        TextField("输入你想预览的文字", text: $model.preview).font(.system(size: 11)).textFieldStyle(.roundedBorder)
                        if !model.previewFace(font).supportsChinese {
                            Text("该字体不含测试用中文字形；中文可能由系统备用字体显示。")
                                .font(.system(size: 9)).foregroundColor(Palette.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(17).background(Palette.canvas).clipShape(RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("一键复制家族名称").font(.system(size: 12, weight: .semibold))
                        CopyNameCard(title: "中文", value: model.chineseName(font), shortcut: "⌘1", note: model.custom[font.id]?.chinese.isEmpty == false ? "自定义名称" : nil) {
                            if let value = model.chineseName(font) { model.copy(value, font: font, label: "中文名") }
                        }
                        CopyNameCard(title: "英文", value: model.englishName(font), shortcut: "⌘2", note: model.custom[font.id]?.english.isEmpty == false ? "自定义名称" : nil) {
                            model.copy(model.englishName(font), font: font, label: "英文名")
                        }
                    }
                    Button { model.showEditor = true } label: {
                        HStack(spacing: 6) { Image(systemName: "pencil.line"); Text("编辑中文 / 英文别名") }.font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundColor(Palette.green)
                    Text("复制的是名称文字。其他电脑需安装同一字体，才可使用相同字形。")
                        .font(.system(size: 9)).foregroundColor(Palette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }.padding(23)
            }.background(Color.white.opacity(0.8))
        } else {
            VStack(spacing: 12) {
                Image(systemName: "textformat").font(.system(size: 35, weight: .light))
                Text("选择一款字体，开始预览").font(.system(size: 12))
            }.foregroundColor(Palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white.opacity(0.8))
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).foregroundColor(Palette.green)
            .padding(.horizontal, 8).padding(.vertical, 4).background(Palette.mint).clipShape(Capsule())
    }
}

struct FontRow: View {
    @ObservedObject var model: AppModel
    let font: FontRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.chineseName(font) ?? model.englishName(font)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("\(model.englishName(font)) · \(font.faces.count) 种样式").font(.system(size: 10)).foregroundColor(Palette.muted).lineLimit(1)
                }
                Spacer()
                Button { model.toggleFavorite(font.id) } label: {
                    Image(systemName: model.favorites.contains(font.id) ? "star.fill" : "star").font(.system(size: 12)).foregroundColor(Palette.muted)
                }.buttonStyle(.plain).help("收藏 \(font.english)")
            }
            Text(model.preview.isEmpty ? "把灵感，写成日常。" : model.preview)
                .font(.custom(model.previewFace(font).id, size: 23)).lineLimit(1).frame(height: 29, alignment: .leading)
                .foregroundColor(Palette.ink.opacity(0.88))
            HStack(spacing: 6) {
                Button("复制中文") { if let value = model.chineseName(font) { model.copy(value, font: font, label: "中文名") } }
                    .buttonStyle(QuietButton()).disabled(model.chineseName(font) == nil).opacity(model.chineseName(font) == nil ? 0.4 : 1)
                    .help(model.chineseName(font) ?? "未提供中文名，可在详情中添加别名")
                Button("复制英文") { model.copy(model.englishName(font), font: font, label: "英文名") }.buttonStyle(QuietButton())
                Spacer(minLength: 0)
            }
        }.padding(16).background(model.selection == font.id ? Color.white : Color.white.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.selection == font.id ? Palette.green.opacity(0.6) : Palette.line.opacity(0.5), lineWidth: 1))
            .contentShape(Rectangle()).onTapGesture { model.selection = font.id }
            .accessibilityElement(children: .contain).accessibilityLabel(font.english)
    }
}

struct CopyNameCard: View {
    let title: String
    let value: String?
    let shortcut: String
    var note: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 9, weight: .semibold)).foregroundColor(Palette.muted)
                        Text(shortcut).font(.system(size: 8, design: .monospaced)).foregroundColor(Palette.muted.opacity(0.7))
                    }
                    Text(value ?? "字体未提供中文名").font(.system(size: 12, weight: .medium))
                        .foregroundColor(value == nil ? Palette.muted : Palette.ink).lineLimit(2).multilineTextAlignment(.leading)
                    if let note = note { Text(note).font(.system(size: 8)).foregroundColor(Palette.muted) }
                }
                Spacer(minLength: 0)
                Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundColor(Palette.green).opacity(value == nil ? 0.3 : 1)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1))
        }.buttonStyle(.plain).disabled(value == nil).help(value.map { "点击复制：\($0)" } ?? "可添加自定义中文别名")
    }
}

struct NameEditor: View {
    @ObservedObject var model: AppModel
    let font: FontRecord
    @Environment(\.dismiss) private var dismiss
    @ViewState private var chinese = ""
    @ViewState private var english = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("给字体一个好记的名字").font(.system(size: 21, weight: .semibold))
            Text(font.english).font(.system(size: 12)).foregroundColor(Palette.muted)
            Text("别名用于搜索和复制；留空将恢复字体原始名称。\n拼音会根据中文别名自动生成，不会修改字体文件。")
                .font(.system(size: 12)).foregroundColor(Palette.muted).lineSpacing(5)
            VStack(alignment: .leading, spacing: 8) {
                Text("中文别名").font(.system(size: 11, weight: .medium))
                TextField(font.chinese ?? "例如：我的标题字体", text: $chinese).textFieldStyle(.roundedBorder)
                Text("英文别名").font(.system(size: 11, weight: .medium)).padding(.top, 6)
                TextField(font.english, text: $english).textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("恢复原名") { chinese = ""; english = "" }.buttonStyle(QuietButton())
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(QuietButton())
                Button("保存") { model.saveNames(CustomNames(chinese: chinese, english: english), for: font.id); dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(QuietButton(active: true))
            }.padding(.top, 8)
        }.padding(28).frame(width: 430).background(Palette.canvas).foregroundColor(Palette.ink)
            .onAppear { chinese = model.custom[font.id]?.chinese ?? ""; english = model.custom[font.id]?.english ?? "" }
    }
}

extension Notification.Name {
    static let refreshCloudFonts = Notification.Name("FontName.refreshCloudFonts")
    static let focusFontSearch = Notification.Name("FontName.focusSearch")
}
