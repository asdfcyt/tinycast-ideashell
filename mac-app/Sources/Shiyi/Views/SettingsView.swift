import AppKit
import SwiftUI

/// 设置：连接账号、手机备份、本机数据。卡片式排布，和其他页面保持同一套玻璃风格。
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var saving = false
    @State private var showIdeashell = false
    @State private var showDida = false
    @State private var showLlm = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var showSjz = false
    @State private var sjzTesting = false
    @State private var sjzResult: (ok: Bool, text: String)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("设置").font(.largeTitle.bold())

                accountsCard
                sjzCard
                displayCard
                appearanceCard
                aiCard
                focusCard
                notifyCard
                backupCard
                dataCard
                shortcutsCard
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(AmbientBackground())
    }

    // MARK: - 账号

    private var accountsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(text: "账号连接")

                credentialRow(
                    icon: "tray.full", tint: Brand.orange,
                    name: "闪念贝壳", connected: model.hasIdeashell,
                    placeholder: "API Key", text: $model.ideashellKeyInput, reveal: $showIdeashell,
                    hint: "在闪念贝壳 App 的「设置 → API / MCP」里创建。用于读写笔记、读取手机备份。"
                )

                Divider()

                credentialRow(
                    icon: "checklist", tint: .blue,
                    name: "滴答清单", connected: model.hasDida,
                    placeholder: "API 口令", text: $model.didaTokenInput, reveal: $showDida,
                    hint: "在滴答清单「设置 → 账户 → API 口令」里创建。用于读写待办和专注。"
                )

                HStack(spacing: 10) {
                    Button {
                        saving = true
                        Task { await model.saveCredentials(); saving = false }
                    } label: {
                        Text("保存并刷新").frame(minWidth: 70)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.orange)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
                    if saving { ProgressView().controlSize(.small) }
                    Spacer()
                    Label("只保存在本机，仅当前用户可读", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - 结审

    private var sjzCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.indigo)
                        .frame(width: 30, height: 30)
                        .background(Color.indigo.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text("结审（审计工作台）").font(.headline)
                            if model.sjzEnabled { TagChip(text: model.hasSjz ? "已连接" : "未填写", tint: model.hasSjz ? .green : .orange) }
                        }
                        Text(model.sjzEnabled
                             ? "把截图、文字、链接存为结审的证据 / 法规 / 线索，并在待办里显示结审任务"
                             : "已关闭：岛上不显示结审区，待办不合并结审任务，也不弹结审提醒")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: $model.sjzEnabled).toggleStyle(.switch).controlSize(.small).labelsHidden()
                }

                if model.sjzEnabled {
                    Divider()
                    sjzField("API Key") {
                        HStack(spacing: 6) {
                            Group {
                                if showSjz { TextField("sjz_…", text: $model.sjzKeyInput) } else { SecureField("sjz_…", text: $model.sjzKeyInput) }
                            }
                            .textFieldStyle(.roundedBorder).font(.body.monospaced())
                            Button { showSjz.toggle() } label: {
                                Image(systemName: showSjz ? "eye.slash" : "eye").frame(width: 18)
                            }
                            .buttonStyle(.borderless).help(showSjz ? "隐藏" : "显示")
                        }
                    }
                    sjzField("服务地址") {
                        TextField(SjzApi.defaultEndpoint, text: $model.sjzEndpoint)
                            .textFieldStyle(.roundedBorder).font(.body.monospaced())
                        if !Self.isLoopback(model.sjzEndpoint) {
                            Label("这不是本机地址，审计数据会经网络传输。结审默认只在本机提供服务，建议用 127.0.0.1。", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(Color.orange)
                        }
                    }
                    HStack(spacing: 10) {
                        Button {
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
                        } label: { Text("保存并测试").frame(minWidth: 70) }
                            .buttonStyle(.borderedProminent).tint(Brand.orange)
                            .disabled(sjzTesting || model.sjzKeyInput.trimmed.isEmpty)
                        if sjzTesting { ProgressView().controlSize(.small) }
                        if let r = sjzResult {
                            Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(r.ok ? Color.green : Color.orange).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    Divider()
                    HStack(spacing: 10) {
                        Image(systemName: "pin")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.indigo)
                            .frame(width: 30, height: 30)
                            .background(Color.indigo.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("钉住项目")
                            Text("灵动岛保存的证据、法规、线索都放进这个项目").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
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
                        .labelsHidden().frame(width: 230)
                        .disabled(!model.hasSjz)
                    }
                    Text("Key 在结审「设置 → 外部应用」里生成；保存证据、法规、记线索、回写任务还需在那里开启「允许写入」。结审的任务、专注和记录只存在结审与本机，不会写入滴答清单或闪念贝壳。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { if model.hasSjz { await model.refreshSjzTarget(); await model.refreshSjzProjects() } }
    }

    private static func isLoopback(_ endpoint: String) -> Bool {
        guard let host = URL(string: endpoint.trimmed)?.host?.lowercased() else { return true }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private func sjzField<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }

    private func credentialRow(
        icon: String, tint: Color, name: String, connected: Bool, placeholder: String,
        text: Binding<String>, reveal: Binding<Bool>, hint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(name).font(.headline)
                TagChip(text: connected ? "已连接" : "未填写", tint: connected ? .green : .orange)
                Spacer()
            }
            HStack(spacing: 6) {
                Group {
                    if reveal.wrappedValue {
                        TextField(placeholder, text: text)
                    } else {
                        SecureField(placeholder, text: text)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                Button {
                    reveal.wrappedValue.toggle()
                } label: {
                    Image(systemName: reveal.wrappedValue ? "eye.slash" : "eye").frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(reveal.wrappedValue ? "隐藏" : "显示")
            }
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 显示模式

    @AppStorage(DisplayMode.key) private var displayMode: DisplayMode = .menuBar
    @AppStorage(DisplayMode.hoverKey) private var islandHover = true
    @AppStorage(DisplayMode.swipeKey) private var islandSwipe = true
    @AppStorage(DisplayMode.captureKey) private var islandCapture = true
    @AppStorage(DisplayMode.activityKey) private var islandActivities = true
    @AppStorage(DisplayMode.shelfKey) private var islandShelf = true
    @AppStorage(DisplayMode.hotkeyKey) private var islandHotkey: IslandHotkey = .optSpace
    @AppStorage(AppTheme.key) private var theme: AppTheme = .system
    @AppStorage(BackgroundPrefs.hideDockKey) private var hideDock = false
    @AppStorage(TicketController.enabledKey) private var ticketOn = true
    @AppStorage(TicketController.soundKey) private var ticketSound = true
    @AppStorage(ImageOCR.key) private var ocrOn = true

    private func islandRow(_ icon: String, _ tint: Color, _ title: String, _ hint: String, _ on: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: on).labelsHidden().toggleStyle(.switch)
        }
        .padding(.vertical, 2)
    }

    private var displayCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "小组件显示方式")
                HStack(spacing: 10) {
                    ForEach(DisplayMode.allCases) { modeTile($0) }
                }
                if displayMode == .island {
                    Divider()
                    islandRow("cursorarrow.motionlines", .blue, "悬停展开", "鼠标移到刘海（没有刘海的屏幕是顶部小条）上就展开；关掉后只能点击展开", $islandHover)
                    islandRow("hand.draw", .purple, "触控板下滑展开", "在刘海上双指下滑展开；展开后在顶部一条上上滑收起", $islandSwipe)
                    islandRow("photo.badge.plus", Brand.orange, "截图提示", "刚截了图（或剪贴板里有新图片）时岛自动弹出，一键存为笔记、暂存，或拖走。截图在桌面时，首次使用 macOS 会请求访问桌面文件夹", $islandCapture)
                    islandRow("text.viewfinder", .teal, "识别截图里的文字", "把截图保存为笔记时，用系统自带的文字识别（本机完成，图片不外传）把图里的字附在笔记后面，之后能搜到", $ocrOn)
                    islandRow("tray.full", .cyan, "暂存架", "展开页底部的暂存区，以及拖放时的「暂存」半边；关掉后拖放只保存，截图提示也不再有「暂存」", $islandShelf)
                    islandRow("bell.badge", .red, "状态提醒", "番茄 / 休息结束、待办到点时岛自动弹出，可直接完成、专注或推迟", $islandActivities)
                    HStack(spacing: 10) {
                        Image(systemName: "command")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.green)
                            .frame(width: 30, height: 30)
                            .background(Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("全局快捷键")
                            Text("在任何 App 里按下即可展开 / 收起灵动岛").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Picker("", selection: $islandHotkey) {
                            ForEach(IslandHotkey.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().frame(width: 130)
                    }
                    .padding(.vertical, 2)
                }
                Text(displayMode == .island
                     ? "灵动岛里是和菜单栏弹窗一样的待办、专注小组件，底部可选暂存架；平时在刘海两侧显示「今天 · 逾期」或专注进度。把截图、链接、文字拖到刘海：左半边保存（自动识别），右半边暂存（开启暂存架时）。展开后 ⌘V 粘贴保存、⌘⇧V 粘贴暂存，Esc 或点击别处收起。"
                     : "菜单栏图标显示「今天 · 逾期」或专注倒计时，点击弹出待办小组件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 外观与后台

    private var appearanceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "外观")
                HStack(spacing: 10) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.orange)
                        .frame(width: 30, height: 30)
                        .background(Brand.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("主题")
                        Text("明亮、暗黑，或跟随系统外观自动切换").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Picker("", selection: $theme) {
                        ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                }
                .padding(.vertical, 2)
                Divider()
                islandRow("moon.zzz", .indigo, "关闭窗口后隐藏 Dock 图标",
                          "关掉主窗口后拾忆一直在后台运行：专注计时、提醒、灵动岛 / 菜单栏都照常。打开后 Dock 里也不再显示图标，要回到窗口，点菜单栏图标或灵动岛上的「打开」。完全退出请按 ⌘Q。", $hideDock)
            }
        }
    }

    private func modeTile(_ m: DisplayMode) -> some View {
        let on = displayMode == m
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button { displayMode = m } label: {
            VStack(spacing: 6) {
                Image(systemName: m.icon).font(.system(size: 22)).foregroundStyle(on ? Brand.orange : Color.secondary)
                Text(m.title).font(.callout.weight(.semibold))
                Text(m.subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14).padding(.horizontal, 8)
            .background(on ? Brand.orange.opacity(0.12) : Color.primary.opacity(0.05), in: shape)
            .overlay(shape.stroke(on ? Brand.orange : Color.clear, lineWidth: 1.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    // MARK: - AI 模型

    private var aiCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.purple)
                        .frame(width: 30, height: 30)
                        .background(Color.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("AI 模型").font(.headline)
                    TagChip(text: model.hasLlm ? "已配置" : "未填写", tint: model.hasLlm ? .green : .orange)
                    Spacer()
                    Menu {
                        ForEach(LlmClient.presets, id: \.name) { p in
                            Button(p.name) { model.llmBaseUrl = p.url; model.llmModel = p.model }
                        }
                    } label: {
                        Label("常用服务", systemImage: "list.bullet")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }

                field("接口地址", "https://…/v1", $model.llmBaseUrl)
                field("模型名", "qwen-plus", $model.llmModel)

                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Group {
                            if showLlm { TextField("sk-…", text: $model.llmKeyInput) } else { SecureField("sk-…", text: $model.llmKeyInput) }
                        }
                        .textFieldStyle(.roundedBorder).font(.body.monospaced())
                        Button { showLlm.toggle() } label: { Image(systemName: showLlm ? "eye.slash" : "eye").frame(width: 18) }
                            .buttonStyle(.borderless)
                    }
                }

                HStack(spacing: 10) {
                    Button("保存") { model.saveLlm(); testResult = nil }
                        .buttonStyle(.borderedProminent).tint(Brand.orange)
                    Button {
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
                    } label: { Text("测试连接") }
                        .buttonStyle(.bordered).disabled(testing || model.llmKeyInput.trimmed.isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                    if let r = testResult {
                        Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(r.ok ? Color.green : Color.red).lineLimit(2)
                    }
                    Spacer()
                }
                Text("支持任何 OpenAI 兼容的接口（通义千问、DeepSeek、OpenAI、智谱等）。目前用于「重新规划」里的 AI 排期；Key 只保存在本机。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func field(_ name: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.body.monospaced())
        }
    }

    // MARK: - 通知

    @AppStorage("notify.focus") private var nFocus = true
    @AppStorage("notify.goal") private var nGoal = true
    @AppStorage("notify.due") private var nDue = true
    @AppStorage("notify.lead") private var nLead = 10
    @AppStorage("notify.digest") private var nDigest = true
    @AppStorage("notify.overdue") private var nOverdue = true
    @AppStorage("notify.sjz") private var nSjz = true
    @AppStorage("sjz.summary") private var nSjzSummary = true

    private var notifyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionTitle(text: "通知")
                    Spacer()
                    Button { Notifier.shared.sendTest() } label: { Label("发送测试", systemImage: "paperplane") }
                        .buttonStyle(.bordered)
                }
                .padding(.bottom, 6)

                notifyGroup("专注")
                notifyRow("timer", Brand.orange, "专注与休息", "番茄完成、休息结束、还剩 5 分钟、暂停太久", $nFocus)
                notifyRow("target", .green, "专注目标达成", "今天的专注时长第一次达到每日目标", $nGoal)

                notifyGroup("待办")
                notifyRow("bell.badge", .blue, "待办到点", "有具体时间的待办，到点提醒", $nDue)
                if nDue {
                    HStack(spacing: 10) {
                        Color.clear.frame(width: 30, height: 1)
                        Text("提前提醒").font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Picker("", selection: $nLead) {
                            Text("不提前").tag(0)
                            Text("5 分钟").tag(5)
                            Text("10 分钟").tag(10)
                            Text("15 分钟").tag(15)
                            Text("30 分钟").tag(30)
                        }
                        .labelsHidden().frame(width: 110)
                    }
                    .padding(.vertical, 4)
                }
                notifyRow("sun.horizon", .purple, "早晚简报", "早上 8:30 今天的安排，晚上 9:00 还没完成的几件", $nDigest)
                notifyRow("exclamationmark.circle", .red, "逾期提醒", "每天 10:00 提醒还有几件逾期", $nOverdue)

                if model.hasSjz {
                    notifyGroup("结审")
                    notifyRow("checkmark.shield", .indigo, "结审提醒", "调研完成、任务到期或逾期、待复核、线索久未跟进、取证单缺证据时，灵动岛弹出提醒（数据只存在本机）", $nSjz)
                    notifyRow("moon.stars", .indigo, "每晚工作小结", "21 点后把当天从拾忆写入的证据 / 法规 / 线索 / 数据、专注时长和完成任务写进结审项目的工作日志", $nSjzSummary)
                }

                Text("待办提醒在待办刷新后重新安排，退出拾忆后也会按时响。如果收不到，请在「系统设置 → 通知」里允许拾忆。")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 10)
            }
        }
        .onChange(of: nDue) { _, _ in Notifier.shared.syncTodos(model.overview) }
        .onChange(of: nLead) { _, _ in Notifier.shared.syncTodos(model.overview) }
        .onChange(of: nDigest) { _, _ in Notifier.shared.syncTodos(model.overview) }
        .onChange(of: nOverdue) { _, _ in Notifier.shared.syncTodos(model.overview) }
    }

    private func notifyGroup(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            .padding(.top, 10).padding(.bottom, 2)
    }

    /// 一行：图标 + 标题 / 说明 + 右侧开关；开关统一靠右对齐
    private func notifyRow(_ icon: String, _ tint: Color, _ title: String, _ hint: String, _ on: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: on).labelsHidden().toggleStyle(.switch)
        }
        .padding(.vertical, 5)
    }

    // MARK: - 专注目标

    private var focusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "专注")
                HStack {
                    Text("每日专注目标")
                    Spacer()
                    Text(goalText).monospacedDigit().foregroundStyle(.secondary)
                    Stepper("", value: $model.focusGoalMin, in: 10 ... 720, step: 10).labelsHidden()
                }
                Text("「今天」页的专注环以它为满环。").font(.caption).foregroundStyle(.secondary)
                Divider()
                islandRow("ticket", Brand.orange, "完成后打印成果小票",
                          "完成（或提前结束）一个番茄后，从屏幕顶部「打印」出一张小票：时长、任务、期间的记录、今日累计。灵动岛模式下从岛里出来，可保存成图片。", $ticketOn)
                if ticketOn {
                    islandRow("speaker.wave.2", .teal, "出纸提示音", "出纸时轻轻响一声", $ticketSound)
                }
            }
        }
    }

    private var goalText: String {
        let m = model.focusGoalMin
        return m < 60 ? "\(m) 分钟" : (m % 60 == 0 ? "\(m / 60) 小时" : "\(m / 60) 小时 \(m % 60) 分钟")
    }

    // MARK: - 手机备份

    private var backupCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(text: "手机备份")
                    if model.backupLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button {
                        Task { await model.loadBackup() }
                    } label: { Label("重新读取", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                        .disabled(model.backupLoading || !model.hasIdeashell)
                }

                if let b = model.backup {
                    HStack(spacing: 10) {
                        miniStat("\(b.workspace.projects.count)", "项目")
                        miniStat("\(b.workspace.taskNotes.count + localOnlyCount)", "任务笔记")
                        miniStat("\(b.workspace.focusLog.count)", "专注记录")
                    }
                    if let d = b.exportedDate {
                        Label("导出于 " + d.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Label("还没有读到备份", systemImage: "tray").foregroundStyle(.secondary)
                }
                if let e = model.backupError { ErrorBanner(text: e) }
                Text("项目、任务笔记的对应关系来自手机在闪念贝壳里的「拾忆备份（请勿删除）」笔记，Mac 端只读取；在 Mac 上新建的任务笔记会记在本机，并把链接写回滴答任务。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 只在本机、还没进手机备份的任务笔记数
    private var localOnlyCount: Int {
        let remote = model.backup?.workspace.taskNotes ?? [:]
        return model.localTaskNotes.keys.filter { remote[$0] == nil }.count
    }

    private func miniStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 本机数据

    private var dataCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "本机数据")
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(LocalStore.dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.callout.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([LocalStore.dir]) }
                        .buttonStyle(.bordered)
                }
                Text("凭证、备份缓存、本机新建的任务笔记都存在这里；笔记和待办本身保存在闪念贝壳和滴答清单，不会存在这里。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 快捷键

    private var shortcutsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "快捷键")
                shortcut("⌘ N", "万能输入：写笔记 / 记待办，自动识别")
                shortcut("⌘ R", "刷新当前页")
            }
        }
    }

    private func shortcut(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.callout.monospaced().weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(width: 64, alignment: .leading)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
