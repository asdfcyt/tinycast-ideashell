import AppKit
import SwiftUI

/// 今天。设计北极星：**一条清楚的行动队列，数据退到侧栏**。
/// 左边是主角——下一件事（可以直接完成 / 专注 / 推迟），下面是逾期、今天、收集箱三组待办；
/// 右边是配角——三个圆环、快捷操作、往日回顾、Daily Note 热力图。窗口变窄时侧栏折到下面，变成单列。
/// 排期工具（一键推迟、自动排期）放在标题右边，随手能用；单条待办悬停时出现「专注 / 推迟」。
struct TodayView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { TodayContent(focus: model.focus) }
}

private let postponeChoices: [(label: String, days: Int)] = [("1 天", 1), ("2 天", 2), ("3 天", 3), ("1 周", 7), ("2 周", 14)]

private struct TodayContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var focus: FocusStore
    @State private var showPlan = false
    @State private var showQuickStart = false

    private var today: String { Day.today() }
    /// 今天的 Daily Note 放在 model 里缓存：切页回来直接显示，不清空重读
    private var dailyToday: DailyDay? { model.dailyToday }
    /// 今天的笔记（Daily Note 单独在下面按条显示，这里不重复列那一篇）
    private var todayNotes: [NoteInfo] {
        model.timeline.filter { $0.day == today && $0.id != dailyToday?.noteId && !$0.tags.contains("daily-note") }
    }
    /// 今天 Daily Note 里最近的 5 条（新的在上）
    private var dailyRecent: [DailyEntry] { Array((dailyToday?.entries ?? []).filter { !$0.struck }.suffix(5).reversed()) }

    private var todayDone: [DidaTask] {
        (model.overview?.done ?? []).filter { $0.completedDate.map { Day.string($0) == today } ?? false }
    }

    private var overdue: [DidaTask] {
        (model.overview?.overdue ?? []).sorted { ($0.date ?? "") < ($1.date ?? "") }
    }

    private var todayTasks: [DidaTask] {
        (model.overview?.todayTasks(today) ?? []).sorted {
            let a = $0.time ?? "99:99", b = $1.time ?? "99:99"
            return a != b ? a < b : $0.priority > $1.priority
        }
    }

    private var undated: [DidaTask] { model.overview?.undated ?? [] }
    private var remaining: Int { overdue.count + todayTasks.count }
    private var todoTotal: Int { todayTasks.count + undated.count + todayDone.count }
    private var loaded: Bool { model.overview != nil || !model.hasDida }

    /// 下一件：今天最早的；今天没有就看最早的逾期
    private var next: (task: DidaTask, overdue: Bool)? {
        if let t = todayTasks.first { return (t, false) }
        if let t = overdue.first { return (t, true) }
        return nil
    }

    var body: some View {
        ScrollView {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 20) { header; mainBlocks }
                        .frame(minWidth: 420, idealWidth: 460, maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 16) { railTop; railBottom(weeks: 20) }
                        .frame(width: 300)
                }
                VStack(alignment: .leading, spacing: 20) {
                    header
                    railTop
                    mainBlocks
                    railBottom(weeks: heatWeeks)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .background(AmbientBackground())
        .overlay(alignment: .bottom) { UndoToast().padding(.bottom, 16) }
        .sheet(isPresented: $showQuickStart) { QuickStartSheet().environmentObject(model).dismissOnOutsideClick() }
        .sheet(isPresented: $showPlan) { ReplanSheet(candidates: model.schedulable(includeOverdue: true)).environmentObject(model).dismissOnOutsideClick() }
        .task {
            async let m: Void = model.loadMemory()
            async let h: Void = model.loadHeat()
            async let d: Void = model.loadDailyToday()
            _ = await (m, h, d)
        }
        // 笔记列表变了（新记了笔记 / 刷新到别处写的）才强制重读；进页面、回到应用只在缓存过期时读
        .onChange(of: model.timeline.map(\.id)) { _, _ in Task { await model.loadDailyToday(ifStale: false) } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.loadDailyToday() } }
    }

    // MARK: - 标题 + 排期工具

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f
    }()

    private var greeting: String {
        switch Date().hourOfDay {
        case 0 ..< 6: return "夜深了"
        case 6 ..< 11: return "早上好"
        case 11 ..< 14: return "中午好"
        case 14 ..< 18: return "下午好"
        default: return "晚上好"
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.dateFormatter.string(from: Date()))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text(greeting).font(.system(size: 34, weight: .bold))
                if model.overview != nil {
                    Text(remaining == 0 ? "今天的待办都清空了" : "还有 \(remaining) 件事")
                        .font(.title3).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if model.hasDida {
                HStack(spacing: 8) {
                    Button { showPlan = true } label: {
                        Label("重新规划", systemImage: "calendar.badge.clock")
                    }
                    .disabled(model.scheduling || model.overview == nil)
                    Button { showQuickStart = true } label: {
                        Label("快速启动", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(Brand.orange)
                    .disabled(model.overview == nil)
                    .help("让 AI 梳理今天的待办、最近的笔记和 Daily Note，无压力地开始")
                }
                .controlSize(.regular)
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - 左：主角

    @ViewBuilder private var mainBlocks: some View {
        if let e = model.todosError { ErrorBanner(text: e) { Task { await model.refreshAll() } } }
        if let e = model.notesError { ErrorBanner(text: e) { Task { await model.refreshAll() } } }
        if model.hasDida {
            nextCard
            if !overdue.isEmpty { overdueSection }
            todaySection
            if !undated.isEmpty { inboxSection }
        } else {
            Panel { Text("填写滴答清单 API 口令后显示待办").foregroundStyle(.secondary).padding(18) }
        }
        notesSection
    }

    @ViewBuilder private var nextCard: some View {
        if let n = next {
            NextCard(task: n.task, overdue: n.overdue, focus: focus)
        } else if loaded {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill").font(.title).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("今天清空了").font(.headline)
                    Text(undated.isEmpty ? "没有待办了，好好休息。" : "收集箱里还有 \(undated.count) 件没排日期，可以帮你排好。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: 18)
        }
    }

    private var overdueSection: some View {
        let list = Array(overdue.dropFirst(next?.overdue == true ? 1 : 0))
        return TaskSection(title: "逾期", count: overdue.count, tint: .red) {
            Button("全部改到今天") { Task { await model.moveToToday(overdue) } }
                .buttonStyle(.link).font(.callout).disabled(model.scheduling)
        } content: {
            if list.isEmpty {
                Text("上面这一件处理掉，就没有逾期了").font(.callout).foregroundStyle(.secondary).padding(14)
            } else {
                ForEach(Array(list.prefix(6).enumerated()), id: \.element.id) { i, t in
                    TaskLine(task: t, overdue: true, focus: focus)
                    if i < min(list.count, 6) - 1 { Divider().padding(.leading, 46) }
                }
                if list.count > 6 {
                    Divider().padding(.leading, 46)
                    Button("在「待办」里查看全部 \(overdue.count) 个") { model.section = .todos }
                        .buttonStyle(.link).font(.callout).padding(.horizontal, 14).padding(.vertical, 9)
                }
            }
        }
    }

    private var todaySection: some View {
        let rest = Array(todayTasks.dropFirst(next?.overdue == false ? 1 : 0))
        return TaskSection(title: "今天", count: todayTasks.count) {
            EmptyView()
        } content: {
            if todayTasks.isEmpty {
                Text(todayDone.isEmpty ? "今天没有待办" : "今天的待办都完成了").font(.callout).foregroundStyle(.secondary).padding(14)
            } else if rest.isEmpty {
                Text("上面这一件做完，今天就清空了").font(.callout).foregroundStyle(.secondary).padding(14)
            } else {
                ForEach(Array(rest.enumerated()), id: \.element.id) { i, t in
                    TaskLine(task: t, focus: focus)
                    if i < rest.count - 1 { Divider().padding(.leading, 46) }
                }
            }
            if !todayDone.isEmpty {
                Divider()
                Text("已完成 \(todayDone.count)").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
                ForEach(todayDone.prefix(5)) { t in TaskLine(task: t, focus: focus) }
            }
        }
    }

    private var inboxSection: some View {
        TaskSection(title: "收集箱", count: undated.count) {
            EmptyView()
        } content: {
            ForEach(Array(undated.prefix(5).enumerated()), id: \.element.id) { i, t in
                TaskLine(task: t, undatedRow: true, focus: focus)
                if i < min(undated.count, 5) - 1 { Divider().padding(.leading, 46) }
            }
            if undated.count > 5 {
                Divider().padding(.leading, 46)
                Button("查看全部 \(undated.count) 个") { model.section = .todos }
                    .buttonStyle(.link).font(.callout).padding(.horizontal, 14).padding(.vertical, 9)
            }
        }
    }

    /// 今天的记录：普通笔记和 Daily Note 的最近几条放在同一条时间线上，新的在上
    private struct FeedItem: Identifiable {
        let id: String
        let time: String
        let text: String
        let isDaily: Bool
        let noteId: String
        let title: String
        /// 日记条目（普通笔记为 nil）：右键删除 / 转待办用
        var entry: DailyEntry?
    }

    private var feed: [FeedItem] {
        var out: [FeedItem] = todayNotes.map {
            FeedItem(id: "n" + $0.id, time: $0.clock ?? "", text: $0.title, isDaily: false, noteId: $0.id, title: $0.title)
        }
        if let noteId = dailyToday?.noteId {
            for (i, e) in dailyRecent.enumerated() {
                out.append(FeedItem(id: "d\(i)" + e.time, time: e.time, text: e.text, isDaily: true, noteId: noteId, title: today + " Daily Note", entry: e))
            }
        }
        return out.sorted { $0.time > $1.time }
    }

    private var notesSection: some View {
        let items = feed
        return TaskSection(title: "今天的笔记", count: items.count) {
            if let noteId = dailyToday?.noteId, !dailyRecent.isEmpty {
                Button { model.openNote(noteId, title: today + " Daily Note") } label: {
                    Label("打开 Daily Note", systemImage: "text.append").font(.caption)
                }
                .buttonStyle(.link)
            }
        } content: {
            if !model.hasIdeashell {
                Text("填写闪念贝壳 API Key 后显示").font(.callout).foregroundStyle(.secondary).padding(14)
            } else if items.isEmpty {
                Text(model.notesLoading ? "加载中…" : "今天还没有笔记").font(.callout).foregroundStyle(.secondary).padding(14)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(it.time).font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.tertiary)
                            .frame(width: 38, alignment: .leading)
                        Image(systemName: it.isDaily ? "text.append" : "doc.text")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(it.isDaily ? Color.green : Color.blue)
                            .frame(width: 14)
                        Text(it.text).font(.callout).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { model.openNote(it.noteId, title: it.title) }
                    .contextMenu { feedMenu(it) }
                    if i < items.count - 1 { Divider().padding(.leading, 62) }
                }
            }
        }
    }

    /// 今天的笔记 / 日记条目的右键菜单
    @ViewBuilder private func feedMenu(_ it: FeedItem) -> some View {
        Button(it.isDaily ? "打开今天的 Daily Note" : "打开笔记") { model.openNote(it.noteId, title: it.title) }
        Button("在闪念贝壳中打开") { model.open(noteURL(it.noteId)) }
        Divider()
        Button(it.isDaily ? "复制这条" : "复制标题") { model.copy(it.text) }
        if let full = model.timeline.first(where: { $0.id == it.noteId })?.text?.trimmed, !it.isDaily, !full.isEmpty {
            Button("复制全文") { model.copy(full) }
        }
        Button("转成待办") {
            Task {
                do {
                    let a = CaptureParser.analyze(it.text, sjz: model.hasSjz)
                    let msg = try await model.submitCapture(a, kind: .todo)
                    model.showNotice(msg)
                } catch {
                    model.showNotice("转成待办失败：" + error.localizedDescription)
                }
            }
        }
        .disabled(!model.hasDida)
        if let e = it.entry {
            Button("新建笔记…") { model.newNoteDraft = NewNoteDraft(title: it.text) }
                .disabled(!model.hasIdeashell)
            Divider()
            Button("删除这条日记…", role: .destructive) { model.requestDelete(.daily(date: today, entry: e, noteId: it.noteId)) }
        }
    }

    // MARK: - 右：配角

    @ViewBuilder private var railTop: some View {
        DashboardCard(focus: focus, loaded: loaded, remaining: remaining, todoDone: todayDone.count, todoTotal: todoTotal)
        QuickActions(focus: focus)
    }

    @ViewBuilder private func railBottom(weeks: Int) -> some View {
        if !model.memory.isEmpty { MemoryPanel(items: Array(model.memory.prefix(4))) }
        if model.hasIdeashell { HeatPanel(weeks: weeks) }
    }
}

// MARK: - 基础部件

private struct Panel<Content: View>: View {
    var radius: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: radius)
    }
}

/// 一组：标题（+ 数量 + 右侧动作）在卡片外面，内容是一张分隔线隔开的列表卡
private struct TaskSection<Trailing: View, Rows: View>: View {
    let title: String
    let count: Int
    var tint: Color = .primary
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.title3.weight(.bold)).foregroundStyle(tint)
                if count > 0 { Text("\(count)").font(.callout.weight(.semibold)).foregroundStyle(.tertiary) }
                Spacer()
                trailing
            }
            .padding(.horizontal, 4)
            Panel { content }
        }
    }
}

private struct RailTitle: View {
    let text: String
    var body: some View { Text(text).font(.subheadline.weight(.bold)).foregroundStyle(.secondary).padding(.horizontal, 4) }
}

/// 「推迟到…」菜单项（单条）
private struct SnoozeItems: View {
    @EnvironmentObject var model: AppModel
    let task: DidaTask
    var body: some View {
        ForEach(SnoozeOption.allCases) { o in
            Button { Task { await model.snooze(task, o) } } label: { Label(o.label, systemImage: o.icon) }
        }
    }
}

/// 「定日期」菜单项（无日期的任务）
private struct ScheduleItems: View {
    @EnvironmentObject var model: AppModel
    let task: DidaTask
    var body: some View {
        let today = Day.today()
        Button("今天") { Task { await model.schedule(task, on: today) } }
        Button("明天") { Task { await model.schedule(task, on: Day.add(today, days: 1)) } }
        Button("本周末") { Task { await model.schedule(task, on: Scheduler.nextSaturday(from: today)) } }
        Button("下周一") { Task { await model.schedule(task, on: Scheduler.nextMonday(from: today)) } }
    }
}

@MainActor private func startFocus(_ task: DidaTask, _ focus: FocusStore) {
    guard focus.run == nil else { return }
    focus.task = task
    focus.quickFocus(focus.focusMinutes)
}

// MARK: - 下一件（主角）

private struct NextCard: View {
    @EnvironmentObject var model: AppModel
    let task: DidaTask
    let overdue: Bool
    @ObservedObject var focus: FocusStore
    @State private var checked = false

    private var meta: String {
        var parts: [String] = []
        if overdue, let d = task.date { parts.append("逾期 \(max(1, Day.diff(d, Day.today()))) 天") }
        else if let t = task.time { parts.append("今天 " + t) }
        else { parts.append("今天") }
        if let p = model.overview?.projectName(task.projectId) { parts.append(p) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.right.circle.fill")
                Text("下一件").fontWeight(.bold)
                Spacer()
                if task.priority >= 5 { Text("高优先级").font(.caption.weight(.semibold)).foregroundStyle(.red) }
            }
            .font(.caption).foregroundStyle(Brand.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.cleanTitle).font(.title2.weight(.bold)).lineLimit(2).strikethrough(checked)
                Text(meta).font(.callout).foregroundStyle(overdue ? Color.red : Color.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.openTask(task) }

            HStack(spacing: 8) {
                Button {
                    guard !checked else { return }
                    withAnimation(.easeOut(duration: 0.2)) { checked = true }
                    Task { await model.complete(task) }
                } label: {
                    Label("完成", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent).tint(Brand.orange)

                Button { startFocus(task, focus) } label: {
                    Label("专注 \(focus.focusMinutes) 分钟", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(focus.run != nil)

                Menu {
                    SnoozeItems(task: task)
                } label: {
                    Label("推迟", systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                .disabled(model.scheduling)
                Spacer(minLength: 0)
            }
            .controlSize(.large)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 18, tint: Brand.orange.opacity(0.14))
    }
}

// MARK: - 一行待办

/// 圆圈 + 标题 + 副标题；悬停时右边出现「专注 / 推迟」（无日期的行是常驻的「定日期」）
private struct TaskLine: View {
    @EnvironmentObject var model: AppModel
    let task: DidaTask
    var overdue = false
    var undatedRow = false
    @ObservedObject var focus: FocusStore
    @State private var checked = false
    @State private var hover = false

    private var ring: Color {
        switch task.priority {
        case 5: return .red
        case 3: return .orange
        case 1: return .blue
        default: return Color.secondary
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if overdue, let d = task.date { parts.append("逾期 \(max(1, Day.diff(d, Day.today()))) 天") }
        if let t = task.time { parts.append(t) }
        if let p = model.overview?.projectName(task.projectId) { parts.append(p) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let done = task.done || checked
        HStack(spacing: 10) {
            Button {
                guard !done else { return }
                withAnimation(.easeOut(duration: 0.2)) { checked = true }
                Task { await model.complete(task) }
            } label: {
                ZStack {
                    Circle().strokeBorder(done ? Color.clear : ring, lineWidth: 1.6)
                    if done {
                        Circle().fill(Color.secondary.opacity(0.55))
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 20, height: 20)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(task.done)

            VStack(alignment: .leading, spacing: 1) {
                Text(task.cleanTitle).font(.body).strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary).lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(overdue ? Color.red : Color.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.openTask(task) }

            if !done {
                if undatedRow {
                    Menu { ScheduleItems(task: task) } label: { Text("定日期") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .disabled(model.scheduling)
                } else {
                    HStack(spacing: 2) {
                        Button { startFocus(task, focus) } label: {
                            Image(systemName: "play.circle").font(.system(size: 16)).frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("专注这件事")
                        .disabled(focus.run != nil)
                        Menu { SnoozeItems(task: task) } label: {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 14)).frame(width: 26, height: 26)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("推迟")
                        .disabled(model.scheduling)
                    }
                    .opacity(hover ? 1 : 0)
                }
            } else if task.done {
                // 已完成的：悬停时出现「恢复为未完成」
                Button { Task { await model.undoComplete(task) } } label: {
                    Image(systemName: "arrow.uturn.backward.circle").font(.system(size: 15)).frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("恢复为未完成")
                .opacity(hover ? 1 : 0)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(hover ? Color.primary.opacity(0.04) : Color.clear)
        .onHover { hover = $0 }
        .contextMenu {
            if let note = model.taskNote(forTask: task) {
                Button("打开任务笔记") { model.openNote(note.noteId, title: note.deliverable) }
            }
            TaskContextMenu(task: task)
        }
    }
}

// MARK: - 专注进行条（今天页和菜单栏共用）

struct FocusRunBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var focus: FocusStore
    @State private var writing = false

    var body: some View {
        if let r = focus.run {
            let ms = r.remainingMs(Int64(focus.now.timeIntervalSince1970 * 1000))
            let left = max(Int(ms / 1000), 0)
            VStack(spacing: 10) {
                // 第一行：图标 + 关联的任务（点一下可以换）+ 倒计时
                HStack(spacing: 8) {
                    Image(systemName: r.paused ? "pause.circle.fill" : (r.kind.isBreak ? "cup.and.saucer.fill" : "timer"))
                        .font(.title3).foregroundStyle(Brand.orange)
                    titleBlock(r)
                    Spacer(minLength: 4)
                    Text(String(format: "%02d:%02d", left / 60, left % 60))
                        .font(.system(size: 24, weight: .semibold).monospacedDigit())
                        .lineLimit(1).fixedSize()
                }
                // 第二行：按钮平分整行宽度，窄的地方也不会被挤掉
                HStack(spacing: 8) {
                    if !r.kind.isBreak {
                        pill("square.and.pencil", "记录", on: writing) { writing.toggle() }
                    }
                    pill(r.paused ? "play.fill" : "pause.fill", r.paused ? "继续" : "暂停") { focus.pauseOrResume() }
                    pill("stop.fill", r.kind.isBreak ? "结束休息" : "结束", filled: true) { Task { await focus.finish() } }
                }
                if writing, !r.kind.isBreak {
                    RecordComposer(focus: focus, compact: true) { writing = false }
                }
            }
        }
    }

    private func titleBlock(_ r: FocusRun) -> some View {
        let name = r.kind.isBreak ? r.kind.label : (r.title.isEmpty ? "自由专注" : r.title)
        let status = r.paused ? "已暂停" : (r.kind.isBreak ? "休息中" : (r.title.isEmpty ? "点一下关联待办" : "专注中"))
        let block = VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.callout.weight(.semibold)).lineLimit(1)
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        return Group {
            if r.kind.isBreak {
                block.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                FocusTaskMenu(focus: focus) {
                    HStack(spacing: 4) {
                        block
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func pill(_ icon: String, _ text: String, on: Bool = false, filled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: icon)
                .font(.callout.weight(.medium))
                .foregroundStyle(filled ? Brand.brown : (on ? Brand.orange : Color.primary))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(filled ? Brand.orange : (on ? Brand.orange.opacity(0.16) : Color.primary.opacity(0.07)), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 选择专注关联的待办：今天的 + 逾期的；没在专注时是「下一次专注」关联谁，专注中直接换
struct FocusTaskMenu<MenuLabel: View>: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var focus: FocusStore
    @ViewBuilder var label: MenuLabel

    var body: some View {
        let ov = model.overview
        let today = (ov?.todayTasks() ?? []).sorted { ($0.time ?? "99:99") < ($1.time ?? "99:99") }
        let late = (ov?.overdue ?? []).sorted { ($0.date ?? "") < ($1.date ?? "") }
        let current = focus.run?.taskId ?? focus.task?.id
        Menu {
            Button { focus.attach(nil) } label: {
                Label("不关联待办", systemImage: current == nil ? "checkmark" : "circle.dashed")
            }
            if !today.isEmpty {
                Section("今天") {
                    ForEach(today.prefix(20)) { t in
                        Button { focus.attach(t) } label: {
                            if current == t.id { Label(t.cleanTitle, systemImage: "checkmark") } else { Text(t.cleanTitle) }
                        }
                    }
                }
            }
            if !late.isEmpty {
                Section("逾期") {
                    ForEach(late.prefix(12)) { t in
                        Button { focus.attach(t) } label: {
                            if current == t.id { Label(t.cleanTitle, systemImage: "checkmark") } else { Text(t.cleanTitle) }
                        }
                    }
                }
            }
        } label: { label }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
    }
}

// MARK: - 侧栏：仪表

private struct DashboardCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var focus: FocusStore
    let loaded: Bool
    let remaining: Int
    let todoDone: Int
    let todoTotal: Int

    private var goal: Int { model.focusGoalMin }
    private var focusMin: Int? { focus.summary?.todayMin }
    private let amber = Color(red: 0.96, green: 0.71, blue: 0.25)
    private var ink: Color { Color.primary.opacity(0.8) }

    static func fmt(_ m: Int) -> String {
        m < 60 ? "\(m)m" : (m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h\(m % 60)m")
    }

    var body: some View {
        Panel(radius: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    rings
                    VStack(alignment: .leading, spacing: 9) {
                        stat(Brand.orange, "专注", focusMin.map(Self.fmt) ?? "–", "/ " + Self.fmt(goal))
                        stat(ink, "待办", loaded ? "\(todoDone)/\(todoTotal)" : "–", nil)
                        stat(amber, "项目进展", model.projectProgress.map { "\(Int($0 * 100))%" } ?? "–", nil)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.selectedProject = nil; model.section = .focus }
                FocusRunBar(focus: focus)
            }
            .padding(16)
        }
    }

    private func stat(_ color: Color, _ name: String, _ value: String, _ suffix: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 19, weight: .bold)).monospacedDigit()
                if let suffix { Text(suffix).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            }
        }
    }

    private var rings: some View {
        let focusP = min(Double(focusMin ?? 0) / Double(max(goal, 1)), 1)
        let todoP = todoTotal == 0 ? 0 : Double(todoDone) / Double(todoTotal)
        let projP = min(max(model.projectProgress ?? 0, 0), 1)
        let stroke: CGFloat = 7, gap: CGFloat = 2.5, size: CGFloat = 92
        return ZStack {
            ring(0, size: size, stroke: stroke, gap: gap, progress: focusP, color: Brand.orange)
            ring(1, size: size, stroke: stroke, gap: gap, progress: todoP, color: ink)
            ring(2, size: size, stroke: stroke, gap: gap, progress: projP, color: amber)
            VStack(spacing: 0) {
                Text(loaded ? "\(remaining)" : "–").font(.system(size: 20, weight: .heavy)).monospacedDigit()
                Text("还剩").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    private func ring(_ i: Int, size: CGFloat, stroke: CGFloat, gap: CGFloat, progress: Double, color: Color) -> some View {
        let d = size - 2 * CGFloat(i) * (stroke + gap) - stroke
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.09), lineWidth: stroke)
            Circle().trim(from: 0, to: progress > 0 ? max(progress, 0.002) : 0)
                .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.7), value: progress)
        }
        .frame(width: d, height: d)
    }
}

// MARK: - 侧栏：快捷操作

private struct QuickActions: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var focus: FocusStore

    private var running: Bool { focus.run != nil && !(focus.run?.kind.isBreak ?? true) }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            focusButton
            QuickButton(icon: "square.and.pencil", tint: Color(red: 0.96, green: 0.71, blue: 0.25), title: "记笔记") {
                model.openQuickAdd(kind: .note)
            }
            QuickButton(icon: "plus", tint: .blue, title: "记待办") { model.openQuickAdd(kind: .todo) }
            QuickButton(icon: "text.append", tint: .green, title: "Daily Note") { model.openQuickAdd(kind: .daily) }
        }
    }

    /// 点一下就按上次的时长开始；右边的小箭头选 15 / 25 / 45 / 60 / 90 分钟。
    /// 刚完成一个番茄、该休息时，主按钮是「休息 N 分」，菜单里可以跳过休息直接专注
    private var focusButton: some View {
        let breakKind = focus.pendingBreak
        return QuickButton(
            icon: running ? "timer" : (breakKind != nil ? "cup.and.saucer.fill" : "play.fill"),
            tint: breakKind != nil && !running ? Color(red: 0.30, green: 0.69, blue: 0.47) : Brand.orange,
            title: running ? "专注中" : (breakKind != nil ? "休息 \(focus.minutes) 分" : "专注 \(focus.minutes) 分")
        ) {
            if running { model.selectedProject = nil; model.section = .focus }
            else if breakKind != nil { focus.start() }
            else { focus.quickFocus(focus.minutes) }
        }
        .overlay(alignment: .trailing) {
            if !running {
                Menu {
                    if let b = breakKind {
                        Button("开始\(b.label) \(focus.minutes) 分钟") { focus.start() }
                        Divider()
                    }
                    ForEach(FocusStore.choices, id: \.self) { m in
                        Button((breakKind != nil ? "跳过休息，专注 " : "专注 ") + "\(m) 分钟") { focus.quickFocus(m) }
                    }
                    Divider()
                    Button("打开专注页") { model.selectedProject = nil; model.section = .focus }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.trailing, 6)
            }
        }
    }
}

private struct QuickButton: View {
    let icon: String
    let tint: Color
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(tint.gradient, in: Circle())
                Text(title).font(.callout.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .glassCard(radius: 12, tint: hover ? Brand.orange.opacity(0.10) : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - 侧栏：往日回顾

private struct MemoryPanel: View {
    @EnvironmentObject var model: AppModel
    let items: [MemoryItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RailTitle(text: "往日回顾")
            Panel {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, m in
                    Button { model.openNote(m.note.id, title: m.note.title) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(m.label).font(.caption.weight(.bold)).foregroundStyle(Brand.orange)
                                Text(String(m.date.dropFirst(5))).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                            }
                            Text(m.note.title).font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            if let s = m.note.summary?.trimmed, !s.isEmpty {
                                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < items.count - 1 { Divider().padding(.leading, 14) }
                }
            }
        }
    }
}

// MARK: - 侧栏：Daily Note 热力图

private struct HeatPanel: View {
    @EnvironmentObject var model: AppModel
    let weeks: Int

    private func metrics(_ w: CGFloat) -> (cell: CGFloat, gap: CGFloat) {
        let n = CGFloat(weeks)
        let cell = min((w - (n - 1) * 3) / n, 20)
        return (cell, max((w - n * cell) / (n - 1), 3))
    }

    private func level(_ i: Int) -> Color {
        [Brand.orange.opacity(0.28), Brand.orange.opacity(0.55), Brand.orange, Brand.orangeDeep][i]
    }

    var body: some View {
        let r = AppModel.heatRange(weeks: weeks)
        let cal = Day.cal
        let counts = model.heat
        let today = Day.string(r.last)
        let days = (0 ..< weeks * 7).map { cal.date(byAdding: .day, value: $0, to: r.first) ?? r.first }
        let vals = days.compactMap { counts[Day.string($0)] }.filter { $0 > 0 }.sorted()
        let at: (Double) -> Int = { q in vals.isEmpty ? 1 : vals[Int(Double(vals.count - 1) * q)] }
        // 档位按「有记录的日子」的条数分布来切（前 25% / 50% / 80%），记得多的人不会满屏深色
        let cuts = [at(0.25), at(0.5), at(0.8)]
        let total = days.reduce(0) { $0 + (counts[Day.string($1)] ?? 0) }
        let month = cal.component(.month, from: r.last)
        let monthDays = days.filter { cal.component(.month, from: $0) == month && Day.string($0) <= today && (counts[Day.string($0)] ?? 0) > 0 }.count

        VStack(alignment: .leading, spacing: 8) {
            RailTitle(text: "Daily Note · 最近 \(weeks) 周")
            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.heatLoading && counts.isEmpty ? "正在读取…" : "本月记了 \(monthDays) 天 · 共 \(total) 条")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Canvas { ctx, size in
                        let (cell, gap) = metrics(size.width)
                        var prev = -1
                        var marks: [(Int, Int)] = []
                        for w in 0 ..< weeks {
                            let m = cal.component(.month, from: cal.date(byAdding: .weekOfYear, value: w, to: r.first) ?? r.first)
                            if m != prev { marks.append((w, m)) }
                            prev = m
                        }
                        if marks.count > 1, marks[1].0 < 3 { marks.removeFirst() }
                        for (w, m) in marks {
                            ctx.draw(Text("\(m)月").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary),
                                     at: CGPoint(x: CGFloat(w) * (cell + gap), y: 6), anchor: .leading)
                        }
                    }
                    .frame(height: 12)
                    Canvas { ctx, size in
                        let (cell, gap) = metrics(size.width)
                        for w in 0 ..< weeks {
                            for d in 0 ..< 7 {
                                let key = Day.string(days[w * 7 + d])
                                if key > today { continue }
                                let n = counts[key] ?? 0
                                let color: Color = n <= 0 ? Color.primary.opacity(0.07)
                                    : (n <= cuts[0] ? level(0) : (n <= cuts[1] ? level(1) : (n <= cuts[2] ? level(2) : level(3))))
                                let rect = CGRect(x: CGFloat(w) * (cell + gap), y: CGFloat(d) * (cell + gap), width: cell, height: cell)
                                ctx.fill(Path(roundedRect: rect, cornerRadius: cell * 0.3), with: .color(color))
                            }
                        }
                    }
                    .aspectRatio(CGFloat(weeks) / 7.0, contentMode: .fit)
                }
                .padding(14)
            }
        }
    }
}
