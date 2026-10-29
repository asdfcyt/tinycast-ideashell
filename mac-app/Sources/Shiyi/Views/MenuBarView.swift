import AppKit
import SwiftUI

/// 菜单栏上的小标签：平时是「今天 N · 逾期 M」；在专注 / 休息时变成倒计时
struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel

    var body: some View { LabelContent(focus: model.focus) }

    private struct LabelContent: View {
        @EnvironmentObject var model: AppModel
        @ObservedObject var focus: FocusStore

        var body: some View {
            HStack(spacing: 4) {
                if let r = focus.run {
                    Image(systemName: r.paused ? "pause.fill" : (r.kind.isBreak ? "cup.and.saucer.fill" : "timer"))
                    FocusTick(clock: focus.clock) { now in
                        let left = max(Int(r.remainingMs(now) / 1000), 0)
                        Text(String(format: "%02d:%02d", left / 60, left % 60)).monospacedDigit()
                    }
                } else {
                    Image(systemName: "checklist")
                    if model.hasDida, let ov = model.overview {
                        Text("\(ov.todayTasks().count)" + (ov.overdue.isEmpty ? "" : " · \(ov.overdue.count)"))
                    }
                }
            }
            .task { model.start() }
        }
    }
}

/// 菜单栏小组件：今天 N · 逾期 M，点圆圈直接完成。
/// 顶部一行放标题和图标按钮（快速记录 / 刷新 / 打开拾忆 / 退出），下面是三项小统计、专注条和紧凑的待办列表。
struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    /// 灵动岛里不显示收集箱（没有日期的待办），只显示定在今天的
    var showInbox = true
    /// 出现 / 窗口变成 key 时自动刷新。灵动岛里关掉：点一下按钮窗口就变成 key，刷新结果会压在高度动画上，由岛在展开动画停稳后统一刷新
    var autoRefresh = true
    @State private var adding = false
    @ObservedObject private var shelf = StickyShelf.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MicStrip()
            Divider()
            MenuFocus(focus: model.focus)
            if adding {
                QuickAddView(compact: true).environmentObject(model)
            } else if !model.hasDida {
                Text("还没有填写滴答清单 API 口令").foregroundStyle(.secondary).padding(14)
            } else if let ov = model.overview {
                tasks(ov)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(20)
            }
        }
        .frame(width: 380)
        .task { model.start() }
        .onAppear { refreshIfNeeded() }
        // 弹窗每次打开（窗口变成 key）都刷新一次，不用等定时器
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refreshIfNeeded() }
    }

    @State private var lastRefresh = Date.distantPast

    private func refreshIfNeeded() {
        guard autoRefresh, model.hasDida, Date().timeIntervalSince(lastRefresh) > 3 else { return }
        lastRefresh = Date()
        Task {
            await model.loadOverview(silent: true)
            await model.focus.refresh()
        }
    }

    /// 正在专注 / 休息时，弹窗顶部是计时条；没在计时就是一行「开始专注」
    private struct MenuFocus: View {
        @EnvironmentObject var model: AppModel
        @ObservedObject var focus: FocusStore

        static func shortTitle(_ t: String?) -> String {
            guard let t, !t.isEmpty else { return "关联待办" }
            // 按显示宽度估算：中文算 2，其他算 1，总宽不超过 14
            var w = 0, out = ""
            for ch in t {
                let cw = ch.unicodeScalars.first.map { $0.value > 0x2E80 ? 2 : 1 } ?? 1
                if w + cw > 14 { return out + "…" }
                w += cw; out.append(ch)
            }
            return out
        }
        var body: some View {
            VStack(spacing: 0) {
                if focus.run != nil {
                    FocusRunBar(focus: focus).padding(.horizontal, 12).padding(.vertical, 8)
                } else {
                    HStack(spacing: 8) {
                        if let b = focus.pendingBreak {
                            Button { focus.start() } label: {
                                Label("开始\(b.label) \(focus.minutes) 分钟", systemImage: "cup.and.saucer.fill").font(.callout.weight(.medium))
                            }
                            .buttonStyle(.borderless).fixedSize().layoutPriority(2)
                            Button("跳过") { focus.skipBreak() }
                                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                                .help("跳过休息，直接专注")
                        } else {
                            HStack(spacing: 5) {
                                Button { focus.quickFocus(focus.minutes) } label: {
                                    Label("开始专注", systemImage: "play.fill").font(.callout.weight(.medium))
                                }
                                .buttonStyle(.borderless).fixedSize()
                                DurationMenu(focus: focus)
                            }
                            .layoutPriority(2)
                        }
                        Spacer(minLength: 6)
                        // 关联待办：选了之后「开始专注」就会绑定它
                        FocusTaskMenu(focus: focus) {
                            HStack(spacing: 4) {
                                Image(systemName: focus.task == nil ? "link" : "link.circle.fill")
                                    .foregroundStyle(focus.task == nil ? Color.secondary : Brand.orange)
                                // Menu 的标签不受 frame 限制，长标题会把整个小组件撑宽，所以按字数手动截断
                                Text(Self.shortTitle(focus.task?.cleanTitle)).lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .fixedSize()
                        .help(focus.task?.cleanTitle ?? "关联待办")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                Divider()
            }
        }
    }

    /// 「15 分钟 ⌄」：点一下弹出时长列表，选了就换（休息时长不在这里改）
    private struct DurationMenu: View {
        @ObservedObject var focus: FocusStore

        private var options: [Int] {
            FocusStore.choices.contains(focus.minutes) ? FocusStore.choices : (FocusStore.choices + [focus.minutes]).sorted()
        }

        var body: some View {
            Menu {
                ForEach(options, id: \.self) { m in
                    Button { focus.minutes = m } label: {
                        if focus.minutes == m { Label("\(m) 分钟", systemImage: "checkmark") } else { Text("\(m) 分钟") }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text("\(focus.minutes) 分钟").font(.callout.weight(.semibold)).monospacedDigit()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .bold))
                }
                .foregroundStyle(Brand.orange)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Brand.orange.opacity(0.14), in: Capsule())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize()
            .help("选择专注时长")
        }
    }

    private func iconButton(_ icon: String, _ help: String, tint: Color = .secondary, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var header: some View {
        HStack(spacing: 6) {
            let ov = model.overview
            VStack(alignment: .leading, spacing: 1) {
                Text("今天 \(ov?.todayTasks().count ?? 0) · 逾期 \(ov?.overdue.count ?? 0)").font(.system(size: 15, weight: .semibold))
                Text(Day.label(Day.today()) + " " + Date().formatted(.dateTime.month().day().weekday())).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if model.todosLoading { ProgressView().controlSize(.small) }
            iconButton(adding ? "xmark" : "plus", adding ? "收起" : "快速记录") { adding.toggle() }
            iconButton("note.text.badge.plus", "新建便签（可钉在桌面上）") { StickyController.shared.create() }
            if !shelf.closed.isEmpty {
                Menu {
                    ForEach(shelf.closed.prefix(15)) { n in
                        Button(StickyShelf.preview(n)) { StickyController.shared.reopen(n.id) }
                    }
                    Divider()
                    Button("清空已关闭的便签") { StickyController.shared.clearClosed() }
                } label: {
                    Image(systemName: "tray.full")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.06), in: Circle())
                        .contentShape(Circle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("已关闭的便签")
            }
            iconButton("arrow.clockwise", "刷新") { Task { await model.loadOverview() } }
            iconButton("dot.radiowaves.left.and.right", "猛犸麦克风按键") { MicWindow.show() }
            iconButton("macwindow", "打开拾忆") { MainWindow.show() }
            iconButton("power", "退出") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }

    /// 三项小统计：今天已完成 / 今天专注 / 今天的笔记
    private func stats(_ ov: DidaOverview) -> some View {
        let today = Day.today()
        let done = ov.done.filter { $0.completedDate.map { Day.string($0) == today } ?? false }.count
        let total = ov.todayTasks().count + done
        let notes = model.timeline.filter { $0.day == today }.count
        let focusMin = model.focus.summary?.todayMin
        return HStack(spacing: 10) {
            stat("checkmark.circle", "\(done)/\(total)", "已完成", .green)
            stat("timer", focusMin.map(Self.compactMinutes) ?? "–", "专注", Brand.orange)
            stat("note.text", "\(notes)", "笔记", .blue)
        }
        .padding(.trailing, 12)
    }

    private func stat(_ icon: String, _ value: String, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(tint)
            Text(value).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .fixedSize()
    }

    /// 紧凑的时长：1小时15分 / 45分，保证不换行
    private static func compactMinutes(_ m: Int) -> String {
        let h = m / 60, r = m % 60
        if h == 0 { return "\(r)分" }
        return r == 0 ? "\(h)小时" : "\(h)小时\(r)分"
    }

    /// 全部直接铺开，不用滚动条：今天的全部显示；逾期最多 6 条、收集箱最多 3 条，其余提示去主窗口看
    private func tasks(_ ov: DidaOverview) -> some View {
        let overdue = ov.overdue.sorted { ($0.date ?? "") < ($1.date ?? "") }
        let today = ov.todayTasks().sorted { ($0.time ?? "99:99") < ($1.time ?? "99:99") }
        let inbox = showInbox ? ov.undated : []
        return VStack(alignment: .leading, spacing: 0) {
            if let e = model.todosError { Text(e).font(.caption).foregroundStyle(.orange).padding(.horizontal, 12).padding(.vertical, 6) }
            HStack(spacing: 0) {
                sectionLabel("今天", today.count, .primary)
                Spacer(minLength: 8)
                stats(ov).padding(.top, 8)
            }
            if today.isEmpty {
                Text("今天没有待办").font(.callout).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.vertical, 4)
            }
            ForEach(today) { MenuTaskRow(task: $0) }
            if !overdue.isEmpty {
                sectionLabel("逾期", overdue.count, .red)
                ForEach(overdue.prefix(6)) { MenuTaskRow(task: $0, overdue: true) }
                if overdue.count > 6 { more(overdue.count - 6) }
            }
            if !inbox.isEmpty {
                sectionLabel("收集箱", inbox.count, .secondary)
                ForEach(inbox.prefix(3)) { MenuTaskRow(task: $0, inbox: true) }
                if inbox.count > 3 { more(inbox.count - 3) }
            }
        }
        .padding(.vertical, 4)
    }

    private func more(_ n: Int) -> some View {
        Text("还有 \(n) 个，在拾忆里查看").font(.caption).foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.vertical, 3)
    }

    private func sectionLabel(_ text: String, _ count: Int, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(text).font(.caption.weight(.bold)).foregroundStyle(tint)
            Text("\(count)").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
    }
}

/// 菜单栏里的一行待办：圆圈 + 标题（一行）+ 右边的时间 / 逾期天数 / 项目
private struct MenuTaskRow: View {
    @EnvironmentObject var model: AppModel
    let task: DidaTask
    var overdue = false
    var inbox = false
    @State private var hover = false

    private var tint: Color {
        switch task.priority {
        case 5: return .red
        case 3: return .orange
        case 1: return .blue
        default: return Color.secondary.opacity(0.7)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { Task { await model.complete(task) } } label: {
                Image(systemName: "circle").font(.system(size: 15)).foregroundStyle(tint)
            }
            .buttonStyle(.plain).help("完成")
            VStack(alignment: .leading, spacing: 0) {
                Text(task.cleanTitle).font(.system(size: 13)).lineLimit(1)
                let sub = subtitle
                if !sub.isEmpty { Text(sub).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1) }
            }
            Spacer(minLength: 6)
            if overdue, let d = task.date {
                Text("逾期 \(max(1, Day.diff(d, Day.today()))) 天").font(.caption2.weight(.medium)).foregroundStyle(.red)
            } else if let t = task.time {
                Text(t).font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
            }
            // 悬停时出现：用这件待办开始一个专注
            if hover, model.focus.run == nil {
                Button {
                    model.focus.attach(task)
                    model.focus.quickFocus(model.focus.focusMinutes)
                } label: {
                    Image(systemName: "play.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Brand.brown)
                        .frame(width: 22, height: 22).background(Brand.orange, in: Circle())
                }
                .buttonStyle(.plain).help("专注这件事")
            }
        }
        .onHover { hover = $0 }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            MainWindow.show()
            model.openTask(task)
        }
    }

    /// 第二行：项目 · 标签 · 备注开头
    private var subtitle: String {
        var parts: [String] = []
        if let p = model.overview?.projectName(task.projectId) { parts.append(p) }
        if task.repeatFlag != nil { parts.append("重复") }
        parts.append(contentsOf: task.tags.prefix(2).map { "#" + $0 })
        let c = task.content.trimmed.replacingOccurrences(of: "\n", with: " ")
        if !c.isEmpty { parts.append(String(c.prefix(24))) }
        return parts.joined(separator: " · ")
    }
}
