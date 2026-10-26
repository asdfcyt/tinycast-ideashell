import AppKit
import SwiftUI

// MARK: - 设置窗口

/// 设置的分类：左侧导航，一类一页
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, account, ai, data, voice, lexicon, widget, focus, notify

    var id: String { rawValue }

    /// 侧边栏的分组
    static let sections: [(title: String, tabs: [SettingsTab])] = [
        ("通用", [.general, .account, .ai, .data]),
        ("功能", [.voice, .lexicon, .widget, .focus, .notify]),
    ]

    var title: String {
        switch self {
        case .general: return "通用"
        case .account: return "账号"
        case .ai: return "AI 模型"
        case .data: return "数据与备份"
        case .voice: return "语音输入"
        case .lexicon: return "词库"
        case .widget: return "小组件"
        case .focus: return "专注"
        case .notify: return "通知"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .account: return "person.crop.circle.fill"
        case .ai: return "sparkles"
        case .data: return "externaldrive.fill"
        case .voice: return "mic.fill"
        case .lexicon: return "text.book.closed.fill"
        case .widget: return "capsule.portrait.fill"
        case .focus: return "timer"
        case .notify: return "bell.badge.fill"
        }
    }

    /// 搜索用的关键词
    var keywords: String {
        switch self {
        case .general: return "外观 主题 暗黑 明亮 dock 后台 快捷键 万能输入"
        case .account: return "闪念贝壳 滴答清单 结审 腾讯云 secretid secretkey api key 口令 连接 账号 凭证"
        case .ai: return "ai 模型 大模型 接口 openai 通义 deepseek key 测试连接"
        case .data: return "备份 手机 本机 数据 目录 finder"
        case .voice: return "语音 快捷键 识别 引擎 腾讯云 option 录音 听写 麦克风 权限 历史"
        case .lexicon: return "词库 热词 替换 纠错 同音字 专有名词 人名"
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
            List(selection: Binding<SettingsTab?>(get: { nav.tab }, set: { if let v = $0 { nav.tab = v } })) {
                ForEach(SettingsTab.sections, id: \.title) { sec in
                    let items = sec.tabs.filter(matches)
                    if !items.isEmpty {
                        Section(sec.title) {
                            ForEach(items) { t in
                                Label {
                                    Text(t.title)
                                } icon: {
                                    SideIcon(symbol: t.icon, selected: nav.tab == t)
                                }
                                .font(.system(size: 13))
                                .tag(t)
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 210)
            .searchable(text: $query, placement: .sidebar, prompt: "搜索设置")
        } detail: {
            pane
                .navigationTitle(nav.tab.title)
        }
        .frame(minWidth: 780, minHeight: 540)
    }

    /// 侧边栏图标：淡蓝底 + 蓝色符号，选中时变成白色
    private struct SideIcon: View {
        let symbol: String
        let selected: Bool
        var body: some View {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.accentColor)
                .frame(width: 17, height: 17)
                .background(selected ? Color.white.opacity(0.22) : Color.accentColor.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
        }
    }

    @ViewBuilder private var pane: some View {
        switch nav.tab {
        case .general: GeneralPane()
        case .account: AccountPane()
        case .ai: AIPane()
        case .data: DataPane()
        case .voice: VoiceSettingsPane()
        case .lexicon: LexiconPane()
        case .widget: WidgetPane()
        case .focus: FocusPane()
        case .notify: NotifyPane()
        }
    }
}

// MARK: - 小零件（统一的页面 / 分组 / 行）

/// 一页：可滚动，内容限宽居中
struct SPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .padding(.horizontal, 28).padding(.vertical, 20)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}

/// 一组：小标题 + 圆角底板（行与行之间自动加细分隔线）+ 底部说明
struct SGroup<Content: View>: View {
    var title: String?
    var chip: (String, Color)?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, chip: (String, Color)? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.chip = chip; self.footer = footer; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
                    if let chip { TagChip(text: chip.0, tint: chip.1) }
                }
                .padding(.leading, 4)
            }
            _VariadicView.Tree(SDividedRoot()) { content }
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
            if let footer {
                Text(footer).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

private struct SDividedRoot: _VariadicView_MultiViewRoot {
    @ViewBuilder func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                child
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if child.id != last { Divider().opacity(0.6).padding(.leading, 12) }
            }
        }
    }
}

/// 一行：左边标题 + 灰色说明，右边放控件
struct SRow<Trailing: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, hint: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.hint = hint; self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let hint {
                    Text(hint).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
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
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
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

/// 行内的小按钮（测试 / 打开 / 前往…）：次要样式，不抢眼
struct SAction: View {
    let title: String
    var systemImage: String?
    var disabled = false
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.disabled = disabled; self.action = action
    }

    var body: some View {
        Button(action: action) {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(disabled)
    }
}

/// 「一件事 + 右边一个小按钮」的行；结果（成功 / 失败）直接显示在左边说明处
struct SActionRow: View {
    let title: String
    var hint: String?
    let button: String
    var busy = false
    var result: (ok: Bool, text: String)?
    var disabled = false
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let r = result {
                    Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5)).foregroundStyle(r.ok ? Color.green : Color.orange)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                } else if let hint {
                    Text(hint).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if busy { ProgressView().controlSize(.small) }
            SAction(button, disabled: disabled || busy, action: action)
        }
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
                if reveal { TextField(placeholder, text: $text) } else { SecureField(placeholder, text: $text) }
            }
            .textFieldStyle(.roundedBorder).font(.system(size: 12.5).monospaced())
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
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder).font(.system(size: 12.5).monospaced())
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

    private static func isLoopback(_ endpoint: String) -> Bool {
        guard let host = URL(string: endpoint.trimmed)?.host?.lowercased() else { return true }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private var tencentReady: Bool { !tencentId.trimmed.isEmpty && !tencentKey.trimmed.isEmpty }

    var body: some View {
        SPage {
            SGroup("闪念贝壳",
                   chip: saving ? ("保存中…", .gray) : (model.hasIdeashell ? ("已连接", .green) : ("未填写", .orange)),
                   footer: "在闪念贝壳 App 的「设置 → API / MCP」里创建。用于读写笔记、读取手机备份。填完离开输入框即自动保存。") {
                SRow("API Key") { SecretField(placeholder: "API Key", text: $model.ideashellKeyInput, onCommit: commitCredentials) }
            }

            SGroup("滴答清单",
                   chip: saving ? ("保存中…", .gray) : (model.hasDida ? ("已连接", .green) : ("未填写", .orange)),
                   footer: "在滴答清单「设置 → 账户 → API 口令」里创建。用于读写待办和专注。") {
                SRow("API 口令") { SecretField(placeholder: "API 口令", text: $model.didaTokenInput, onCommit: commitCredentials) }
            }

            SGroup("腾讯云",
                   chip: tencentReady ? ("已填写", .green) : ("未填写", .gray),
                   footer: "语音输入选「腾讯云」识别引擎时使用，在腾讯云控制台「访问管理 → API 密钥」创建。录音会上传到腾讯云。") {
                SRow("SecretId") { SText(placeholder: "AKID…", text: $tencentId, onCommit: commitTencent) }
                SRow("SecretKey") { SecretField(placeholder: "", text: $tencentKey, onCommit: commitTencent) }
            }

            SGroup("结审（审计工作台）",
                   chip: model.sjzEnabled ? (model.hasSjz ? "已连接" : "未填写", model.hasSjz ? .green : .orange) : nil,
                   footer: model.sjzEnabled
                       ? "Key 在结审「设置 → 外部应用」里生成；保存证据、法规、记线索、回写任务还需在那里开启「允许写入」。结审的任务、专注和记录只存在结审与本机，不会写入滴答清单或闪念贝壳。"
                       : nil) {
                SToggle("启用结审",
                        model.sjzEnabled ? "把截图、文字、链接存为证据 / 法规 / 线索，并在待办里显示结审任务"
                                         : "已关闭：岛上不显示结审区，待办不合并结审任务，也不弹结审提醒",
                        $model.sjzEnabled)
                if model.sjzEnabled {
                    SRow("API Key") { SecretField(placeholder: "sjz_…", text: $model.sjzKeyInput, onCommit: commitSjz) }
                    SRow("服务地址", hint: Self.isLoopback(model.sjzEndpoint) ? nil : "不是本机地址，审计数据会经网络传输，建议用 127.0.0.1") {
                        SText(placeholder: SjzApi.defaultEndpoint, text: $model.sjzEndpoint, onCommit: commitSjz)
                    }
                    SActionRow(title: "连接测试", hint: "检查 Key 和服务地址是否可用", button: "测试",
                               busy: sjzTesting, result: sjzResult, disabled: model.sjzKeyInput.trimmed.isEmpty) {
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
                    SRow("钉住项目", hint: "灵动岛保存的证据、法规、线索都放进这个项目") {
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

            Label("所有密钥只保存在本机，仅当前用户可读", systemImage: "lock.fill")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
        }
        .onAppear {
            tencentId = model.credentials.tencentId
            tencentKey = model.credentials.tencentKey
        }
        .onDisappear { commitCredentials(); commitTencent(); commitSjz() }
        .task { if model.hasSjz { await model.refreshSjzTarget(); await model.refreshSjzProjects() } }
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

// MARK: - AI 模型

private struct AIPane: View {
    @EnvironmentObject var model: AppModel
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    var body: some View {
        SPage {
            SGroup("接口", chip: model.hasLlm ? ("已配置", .green) : ("未填写", .orange),
                   footer: "支持任何 OpenAI 兼容的接口（通义千问、DeepSeek、OpenAI、智谱等）。用于「重新规划」的 AI 排期和语音输入的整理；填完离开输入框即自动保存，Key 只保存在本机。") {
                SRow("常用服务", hint: "一键填入接口地址和模型名") {
                    Menu {
                        ForEach(LlmClient.presets, id: \.name) { p in
                            Button(p.name) { model.llmBaseUrl = p.url; model.llmModel = p.model; commit() }
                        }
                    } label: { Text("选择…").font(.system(size: 13)) }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                SRow("接口地址") { SText(placeholder: "https://…/v1", text: $model.llmBaseUrl, onCommit: commit) }
                SRow("模型名") { SText(placeholder: "qwen-plus", text: $model.llmModel, onCommit: commit) }
                SRow("API Key") { SecretField(placeholder: "sk-…", text: $model.llmKeyInput, onCommit: commit) }
                SActionRow(title: "连接测试", hint: "发一条请求，检查地址、模型和 Key 是否可用", button: "测试",
                           busy: testing, result: testResult, disabled: model.llmKeyInput.trimmed.isEmpty) {
                    model.saveLlm()
                    testing = true
                    testResult = nil
                    Task {
                        do {
                            let r = try await model.llm.chatJSON(system: "只输出 JSON 对象：{\"ok\":true}", user: "ping", timeout: 20)
                            testResult = (true, "连接正常" + (r.isEmpty ? "" : "（模型 \(model.llmModel)）"))
                        } catch {
                            testResult = (false, error.localizedDescription)
                        }
                        testing = false
                    }
                }
            }
        }
        .onDisappear { commit() }
    }

    private func commit() {
        model.saveLlm()
        testResult = nil
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
    @AppStorage(DisplayMode.hotkeyKey) private var hotkey: IslandHotkey = .optSpace
    @AppStorage(ImageOCR.key) private var ocrOn = true

    var body: some View {
        SPage {
            VStack(alignment: .leading, spacing: 6) {
                Text("显示方式").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                HStack(spacing: 10) {
                    ForEach(DisplayMode.allCases) { tile($0) }
                }
                Text(displayMode == .island
                     ? "灵动岛里是和菜单栏弹窗一样的待办、专注小组件，底部可选暂存架；平时在刘海两侧显示「今天 · 逾期」或专注进度。把截图、链接、文字拖到刘海：左半边保存（自动识别），右半边暂存。展开后 ⌘V 粘贴保存、⌘⇧V 粘贴暂存，Esc 或点击别处收起。"
                     : "菜单栏图标显示「今天 · 逾期」或专注倒计时，点击弹出待办小组件。")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }

            if displayMode == .island {
                SGroup("展开方式") {
                    SToggle("悬停展开", "鼠标移到刘海（没有刘海的屏幕是顶部小条）上就展开", $hover)
                    SToggle("触控板下滑展开", "在刘海上双指下滑展开；展开后在顶部一条上上滑收起", $swipe)
                    SRow("全局快捷键", hint: "在任何 App 里按下即可展开 / 收起") {
                        SPick(selection: $hotkey, options: IslandHotkey.allCases.map { ($0, $0.label) })
                    }
                }

                SGroup("功能") {
                    SToggle("截图提示", "刚截了图（或剪贴板里有新图片）时岛自动弹出，一键存为笔记、暂存，或拖走", $capture)
                    SToggle("识别截图里的文字", "保存截图为笔记时，用系统文字识别（本机完成，图片不外传）把图里的字附在后面，之后能搜到", $ocrOn)
                    SToggle("暂存架", "展开页底部的暂存区，以及拖放时的「暂存」半边", $shelf)
                    SToggle("状态提醒", "番茄 / 休息结束、待办到点时岛自动弹出，可直接完成、专注或推迟", $activities)
                }
            }
        }
    }

    private func tile(_ m: DisplayMode) -> some View {
        let on = displayMode == m
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button { displayMode = m } label: {
            VStack(spacing: 4) {
                Image(systemName: m.icon).font(.system(size: 18)).foregroundStyle(on ? Brand.orange : Color.secondary)
                Text(m.title).font(.system(size: 12.5, weight: .semibold))
                Text(m.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12).padding(.horizontal, 8)
            .background(on ? Brand.orange.opacity(0.12) : Color.primary.opacity(0.05), in: shape)
            .overlay(shape.stroke(on ? Brand.orange : Color.primary.opacity(0.07), lineWidth: on ? 1.5 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 通用

private struct GeneralPane: View {
    @AppStorage(AppTheme.key) private var theme: AppTheme = .system
    @AppStorage(BackgroundPrefs.hideDockKey) private var hideDock = false

    var body: some View {
        SPage {
            SGroup("外观") {
                SRow("主题", hint: "明亮、暗黑，或跟随系统自动切换") {
                    SPick(selection: $theme, options: AppTheme.allCases.map { ($0, $0.title) })
                }
            }

            SGroup("后台运行",
                   footer: "关掉主窗口后拾忆一直在后台运行：专注计时、提醒、灵动岛 / 菜单栏都照常。要回到窗口，点菜单栏图标或灵动岛上的「打开」。完全退出请按 ⌘Q。") {
                SToggle("关闭窗口后隐藏 Dock 图标", nil, $hideDock)
            }

            SGroup("快捷键") {
                shortcut("⌘ N", "万能输入：写笔记 / 记待办，自动识别")
                shortcut("⇧⌘ N / ⇧⌘ T / ⇧⌘ D", "直接记笔记 / 待办 / 日记")
                shortcut("⌘ R", "刷新当前页")
                shortcut("⌘ ,", "打开设置")
                shortcut("⌘ 1 – 6", "切换页面（今天 / 行动 / 待办 / 日历 / 回顾 / 洞察）")
                QuickAddHotkeyRow()
            }
        }
    }

    private func shortcut(_ keys: String, _ text: String) -> some View {
        SRow(text) {
            Text(keys)
                .font(.system(size: 12, design: .monospaced).weight(.medium))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
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
            SGroup("目标", footer: "「今天」页的专注环以它为满环。") {
                SRow("每日专注目标") {
                    HStack(spacing: 8) {
                        Text(goalText).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                        Stepper("", value: $model.focusGoalMin, in: 10 ... 720, step: 10).labelsHidden()
                    }
                }
            }

            SGroup("成果小票") {
                SToggle("完成后打印成果小票",
                        "完成（或提前结束）一个番茄后，从屏幕顶部「打印」出一张小票：时长、任务、期间的记录、今日累计",
                        $ticketOn)
                if ticketOn {
                    SToggle("出纸提示音", "出纸时轻轻响一声", $ticketSound)
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
            SGroup("专注") {
                SToggle("专注与休息", "番茄完成、休息结束、还剩 5 分钟、暂停太久", $nFocus)
                SToggle("专注目标达成", "今天的专注时长第一次达到每日目标", $nGoal)
            }

            SGroup("待办") {
                SToggle("待办到点", "有具体时间的待办，到点提醒", $nDue)
                if nDue {
                    SRow("提前提醒") {
                        SPick(selection: $nLead, options: [(0, "不提前"), (5, "5 分钟"), (10, "10 分钟"), (15, "15 分钟"), (30, "30 分钟")])
                    }
                }
                SToggle("早晚简报", "早上 8:30 今天的安排，晚上 9:00 还没完成的几件", $nDigest)
                SToggle("逾期提醒", "每天 10:00 提醒还有几件逾期", $nOverdue)
            }

            if model.hasSjz {
                SGroup("结审") {
                    SToggle("结审提醒", "调研完成、任务到期或逾期、待复核、线索久未跟进、取证单缺证据时，灵动岛弹出提醒", $nSjz)
                    SToggle("每晚工作小结", "21 点后把当天写入的证据 / 法规 / 线索、专注时长和完成任务写进结审项目的工作日志", $nSjzSummary)
                }
            }

            SGroup("测试", footer: "待办提醒在待办刷新后重新安排，退出拾忆后也会按时响。收不到时，请在「系统设置 → 通知」里允许拾忆。") {
                SActionRow(title: "发送测试通知", hint: "立刻弹一条，确认能收到", button: "发送") { Notifier.shared.sendTest() }
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

    /// 只在本机、还没进手机备份的任务笔记数
    private var localOnlyCount: Int {
        let remote = model.backup?.workspace.taskNotes ?? [:]
        return model.localTaskNotes.keys.filter { remote[$0] == nil }.count
    }

    var body: some View {
        SPage {
            SGroup("手机备份",
                   footer: "项目、任务笔记的对应关系来自手机在闪念贝壳里的「拾忆备份（请勿删除）」笔记，Mac 端只读取；在 Mac 上新建的任务笔记会记在本机，并把链接写回滴答任务。") {
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
                SActionRow(title: "重新读取", hint: "从闪念贝壳读取手机最新的备份", button: "读取",
                           busy: model.backupLoading, disabled: !model.hasIdeashell) { Task { await model.loadBackup() } }
            }

            SGroup("本机数据",
                   footer: "凭证、备份缓存、本机新建的任务笔记都存在这里；笔记和待办本身保存在闪念贝壳和滴答清单，不会存在这里。") {
                SRow("位置") {
                    Text(LocalStore.dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                SActionRow(title: "在 Finder 中显示", button: "显示") { NSWorkspace.shared.activateFileViewerSelecting([LocalStore.dir]) }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        SRow(title) { Text(value).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary) }
    }
}
