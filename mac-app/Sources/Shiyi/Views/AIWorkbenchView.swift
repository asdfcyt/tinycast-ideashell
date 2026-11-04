import AppKit
import Charts
import SwiftUI

/// 工作台里正在写的派活：右键「派活」从别处带进来的资料、选中的 Agent 都存在这里
@MainActor
final class WorkbenchDraft: ObservableObject {
    static let shared = WorkbenchDraft()

    @Published var text = ""
    /// 带进来的资料（想法 / 笔记 / Daily Note）：和指令分开，作为附件交给 Agent
    @Published var items: [ContextItem] = []
    var material: String? {
        get { ContextItem.joined(items) }
        set {
            if let t = newValue, !t.trimmed.isEmpty {
                items = [ContextItem(id: "clip", kind: .text, title: "选中的内容", body: t)]
            } else {
                items = []
            }
        }
    }
    @Published var targetId = UserDefaults.standard.string(forKey: "dispatch.lastTarget") ?? "workbuddy"
    @Published var continueChat = false
    @Published var pickedSession: String?
    @Published var sending = false
    @Published var error: String?
    /// 每加一次，输入框重新拿到焦点
    @Published var focusTick = 0
}

/// 调度（主窗口页面）：顶部一条派活输入，下面三个标签——任务 / 自动派活 / Agent 与用量，一次只看一件事。
/// 配置（各 Agent 的开关、审批规则、命令行目标）仍在「设置 → AI 调度台」。
struct AIWorkbenchView: View {
    private enum Tab: String, CaseIterable {
        case tasks = "任务", rules = "自动派活", agents = "Agent 与用量"
    }

    private enum TaskFilter: String, CaseIterable {
        case all = "全部", active = "进行中", finished = "已结束", failed = "没跑成"
    }

    private struct RuleEdit: Identifiable {
        let id = UUID()
        var rule: DispatchRule?
        var preset: DispatchRule?
    }

    /// 一条已结束的记录：自己派的活，或外部 Agent（Cursor / WorkBuddy / 终端里的 opencode）的完成记录
    private enum Activity: Identifiable {
        case job(LedgerJob)
        case record(AgentResultRecord)

        var id: UUID {
            switch self {
            case .job(let j): return j.id
            case .record(let r): return r.id
            }
        }

        var date: Date {
            switch self {
            case .job(let j): return j.endedAt ?? j.createdAt
            case .record(let r): return r.at
            }
        }
    }

    @EnvironmentObject var model: AppModel
    @ObservedObject private var draft = WorkbenchDraft.shared
    @ObservedObject private var ledger = DispatchLedger.shared
    @ObservedObject private var center = ApprovalCenter.shared
    @ObservedObject private var runs = AgentRunTracker.shared
    @ObservedObject private var ocStore = OpenCodeStore.shared
    @ObservedObject private var engine = DispatchRuleEngine.shared
    @ObservedObject private var results = AgentResultStore.shared
    @AppStorage("dispatch.opencode.dir") private var ocDir = ""
    @AppStorage("dispatch.opencode.extraDirs") private var ocExtra = ""
    @FocusState private var focused: Bool
    @State private var tab: Tab = .tasks
    @State private var filter: TaskFilter = .all
    @State private var showAll = false
    @State private var detailJob: UUID?
    @State private var ruleEditing: RuleEdit?
    /// 权限档存在 UserDefaults 里，改了之后靠它刷新界面
    @State private var accessTick = 0
    @State private var showPicker = false

    private static let pageWidth: CGFloat = 900

    // MARK: 当前选择

    private var targets: [DispatchTarget] { DispatchTarget.available }
    private var target: DispatchTarget { targets.first { $0.id == draft.targetId } ?? targets.first ?? .workbuddy }
    private var workDir: String { ocDir.isEmpty ? (ocStore.dirs.first ?? "") : ocDir }
    private var workSession: OpenCodeSession? { ocStore.sessions.first { $0.id == draft.pickedSession } ?? ocStore.sessions.first }
    /// 只有 WorkBuddy（当前对话）和 opencode（会话列表）能在这里选「继续」；其他命令行接着聊走验收卡上的追问
    private var canContinue: Bool { target == .opencode || target == .workbuddy }
    private var continuing: Bool { draft.continueChat && canContinue }

    private var attention: Int { center.pending.count + center.completions.count }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                composer
                tabBar
            }
            .padding(.horizontal, 28).padding(.top, 14)
            .frame(maxWidth: Self.pageWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .tasks: tasksTab
                    case .rules: rulesTab
                    case .agents: agentsTab
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
                .frame(maxWidth: Self.pageWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(AmbientBackground())
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { SettingsWindow.show() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Agent 开关、审批规则、命令行目标（设置 → AI 调度台）")
            }
        }
        .sheet(item: $ruleEditing) { e in
            DispatchRuleEditor(existing: e.rule, preset: e.preset)
        }
        .sheet(isPresented: Binding(get: { detailJob != nil }, set: { if !$0 { detailJob = nil } })) {
            if let id = detailJob { DispatchJobDetail(id: id) }
        }
        .onAppear {
            ocStore.refresh(after: 0.6)
            focused = true
        }
        .onChange(of: draft.focusTick) { _, _ in
            tab = .tasks
            focused = true
        }
    }

    // MARK: - 标签栏

    private var tabBar: some View {
        HStack(alignment: .bottom, spacing: 26) {
            ForEach(Tab.allCases, id: \.self) { t in tabButton(t) }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func tabButton(_ t: Tab) -> some View {
        let on = tab == t
        let activeCount = ledger.jobs.filter { $0.state.isActive }.count
        return Button { tab = t } label: {
            VStack(spacing: 7) {
                HStack(spacing: 6) {
                    Text(t.rawValue).font(.system(size: 14, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                    if t == .tasks, attention > 0 {
                        Text("等你 \(attention)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Color.orange, in: Capsule())
                    } else if t == .tasks, activeCount > 0 {
                        Text("\(activeCount) 个进行中").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
                Rectangle().fill(on ? Brand.orange : Color.clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 派活输入条

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.text)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.hidden)
                    .focused($focused)
                    .frame(height: editorHeight)
                    .padding(.horizontal, -5)
                if draft.text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 15)).foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                        .padding(.top, 0)
                }
            }
            if !draft.items.isEmpty { itemsRow }
            if let e = draft.error {
                Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                // 选项合成一个整体：谁来做 | 在哪 | 权限
                HStack(spacing: 0) {
                    agentMenu
                    if !targets.isEmpty {
                        segDivider
                        modeMenu
                        if target.isCommand {
                            segDivider
                            accessMenu
                        }
                    }
                    segDivider
                    contextMenu
                }
                .background(Color.primary.opacity(0.06), in: Capsule())
                Spacer(minLength: 8)
                sendButton
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    /// 带入上下文：搜想法 / 待办，或一键带入剪贴板、Daily Note；作为「资料」和指令分开发给 Agent
    private var contextMenu: some View {
        let n = draft.items.count
        return Button { showPicker.toggle() } label: {
            seg("paperclip", n > 0 ? "上下文 · \(n) 项" : "带入上下文", tint: n > 0 ? Brand.orange : .secondary, chevron: false)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            ContextPicker { showPicker = false }.environmentObject(model)
        }
        .help("搜索想法、待办，或带入剪贴板 / Daily Note 作为资料（和指令分开，不会被当成指令）")
    }

    private var segDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14)
    }

    private var placeholder: String {
        if targets.isEmpty { return "还没有能接活的 Agent：到「设置 → AI 调度台」接入 WorkBuddy，或安装 opencode / Claude Code" }
        return draft.material != nil ? "对这份资料做什么？留空 = 让 \(target.title) 处理它" : "让 \(target.title) 做点什么…"
    }

    /// 输入框高度：两行起步，随内容长，最多 7 行
    private var editorHeight: CGFloat {
        let lines = draft.text.components(separatedBy: "\n").reduce(0) { $0 + max(1, Int((Double($1.count) / 64).rounded(.up))) }
        return min(CGFloat(max(lines, 2)) * 21 + 4, 150)
    }

    /// 选项里的一格：图标 + 文字（+ 上下箭头）；外面的整体胶囊负责背景
    private func seg(_ icon: String, _ text: String, tint: Color, chevron: Bool = true) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 200, alignment: .leading).fixedSize(horizontal: true, vertical: false)
            if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary) }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    /// 谁来做
    private var agentMenu: some View {
        Menu {
            ForEach(targets) { t in
                Button {
                    draft.targetId = t.id
                    if !(t == .opencode || t == .workbuddy) { draft.continueChat = false }
                } label: {
                    if t == target { Label(t.title, systemImage: "checkmark") } else { Label(t.title, systemImage: t.icon) }
                }
            }
        } label: {
            seg(target.icon, target.title, tint: target.color)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(targets.isEmpty)
        .help("选择谁来做")
    }

    /// 权限档：「完全放开」要二次确认
    private var accessMenu: some View {
        let _ = accessTick
        let p = target.profile
        let tint: Color = p.access == .full ? .red : .secondary
        return Menu {
            ForEach(AgentAccess.allCases, id: \.self) { a in
                Button {
                    if a == .full, !AgentAccess.confirmFull(for: p.name) { return }
                    p.access = a
                    accessTick += 1
                } label: {
                    if a == p.access { Label(a.label, systemImage: "checkmark") } else { Text(a.label) }
                }
            }
        } label: {
            seg(p.access == .full ? "exclamationmark.shield" : (p.access == .read ? "lock" : "pencil.line"), p.access.label, tint: tint)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("这个 Agent 这次能做什么（在这里改的，下次派活也沿用）")
    }

    /// 新开 / 继续，以及（命令行）在哪个目录
    private var modeMenu: some View {
        let t = target
        let icon: String
        let label: String
        if continuing {
            icon = "text.bubble"
            label = t == .opencode ? "继续 · " + (workSession?.displayTitle ?? "无会话") : "继续当前对话"
        } else {
            icon = t.isCommand ? "folder" : "plus.bubble"
            label = t.isCommand ? (workDir.isEmpty ? "选择文件夹" : (workDir as NSString).lastPathComponent) : "新开对话"
        }
        return Menu {
            if t.isCommand {
                Section("新开对话") {
                    ForEach(dirChoices, id: \.self) { d in
                        Button {
                            ocDir = d
                            draft.continueChat = false
                        } label: {
                            let n = (d as NSString).lastPathComponent
                            if !continuing && d == workDir { Label(n, systemImage: "checkmark") } else { Label(n, systemImage: "folder") }
                        }
                        .help(d)
                    }
                    Button("选择文件夹…") { chooseDir() }
                }
                if t == .opencode, !ocStore.sessions.isEmpty {
                    Section("继续对话") {
                        ForEach(ocStore.sessions.prefix(8)) { s in
                            Button {
                                draft.pickedSession = s.id
                                draft.continueChat = true
                            } label: {
                                let n = s.displayTitle + " · " + s.dirName
                                if continuing && s.id == workSession?.id { Label(n, systemImage: "checkmark") } else { Label(n, systemImage: "text.bubble") }
                            }
                        }
                    }
                }
            } else {
                Button { draft.continueChat = false } label: {
                    if !continuing { Label("新开对话", systemImage: "checkmark") } else { Label("新开对话", systemImage: "plus.bubble") }
                }
                Button { draft.continueChat = true } label: {
                    if continuing { Label("继续当前对话", systemImage: "checkmark") } else { Label("继续当前对话", systemImage: "text.bubble") }
                }
            }
        } label: {
            seg(icon, label, tint: .secondary)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
        .help(t.isCommand && !continuing ? workDir : "新开还是继续对话")
    }

    private var dirChoices: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for d in [workDir] + ocExtra.split(separator: "\n").map(String.init) + ocStore.dirs where !d.isEmpty && seen.insert(d).inserted { out.append(d) }
        return out
    }

    private func chooseDir() {
        FolderPicker.pick(title: "选择工作目录", start: workDir) { path in
            guard let path else { return }
            ocDir = path
            draft.continueChat = false
            var extra = ocExtra.split(separator: "\n").map(String.init).filter { $0 != path }
            extra.insert(path, at: 0)
            ocExtra = extra.prefix(6).joined(separator: "\n")
        }
    }

    /// 已带入的资料：一排小标签，点叉去掉
    private var itemsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(draft.items) { it in
                    HStack(spacing: 5) {
                        Image(systemName: it.kind.icon).font(.system(size: 10, weight: .semibold))
                        Text(it.title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 180, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                        Text("\(it.body.count) 字").foregroundStyle(.tertiary).fixedSize()
                        Button { draft.items.removeAll { $0.id == it.id } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("不带这份资料")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
        }
    }

    private var sendButton: some View {
        let empty = draft.text.trimmed.isEmpty && draft.material == nil
        let disabled = draft.sending || empty || targets.isEmpty
        return Button(action: send) {
            HStack(spacing: 6) {
                if draft.sending { ProgressView().controlSize(.small) } else { Text("派出").font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize() }
                Text("⌘↩").font(.caption2).opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 15).padding(.vertical, 7)
            .background(Brand.orange.opacity(disabled ? 0.35 : 1), in: Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(disabled)
    }

    private func send() {
        let text = draft.text.trimmed
        guard !draft.sending, !text.isEmpty || draft.material != nil else { return }
        let t = target
        var plan = DispatchPlan(target: t, fresh: !continuing)
        plan.material = draft.material
        if t.isCommand {
            if continuing {
                guard let s = workSession else { draft.error = "没有可以继续的 opencode 会话"; return }
                plan.session = s
            } else {
                guard !workDir.isEmpty else { draft.error = "先选一个文件夹"; return }
                plan.dir = workDir
            }
        }
        UserDefaults.standard.set(t.id, forKey: "dispatch.lastTarget")
        draft.sending = true
        draft.error = nil
        Task {
            let r = await DispatchCenter.shared.send(text, plan: plan)
            draft.sending = false
            if r.ok {
                draft.text = ""
                draft.material = nil
                model.showNotice("已派给 \(t.title)")
                filter = .all
                tab = .tasks
                draft.focusTick += 1
            } else {
                draft.error = r.message
            }
        }
    }

    // MARK: - 标签一：任务

    /// 账本之外、正在跑的 Agent（Cursor / WorkBuddy / 自己开的 opencode）：和账本里的重复的不再列
    private var extraRuns: [AgentRun] {
        let active = ledger.jobs.filter { $0.state.isActive }
        return runs.runs.filter { r in
            if r.source == .claude || r.source == .cli { return false }
            return !active.contains { j in
                DispatchTarget(rawValue: j.target)?.profile.source == r.source && AgentProject.name(j.cwd) == r.project
            }
        }
    }

    private var finished: [Activity] {
        var out: [Activity] = []
        for j in ledger.jobs where !j.state.isActive {
            if filter == .failed, !(j.state == .failed || j.state == .interrupted) { continue }
            out.append(.job(j))
        }
        for r in results.records where filter != .failed || r.failed { out.append(.record(r)) }
        return out.sorted { $0.date > $1.date }
    }

    private var tasksTab: some View {
        let activeJobs = ledger.jobs.filter { $0.state.isActive }
        let others = extraRuns
        let showAttention = attention > 0 && filter == .all
        let showActive = filter == .all || filter == .active
        let showFinished = filter != .active
        let all = showFinished ? finished : []
        let shown = Array(all.prefix(showAll ? 80 : 20))
        let hasAny = showAttention || (showActive && !(activeJobs.isEmpty && others.isEmpty)) || !shown.isEmpty
        return VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Picker("", selection: $filter) {
                    ForEach(TaskFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if ledger.jobs.contains(where: { !$0.state.isActive }) || !results.records.isEmpty {
                    Button("清空已结束") {
                        ledger.clearFinished()
                        results.clear()
                    }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                }
            }

            if showAttention {
                block("需要你处理", count: attention) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 440, maximum: 460), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                        ForEach(center.pending) { a in
                            ApprovalCardView(a: a, first: a.id == center.pending.first?.id)
                        }
                        ForEach(center.completions) { c in
                            CompletionCardView(c: c)
                        }
                    }
                }
            }

            if showActive, !(activeJobs.isEmpty && others.isEmpty) {
                block("进行中", count: activeJobs.count + others.count) {
                    VStack(spacing: 8) {
                        ForEach(activeJobs) { j in WorkbenchJobRow(j: j) { detailJob = j.id } }
                        ForEach(others) { r in WorkbenchRunRow(r: r) }
                    }
                }
            }

            ForEach(grouped(shown), id: \.title) { g in
                block(g.title, count: nil) {
                    VStack(spacing: 8) {
                        ForEach(g.items) { a in
                            switch a {
                            case .job(let j): WorkbenchJobRow(j: j) { detailJob = j.id }
                            case .record(let r): WorkbenchRecordRow(r: r)
                            }
                        }
                    }
                }
            }

            if all.count > 20 {
                Button(showAll ? "收起" : "显示更多（还有 \(all.count - 20) 条）") { showAll.toggle() }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }

            if !hasAny { emptyState(filter == .all ? "还没有任务" : "没有符合的记录", filter == .all ? "在上面写一句话，选个 Agent，⌘↩ 派出去" : nil) }
        }
    }

    /// 按天分组：今天 / 昨天 / M月d日
    private func grouped(_ items: [Activity]) -> [(title: String, items: [Activity])] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        var out: [(title: String, items: [Activity])] = []
        for a in items {
            let title = cal.isDateInToday(a.date) ? "今天" : (cal.isDateInYesterday(a.date) ? "昨天" : f.string(from: a.date))
            if let i = out.indices.last, out[i].title == title { out[i].items.append(a) } else { out.append((title, [a])) }
        }
        return out
    }

    // MARK: - 标签二：自动派活

    private var reminders: [DidaTask] {
        guard let ov = model.overview else { return [] }
        let tag = DispatchRuleEngine.reminderTag
        return (ov.overdue + ov.upcoming + ov.undated)
            .filter { !$0.done && $0.tags.contains { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) == tag } }
            .sorted { ($0.date ?? "9999", $0.time ?? "") < ($1.date ?? "9999", $1.time ?? "") }
    }

    private var rulesTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            block("规则", count: engine.rules.isEmpty ? nil : engine.rules.count, trailing: {
                Menu {
                    ForEach(DispatchRuleTemplate.all) { t in
                        Button { ruleEditing = RuleEdit(rule: nil, preset: t.rule) } label: { Label(t.title, systemImage: t.icon) }
                    }
                    Divider()
                    Button("空白规则…") { ruleEditing = RuleEdit(rule: nil, preset: nil) }
                } label: {
                    Label("添加", systemImage: "plus").font(.callout)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
            }) {
                if engine.rules.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("到点、或滴答任务带上标签，Agent 就自己开工。默认关闭、默认只读；跑完没有要你拍板的事，不打扰你。")
                            .font(.callout).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                            ForEach(DispatchRuleTemplate.all) { t in templateCard(t) }
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(engine.rules) { r in ruleRow(r) }
                    }
                }
            }

            let list = reminders
            if !list.isEmpty {
                block("待复查", count: list.count) {
                    VStack(spacing: 8) {
                        ForEach(list.prefix(8)) { t in reminderRow(t) }
                    }
                }
            }
        }
    }

    private func templateCard(_ t: DispatchRuleTemplate) -> some View {
        Button { ruleEditing = RuleEdit(rule: nil, preset: t.rule) } label: {
            HStack(spacing: 10) {
                Image(systemName: t.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.orange)
                    .frame(width: 30, height: 30).background(Brand.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.system(size: 13.5, weight: .semibold))
                    Text(t.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle").foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func ruleRow(_ r: DispatchRule) -> some View {
        let icon = r.trigger == .todoTag ? "tag" : (r.trigger == .workdays ? "calendar" : "clock")
        let used = engine.firedToday(r)
        var status = [engine.nextText(r)]
        if let n = r.lastNote, !n.isEmpty { status.append("上次 " + n) }
        return HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 28, height: 28).background((r.enabled ? Brand.orange : Color.gray).gradient, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name.isEmpty ? "未命名" : r.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                Text(r.baseSummary + " · " + status.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(used)/\(r.dailyLimit)").font(.system(size: 11.5)).monospacedDigit()
                .foregroundStyle(used >= r.dailyLimit ? Color.orange : Color.secondary).fixedSize().help("今天已触发 / 每天上限")
            moreMenu {
                Button("现在试跑一次") { engine.runNow(r.id) }
                Button("修改…") { ruleEditing = RuleEdit(rule: r, preset: nil) }
            }
            Toggle("", isOn: ruleToggle(r)).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .rowCard()
    }

    private func ruleToggle(_ r: DispatchRule) -> Binding<Bool> {
        Binding(
            get: { engine.rules.first { $0.id == r.id }?.enabled ?? false },
            set: { on in
                if on, r.access == .full, !AgentAccess.confirmFull(for: DispatchTarget(rawValue: r.profileId)?.title ?? "这个 Agent") { return }
                engine.setEnabled(r.id, on)
            }
        )
    }

    private func reminderRow(_ t: DidaTask) -> some View {
        let late = (t.date ?? "9999") < Day.today()
        var when = "没定时间"
        if let d = t.date {
            let day = d == Day.today() ? "今天" : (d == Day.add(Day.today(), days: 1) ? "明天" : (late ? "已逾期 " + d : d))
            when = day + (t.time.map { " " + $0 } ?? "")
        }
        return Button { model.openTask(t) } label: {
            HStack(spacing: 12) {
                Image(systemName: "alarm").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(Color.indigo.gradient, in: Circle())
                Text(t.cleanTitle).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(when).font(.system(size: 12)).foregroundStyle(late ? Color.red : Color.secondary).fixedSize()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .rowCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: - 标签三：Agent 与用量

    private struct DayCount: Identifiable {
        let id = UUID()
        let day: Date
        let kind: String
        let n: Int
    }

    private var weekData: [DayCount] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var out: [DayCount] = []
        for k in (0..<7).reversed() {
            guard let d = cal.date(byAdding: .day, value: -k, to: today), let e = cal.date(byAdding: .day, value: 1, to: d) else { continue }
            let js = ledger.jobs.filter { $0.createdAt >= d && $0.createdAt < e }
            out.append(DayCount(day: d, kind: "完成", n: js.filter { $0.state == .done }.count))
            out.append(DayCount(day: d, kind: "没跑成", n: js.filter { $0.state == .failed || $0.state == .interrupted }.count))
            out.append(DayCount(day: d, kind: "其他", n: js.filter { [.cancelled, .queued, .running, .retrying].contains($0.state) }.count))
        }
        return out
    }

    private var agentsTab: some View {
        let list = AgentProfiles.all.filter { $0.kind == .command || $0.id == "workbuddy" }
        return VStack(alignment: .leading, spacing: 22) {
            block("用量", count: nil) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("近 7 天派活").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
                        Chart(weekData) { d in
                            BarMark(x: .value("日期", d.day, unit: .day), y: .value("轮数", d.n), width: .ratio(0.6))
                                .foregroundStyle(by: .value("结果", d.kind))
                        }
                        .chartForegroundStyleScale(["完成": Color.green, "没跑成": Color.red, "其他": Color.gray.opacity(0.45)])
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day)) { _ in
                                AxisValueLabel(format: .dateTime.weekday(.narrow))
                            }
                        }
                        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                        .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
                        .frame(height: 130)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(spacing: 12) {
                        usageTile("今天", since: Calendar.current.startOfDay(for: Date()))
                        usageTile("近 7 天", since: Date().addingTimeInterval(-7 * 86400))
                    }
                    .frame(width: 220)
                }
            }
            block("Agent", count: list.filter(\.enabled).count) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(list) { p in agentCard(p) }
                }
            }
        }
    }

    private func usageTile(_ title: String, since: Date) -> some View {
        let u = ledger.usageSummary(since: since)
        var detail: [String] = []
        if u.runs > u.unreported { detail.append(DispatchResult.compact(u.tokens) + " Token") }
        if u.hasCost { detail.append(String(format: "$%.2f", u.cost)) }
        if u.unreported > 0 { detail.append("\(u.unreported) 轮未上报") }
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(u.runs)").font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                Text("轮").font(.callout).foregroundStyle(.secondary)
            }
            Text(detail.isEmpty ? "—" : detail.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func agentCard(_ p: AgentProfile) -> some View {
        let start = Calendar.current.startOfDay(for: Date())
        let week = Date().addingTimeInterval(-7 * 86400)
        let mine = ledger.jobs.filter { $0.target == p.id }
        let busy = mine.filter { $0.state.isActive }.count
        let today = mine.filter { $0.createdAt >= start }.count
        let tokens = mine.filter { $0.createdAt >= week }.compactMap { $0.usage?.tokens }.reduce(0, +)
        let on = p.enabled
        let tint = p.swiftColor
        let state = !on ? (p.kind == .command ? "没装" : "未接入") : (busy > 0 ? "忙碌 · \(busy) 个任务" : "空闲")
        var stats = ["今天 \(today) 轮"]
        if tokens > 0 { stats.append("近 7 天 " + DispatchResult.compact(tokens) + " Token") }
        return Button {
            guard on else { return }
            draft.targetId = p.id
            if !(p.id == "opencode" || p.id == "workbuddy") { draft.continueChat = false }
            draft.focusTick += 1
        } label: {
            HStack(spacing: 11) {
                Image(systemName: p.icon).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(tint.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Circle().fill(!on ? Color.gray : (busy > 0 ? Color.orange : Color.green)).frame(width: 6, height: 6)
                        Text(state).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(stats.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if p.kind == .command, on {
                    let _ = accessTick
                    Text(p.access.label).font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(p.access == .full ? Color.red : Color.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((p.access == .full ? Color.red : Color.primary).opacity(0.08), in: Capsule())
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(on ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(on ? "选它来派活" : "到「设置 → AI 调度台」接入或安装")
    }

    // MARK: - 通用

    private func block<C: View>(_ title: String, count: Int?, @ViewBuilder _ content: () -> C) -> some View {
        block(title, count: count, trailing: { EmptyView() }, content)
    }

    private func block<C: View, T: View>(_ title: String, count: Int?, @ViewBuilder trailing: () -> T, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                if let count, count > 0 {
                    Text("\(count)").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.tertiary)
                }
                Spacer()
                trailing()
            }
            content()
        }
    }

    private func emptyState(_ title: String, _ hint: String?) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            if let hint { Text(hint).font(.callout).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 50)
    }

    private func moreMenu<C: View>(@ViewBuilder _ items: () -> C) -> some View {
        Menu { items() } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24).background(Color.primary.opacity(0.08), in: Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

// MARK: - 行

private extension View {
    /// 列表里一行的外框：统一的留白和圆角
    func rowCard() -> some View {
        self
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
    }
}

private struct RowMore<C: View>: View {
    @ViewBuilder var items: C

    var body: some View {
        Menu { items } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24).background(Color.primary.opacity(0.08), in: Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

private struct StatusTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color).lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 1.5).background(color.opacity(0.13), in: Capsule())
    }
}

private struct RowIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            .frame(width: 28, height: 28).background(tint.gradient, in: Circle())
    }
}

private func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

private func clockText(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M月d日 HH:mm"
    return f.string(from: d)
}

/// 一条派活：状态 + 指令 + 一行元信息 + 结果（默认两行，点开全文）；次要操作都收在「…」里
private struct WorkbenchJobRow: View {
    let j: LedgerJob
    var onDetail: () -> Void
    @State private var expanded = false
    private var ledger: DispatchLedger { DispatchLedger.shared }
    private var target: DispatchTarget? { DispatchTarget(rawValue: j.target) }
    /// Agent 的结果（账本自己拿到的，或从验收卡 / opencode 本地数据库里取的；不另外调用模型）
    private var preview: String { (j.result ?? "").trimmed }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RowIcon(symbol: target?.icon ?? "terminal", tint: target?.color ?? .gray)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(j.prompt.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    StatusTag(text: j.state.label, color: color)
                }
                meta
                if !preview.isEmpty { ResultText(text: preview, expanded: expanded) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if j.managed {
                    if j.state.isActive {
                        circleButton("stop.fill", "停止", .red) { ledger.stop(j.id) }
                    } else {
                        circleButton("arrow.clockwise", "重跑", .secondary) { ledger.rerun(j.id) }
                    }
                }
                RowMore {
                    Button("详情和时间线") { onDetail() }
                    if !preview.isEmpty { Button("复制结果") { copyToPasteboard(preview) } }
                    if !j.cwd.isEmpty { Button("打开目录") { NSWorkspace.shared.open(URL(fileURLWithPath: j.cwd)) } }
                    if j.managed { Button("打开日志") { NSWorkspace.shared.open(DispatchLedger.logURL(j.id)) } }
                    if j.hasMaterial { Button("查看资料") { NSWorkspace.shared.open(DispatchLedger.materialURL(j.id)) } }
                    if !j.state.isActive {
                        Divider()
                        Button("删除这条记录", role: .destructive) { ledger.remove(j.id) }
                    }
                }
            }
        }
        .rowCard()
        .onTapGesture { if preview.isEmpty { onDetail() } else { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } }
    }

    private var color: Color {
        switch j.state {
        case .queued, .running: return .orange
        case .retrying: return .yellow
        case .done: return .green
        case .failed: return .red
        case .cancelled, .interrupted: return .secondary
        }
    }

    private func circleButton(_ symbol: String, _ help: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                .frame(width: 24, height: 24).background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 一行小字：目标 · 来源 · 目录 · 权限 · 时间 / 耗时 · 用量；没跑成时带上原因
    @ViewBuilder private var meta: some View {
        if j.state == .running {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let s = max(Int(ctx.date.timeIntervalSince(j.startedAt ?? ctx.date)), 0)
                Text(base(extra: String(format: "%d:%02d", s / 60, s % 60))).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        } else {
            Text(base(extra: nil)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
    }

    private func base(extra: String?) -> String {
        var parts = [j.targetTitle]
        if j.origin.hasPrefix("规则") { parts.append(j.origin) }
        if !j.cwd.isEmpty { parts.append((j.cwd as NSString).lastPathComponent) }
        if j.hasMaterial { parts.append("带资料") }
        if let a = j.access, let acc = AgentAccess(rawValue: a), acc != .edit { parts.append(acc.label) }
        if let extra { parts.append(extra) }
        else if j.state == .retrying, let t = j.nextRetryAt { parts.append("第 \(j.attempts) 次没跑成 · \(clockText(t)) 重试") }
        else if let d = j.duration, j.state != .queued { parts.append(d < 60 ? "\(Int(d)) 秒" : "\(Int(d / 60)) 分钟") }
        if !j.state.isActive, let e = j.endedAt { parts.append(clockText(e)) }
        if let u = j.usage { parts.append(DispatchResult.compact(u.tokens) + " Token" + (u.cost.map { String(format: " · $%.2f", $0) } ?? "")) }
        if j.state == .failed || j.state == .retrying, !j.message.isEmpty {
            parts.append(String(j.message.replacingOccurrences(of: "\n", with: " ").suffix(60)))
        }
        return parts.joined(separator: " · ")
    }
}

/// 结果文字：折叠时两行，展开后完整显示并可选中（行内 Markdown 会渲染）
private struct ResultText: View {
    let text: String
    let expanded: Bool

    var body: some View {
        let shown = Text(attributed)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        Group {
            if expanded {
                shown.textSelection(.enabled)
            } else {
                shown.lineLimit(2).truncationMode(.tail)
            }
        }
        .padding(.top, 2)
    }

    private var attributed: AttributedString {
        let opt = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: opt)) ?? AttributedString(text)
    }
}

/// 外部 Agent 的一条完成记录
private struct WorkbenchRecordRow: View {
    let r: AgentResultRecord
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RowIcon(symbol: r.source.icon, tint: r.source.color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("\(r.source.title) · \(r.project)").font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    StatusTag(text: r.failed ? "没做成" : "已完成", color: r.failed ? .red : .green)
                }
                Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                ResultText(text: r.summary, expanded: expanded)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RowMore {
                Button("复制结果") { copyToPasteboard(r.summary) }
                if !r.cwd.isEmpty, FileManager.default.fileExists(atPath: r.cwd) {
                    Button("打开目录") { NSWorkspace.shared.open(URL(fileURLWithPath: r.cwd)) }
                }
                Divider()
                Button("删除这条记录", role: .destructive) { AgentResultStore.shared.remove(r.id) }
            }
        }
        .rowCard()
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
    }

    private var meta: String {
        var parts = ["外部 Agent", clockText(r.at)]
        if let d = r.duration { parts.append(d < 60 ? "\(Int(d)) 秒" : "\(Int(d / 60)) 分钟") }
        return parts.joined(separator: " · ")
    }
}

/// 账本之外的运行中 Agent（Cursor / WorkBuddy / 你自己在终端里开的 opencode）
private struct WorkbenchRunRow: View {
    let r: AgentRun
    @ObservedObject private var center = ApprovalCenter.shared

    var body: some View {
        let waiting = center.pending.contains { $0.source == r.source }
        HStack(spacing: 12) {
            RowIcon(symbol: r.source.icon, tint: r.source.color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("\(r.source.title) · \(r.project)").font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    StatusTag(text: waiting ? "等你批准" : "运行中", color: .orange)
                }
                Text(r.activity ?? "思考中…")
                    .font(.system(size: 12, design: r.activity == nil ? .default : .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let s = max(Int(ctx.date.timeIntervalSince(r.started)), 0)
                Text(String(format: "%d:%02d", s / 60, s % 60))
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
            }
            if r.canStop {
                Button { AgentRunTracker.shared.stop(r) } label: {
                    Group {
                        if r.stopping { ProgressView().controlSize(.mini) } else { Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)) }
                    }
                    .foregroundStyle(r.stopping ? Color.secondary : Color.red)
                    .frame(width: 24, height: 24).background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain).disabled(r.stopping)
                .help(r.stopping ? "正在停止…" : "停止")
            }
        }
        .rowCard()
    }
}
