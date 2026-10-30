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
    /// 过滤 / 排序后的数据按版本缓存在 model 里（见 TodayData.swift），这里读多少遍都不再重算
    private var dailyToday: DailyDay? { model.dailyToday }
    private var todayNotes: [NoteInfo] { model.todayData().todayNotes }
    private var dailyRecent: [DailyEntry] { model.todayData().dailyRecent }
    private var todayDone: [DidaTask] { model.todayData().todayDone }
    private var overdue: [DidaTask] { model.todayData().overdue }
    private var todayTasks: [DidaTask] { model.todayData().todayTasks }
    private var undated: [DidaTask] { model.todayData().undated }
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
            await runAll([
                { await model.loadMemory() },
                { await model.loadHeat() },
                { await model.loadDailyToday() },
            ])
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
            HStack(spacing: 8) {
                if model.hasDida {
                    Button { showPlan = true } label: {
                        Label("重新规划", systemImage: "calendar.badge.clock")
                    }
                    .disabled(model.scheduling || model.overview == nil)
                    Button { showQuickStart = true } label: {
                        Label("快速启动", systemImage: "bolt.fill")
                    }
                    .disabled(model.overview == nil)
                    .help("让 AI 梳理今天的待办、最近的笔记和 Daily Note，无压力地开始")
                }
                FocusStartButton(focus: focus)
            }
            .controlSize(.regular)
            .padding(.bottom, 4)
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
        // 今天的待办全部列出来（包括上面「下一件」卡片里的那一件），标题上的数字和列表对得上
        let rest = todayTasks
        return TaskSection(title: "今天", count: todayTasks.count) {
            EmptyView()
        } content: {
            if todayTasks.isEmpty {
                Text(todayDone.isEmpty ? "今天没有待办" : "今天的待办都完成了").font(.callout).foregroundStyle(.secondary).padding(14)
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
        Button("使用便签打开") {
            if it.isDaily { StickyController.shared.create(text: it.text) } else { model.openNoteAsSticky(it.noteId, title: it.title) }
        }
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
        if model.hasSjz { AuditProjectCard() }
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
    @ObservedObject private var session = BreakSession.shared
    @ObservedObject private var music = BreakSession.shared.music
    @ObservedObject private var sound = AmbientSound.shared
    @State private var writing = false

    var body: some View {
        if let r = focus.run {
            VStack(spacing: 10) {
                // 第一行：图标 + 关联的任务（点一下可以换）+ 倒计时
                HStack(spacing: 8) {
                    // 休息时图标和休息页上当前的动作保持一致
                    Image(systemName: r.paused ? "pause.circle.fill" : (r.kind.isBreak ? session.move(for: focus).icon : "timer"))
                        .font(.title3).foregroundStyle(Brand.orange)
                    titleBlock(r)
                    if r.kind.isBreak { breakChips }
                    Spacer(minLength: 4)
                    FocusTick(clock: focus.clock) { now in
                        let left = max(Int(r.remainingMs(now) / 1000), 0)
                        Text(String(format: "%02d:%02d", left / 60, left % 60))
                            .font(.system(size: 24, weight: .semibold).monospacedDigit())
                            .lineLimit(1).fixedSize()
                    }
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
                // 休息：名字后面紧跟着跟练 / 歌 / 环境音的状态，右边留给倒计时
                block.layoutPriority(1)
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

    /// 休息中的状态：跟练倒计时、正在播放的歌、环境音。点一下可以停 / 暂停
    @ViewBuilder private var breakChips: some View {
        HStack(spacing: 5) {
            if let end = session.practiceEnd {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = Int(end.timeIntervalSince(ctx.date).rounded(.up))
                    if left > 0 {
                        chip(session.move(for: focus).icon, String(format: "%d:%02d", left / 60, left % 60), help: "跟练中，点一下停止") {
                            session.practiceEnd = nil
                        }
                    }
                }
            }
            if let t = music.track, t.playing {
                chip("music.note", t.title, help: "\(t.title) · \(t.artist)，点一下暂停") { music.toggle(t.app) }
                    .frame(maxWidth: 96)
            }
            if let k = sound.current {
                chip(k.icon, nil, help: "\(k.label)，点一下关闭") { sound.stop() }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chip(_ icon: String, _ text: String?, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                if let text { Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1) }
            }
            .foregroundStyle(Brand.orange)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Brand.orange.opacity(0.16), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
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

// MARK: - 侧栏：当前审计项目

/// 正在做的审计项目（结审里「当前项目」，没钉住就取第一个）：阶段进度，以及已发出、还没收回的取证单——到了回复期限没收回的标红
struct AuditProjectCard: View {
    @EnvironmentObject var model: AppModel
    @State private var docs: SjzDocs?
    @State private var items: [SjzOutstanding] = []
    @State private var caps: [SjzCapture] = []
    @State private var summaries: [SjzSummary] = []
    @State private var loadedItems = false
    /// 取证单发出后多少天内应当收回；超过就算逾期（结审里没有单独的期限字段，先统一按这个天数算）
    @AppStorage("sjz.replyDays") private var replyDays = 5
    /// 正在预览的那一类：点统计数字或右键菜单选择，弹出里面具体有哪些
    @State private var peek: Peek?

    enum Peek: String, Identifiable, CaseIterable {
        case today, clues, ideas, evidence, regulations, datalists, all, open, overdue, summaries
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: return "今日新增"
            case .clues: return "待核实线索"
            case .ideas: return "想法"
            case .evidence: return "证据"
            case .regulations: return "法规"
            case .datalists: return "资料清单"
            case .all: return "全部记录"
            case .open: return "未完成任务"
            case .overdue: return "逾期任务"
            case .summaries: return "工作小结"
            }
        }
        var icon: String {
            switch self {
            case .today: return "sparkles"
            case .clues: return "lightbulb"
            case .ideas: return "text.bubble"
            case .evidence: return "doc.text.image"
            case .regulations: return "book.closed"
            case .datalists: return "list.clipboard"
            case .all: return "tray.full"
            case .open: return "checklist"
            case .overdue: return "exclamationmark.circle"
            case .summaries: return "doc.richtext"
            }
        }
        /// 统计里有对应数字的几类：弹窗挂在那个数字上，其余的挂在整张卡片上
        var hasTile: Bool { self == .open || self == .overdue || self == .clues || self == .today || self == .summaries }
    }

    struct PeekEntry: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let title: String
        let sub: String
        let trailing: String
        let trailTint: Color
        let open: () -> Void
    }

    private static var docCache: [String: SjzDocs] = [:]
    private static var itemCache: [String: [SjzOutstanding]] = [:]
    private static var capCache: [String: [SjzCapture]] = [:]

    private var name: String { model.sjzPin.project.isEmpty ? (model.sjzOverview?.projects.first?.name ?? "") : model.sjzPin.project }
    private var title: String {
        if let t = model.sjzOverview?.projects.first(where: { $0.name == name })?.title, !t.isEmpty { return t }
        return model.sjzPin.projectTitle.isEmpty ? name : model.sjzPin.projectTitle
    }

    private var stat: SjzProjectStat? { model.sjzOverview?.projects.first { $0.name == name } }
    private var todayCount: Int { caps.filter { c in c.date.map { Calendar.current.isDateInToday($0) } ?? false }.count }
    private var pendingClues: Int { caps.filter { $0.kind == "clue" && $0.status == "pending" }.count }

    /// 一行待收回的东西：已发出没收回的取证单，或带 #资料清单 标签、有计划日期和截止日期的任务
    private struct Row: Identifiable {
        let id: String
        let isList: Bool
        let title: String
        let matter: String
        let range: String?
        /// 距离到期还有几天（负数 = 已逾期）；没有日期为 nil
        let left: Int?
        /// 还没到计划开始日（资料清单）
        let notStarted: Bool
        let open: () -> Void
    }

    private static let rangeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()

    private var rows: [Row] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func days(_ to: Date) -> Int { cal.dateComponents([.day], from: today, to: cal.startOfDay(for: to)).day ?? 0 }
        let f = Self.rangeFmt
        let n = name
        var out: [Row] = items.map { it in
            let d = it.sentDate
            let isData = it.kind == "data_request"
            let due = isData ? Day.parse(it.dueAt) : d.flatMap { cal.date(byAdding: .day, value: replyDays, to: cal.startOfDay(for: $0)) }
            return Row(id: "note:" + it.path, isList: isData,
                       title: [it.no, it.unit.isEmpty ? it.title : it.unit].filter { !$0.isEmpty }.joined(separator: " "),
                       matter: it.matter.isEmpty ? (it.unit.isEmpty ? "" : it.title) : it.matter,
                       range: d.flatMap { s in due.map { "\(f.string(from: s)) 发出 → \(f.string(from: $0)) \(isData ? "截止" : "到期")" } },
                       left: due.map(days), notStarted: false,
                       open: { model.openSjzApp(project: n, to: "/documents?open=" + AppModel.urlEnc(it.path)) })
        }
        for t in model.sjzOverview?.next ?? [] where t.project == n && Self.isList(t) {
            let sd = Day.parse(String((t.startDate ?? "").prefix(10)))
            let dd = Day.parse(String(t.dueDate.prefix(10)))
            guard let sd, let dd else { continue }
            out.append(Row(id: "task:" + t.id, isList: true,
                           title: Self.cleanTitle(t.subject), matter: "",
                           range: "\(f.string(from: sd)) → \(f.string(from: dd))",
                           left: days(dd), notStarted: days(sd) > 0,
                           open: { model.openSjzApp(project: n, to: "/tasks?task=" + AppModel.urlEnc(t.id)) }))
        }
        return out.sorted { ($0.left ?? 9999) < ($1.left ?? 9999) }
    }

    /// 任务里带「#资料清单」标签，并且同时有计划日期和截止日期
    private static func isList(_ t: SjzTaskLite) -> Bool {
        guard (t.subject + " " + t.detail).contains("#资料清单") else { return false }
        return !(t.startDate ?? "").isEmpty && !t.dueDate.isEmpty
    }

    private static func cleanTitle(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "#资料清单", with: "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "资料清单" : t
    }

    var body: some View {
        if !name.isEmpty {
            let rs = rows
            let late = rs.filter { ($0.left ?? 0) < 0 }.count
            Panel(radius: 18) {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield").font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.orange)
                            .frame(width: 30, height: 30)
                            .background(Brand.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("正在做的审计项目").font(.caption).foregroundStyle(.secondary)
                            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.section = .focus; model.selectedProject = SjzTasks.prefix + name }
                    if let d = docs, !d.phases.isEmpty { phaseBar(d) }
                    HStack(alignment: .top, spacing: 0) {
                        mini("未完成", "\(stat?.open ?? 0)", .primary.opacity(0.85), .open)
                        mini("逾期", "\(stat?.overdue ?? 0)", (stat?.overdue ?? 0) > 0 ? .red : .primary.opacity(0.85), .overdue)
                        mini("待核实线索", "\(pendingClues)", pendingClues > 0 ? .pink : .primary.opacity(0.85), .clues)
                        mini("今天新增", "\(todayCount)", todayCount > 0 ? Brand.orange : .primary.opacity(0.85), .today)
                        mini("工作小结", "\(summaries.count)", .primary.opacity(0.85), .summaries)
                    }
                    .padding(.horizontal, -6)
                    if !rs.isEmpty {
                        Divider().opacity(0.6)
                        HStack(spacing: 6) {
                            Text("待收回").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text("\(rs.count)").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            if late > 0 { TagChip(text: "\(late) 条已逾期", tint: .red) }
                            Spacer(minLength: 4)
                            if rs.contains(where: { !$0.isList }) {
                                Text("取证单期限 \(replyDays) 天").font(.caption2).foregroundStyle(.tertiary).help("取证单发出后 \(replyDays) 天内应收回，右键卡片可以改；资料清单按任务的计划日期和截止日期算")
                            }
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(rs.prefix(3)) { r in row(r) }
                            if rs.count > 3 { Text("还有 \(rs.count - 3) 条，在结审里查看").font(.caption2).foregroundStyle(.tertiary) }
                        }
                    }
                    let recent = recentEntries
                    if !recent.isEmpty {
                        Divider().opacity(0.6)
                        Text("最近").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, -4)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(recent) { r in
                                RecentRow(icon: r.icon, tint: r.tint, text: r.text, time: r.date.map(Self.timeLabel) ?? "", action: r.action)
                            }
                        }
                    }
                }
                .padding(14)
            }
            .popover(item: Binding(get: { peek.flatMap { $0.hasTile ? nil : $0 } }, set: { if $0 == nil { peek = nil } }), arrowEdge: .leading) { k in
                peekList(k)
            }
            .contextMenu {
                Section("打开") {
                    Button { model.section = .focus; model.selectedProject = SjzTasks.prefix + name } label: { Label("在拾忆里打开项目", systemImage: "folder") }
                    Button { model.openSjzApp(project: name, to: "/") } label: { Label("在结审里打开项目", systemImage: "arrow.up.forward.app") }
                    Button { model.openSjzApp(project: name, to: "/evidence?tab=note") } label: { Label("在结审里打开取证单", systemImage: "doc.text") }
                }
                Section("设置") {
                    Menu {
                        ForEach([3, 5, 7, 10, 15, 30], id: \.self) { d in
                            Button { replyDays = d } label: { if replyDays == d { Label("\(d) 天", systemImage: "checkmark") } else { Text("\(d) 天") } }
                        }
                    } label: { Label("取证单回复期限（\(replyDays) 天）", systemImage: "clock.badge.checkmark") }
                }
            }
            .task(id: name) { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .sjzCapturesChanged)) { _ in Task { await load() } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await load() } }
        } else {
            Color.clear.frame(height: 0)
                .task { await model.refreshSjzTarget(); await model.refreshSjzOverview() }
        }
    }

    private func row(_ r: Row) -> some View {
        let (badge, tint) = Self.badge(r.left, notStarted: r.notStarted)
        return Button(action: r.open) {
            HStack(alignment: .center, spacing: 8) {
                Text(badge).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 52).padding(.vertical, 3)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(r.isList ? "资料清单" : "取证单").font(.system(size: 10, weight: .medium)).foregroundStyle(r.isList ? Color.indigo : Brand.orange)
                        if let range = r.range {
                            Text(range).font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle((r.left ?? 0) < 0 ? Color.red : Color.secondary)
                        }
                        if !r.matter.isEmpty { Text(r.matter).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(r.id.hasPrefix("task:") ? "在结审里打开这个任务" : r.isList ? "在结审里打开这份资料清单" : "在结审里打开这份取证单")
    }

    private static func badge(_ left: Int?, notStarted: Bool) -> (String, Color) {
        guard let left else { return ("未记日期", .secondary) }
        if notStarted, left >= 0 { return ("未开始", .secondary) }
        if left < 0 { return ("逾期 \(-left) 天", .red) }
        if left == 0 { return ("今天到期", .orange) }
        if left <= 2 { return ("还剩 \(left) 天", .orange) }
        return ("还剩 \(left) 天", .secondary)
    }

    private func mini(_ label: String, _ value: String, _ color: Color, _ k: Peek) -> some View {
        PeekTile(label: label, value: value, color: color, active: peek == k) { peek = peek == k ? nil : k }
            .popover(isPresented: Binding(get: { peek == k }, set: { if !$0 && peek == k { peek = nil } }), arrowEdge: .bottom) { peekList(k) }
    }

    private func peekList(_ k: Peek) -> some View {
        PeekListView(kind: k, entries: entries(k),
                     headCount: k == .summaries ? Self.summaryHeadCount(summaries) : nil,
                     actions: k == .summaries ? Self.summaryActions(project: name, model: model) : []) { peek = nil }
    }

    /// 工作小结的列表项：点一下在结审里打开这份小结
    static func summaryEntries(_ list: [SjzSummary], project: String, model: AppModel) -> [PeekEntry] {
        orderedSummaries(list).map { s in
            PeekEntry(id: "summary:" + s.path, icon: "doc.richtext", tint: .indigo,
                      title: "\(s.kindLabel) · \(s.shortPeriod)",
                      sub: [s.manual ? "手写" : (s.auto ? "自动生成" : "手动生成"), s.ai ? "AI 润色" : ""].filter { !$0.isEmpty }.joined(separator: " · "),
                      trailing: s.date.map(timeLabel) ?? "", trailTint: .secondary,
                      open: { model.openSjzPreview(project: project, capture: s.asCapture) })
        }
    }

    /// 排序：每种小结（周报、日报、阶段报告、项目小结）最新的一份排最前，其余按时间排在后面
    static func orderedSummaries(_ list: [SjzSummary]) -> [SjzSummary] {
        let sorted = list.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let heads = ["weekly", "daily", "phase", "project"].compactMap { k in sorted.first { $0.kind == k } }
        return heads + sorted.filter { s in !heads.contains(where: { $0.path == s.path }) }
    }

    /// 前面几条默认展开（每种最新的一份），其余折叠
    static func summaryHeadCount(_ list: [SjzSummary]) -> Int { Set(list.map(\.kind)).count }

    struct PeekAction: Identifiable {
        let id: String
        let label: String
        let icon: String
        let run: () async -> Void
    }

    /// 弹窗底部的「生成今日日报 / 本周周报」
    static func summaryActions(project: String, model: AppModel) -> [PeekAction] {
        [("daily", "生成今日日报", "sun.max"), ("weekly", "生成本周周报", "calendar")].map { kind, label, icon in
            PeekAction(id: kind, label: label, icon: icon, run: { await generateSummary(project: project, kind: kind, model: model) })
        }
    }

    /// 生成并打开预览；同一统计期间已有小结时先问：覆盖还是查看已有的
    @MainActor static func generateSummary(project: String, kind: String, model: AppModel) async {
        do {
            var r = try await model.sjz.generateSummary(project: project, kind: kind)
            if r.exists, let s = r.summary {
                let alert = NSAlert()
                alert.messageText = "已经有一份\(s.kindLabel)"
                let mine = r.message.contains("手写")
                alert.informativeText = mine ? "这份是你手写的，覆盖后你写的内容会丢失。要覆盖，还是先看看已有的？" : "同一统计期间只保留一份。要覆盖重新生成，还是先看看已有的？"
                alert.addButton(withTitle: mine ? "仍然覆盖" : "覆盖重新生成")
                alert.addButton(withTitle: "查看已有的")
                alert.addButton(withTitle: "取消")
                switch alert.runModal() {
                case .alertFirstButtonReturn: r = try await model.sjz.generateSummary(project: project, kind: kind, overwrite: true)
                case .alertSecondButtonReturn: model.openSjzPreview(project: project, capture: s.asCapture); return
                default: return
                }
            }
            guard let s = r.summary else { model.showNotice(r.message.isEmpty ? "没有生成" : r.message); return }
            SjzDetailStore.forget(project: project, id: s.asCapture.id)
            model.showNotice("已生成\(s.kindLabel)")
            model.openSjzPreview(project: project, capture: s.asCapture)
        } catch { model.showNotice(error.localizedDescription) }
    }

    private func capEntries(_ list: [SjzCapture]) -> [PeekEntry] {
        let n = name
        return list.map { c in
            PeekEntry(id: c.id, icon: c.icon, tint: SjzProjectDetailView.kindTint(c.kind),
                      title: (c.title.isEmpty ? c.summary : c.title).mdPlain,
                      sub: ["\(c.kindLabel) · \(c.id)", c.statusLabel].filter { !$0.isEmpty }.joined(separator: " · "),
                      trailing: c.date.map(Self.timeLabel) ?? "", trailTint: .secondary,
                      open: { model.openSjzEditor(project: n, capture: c) })
        }
    }

    private func taskEntries(overdueOnly: Bool) -> [PeekEntry] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let n = name
        let list: [(SjzTaskLite, Int?)] = (model.sjzOverview?.next ?? []).filter { $0.project == n }.map { t in
            let due = Day.parse(String(t.dueDate.prefix(10)))
            return (t, due.map { cal.dateComponents([.day], from: today, to: cal.startOfDay(for: $0)).day ?? 0 })
        }
        return list.filter { !overdueOnly || ($0.1 ?? 0) < 0 }
            .sorted { ($0.1 ?? 9999) < ($1.1 ?? 9999) }
            .map { t, left in
                let (badge, tint) = Self.badge(left, notStarted: false)
                return PeekEntry(id: "task:" + t.id, icon: Self.isList(t) ? "list.clipboard" : "checklist", tint: Self.isList(t) ? .indigo : Brand.orange,
                                 title: Self.cleanTitle(t.subject), sub: Self.isList(t) ? "资料清单任务" : "任务",
                                 trailing: badge, trailTint: tint,
                                 open: { model.openSjzApp(project: n, to: "/tasks?task=" + AppModel.urlEnc(t.id)) })
            }
    }

    private func entries(_ k: Peek) -> [PeekEntry] {
        switch k {
        case .today: return capEntries(caps.filter { c in c.date.map { Calendar.current.isDateInToday($0) } ?? false })
        case .clues: return capEntries(caps.filter { $0.kind == "clue" && $0.status == "pending" })
        case .ideas: return capEntries(caps.filter { $0.kind == "idea" })
        case .evidence: return capEntries(caps.filter { $0.kind == "evidence" })
        case .regulations: return capEntries(caps.filter { $0.kind == "regulation" })
        case .datalists: return capEntries(caps.filter { $0.kind == "datalist" })
        case .all: return capEntries(caps)
        case .open: return taskEntries(overdueOnly: false)
        case .overdue: return taskEntries(overdueOnly: true)
        case .summaries: return Self.summaryEntries(summaries, project: name, model: model)
        }
    }

    fileprivate static func timeLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: d)
    }

    private func phaseBar(_ d: SjzDocs) -> some View {
        let cur = d.phases.firstIndex(where: { $0.current }) ?? d.phases.firstIndex(where: { $0.key == d.phase }) ?? 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                ForEach(Array(d.phases.enumerated()), id: \.offset) { i, _ in
                    Capsule().fill(i < cur ? Brand.orange.opacity(0.45) : i == cur ? Brand.orange : Color.primary.opacity(0.1)).frame(height: 4)
                }
            }
            HStack {
                Text(d.phases[cur].label).font(.caption.weight(.semibold))
                Spacer()
                Text("第 \(cur + 1) / \(d.phases.count) 阶段").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private struct RecentEntry: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let text: String
        let date: Date?
        let action: () -> Void
    }

    /// 「最近」：拾忆写进去的记录（工作小结单独放在统计行里）
    private var recentEntries: [RecentEntry] {
        let n = name
        let out: [RecentEntry] = caps.prefix(3).map { c in
            RecentEntry(id: c.id, icon: c.icon, tint: SjzProjectDetailView.kindTint(c.kind),
                        text: "\(c.kindLabel) · \(c.title.isEmpty ? c.summary : c.title)".mdPlain, date: c.date,
                        action: { model.openSjzPreview(project: n, capture: c) })
        }
        return out
    }

    /// 先用上次的结果画出来，再在后台刷新；钉住的项目或概览还没读到时先读
    private func load() async {
        if model.sjzPin.project.isEmpty { await model.refreshSjzTarget() }
        if model.sjzOverview == nil { await model.refreshSjzOverview() }
        let n = name
        guard !n.isEmpty else { return }
        if docs == nil, let c = Self.docCache[n] { docs = c }
        if items.isEmpty, let c = Self.itemCache[n] { items = c; loadedItems = true }
        if caps.isEmpty, let c = Self.capCache[n] { caps = c }
        if let c = try? await model.sjz.captures(project: n, limit: 300) { caps = c; Self.capCache[n] = c }
        if let c = try? await model.sjz.outstanding(project: n) { items = c; loadedItems = true; Self.itemCache[n] = c }
        if let sm = try? await model.sjz.summaries(project: n) { summaries = sm }
        if let d = try? await model.sjz.documents(project: n) { docs = d; Self.docCache[n] = d }
    }
}

/// 「最近」里的一条：点一下用快速预览打开
private struct RecentRow: View {
    let icon: String
    let tint: Color
    let text: String
    let time: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10.5)).foregroundStyle(tint)
                Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if !time.isEmpty { Text(time).font(.system(size: 10.5)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.primary.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .help("点一下预览")
    }
}

/// 统计里的一格数字：可以点，悬停时有底色，弹窗打开时保持高亮
private struct PeekTile: View {
    let label: String
    let value: String
    let color: Color
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 18, weight: .bold)).monospacedDigit().foregroundStyle(color)
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.vertical, 4).padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(active ? 0.09 : hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .help("点一下看看是哪些")
    }
}

/// 预览弹窗：这一类里具体有哪些，点一条直接打开
struct PeekListView: View {
    let kind: AuditProjectCard.Peek
    let entries: [AuditProjectCard.PeekEntry]
    /// 只先显示前几条，其余折叠成「显示更早的 n 条」；nil = 全部显示
    var headCount: Int? = nil
    var actions: [AuditProjectCard.PeekAction] = []
    let close: () -> Void
    @State private var hoverId: String?
    @State private var expanded = false
    private var shown: [AuditProjectCard.PeekEntry] {
        guard let h = headCount, !expanded, entries.count > h else { return entries }
        return Array(entries.prefix(h))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: kind.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.orange)
                Text(kind.title).font(.system(size: 13, weight: .semibold))
                Text("\(entries.count)").font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
                Spacer()
                // 「生成今日日报 / 本周周报」之类的动作：以图标放在标题右边，悬停显示名称
                ForEach(actions) { a in
                    Button { close(); Task { await a.run() } } label: {
                        Image(systemName: a.icon).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Brand.orange)
                            .frame(width: 26, height: 24)
                            .background(Brand.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(a.label)
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            Divider().opacity(0.6)
            if entries.isEmpty {
                Text("现在没有这一类的内容").font(.callout).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(shown) { e in
                            Button { close(); e.open() } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: e.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(e.tint)
                                        .frame(width: 24, height: 24)
                                        .background(e.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(e.title.isEmpty ? "（无标题）" : e.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                                        Text(e.sub).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                    Spacer(minLength: 6)
                                    if !e.trailing.isEmpty {
                                        Text(e.trailing).font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(e.trailTint)
                                    }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(hoverId == e.id ? Color.primary.opacity(0.06) : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hoverId = $0 ? e.id : (hoverId == e.id ? nil : hoverId) }
                        }
                        if let h = headCount, entries.count > h {
                            Button { expanded.toggle() } label: {
                                Text(expanded ? "收起" : "显示更早的 \(entries.count - h) 份")
                                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 340)
            }
        }
        .frame(width: 340)
    }
}

// MARK: - 标题栏：开始专注

/// 「快速启动」右边的开始专注：点一下按上次的时长开始，右边小箭头选 15 / 25 / 45 / 60 / 90 分钟；
/// 刚完成一个番茄、该休息时，主按钮是「休息 N 分」，菜单里可以跳过休息直接专注
private struct FocusStartButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var focus: FocusStore

    private var running: Bool { focus.run != nil && !(focus.run?.kind.isBreak ?? true) }

    var body: some View {
        let breakKind = focus.pendingBreak
        let title = running ? "专注中" : (breakKind != nil ? "休息 \(focus.minutes) 分" : "专注 \(focus.minutes) 分")
        let icon = running ? "timer" : (breakKind != nil ? "cup.and.saucer.fill" : "play.fill")
        let primary = {
            if running { model.selectedProject = nil; model.section = .focus }
            else if breakKind != nil { focus.start() }
            else { focus.quickFocus(focus.minutes) }
        }
        Group {
            if running {
                Button(action: primary) { Label(title, systemImage: icon) }
            } else {
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
                    Label(title, systemImage: icon)
                } primaryAction: { primary() }
                .menuStyle(.borderedButton)
                .fixedSize()
            }
        }
        .help(running ? "专注进行中，点击打开专注页" : "按上次的时长开始专注，右边的箭头可以选时间")
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

    /// 今天页上任何数据变化都会重算这里的 body：只负责把输入交给 HeatGrid，输入没变就整块跳过（不再每次重算 180 天的日期字符串、重画画布）
    var body: some View {
        HeatGrid(weeks: weeks, counts: model.heat, loading: model.heatLoading, today: Day.today()).equatable()
    }
}

private struct HeatGrid: View, Equatable {
    let weeks: Int
    let counts: [String: Int]
    let loading: Bool
    /// 今天（跨天后重算）
    let today: String

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
        let days = (0 ..< weeks * 7).map { cal.date(byAdding: .day, value: $0, to: r.first) ?? r.first }
        // 每一天的日期字符串只格式化一次（下面统计和画布都用它）
        let keys = days.map { Day.string($0) }
        let vals = keys.compactMap { counts[$0] }.filter { $0 > 0 }.sorted()
        let at: (Double) -> Int = { q in vals.isEmpty ? 1 : vals[Int(Double(vals.count - 1) * q)] }
        // 档位按「有记录的日子」的条数分布来切（前 25% / 50% / 80%），记得多的人不会满屏深色
        let cuts = [at(0.25), at(0.5), at(0.8)]
        let total = keys.reduce(0) { $0 + (counts[$1] ?? 0) }
        let month = cal.component(.month, from: r.last)
        let monthDays = keys.indices.filter { i in
            cal.component(.month, from: days[i]) == month && keys[i] <= today && (counts[keys[i]] ?? 0) > 0
        }.count

        VStack(alignment: .leading, spacing: 8) {
            RailTitle(text: "Daily Note · 最近 \(weeks) 周")
            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    Text(loading && counts.isEmpty ? "正在读取…" : "本月记了 \(monthDays) 天 · 共 \(total) 条")
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
                                let key = keys[w * 7 + d]
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
