import SwiftUI

enum ReadingSource: String, CaseIterable {
    case caixin, aihot, lifeweek
    var title: String {
        switch self {
        case .caixin: "财新周刊"
        case .aihot: "AI 日报"
        case .lifeweek: "三联"
        }
    }
}

/// 阅读：三个来源。
/// 财新周刊 / 三联生活周刊：左边是入口，右边是内嵌浏览器——用你自己的账号登录后读全文（财新另有重排版）；
/// AI 日报：AIHOT 的公开接口，原生渲染日报和精选，原文再到浏览器里打开。
struct ReadingView: View {
    @ObservedObject private var store = WeeklyStore.shared
    @ObservedObject private var aihot = AIHotStore.shared
    @ObservedObject private var reader = ReaderController.shared
    @AppStorage("reader.source") private var sourceRaw = ReadingSource.caixin.rawValue
    @State private var selected: String?
    @State private var showTypography = false
    /// 右边是不是正显示内嵌浏览器（不是的话显示占位 / AIHOT 的原生内容）
    @State private var webShown = false
    @State private var aiTab: AIHotTab = .daily
    @State private var aiPick: AIHotItem?

    private var source: ReadingSource { ReadingSource(rawValue: sourceRaw) ?? .caixin }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Picker("", selection: $sourceRaw) {
                    ForEach(ReadingSource.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
                Divider()
                switch source {
                case .caixin: sidebar
                case .aihot: AIHotSidebar(store: aihot, tab: $aiTab, pick: $aiPick)
                case .lifeweek: lifeweekSidebar
                }
            }
            .frame(width: 292)
            Divider()
            detail
        }
        .background(AmbientBackground())
        .toolbar { readerToolbar }
        .task {
            await store.loadIfNeeded()
            await aihot.loadIfNeeded()
            await reader.refreshLogin()
        }
        .onChange(of: sourceRaw) { _, _ in
            webShown = false
            selected = nil
            if source == .lifeweek { openLifeweek("https://www.lifeweek.com.cn/") }
        }
        .onChange(of: aiTab) { _, _ in webShown = false }
        .onChange(of: aiPick) { _, _ in webShown = false }
    }

    // MARK: 三联：入口列表（官网是单页应用、内容属会员，不做目录，只给入口）

    private var lifeweekSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach([("首页", "house", "https://www.lifeweek.com.cn/"),
                     ("杂志（历年各期）", "books.vertical", "https://www.lifeweek.com.cn/magazine"),
                     ("中读课程", "headphones", "https://www.lifeweek.com.cn/zhongdu")], id: \.0) { item in
                Button { openLifeweek(item.2) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.1).frame(width: 18).foregroundStyle(Brand.orange)
                        Text(item.0).font(.system(size: 13.5, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("三联生活周刊的内容属会员，也没有开放接口：这里用内置浏览器打开官网，在页面右上角「登录/注册」后即可阅读，登录状态只留在本机。")
                .font(.caption).foregroundStyle(.tertiary).lineSpacing(3)
                .padding(.horizontal, 10).padding(.bottom, 12)
        }
        .padding(.horizontal, 4).padding(.top, 10)
    }

    private func openLifeweek(_ s: String) {
        guard let u = URL(string: s) else { return }
        reader.open(u)
        webShown = true
    }

    private func openWeb(_ u: URL) {
        reader.open(u)
        webShown = true
    }

    // MARK: 左：期号 + 目录

    private var sidebar: some View {
        VStack(spacing: 0) {
            issueHeader
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
            Divider()
            if let e = store.error, store.sections.isEmpty {
                VStack(spacing: 10) {
                    Text(e).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("重试") { Task { await store.reload() } }
                }
                .padding(20).frame(maxHeight: .infinity)
            } else if store.sections.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.sections) { s in
                            Text(s.name).font(.caption.weight(.bold)).foregroundStyle(Brand.orange)
                                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
                            ForEach(s.articles) { a in row(a) }
                        }
                    }
                    .padding(.horizontal, 4).padding(.bottom, 12)
                }
            }
            Divider()
            account.padding(.horizontal, 14).padding(.vertical, 9)
        }
    }

    private var issueHeader: some View {
        HStack(spacing: 10) {
            AsyncImage(url: store.current?.cover) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.primary.opacity(0.06)
            }
            .frame(width: 42, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 3) {
                Menu {
                    ForEach(store.issues.prefix(40)) { i in
                        Button {
                            Task { await store.select(i) }
                        } label: {
                            Text((i.no == store.current?.no ? "✓ " : "") + i.label + "　" + i.title)
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(store.current?.label ?? "财新周刊").font(.system(size: 14, weight: .bold))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Text(store.current?.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button { Task { await store.reload() } } label: {
                if store.loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("刷新目录").disabled(store.loading)
        }
    }

    private func row(_ a: WeeklyArticle) -> some View {
        let on = selected == a.id
        let done = store.isRead(a)
        return Button { open(a) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(a.title).font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(done && !on ? Color.secondary : Color.primary).lineLimit(2)
                if !a.summary.isEmpty {
                    Text(a.summary).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(on ? Brand.orange.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var account: some View {
        HStack(spacing: 6) {
            Circle().fill(reader.loggedIn ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(reader.loggedIn ? "已登录财新" : "未登录财新").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if reader.loggedIn {
                Button("退出") { Task { await reader.logout() } }.buttonStyle(.link).font(.caption)
            } else {
                Button("登录") { reader.openLogin(back: URL(string: "https://weekly.caixin.com/")) }.buttonStyle(.link).font(.caption)
            }
        }
    }

    private func open(_ a: WeeklyArticle) {
        selected = a.id
        store.markRead(a)
        reader.open(a.url)
        webShown = true
    }

    // MARK: 右：阅读

    @ViewBuilder private var detail: some View {
        if source == .aihot && !webShown {
            AIHotDetail(store: aihot, tab: aiTab, pick: aiPick, open: openWeb)
        } else if !webShown {
            VStack(spacing: 10) {
                Image(systemName: "newspaper").font(.system(size: 38)).foregroundStyle(.tertiary)
                Text("选一篇文章开始阅读").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if source == .caixin && reader.article && reader.locked { lockedBanner; Divider() }
                ReaderWebView(controller: reader)
            }
        }
    }

    /// 放进窗口标题栏（刷新按钮左边），不再占一条工具行
    @ToolbarContentBuilder private var readerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if webShown {
                if source == .aihot {
                    toolButton("list.bullet.rectangle", "回到日报 / 精选") { webShown = false }
                }
                if reader.canGoBack {
                    toolButton("chevron.left", "返回") { reader.goBack() }
                }
                if reader.loading { ProgressView().controlSize(.small) }
                if reader.article {
                    toolButton("textformat.size.smaller", "字号减小") { reader.size = max(reader.size - 1, 14) }
                    toolButton("textformat.size.larger", "字号增大") { reader.size = min(reader.size + 1, 30) }
                    Button { showTypography.toggle() } label: { Image(systemName: "textformat") }
                        .help("排版：字体、行距、栏宽、段首缩进")
                        .popover(isPresented: $showTypography, arrowEdge: .bottom) { typographyPanel }
                    Menu {
                        Picker("外观", selection: $reader.theme) {
                            Text("纸张").tag("paper")
                            Text("白色").tag("white")
                            Text("深色").tag("dark")
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "circle.lefthalf.filled")
                    }
                    .help("阅读外观")
                    toolButton("note.text.badge.plus", "把选中的文字摘到便签（带出处）") { Task { await reader.clipSelectionToSticky() } }
                }
                toolButton("safari", "在浏览器中打开") { reader.openInBrowser() }
            }
        }
    }

    private func toolButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }.help(help)
    }

    /// 排版面板：字体 / 字号 / 行距 / 栏宽 / 段首缩进 / 两端对齐
    private var typographyPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("字体", selection: $reader.font) {
                Text("宋体").tag("song")
                Text("黑体").tag("hei")
                Text("楷体").tag("kai")
            }
            .pickerStyle(.segmented).labelsHidden()
            slider("字号", value: $reader.size, range: 14 ... 30, step: 1, text: "\(Int(reader.size))")
            slider("行距", value: $reader.leading, range: 1.5 ... 2.5, step: 0.05, text: String(format: "%.2f", reader.leading))
            slider("栏宽", value: $reader.width, range: 520 ... 960, step: 20, text: "\(Int(reader.width))")
            Toggle("段首空两格", isOn: $reader.indent)
            Toggle("两端对齐", isOn: $reader.justify)
            HStack {
                Text("中英文自动加间距、标点避头尾已开启").font(.caption).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Button("恢复默认") { reader.resetTypography() }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(16).frame(width: 290)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.callout).frame(width: 34, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(text).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
    }

    private var lockedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(Brand.orange)
            Text(reader.loggedIn ? "只显示了预览：这个账号没有《财新周刊》阅读权限，或登录已过期" : "只显示了预览：登录有《财新周刊》权限的账号后可读全文")
                .font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Button(reader.loggedIn ? "重新登录" : "登录") { reader.openLogin() }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Brand.orange.opacity(0.08))
    }
}
