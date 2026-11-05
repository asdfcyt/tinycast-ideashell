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
        case tasks = "任务", rules = "自动派活", agents = "用量"
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
    @State private var detail: TaskRef?
    @State private var ruleEditing: RuleEdit?
    /// 权限档存在 UserDefaults 里，改了之后靠它刷新界面
    @State private var accessTick = 0
    @State private var showPicker = false
    @State private var panelOpen = false
    /// 底部输入条的实际高度：办公室按剩下的高度算大小
    @State private var barH: CGFloat = 130
    @State private var selected: String?

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
        let cast = OfficeCast.build()
        return GeometryReader { geo in
            // 办公室 + 底下的输入条合成一整块，按窗口宽高整体缩放，不裁剪、不滚动；
            // 窗口比 16:9 更高时，办公室竖向最多拉长 12%，其余留白
            let availW = geo.size.width - 40
            let availH = geo.size.height - 24
            let hFit = availH - barH - 3
            let w0 = min(availW, 1500)
            let w = hFit >= w0 * OfficeLayout.H / OfficeLayout.W ? w0 : max(480, hFit * OfficeLayout.W / OfficeLayout.H)
            let hMin = w * OfficeLayout.H / OfficeLayout.W
            let h = max(hMin, min(hFit, hMin * 1.12))
            VStack(spacing: 0) {
                PixelOfficeScene(agents: cast, board: board, selected: $selected)
                    .frame(width: w, height: h)
                    .overlay {
                        // 面板开着时，点面板以外的地方就收起来
                        if panelOpen {
                            Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { panelOpen = false }
                        }
                    }
                    .overlay(alignment: .topLeading) { hudTitle(cast) }
                    .overlay(alignment: .topTrailing) { hudSigns }
                    .overlay(alignment: .topLeading) {
                        if let a = cast.first(where: { $0.id == selected }) {
                            agentCard(a).frame(width: 280).padding(.leading, 12).padding(.top, 60)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if panelOpen { panel(width: min(w * 0.44, 460), height: h - 54 - 12).padding(.top, 54).padding(.trailing, 12) }
                    }
                composer
                    .pixelBar()
                    .frame(width: w)
                    .background(GeometryReader { g in Color.clear.preference(key: BarHeightKey.self, value: g.size.height) })
            }
            .pixelFrame()
            .frame(width: geo.size.width, height: geo.size.height)
            .onPreferenceChange(BarHeightKey.self) { v in
                if abs(v - barH) > 0.5 { barH = v }
            }
        }
        .background(AmbientBackground())
        .animation(.easeOut(duration: 0.18), value: panelOpen)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { SettingsWindow.show() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Agent 开关、审批规则（设置 → AI 调度台）")
            }
        }
        .sheet(item: $ruleEditing) { e in
            DispatchRuleEditor(existing: e.rule, preset: e.preset)
        }
        .sheet(item: $detail) { ref in
            TaskDetailSheet(ref: ref)
        }
        .onAppear {
            ocStore.refresh(after: 0.6)
            focused = true
        }
        .onChange(of: draft.focusTick) { _, _ in
            focused = true
        }
    }

    // MARK: - 办公室里的牌子

    private var board: OfficeBoard {
        let start = Calendar.current.startOfDay(for: Date())
        let done = ledger.jobs.filter { $0.state == .done && ($0.endedAt ?? $0.createdAt) >= start }.count
        return OfficeBoard(active: ledger.activeCount + extraRuns.count, waiting: attention, done: done)
    }

    private func hudTitle(_ cast: [OfficeAgent]) -> some View {
        let working = cast.filter { $0.mood == .working }.count
        let failed = cast.filter { $0.mood == .error }.count
        var parts: [String] = ["\(cast.count) 位 Agent"]
        if working > 0 { parts.append("\(working) 在忙") }
        if attention > 0 { parts.append("\(attention) 件等你") }
        if failed > 0 { parts.append("\(failed) 个没跑成") }
        if working == 0 && attention == 0 && failed == 0 { parts.append("都在休息") }
        if board.done > 0 { parts.append("今天完成 \(board.done)") }
        return VStack(alignment: .leading, spacing: 2) {
            Text("AI 办公室").font(OfficeAssets.pixelFont(18))
            Text(parts.joined(separator: " · ")).font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .pixelBox()
        .padding(.leading, 14).padding(.top, 12)
    }

    private var hudSigns: some View {
        HStack(spacing: 6) {
            sign(.tasks, "list.bullet.rectangle", badge: attention > 0 ? "\(attention)" : nil)
            sign(.rules, "clock.arrow.2.circlepath", badge: nil)
            sign(.agents, "chart.bar", badge: nil)
        }
        .padding(.trailing, 14).padding(.top, 14)
    }

    /// 挂在办公室墙上的牌子：点一下，在办公室里展开对应的面板
    private func sign(_ t: Tab, _ icon: String, badge: String?) -> some View {
        let on = panelOpen && tab == t
        return Button {
            if on { panelOpen = false } else { tab = t; panelOpen = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(t.rawValue).font(OfficeAssets.pixelFont(14))
                if let badge {
                    Text(badge).font(OfficeAssets.pixelFont(12)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Color.red, in: Rectangle())
                }
            }
            .foregroundStyle(on ? Color.white : Color(red: 1, green: 0.94, blue: 0.82))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(on ? Brand.orange : Color(red: 0.42, green: 0.27, blue: 0.14))
            .overlay(Rectangle().strokeBorder(Color(red: 0.1, green: 0.07, blue: 0.04), lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func agentCard(_ a: OfficeAgent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Rectangle().fill(a.color).frame(width: 10, height: 10)
                Text(a.name).font(OfficeAssets.pixelFont(16))
                Text(OfficeBreed.of(a.id).name).font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary)
                Text(a.mood.label).font(OfficeAssets.pixelFont(12)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(a.mood.tint, in: Rectangle())
                Spacer(minLength: 0)
                Button { selected = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            if !a.task.trimmed.isEmpty {
                Text(a.task.trimmed).font(OfficeAssets.pixelFont(12)).lineLimit(3).textSelection(.enabled)
            } else {
                Text(a.mood == .idle ? "手头没有活，在沙发上歇着。" : "没有记录到具体任务。").font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary)
            }
            if let act = a.activity, !act.isEmpty {
                Label(act, systemImage: "terminal").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let st = a.started {
                Text("开始于 " + clockText(st)).font(OfficeAssets.pixelFont(12)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                if let id = a.jobId {
                    cardButton("查看详情", "doc.text") { detail = .job(id) }
                    if a.jobActive { cardButton("停止", "stop.circle") { ledger.stop(id) } }
                    if a.canRerun { cardButton("重跑", "arrow.clockwise") { ledger.rerun(id) } }
                }
                if a.mood == .waiting { cardButton("去处理", "bell") { tab = .tasks; panelOpen = true } }
                Button { draft.targetId = a.id.hasPrefix("src.") ? draft.targetId : a.id; focused = true } label: {
                    Text("派活给它").font(OfficeAssets.pixelFont(12)).foregroundStyle(Brand.orange)
                }
                .buttonStyle(.plain)
                .disabled(a.id.hasPrefix("src."))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelCard()
    }

    private func cardButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(OfficeAssets.pixelFont(12))
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 昨日小记：昨天派过什么、结果怎样
    private var memoCard: some View {
        let cal = Calendar.current
        let end = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -1, to: end) ?? end
        let js = ledger.jobs.filter { j in
            let d = j.startedAt ?? j.createdAt
            return d >= start && d < end
        }
        let ok = js.filter { $0.state == .done }.count
        let bad = js.filter { $0.state == .failed || $0.state == .interrupted }.count
        return VStack(alignment: .leading, spacing: 6) {
            Text("昨日小记").font(OfficeAssets.pixelFont(14)).foregroundStyle(.secondary)
            if js.isEmpty {
                Text("昨天没有派活").font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary)
            } else {
                Text("派出 \(js.count) · 完成 \(ok)" + (bad > 0 ? " · 没跑成 \(bad)" : "")).font(OfficeAssets.pixelFont(12))
                ForEach(js.prefix(3)) { j in
                    Text("· " + j.targetTitle + "：" + j.prompt.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelCard()
    }

    // MARK: - 办公室里的面板：任务 / 自动派活 / 用量

    private func panel(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(tab.rawValue).font(OfficeAssets.pixelFont(14)).lineLimit(1)
                if tab == .tasks, attention > 0 {
                    Text("等你 \(attention)").font(OfficeAssets.pixelFont(12)).lineLimit(1).fixedSize().foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Color.orange, in: Rectangle())
                }
                Spacer(minLength: 0)
                Button { panelOpen = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).padding(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            PixelRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if tab == .tasks { memoCard }
                    switch tab {
                    case .tasks: tasksTab
                    case .rules: rulesTab
                    case .agents: agentsTab
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: width, height: height)
        .pixelBox()
    }

    // MARK: - 派活输入条

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: $draft.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(2...8)
                .focused($focused)
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
                selected = t.id
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
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(TaskFilter.allCases, id: \.self) { f in
                        Button { filter = f } label: {
                            Text(f.rawValue).font(OfficeAssets.pixelFont(12))
                                .foregroundStyle(filter == f ? Color.white : Color.primary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(filter == f ? Brand.orange : Color.primary.opacity(0.08), in: Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
                if ledger.jobs.contains(where: { !$0.state.isActive }) || !results.records.isEmpty {
                    Button("清空已结束") {
                        ledger.clearFinished()
                        results.clear()
                    }
                    .buttonStyle(.plain).font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary)
                }
            }

            if showAttention {
                block("需要你处理", count: attention) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
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
                    VStack(spacing: 6) {
                        ForEach(activeJobs) { j in WorkbenchJobRow(j: j) { detail = .job(j.id) } }
                        ForEach(others) { r in WorkbenchRunRow(r: r) }
                    }
                }
            }

            ForEach(grouped(shown), id: \.title) { g in
                block(g.title, count: nil) {
                    VStack(spacing: 6) {
                        ForEach(g.items) { a in
                            switch a {
                            case .job(let j): WorkbenchJobRow(j: j) { detail = .job(j.id) }
                            case .record(let r): WorkbenchRecordRow(r: r) { detail = .record(r.id) }
                            }
                        }
                    }
                }
            }

            if all.count > 20 {
                Button(showAll ? "收起" : "显示更多（还有 \(all.count - 20) 条）") { showAll.toggle() }
                    .buttonStyle(.plain).font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 14) {
            block("规则", count: engine.rules.isEmpty ? nil : engine.rules.count, trailing: {
                Menu {
                    ForEach(DispatchRuleTemplate.all) { t in
                        Button { ruleEditing = RuleEdit(rule: nil, preset: t.rule) } label: { Label(t.title, systemImage: t.icon) }
                    }
                    Divider()
                    Button("空白规则…") { ruleEditing = RuleEdit(rule: nil, preset: nil) }
                } label: {
                    Label("添加", systemImage: "plus").font(OfficeAssets.pixelFont(12))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
            }) {
                if engine.rules.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("到点、或滴答任务带上标签，Agent 就自己开工。默认关闭、默认只读；跑完没有要你拍板的事，不打扰你。")
                            .font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                            ForEach(DispatchRuleTemplate.all) { t in templateCard(t) }
                        }
                    }
                } else {
                    VStack(spacing: 6) {
                        ForEach(engine.rules) { r in ruleRow(r) }
                    }
                }
            }

            let list = reminders
            if !list.isEmpty {
                block("待复查", count: list.count) {
                    VStack(spacing: 6) {
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
                    .frame(width: 24, height: 24).background(Brand.orange.opacity(0.14), in: Rectangle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(OfficeAssets.pixelFont(12))
                    Text(t.detail).font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle").foregroundStyle(.tertiary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pixelTile()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func ruleRow(_ r: DispatchRule) -> some View {
        let icon = r.trigger == .todoTag ? "tag" : (r.trigger == .workdays ? "calendar" : "clock")
        let used = engine.firedToday(r)
        var status = [engine.nextText(r)]
        if let n = r.lastNote, !n.isEmpty { status.append("上次 " + n) }
        if r.enabled, let t = engine.lastCheck { status.append("检查于 " + clockText(t)) }
        return HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background((r.enabled ? Brand.orange : Color.gray), in: Rectangle())
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name.isEmpty ? "未命名" : r.name).font(OfficeAssets.pixelFont(12)).lineLimit(1)
                Text(r.baseSummary + " · " + status.joined(separator: " · ")).font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(used)/\(r.dailyLimit)").font(OfficeAssets.pixelFont(12)).monospacedDigit()
                .foregroundStyle(used >= r.dailyLimit ? Color.orange : Color.secondary).fixedSize().help("今天已触发 / 每天上限")
            moreMenu {
                Button("预览会派哪些") { previewRule(r) }
                Button("现在试跑一次") { engine.runNow(r.id) }
                Button("修改…") { ruleEditing = RuleEdit(rule: r, preset: nil) }
            }
            Toggle("", isOn: ruleToggle(r)).labelsHidden().toggleStyle(PixelToggleStyle())
        }
        .rowCard()
    }

    private func previewRule(_ r: DispatchRule) {
        let alert = NSAlert()
        alert.messageText = "「\(r.name.isEmpty ? "未命名" : r.name)」" + (r.enabled ? "" : "（已关闭）")
        alert.informativeText = r.baseSummary + "\n\n" + engine.preview(r)
        alert.addButton(withTitle: "好")
        alert.runModal()
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
            HStack(spacing: 8) {
                Image(systemName: "alarm").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(Color.indigo, in: Rectangle())
                Text(t.cleanTitle).font(OfficeAssets.pixelFont(12)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(when).font(OfficeAssets.pixelFont(12)).foregroundStyle(late ? Color.red : Color.secondary).fixedSize()
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
        return VStack(alignment: .leading, spacing: 14) {
            block("用量", count: nil) {
                VStack(spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        usageTile("今天", since: Calendar.current.startOfDay(for: Date()))
                        usageTile("近 7 天", since: Date().addingTimeInterval(-7 * 86400))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("近 7 天派活").font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary)
                        Chart(weekData) { d in
                            BarMark(x: .value("日期", d.day, unit: .day), y: .value("轮数", d.n), width: .ratio(0.5))
                                .foregroundStyle(by: .value("结果", d.kind))
                        }
                        .chartForegroundStyleScale(["完成": Color.green, "没跑成": Color.red, "其他": Color.gray.opacity(0.45)])
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day)) { _ in
                                AxisValueLabel(format: .dateTime.weekday(.narrow))
                            }
                        }
                        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                        .chartLegend(position: .trailing, alignment: .top, spacing: 8)
                        .font(OfficeAssets.pixelFont(12))
                        .frame(height: 84)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pixelTile()
                }
            }
            block("Agent", count: list.filter(\.enabled).count) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
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
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(u.runs)").font(OfficeAssets.pixelFont(24)).monospacedDigit()
                Text("轮").font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary)
            }
            Text(detail.isEmpty ? "—" : detail.joined(separator: " · "))
                .font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelTile()
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
            HStack(spacing: 8) {
                Image(systemName: p.icon).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(tint, in: Rectangle())
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.name).font(OfficeAssets.pixelFont(14)).lineLimit(1)
                        Rectangle().fill(!on ? Color.gray : (busy > 0 ? Color.orange : Color.green)).frame(width: 6, height: 6)
                        Text(state).font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(stats.joined(separator: " · ")).font(OfficeAssets.pixelFont(12)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if p.kind == .command, on {
                    let _ = accessTick
                    Text(p.access.label).font(OfficeAssets.pixelFont(12))
                        .foregroundStyle(p.access == .full ? Color.red : Color.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((p.access == .full ? Color.red : Color.primary).opacity(0.08), in: Rectangle())
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pixelTile()
            .opacity(on ? 1 : 0.5)
            .contentShape(Rectangle())
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
                Text(title).font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary)
                if let count, count > 0 {
                    Text("\(count)").font(OfficeAssets.pixelFont(12)).monospacedDigit().foregroundStyle(.tertiary)
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
            Text(title).font(OfficeAssets.pixelFont(14)).foregroundStyle(.secondary)
            if let hint { Text(hint).font(OfficeAssets.pixelFont(12)).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 50)
    }

    private func moreMenu<C: View>(@ViewBuilder _ items: () -> C) -> some View {
        Menu { items() } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24).background(Color.primary.opacity(0.08), in: Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

// MARK: - 行

private extension View {
    /// 列表里一行的外框：统一的留白和圆角
    func rowCard() -> some View {
        self
            .padding(.horizontal, 8).padding(.vertical, 6)
            .pixelTile()
            .contentShape(Rectangle())
    }
}

private struct RowMore<C: View>: View {
    @ViewBuilder var items: C

    var body: some View {
        Menu { items } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24).background(Color.primary.opacity(0.08), in: Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

private struct StatusTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(OfficeAssets.pixelFont(12)).foregroundStyle(color).lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 1.5).background(color.opacity(0.13), in: Rectangle())
    }
}

private struct RowIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            .frame(width: 24, height: 24).background(tint, in: Rectangle())
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
    private var ledger: DispatchLedger { DispatchLedger.shared }
    private var target: DispatchTarget? { DispatchTarget(rawValue: j.target) }
    /// Agent 的结果（账本自己拿到的，或从验收卡 / opencode 本地数据库里取的；不另外调用模型）
    private var preview: String { (j.result ?? "").trimmed }

    var body: some View {
        HStack(spacing: 8) {
            RowIcon(symbol: target?.icon ?? "terminal", tint: target?.color ?? .gray)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(j.prompt.replacingOccurrences(of: "\n", with: " ")).font(OfficeAssets.pixelFont(12)).lineLimit(1).truncationMode(.tail)
                    StatusTag(text: j.state.label, color: color)
                }
                meta
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
                    Button("查看详情") { onDetail() }
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
        .frame(height: 36)
        .rowCard()
        .onTapGesture { onDetail() }
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
                .frame(width: 24, height: 24).background(Color.primary.opacity(0.08), in: Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 一行小字：目标 · 来源 · 目录 · 权限 · 时间 / 耗时 · 用量；没跑成时带上原因
    @ViewBuilder private var meta: some View {
        if j.state == .running {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let s = max(Int(ctx.date.timeIntervalSince(j.startedAt ?? ctx.date)), 0)
                Text(base(extra: String(format: "%d:%02d", s / 60, s % 60))).font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        } else {
            Text(base(extra: nil)).font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
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
    var onDetail: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RowIcon(symbol: r.source.icon, tint: r.source.color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("\(r.source.title) · \(r.project)").font(OfficeAssets.pixelFont(12)).lineLimit(1).truncationMode(.middle)
                    StatusTag(text: r.failed ? "没做成" : "已完成", color: r.failed ? .red : .green)
                }
                Text(meta).font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RowMore {
                Button("查看详情") { onDetail() }
                Button("复制结果") { copyToPasteboard(r.summary) }
                if !r.cwd.isEmpty, FileManager.default.fileExists(atPath: r.cwd) {
                    Button("打开目录") { NSWorkspace.shared.open(URL(fileURLWithPath: r.cwd)) }
                }
                Divider()
                Button("删除这条记录", role: .destructive) { AgentResultStore.shared.remove(r.id) }
            }
        }
        .frame(height: 36)
        .rowCard()
        .onTapGesture { onDetail() }
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
        HStack(spacing: 8) {
            RowIcon(symbol: r.source.icon, tint: r.source.color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("\(r.source.title) · \(r.project)").font(OfficeAssets.pixelFont(12)).lineLimit(1).truncationMode(.middle)
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
                    .frame(width: 24, height: 24).background(Color.primary.opacity(0.08), in: Rectangle())
                }
                .buttonStyle(.plain).disabled(r.stopping)
                .help(r.stopping ? "正在停止…" : "停止")
            }
        }
        .frame(height: 36)
        .rowCard()
    }
}


private struct BarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - 像素风的卡片 / 边框

private struct PixelPalette {
    let bg: Color
    let line: Color

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            bg = Color(red: 0x2A / 255, green: 0x21 / 255, blue: 0x1A / 255)
            line = Color(red: 0x8A / 255, green: 0x6A / 255, blue: 0x44 / 255)
        } else {
            bg = Color(red: 0xFB / 255, green: 0xF1 / 255, blue: 0xDA / 255)
            line = Color(red: 0x6B / 255, green: 0x44 / 255, blue: 0x23 / 255)
        }
    }
}

private struct PixelCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var padding: CGFloat = 12

    func body(content: Content) -> some View {
        let c = PixelPalette(scheme)
        return content
            .padding(padding)
            .background(c.bg)
            .overlay(Rectangle().strokeBorder(c.line, lineWidth: 2))
            .background(c.line.opacity(0.28).offset(x: 3, y: 3))
    }
}

private struct PixelFrameModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let c = PixelPalette(scheme)
        return content
            .overlay(Rectangle().strokeBorder(c.line, lineWidth: 4))
            .background(c.line.opacity(0.28).offset(x: 4, y: 4))
    }
}

private struct PixelBarModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let c = PixelPalette(scheme)
        return content
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(c.bg)
            .overlay(alignment: .top) { Rectangle().fill(c.line).frame(height: 3) }
    }
}

/// 像素风的开关：方块滑轨
private struct PixelToggleStyle: ToggleStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let c = PixelPalette(scheme)
        return Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Rectangle().fill(configuration.isOn ? Brand.orange : c.line.opacity(0.25))
                Rectangle().fill(Color.white).frame(width: 10, height: 10).padding(2)
            }
            .frame(width: 30, height: 14)
            .overlay(Rectangle().strokeBorder(c.line, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

private struct PixelRule: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle().fill(PixelPalette(scheme).line).frame(height: 2)
    }
}

private struct PixelTileModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let c = PixelPalette(scheme)
        return content
            .background(c.line.opacity(0.09))
            .overlay(Rectangle().strokeBorder(c.line.opacity(0.5), lineWidth: 1.5))
    }
}

private extension View {
    func pixelTile() -> some View { modifier(PixelTileModifier()) }
    func pixelBar() -> some View { modifier(PixelBarModifier()) }
    func pixelCard() -> some View { modifier(PixelCardModifier()) }
    func pixelBox() -> some View { modifier(PixelCardModifier(padding: 0)) }
    func pixelFrame() -> some View { modifier(PixelFrameModifier()) }
}

// MARK: - 任务详情（所有记录统一的弹窗）

private enum TaskRef: Identifiable {
    case job(UUID)
    case record(UUID)

    var id: UUID {
        switch self {
        case .job(let i), .record(let i): return i
        }
    }
}

/// 一条记录的详情：指令 / 信息 / 结果 / 时间线 / 日志 合在一起；没有的段落（比如外部 Agent 没有日志）就不显示
private struct TaskDetailSheet: View {
    let ref: TaskRef
    @ObservedObject private var ledger = DispatchLedger.shared
    @ObservedObject private var results = AgentResultStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var log = ""

    private struct Action: Identifiable {
        let id = UUID()
        let title: String
        let run: () -> Void
        var danger = false
    }

    private struct Model {
        var title: String
        var icon: String
        var tint: Color
        var status: String
        var statusColor: Color
        var prompt: String?
        var info: [(String, String)] = []
        var resultTitle = "结果"
        var result: String?
        var events: [(Date, String)] = []
        var logId: UUID?
        var active = false
        var actions: [Action] = []
    }

    var body: some View {
        let c = PixelPalette(scheme)
        Group {
            if let m = model {
                content(m, c)
            } else {
                VStack(spacing: 12) {
                    Text("这条记录已经不在了").font(OfficeAssets.pixelFont(14)).foregroundStyle(.secondary)
                    Button("关闭") { dismiss() }
                }
                .padding(40).frame(width: 520, height: 200)
            }
        }
        .background(c.bg)
        .task(id: ref.id) { await followLog() }
    }

    private var model: Model? {
        switch ref {
        case .job(let id):
            guard let j = ledger.jobs.first(where: { $0.id == id }) else { return nil }
            let t = DispatchTarget(rawValue: j.target)
            var m = Model(title: j.targetTitle, icon: t?.icon ?? "terminal", tint: t?.color ?? .gray,
                          status: j.state.label, statusColor: Self.color(j.state))
            m.prompt = j.prompt
            if !j.cwd.isEmpty { m.info.append(("目录", (j.cwd as NSString).abbreviatingWithTildeInPath)) }
            if let a = j.access, let acc = AgentAccess(rawValue: a) { m.info.append(("权限", acc.label)) }
            m.info.append(("来源", j.origin + (j.hasMaterial ? " · 带资料" : "")))
            if j.managed { m.info.append(("尝试", "\(j.attempts) 次")) }
            if let d = j.duration { m.info.append(("耗时", Self.duration(d))) }
            if let sid = j.sessionId, !sid.isEmpty { m.info.append(("会话", sid)) }
            if let u = j.usage {
                m.info.append(("用量", DispatchResult.compact(u.tokens) + " Token（入 \(DispatchResult.compact(u.input)) · 出 \(DispatchResult.compact(u.output))）"
                    + (u.cost.map { String(format: " · $%.4f", $0) } ?? "")))
            } else if j.managed, !j.state.isActive {
                m.info.append(("用量", "未上报"))
            }
            if let r = j.result, !r.isEmpty {
                m.result = r
            } else if !j.message.isEmpty {
                m.result = j.message
                m.resultTitle = j.state == .done ? "输出" : "说明"
            }
            m.events = j.events.map { ($0.at, $0.text) }
            m.active = j.state.isActive
            if j.managed { m.logId = j.id }
            if j.managed {
                if j.state.isActive {
                    m.actions.append(Action(title: "停止") { ledger.stop(j.id) })
                } else {
                    m.actions.append(Action(title: "重跑") { ledger.rerun(j.id) })
                }
            }
            if j.hasMaterial { m.actions.append(Action(title: "查看资料") { NSWorkspace.shared.open(DispatchLedger.materialURL(j.id)) }) }
            if !j.cwd.isEmpty { m.actions.append(Action(title: "打开目录") { NSWorkspace.shared.open(URL(fileURLWithPath: j.cwd)) }) }
            if j.managed { m.actions.append(Action(title: "打开日志文件") { NSWorkspace.shared.open(DispatchLedger.logURL(j.id)) }) }
            return m
        case .record(let id):
            guard let r = results.records.first(where: { $0.id == id }) else { return nil }
            var m = Model(title: r.source.title, icon: r.source.icon, tint: r.source.color,
                          status: r.failed ? "没做成" : "已完成", statusColor: r.failed ? .red : .green)
            m.info.append(("项目", r.project))
            if !r.cwd.isEmpty { m.info.append(("目录", (r.cwd as NSString).abbreviatingWithTildeInPath)) }
            m.info.append(("来源", "外部 Agent"))
            if let d = r.duration { m.info.append(("耗时", Self.duration(d))) }
            if let sid = r.sessionId, !sid.isEmpty { m.info.append(("会话", sid)) }
            m.result = r.summary
            // 外部 Agent 只留下了「做完了」这一个事件：开始时间由耗时倒推
            if let d = r.duration { m.events.append((r.at.addingTimeInterval(-d), "开始")) }
            m.events.append((r.at, r.failed ? "没做成" : "完成"))
            if !r.summary.isEmpty { m.actions.append(Action(title: "复制结果") { copyToPasteboard(r.summary) }) }
            if !r.cwd.isEmpty, FileManager.default.fileExists(atPath: r.cwd) {
                m.actions.append(Action(title: "打开目录") { NSWorkspace.shared.open(URL(fileURLWithPath: r.cwd)) })
            }
            m.actions.append(Action(title: "删除这条记录", run: {
                AgentResultStore.shared.remove(r.id)
                dismiss()
            }, danger: true))
            return m
        }
    }

    private func content(_ m: Model, _ c: PixelPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RowIcon(symbol: m.icon, tint: m.tint)
                Text(m.title).font(OfficeAssets.pixelFont(16)).lineLimit(1)
                StatusTag(text: m.status, color: m.statusColor)
                Spacer(minLength: 0)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).padding(4)
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            PixelRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let p = m.prompt, !p.trimmed.isEmpty {
                        section("指令") {
                            Text(p).font(.system(size: 12.5)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    section("信息") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(m.info.enumerated()), id: \.offset) { _, kv in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(kv.0).font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                                    Text(kv.1).font(.system(size: 12.5)).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                    if let r = m.result, !r.trimmed.isEmpty {
                        section(m.resultTitle) {
                            Text(markdown(r)).font(.system(size: 12.5)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !m.events.isEmpty {
                        section("时间线") {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(m.events.enumerated()), id: \.offset) { _, e in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Rectangle().fill(c.line).frame(width: 6, height: 6)
                                        Text(Self.time(e.0)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                                        Text(e.1).font(.system(size: 12.5))
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                        }
                    }
                    if m.logId != nil, !log.isEmpty {
                        section("日志") {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    Text(log).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    Color.clear.frame(height: 1).id("logEnd")
                                }
                                .frame(height: 190)
                                .onChange(of: log) { _, _ in proxy.scrollTo("logEnd", anchor: .bottom) }
                                .onAppear { proxy.scrollTo("logEnd", anchor: .bottom) }
                            }
                        }
                    }
                }
                .padding(14)
            }
            .scrollIndicators(.hidden)
            if !m.actions.isEmpty {
                PixelRule()
                HStack(spacing: 6) {
                    ForEach(m.actions) { a in
                        Button(action: a.run) {
                            Text(a.title).font(OfficeAssets.pixelFont(12))
                                .foregroundStyle(a.danger ? Color.red : Color.primary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(c.line.opacity(0.12), in: Rectangle())
                                .overlay(Rectangle().strokeBorder(c.line.opacity(0.5), lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .frame(width: 560, height: 620)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Rectangle().fill(Brand.orange).frame(width: 6, height: 6)
                Text(title).font(OfficeAssets.pixelFont(12)).foregroundStyle(.secondary)
            }
            body().padding(8).frame(maxWidth: .infinity, alignment: .leading).pixelTile()
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        let opt = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: opt)) ?? AttributedString(s)
    }

    /// 读日志末尾；任务还在跑就每两秒刷新一次
    private func followLog() async {
        guard case .job(let id) = ref else { return }
        while !Task.isCancelled {
            log = Self.readLogTail(id)
            let active = ledger.jobs.first(where: { $0.id == id })?.state.isActive ?? false
            if !active { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private static func readLogTail(_ id: UUID) -> String {
        guard let h = try? FileHandle(forReadingFrom: DispatchLedger.logURL(id)) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 40_000 ? size - 40_000 : 0)
        let s = String(data: h.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let clean = s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func color(_ s: LedgerState) -> Color {
        switch s {
        case .queued, .running: return .orange
        case .retrying: return .yellow
        case .done: return .green
        case .failed: return .red
        case .cancelled, .interrupted: return .secondary
        }
    }

    private static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm:ss" : "M/d HH:mm:ss"
        return f.string(from: d)
    }

    private static func duration(_ s: TimeInterval) -> String {
        let n = Int(s)
        return n >= 60 ? "\(n / 60) 分 \(n % 60) 秒" : "\(n) 秒"
    }
}
