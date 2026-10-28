import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 设置窗口

/// 设置的分类：左侧导航，一类一页
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, account, data, voice, mic, widget, focus, notify

    var id: String { rawValue }

    /// 侧边栏的分组
    static let sections: [(title: String, tabs: [SettingsTab])] = [
        ("通用", [.general, .account, .data]),
        ("功能", [.voice, .mic, .widget, .focus, .notify]),
    ]

    var title: String {
        switch self {
        case .general: return "通用"
        case .account: return "账号"
        case .data: return "数据与备份"
        case .voice: return "语音输入"
        case .mic: return "猛犸麦克风"
        case .widget: return "小组件"
        case .focus: return "专注"
        case .notify: return "通知"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .account: return "person.crop.circle.fill"
        case .data: return "externaldrive.fill"
        case .voice: return "mic.fill"
        case .mic: return "dot.radiowaves.left.and.right"
        case .widget: return "capsule.portrait.fill"
        case .focus: return "timer"
        case .notify: return "bell.badge.fill"
        }
    }

    /// 侧边栏图标底色（每一类一个颜色，和系统设置一样好认）
    var color: Color {
        switch self {
        case .general: return .gray
        case .account: return .blue
        case .data: return .teal
        case .voice: return .pink
        case .mic: return .indigo
        case .widget: return .cyan
        case .focus: return .orange
        case .notify: return .red
        }
    }

    /// 搜索用的关键词
    var keywords: String {
        switch self {
        case .general: return "外观 主题 暗黑 明亮 dock 后台 快捷键 热键 全局 万能输入 灵动岛 语音输入 菜单 自定义"
        case .account: return "闪念贝壳 滴答清单 结审 腾讯云 secretid secretkey api key 口令 连接 账号 凭证 ai 模型 大模型 接口 openai 通义 deepseek 测试连接"
        case .data: return "备份 手机 本机 数据 目录 finder"
        case .voice: return "语音 快捷键 识别 引擎 腾讯云 option 录音 听写 麦克风 权限 历史 词库 热词 替换 纠错 同音字 专有名词 人名"
        case .mic: return "猛犸 hollyland lark a2 无线麦克风 发射器 接收器 按键 单击 双击 三击 静音 降噪 电量"
        case .widget: return "灵动岛 菜单栏 小组件 悬停 截图 暂存架 刘海 ocr 状态提醒"
        case .focus: return "专注 番茄 目标 小票 打印 提示音"
        case .notify: return "通知 提醒 简报 逾期 到点 提前"
        }
    }
}

/// 设置窗口当前在哪一页（外面也能指定：比如「去设置 AI 模型」）
@MainActor
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var tab: SettingsTab = .general
    @Published var showVoiceHistory = false
}

/// 统一打开设置窗口的入口：主窗口、菜单、灵动岛、各种「去设置」按钮都走这里
@MainActor
enum SettingsWindow {
    /// 由主窗口的 SwiftUI 视图写入（拿 openWindow）
    static var opener: (() -> Void)?

    static func show(_ tab: SettingsTab? = nil) {
        if let tab { SettingsNav.shared.tab = tab }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { !($0 is NSPanel) && $0.title == "设置" }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            opener?()
        }
    }
}

struct SettingsRoot: View {
    @ObservedObject private var nav = SettingsNav.shared
    @State private var query = ""

    private func matches(_ t: SettingsTab) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || t.title.lowercased().contains(q) || t.keywords.lowercased().contains(q)
    }

    var body: some View {
        NavigationSplitView {
            // 系统原生的侧边栏列表：选中态、间距、液态玻璃都交给系统
            List(selection: Binding(get: { nav.tab }, set: { if let t = $0 { nav.tab = t } })) {
                // 和系统设置一样：没有分组标题，组与组之间留一段空白
                ForEach(Array(SettingsTab.sections.enumerated()), id: \.offset) { idx, sec in
                    let items = sec.tabs.filter(matches)
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { t in
                                HStack(spacing: 7) {
                                    SideIcon(symbol: t.icon, color: t.color)
                                    Text(t.title).font(.system(size: 13))
                                }
                                    .tag(t)
                            }
                        } header: {
                            if idx > 0 { Color.clear.frame(height: 8) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(200)
            .searchable(text: $query, placement: .sidebar, prompt: "搜索设置")
        } detail: {
            pane
                .navigationTitle(nav.tab.title)
        }
        // 宽度固定（就是原来的最小宽度），只允许上下拉伸
        .frame(minWidth: Self.fixedWidth, maxWidth: Self.fixedWidth, minHeight: 540)
    }

    static let fixedWidth: CGFloat = 780

    /// 侧边栏图标：和系统设置一样，彩色圆角方块 + 白色符号
    private struct SideIcon: View {
        let symbol: String
        let color: Color
        var body: some View {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
        }
    }

    @ViewBuilder private var pane: some View {
        switch nav.tab {
        case .general: GeneralPane()
        case .account: AccountPane()
        case .data: DataPane()
        case .voice: VoiceSettingsPane()
        case .mic: MicSettingsPane()
        case .widget: WidgetPane()
        case .focus: FocusPane()
        case .notify: NotifyPane()
        }
    }
}

// MARK: - 小零件（统一的页面 / 分组 / 行）

/// 一页：系统原生的「分组表单」（和系统设置同一个版式：圆角分组、细分隔线、液态玻璃跟随系统）
struct SPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Form { content }
            .formStyle(.grouped)
    }
}

/// 一组：原生 Section（小标题 + 圆角分组）。说明文字能不写就不写，让排版自己说话。
/// `trailing` 是标题行右侧的图标按钮（测试 / 刷新 / 还原…）；`result` 是操作结果，显示在分组下方。
struct SGroup<Content: View, Trailing: View>: View {
    var title: String?
    var chip: (String, Color)?
    var footer: String?
    var result: (ok: Bool, text: String)?
    var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String? = nil, chip: (String, Color)? = nil, footer: String? = nil,
         result: (ok: Bool, text: String)? = nil,
         @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title; self.chip = chip; self.footer = footer; self.result = result
        self.trailing = trailing(); self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            if title != nil || chip != nil {
                HStack(spacing: 6) {
                    if let title { Text(title) }
                    if let chip { TagChip(text: chip.0, tint: chip.1) }
                    Spacer(minLength: 8)
                    trailing
                }
            }
        } footer: {
            if result != nil || footer != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let r = result {
                        Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(r.ok ? Color.green : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let footer { Text(footer) }
                }
            }
        }
    }
}

extension SGroup where Trailing == EmptyView {
    init(_ title: String? = nil, chip: (String, Color)? = nil, footer: String? = nil,
         result: (ok: Bool, text: String)? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, chip: chip, footer: footer, result: result, trailing: { EmptyView() }, content: content)
    }
}

/// 可折叠的一组：点标题收起 / 展开，状态记在本机；收起后标题上的状态标签和图标按钮还在
struct SFoldGroup<Content: View, Trailing: View>: View {
    let title: String
    var chip: (String, Color)?
    var footer: String?
    var result: (ok: Bool, text: String)?
    var trailing: Trailing
    @ViewBuilder var content: Content
    @AppStorage private var open: Bool

    init(_ title: String, fold key: String, open: Bool = true, chip: (String, Color)? = nil, footer: String? = nil,
         result: (ok: Bool, text: String)? = nil,
         @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title; self.chip = chip; self.footer = footer; self.result = result
        self.trailing = trailing(); self.content = content()
        self._open = AppStorage(wrappedValue: open, "settings.fold." + key)
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
    }

    var body: some View {
        Section {
            if open { content }
        } header: {
            HStack(spacing: 6) {
                Button { toggle() } label: {
                    // 显式指定字体：分组收起后是空的，系统会把空分组的标题换成灰色细体
                    Text(title).font(.headline).foregroundStyle(.primary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let chip { TagChip(text: chip.0, tint: chip.1) }
                Spacer(minLength: 8)
                trailing
                // 展开 / 收起箭头统一放在标题最右侧
                Button { toggle() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "收起" : "展开")
            }
        } footer: {
            if result != nil || (open && footer != nil) {
                VStack(alignment: .leading, spacing: 4) {
                    if let r = result {
                        Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(r.ok ? Color.green : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if open, let footer { Text(footer) }
                }
            }
        }
    }
}

extension SFoldGroup where Trailing == EmptyView {
    init(_ title: String, fold key: String, open: Bool = true, chip: (String, Color)? = nil, footer: String? = nil,
         result: (ok: Bool, text: String)? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, fold: key, open: open, chip: chip, footer: footer, result: result, trailing: { EmptyView() }, content: content)
    }
}

/// 一行：左边标题（需要时加一行灰色说明），右边放控件（原生 LabeledContent，对齐方式和系统设置一致）
struct SRow<Trailing: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, hint: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.hint = hint; self.trailing = trailing()
    }

    var body: some View {
        LabeledContent {
            trailing
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let hint {
                    Text(hint).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// 开关一行
struct SToggle: View {
    let title: String
    var hint: String?
    @Binding var isOn: Bool

    init(_ title: String, _ hint: String? = nil, _ isOn: Binding<Bool>) {
        self.title = title; self.hint = hint; self._isOn = isOn
    }

    var body: some View {
        SRow(title, hint: hint) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

/// 右侧下拉：只显示当前值 + 上下箭头，所有页面右边缘对齐
struct SPick<V: Hashable>: View {
    @Binding var selection: V
    let options: [(V, String)]

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { Text(options[$0].1).tag(options[$0].0) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Text(options.first(where: { $0.0 == selection })?.1 ?? "").font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// 图标按钮（测试 / 刷新 / 打开 / 授权…）：不写字，悬停显示名称；`busy` 时换成转圈
struct SIconButton: View {
    let symbol: String
    let help: String
    var busy = false
    var disabled = false
    let action: () -> Void

    init(symbol: String, help: String, busy: Bool = false, disabled: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol; self.help = help; self.busy = busy; self.disabled = disabled; self.action = action
    }

    var body: some View {
        Group {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button(action: action) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(disabled)
            }
        }
        .frame(width: 22, height: 20)
        .help(help)
    }
}

/// 点一下去别处的行（词库、识别历史…）：右边一个小箭头，和系统设置里的跳转行一样
struct SLinkRow: View {
    let title: String
    var hint: String?
    var symbol = "chevron.right"
    let action: () -> Void

    init(_ title: String, hint: String? = nil, symbol: String = "chevron.right", action: @escaping () -> Void) {
        self.title = title; self.hint = hint; self.symbol = symbol; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let hint {
                        Text(hint).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 密钥输入：默认遮住，右边的眼睛可以看；回车 / 离开输入框时触发 onCommit（自动保存）
struct SecretField: View {
    let placeholder: String
    @Binding var text: String
    var onCommit: (() -> Void)?
    @State private var reveal = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if reveal { TextField("", text: $text, prompt: Text(placeholder)) } else { SecureField("", text: $text, prompt: Text(placeholder)) }
            }
            .labelsHidden()
            .textFieldStyle(.plain).multilineTextAlignment(.trailing)
            .font(.system(size: 12.5).monospaced())
            .frame(width: 260)
            .focused($focused)
            .onSubmit { onCommit?() }
            .onChange(of: focused) { _, f in if !f { onCommit?() } }
            Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye").frame(width: 16) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(reveal ? "隐藏" : "显示")
        }
    }
}

/// 输入框（右侧，固定宽度）
struct SText: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = 282
    var onCommit: (() -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder))
            .labelsHidden()
            .textFieldStyle(.plain).multilineTextAlignment(.trailing)
            .font(.system(size: 12.5).monospaced())
            .frame(width: width)
            .focused($focused)
            .onSubmit { onCommit?() }
            .onChange(of: focused) { _, f in if !f { onCommit?() } }
    }
}

// MARK: - 账号

private struct AccountPane: View {
    @EnvironmentObject var model: AppModel
    @State private var saving = false
    @State private var sjzTesting = false
    @State private var sjzResult: (ok: Bool, text: String)?
    @State private var tencentId = ""
    @State private var tencentKey = ""
    @State private var llmTesting = false
    @State private var llmResult: (ok: Bool, text: String)?

    private static func isLoopback(_ endpoint: String) -> Bool {
        guard let host = URL(string: endpoint.trimmed)?.host?.lowercased() else { return true }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private var tencentReady: Bool { !tencentId.trimmed.isEmpty && !tencentKey.trimmed.isEmpty }

    var body: some View {
        SPage {
            SFoldGroup("闪念贝壳", fold: "ideashell",
                   chip: saving ? ("保存中…", .gray) : (model.hasIdeashell ? ("已连接", .green) : ("未填写", .orange))) {
                SRow("API Key") { SecretField(placeholder: "API Key", text: $model.ideashellKeyInput, onCommit: commitCredentials) }
            }

            SFoldGroup("滴答清单", fold: "dida",
                   chip: saving ? ("保存中…", .gray) : (model.hasDida ? ("已连接", .green) : ("未填写", .orange))) {
                SRow("API 口令") { SecretField(placeholder: "API 口令", text: $model.didaTokenInput, onCommit: commitCredentials) }
            }

            SFoldGroup("腾讯云", fold: "tencent", open: false,
                   chip: tencentReady ? ("已填写", .green) : ("未填写", .gray)) {
                SRow("SecretId") { SText(placeholder: "AKID…", text: $tencentId, onCommit: commitTencent) }
                SRow("SecretKey") { SecretField(placeholder: "", text: $tencentKey, onCommit: commitTencent) }
            }

            SFoldGroup("AI 模型", fold: "llm", chip: model.hasLlm ? ("已配置", .green) : ("未填写", .orange),
                   result: llmResult,
                   trailing: {
                       SIconButton(symbol: "bolt.horizontal", help: "测试连接", busy: llmTesting,
                                   disabled: model.llmKeyInput.trimmed.isEmpty, action: testLlm)
                   }) {
                SRow("常用服务") {
                    Menu {
                        ForEach(LlmClient.presets, id: \.name) { p in
                            Button(p.name) { model.llmBaseUrl = p.url; model.llmModel = p.model; commitLlm() }
                        }
                    } label: { Text("选择…").font(.system(size: 13)) }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                SRow("接口地址") { SText(placeholder: "https://…/v1", text: $model.llmBaseUrl, onCommit: commitLlm) }
                SRow("模型名") { SText(placeholder: "qwen-plus", text: $model.llmModel, onCommit: commitLlm) }
                SRow("API Key") { SecretField(placeholder: "sk-…", text: $model.llmKeyInput, onCommit: commitLlm) }
            }

            SFoldGroup("结审", fold: "sjz", open: false,
                   chip: model.sjzEnabled ? (model.hasSjz ? "已连接" : "未填写", model.hasSjz ? .green : .orange) : nil,
                   footer: "所有密钥只保存在本机（系统钥匙串），不会上传",
                   result: model.sjzEnabled ? sjzResult : nil,
                   trailing: {
                       if model.sjzEnabled {
                           SIconButton(symbol: "bolt.horizontal", help: "测试连接", busy: sjzTesting,
                                       disabled: model.sjzKeyInput.trimmed.isEmpty, action: testSjz)
                       }
                   }) {
                SToggle("启用结审", nil, $model.sjzEnabled)
                if model.sjzEnabled {
                    SRow("API Key") { SecretField(placeholder: "sjz_…", text: $model.sjzKeyInput, onCommit: commitSjz) }
                    SRow("服务地址", hint: Self.isLoopback(model.sjzEndpoint) ? nil : "不是本机地址，审计数据会经网络传输，建议用 127.0.0.1") {
                        SText(placeholder: SjzApi.defaultEndpoint, text: $model.sjzEndpoint, onCommit: commitSjz)
                    }
                    SRow("钉住项目") {
                        Picker("", selection: Binding(
                            get: { model.sjzPin.project },
                            set: { name in Task { await model.sjzSetProject(name) } }
                        )) {
                            if model.sjzPin.project.isEmpty { Text("未钉住").tag("") }
                            ForEach(model.sjzProjects, id: \.name) { Text($0.title).tag($0.name) }
                            if !model.sjzPin.project.isEmpty, !model.sjzProjects.contains(where: { $0.name == model.sjzPin.project }) {
                                Text(model.sjzPin.projectTitle.isEmpty ? model.sjzPin.project : model.sjzPin.projectTitle).tag(model.sjzPin.project)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                        .disabled(!model.hasSjz)
                    }
                }
            }
        }
        .onAppear {
            tencentId = model.credentials.tencentId
            tencentKey = model.credentials.tencentKey
        }
        .onDisappear { commitCredentials(); commitTencent(); commitSjz(); model.saveLlm() }
        .task { if model.hasSjz { await model.refreshSjzTarget(); await model.refreshSjzProjects() } }
    }

    private func testSjz() {
        sjzTesting = true
        sjzResult = nil
        Task {
            await model.saveSjz()
            do {
                let r = try await model.sjz.listProjects()
                sjzResult = (true, "连接正常，\(r.projects.count) 个项目")
            } catch {
                sjzResult = (false, error.localizedDescription)
            }
            sjzTesting = false
        }
    }

    private func testLlm() {
        model.saveLlm()
        llmTesting = true
        llmResult = nil
        Task {
            do {
                let r = try await model.llm.chatJSON(system: "只输出 JSON 对象：{\"ok\":true}", user: "ping", timeout: 20)
                llmResult = (true, "连接正常" + (r.isEmpty ? "" : "（模型 \(model.llmModel)）"))
            } catch {
                llmResult = (false, error.localizedDescription)
            }
            llmTesting = false
        }
    }

    private func commitLlm() {
        model.saveLlm()
        llmResult = nil
    }

    // 输入框回车 / 离开时自动保存（没改动就不动）

    private func commitCredentials() {
        guard !saving,
              model.ideashellKeyInput.trimmed != model.credentials.ideashellKey
                || model.didaTokenInput.trimmed != model.credentials.didaToken else { return }
        saving = true
        Task { await model.saveCredentials(); saving = false }
    }

    private func commitTencent() {
        guard tencentId.trimmed != model.credentials.tencentId || tencentKey.trimmed != model.credentials.tencentKey else { return }
        model.credentials.setTencent(id: tencentId.trimmed, key: tencentKey.trimmed)
    }

    private func commitSjz() {
        let savedEndpoint = UserDefaults.standard.string(forKey: SjzApi.endpointKey) ?? SjzApi.defaultEndpoint
        let endpoint = model.sjzEndpoint.trimmed.isEmpty ? SjzApi.defaultEndpoint : model.sjzEndpoint.trimmed
        guard model.sjzKeyInput.trimmed != model.credentials.sjzKey || endpoint != savedEndpoint else { return }
        Task { await model.saveSjz() }
    }
}

// MARK: - 小组件（灵动岛 / 菜单栏）

private struct WidgetPane: View {
    @AppStorage(DisplayMode.key) private var displayMode: DisplayMode = .menuBar
    @AppStorage(DisplayMode.hoverKey) private var hover = true
    @AppStorage(DisplayMode.swipeKey) private var swipe = true
    @AppStorage(DisplayMode.captureKey) private var capture = true
    @AppStorage(DisplayMode.activityKey) private var activities = true
    @AppStorage(DisplayMode.shelfKey) private var shelf = true
    @AppStorage(ImageOCR.key) private var ocrOn = true

    var body: some View {
        SPage {
            SGroup("显示方式") {
                HStack(spacing: 10) {
                    ForEach(DisplayMode.allCases) { tile($0) }
                }
            }

            if displayMode == .island {
                SGroup("展开方式") {
                    SToggle("悬停展开", nil, $hover)
                    SToggle("触控板下滑展开", nil, $swipe)
                }

                SGroup("功能") {
                    SToggle("截图提示", nil, $capture)
                    SToggle("识别截图里的文字", nil, $ocrOn)
                    SToggle("暂存架", nil, $shelf)
                    SToggle("状态提醒", nil, $activities)
                }
            }
        }
    }

    private func tile(_ m: DisplayMode) -> some View {
        let on = displayMode == m
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button { displayMode = m } label: {
            VStack(spacing: 4) {
                Image(systemName: m.icon).font(.system(size: 18)).foregroundStyle(on ? Color.accentColor : Color.secondary)
                Text(m.title).font(.system(size: 12.5, weight: .semibold))
                Text(m.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12).padding(.horizontal, 8)
            .background(on ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05), in: shape)
            .overlay(shape.stroke(on ? Color.accentColor : Color.primary.opacity(0.07), lineWidth: on ? 1.5 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 通用

private struct GeneralPane: View {
    @AppStorage(AppTheme.key) private var theme: AppTheme = .system
    @AppStorage(BackgroundPrefs.hideDockKey) private var hideDock = false
    @AppStorage(DisplayMode.key) private var displayMode: DisplayMode = .menuBar
    @AppStorage(VoiceHotkey.key) private var voiceHotkey: VoiceHotkey = .ctrlOptV
    @AppStorage(VoiceSettings.modeKey) private var voiceMode: VoiceMode = .toggle
    @ObservedObject private var shortcuts = AppShortcutStore.shared

    var body: some View {
        SPage {
            SGroup("外观") {
                SRow("主题") {
                    SPick(selection: $theme, options: AppTheme.allCases.map { ($0, $0.title) })
                }
            }

            SGroup("后台运行") {
                SToggle("关闭窗口后隐藏 Dock 图标", nil, $hideDock)
            }

            // 全局快捷键：在任何 App 里都能用（必须带 ⌃ 或 ⌥）
            SGroup("全局快捷键") {
                QuickAddHotkeyRow()
                if displayMode == .island { IslandHotkeyRow() }
                VoiceHotkeyRow()
                if voiceHotkey.modifierKey == nil {
                    SRow("语音触发方式") {
                        SPick(selection: $voiceMode, options: VoiceMode.allCases.map { ($0, $0.label) })
                    }
                }
            }

            // 应用内快捷键：拾忆在前台时用，出现在屏幕顶部的菜单里
            SGroup("应用内快捷键", trailing: {
                if shortcuts.hasAnyCustom {
                    SIconButton(symbol: "arrow.counterclockwise", help: "全部还原为默认") { shortcuts.resetAll() }
                }
            }) {
                ForEach(AppShortcutID.actions) { AppShortcutRow(id: $0) }
            }

            SGroup("切换页面") {
                ForEach(AppShortcutID.pages) { AppShortcutRow(id: $0) }
            }
        }
    }
}

// MARK: - 专注

private struct FocusPane: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(TicketController.enabledKey) private var ticketOn = true
    @AppStorage(TicketController.soundKey) private var ticketSound = true

    private var goalText: String {
        let m = model.focusGoalMin
        return m < 60 ? "\(m) 分钟" : (m % 60 == 0 ? "\(m / 60) 小时" : "\(m / 60) 小时 \(m % 60) 分钟")
    }

    var body: some View {
        SPage {
            SGroup("目标") {
                SRow("每日专注目标") {
                    HStack(spacing: 8) {
                        Text(goalText).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                        Stepper("", value: $model.focusGoalMin, in: 10 ... 720, step: 10).labelsHidden()
                    }
                }
            }

            SGroup("成果小票") {
                SToggle("完成后打印成果小票", nil, $ticketOn)
                if ticketOn {
                    SToggle("出纸提示音", nil, $ticketSound)
                }
            }
        }
    }
}

// MARK: - 通知

private struct NotifyPane: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("notify.focus") private var nFocus = true
    @AppStorage("notify.goal") private var nGoal = true
    @AppStorage("notify.due") private var nDue = true
    @AppStorage("notify.lead") private var nLead = 10
    @AppStorage("notify.digest") private var nDigest = true
    @AppStorage("notify.overdue") private var nOverdue = true
    @AppStorage("notify.sjz") private var nSjz = true
    @AppStorage("sjz.summary") private var nSjzSummary = true

    var body: some View {
        SPage {
            SGroup("专注", trailing: {
                SIconButton(symbol: "bell.badge", help: "发送测试通知") { Notifier.shared.sendTest() }
            }) {
                SToggle("专注与休息", nil, $nFocus)
                SToggle("专注目标达成", nil, $nGoal)
            }

            SGroup("待办") {
                SToggle("待办到点", nil, $nDue)
                if nDue {
                    SRow("提前提醒") {
                        SPick(selection: $nLead, options: [(0, "不提前"), (5, "5 分钟"), (10, "10 分钟"), (15, "15 分钟"), (30, "30 分钟")])
                    }
                }
                SToggle("早晚简报", nil, $nDigest)
                SToggle("逾期提醒", nil, $nOverdue)
            }

            if model.hasSjz {
                SGroup("结审") {
                    SToggle("结审提醒", nil, $nSjz)
                    SToggle("每晚工作小结", nil, $nSjzSummary)
                }
            }

        }
        .onChange(of: nDue) { _, _ in Notifier.shared.syncTodos(model.overview) }
        .onChange(of: nLead) { _, _ in Notifier.shared.syncTodos(model.overview) }
        .onChange(of: nDigest) { _, _ in Notifier.shared.syncTodos(model.overview) }
        .onChange(of: nOverdue) { _, _ in Notifier.shared.syncTodos(model.overview) }
    }
}

// MARK: - 数据与备份

private struct DataPane: View {
    @EnvironmentObject var model: AppModel
    @State private var transferResult: (ok: Bool, text: String)?

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.title = "导出设置"
        panel.nameFieldStringValue = "拾忆设置.plist"
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let n = try SettingsTransfer.export(to: url)
            transferResult = (true, "已导出 \(n) 项设置（不含密钥）")
        } catch {
            transferResult = (false, "导出失败：\(error.localizedDescription)")
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "导入设置"
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let n = try SettingsTransfer.import(from: url)
            transferResult = (true, "已导入 \(n) 项设置，部分设置重启拾忆后生效")
        } catch {
            transferResult = (false, "导入失败：\(error.localizedDescription)")
        }
    }

    /// 只在本机、还没进手机备份的任务笔记数
    private var localOnlyCount: Int {
        let remote = model.backup?.workspace.taskNotes ?? [:]
        return model.localTaskNotes.keys.filter { remote[$0] == nil }.count
    }

    var body: some View {
        SPage {
            SGroup("手机备份", trailing: {
                SIconButton(symbol: "arrow.clockwise", help: "重新读取备份", busy: model.backupLoading,
                            disabled: !model.hasIdeashell) { Task { await model.loadBackup() } }
            }) {
                if let b = model.backup {
                    stat("项目", "\(b.workspace.projects.count)")
                    stat("任务笔记", "\(b.workspace.taskNotes.count + localOnlyCount)")
                    stat("专注记录", "\(b.workspace.focusLog.count)")
                    if let d = b.exportedDate {
                        stat("导出于", d.formatted(date: .abbreviated, time: .shortened))
                    }
                } else {
                    Label("还没有读到备份", systemImage: "tray").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                if let e = model.backupError { ErrorBanner(text: e) }
            }

            SGroup("设置迁移", result: transferResult) {
                SLinkRow("导出设置…", symbol: "square.and.arrow.up") { exportSettings() }
                SLinkRow("导入设置…", symbol: "square.and.arrow.down") { importSettings() }
            }

            SGroup("本机数据") {
                SRow("位置") {
                    HStack(spacing: 8) {
                        Text(LocalStore.dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        SIconButton(symbol: "folder", help: "在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([LocalStore.dir]) }
                    }
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        SRow(title) { Text(value).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary) }
    }
}
