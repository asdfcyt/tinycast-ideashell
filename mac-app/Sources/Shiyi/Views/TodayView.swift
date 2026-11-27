import AppKit
import SwiftUI

/// 今天。设计北极星：**中间是时段（昨天回顾、待办、今天要看），右边是时点（此刻各项进度的仪表盘）**。
/// 中间一列都是同一种卡片：标题行（图标 + 标题 + 数量）+ 分隔线隔开的内容，正文字号统一；
/// 右边的仪表盘平铺在一张底上（不套卡片），用分隔线分段，跟着整页一起滚，只有一个滚动条。窗口变窄时仪表盘折到下面。
/// 开始专注、重新规划、快速启动放在标题栏；单条待办悬停时出现「专注 / 推迟」。
struct TodayView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { TodayContent(focus: model.focus) }
}

private let postponeChoices: [(label: String, days: Int)] = [("1 天", 1), ("2 天", 2), ("3 天", 3), ("1 周", 7), ("2 周", 14)]

private struct TodayContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var focus: FocusStore
    @State private var showAllSjz = false

    private var today: String { Day.today() }
    /// 过滤 / 排序后的数据按版本缓存在 model 里（见 TodayData.swift），这里读多少遍都不再重算
    private var dailyToday: DailyDay? { model.dailyToday }
    private var todayNotes: [NoteInfo] { model.todayData().todayNotes }
    private var dailyRecent: [DailyEntry] { model.todayData().dailyRecent }
    private var todayDone: [DidaTask] { model.todayData().todayDone }
    /// 今天完成的结审任务：完成后就从待办列表里消失了，算进待办环的「已完成」和总数
    private var sjzDone: Int { model.sjzDoneToday }
    private var overdue: [DidaTask] { model.todayData().overdue }
    private var todayTasks: [DidaTask] { model.todayData().todayTasks }
    private var undated: [DidaTask] { model.todayData().undated }
    private var remaining: Int { overdue.count + todayTasks.count }
    private var todoTotal: Int { todayTasks.count + undated.count + todayDone.count + sjzDone }
    private var loaded: Bool { model.overview != nil || !model.hasDida }

    private var olderOverdue: [DidaTask] { model.todayData().olderOverdue }

    var body: some View {
        ScrollView {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    middle
                        .frame(minWidth: 420, idealWidth: 420, maxWidth: .infinity, alignment: .top)
                    dashboard(weeks: 20)
                        .frame(width: 316)
                        .padding(.vertical, 6)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Color.primary.opacity(0.035))
                        .overlay(alignment: .leading) { Divider() }
                }
                VStack(alignment: .leading, spacing: 0) {
                    middle
                    dashboard(weeks: heatWeeks)
                        .background(Color.primary.opacity(0.035))
                }
            }
        }
        .background(AmbientBackground())
        .overlay(alignment: .bottom) { UndoToast().padding(.bottom, 16) }
        .sheet(isPresented: $model.showReplan) { ReplanSheet(candidates: model.schedulable(includeOverdue: true)).environmentObject(model).dismissOnOutsideClick() }
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

    /// 中间一列：昨天回顾、待办、今天要看
    private var middle: some View {
        VStack(alignment: .leading, spacing: 16) { mainBlocks }
            .padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: 780, alignment: .topLeading)
            .frame(maxWidth: .infinity)
    }

    // MARK: - 左：主角

    @ViewBuilder private var mainBlocks: some View {
        if let e = model.todosError { ErrorBanner(text: e) { Task { await model.refreshAll() } } }
        if let e = model.notesError { ErrorBanner(text: e) { Task { await model.refreshAll() } } }
        if model.hasDida || model.hasSjz {
            YesterdayCard(focus: focus, day: Day.add(today, days: -1), done: model.todayData().yesterdayDone, missed: model.todayData().yesterdayMissed)
        }
        // 快速启动的结果（AI 梳理，同一天有缓存就直接用）
        if model.hasDida && model.hasLlm { QuickStartCard() }
        if model.hasDida || model.hasSjz {
            if !olderOverdue.isEmpty { overdueSection }
            todaySection
        } else {
            Panel { Text("填写滴答清单 API 口令后显示待办").foregroundStyle(.secondary).padding(18) }
        }
        // 今天要看：AI 速览 + 往日回顾
        InfoCard()
        if !model.memory.isEmpty { MemoryPanel(items: Array(model.memory.prefix(4))) }
    }

    private var overdueSection: some View {
        let list = olderOverdue
        let long = list.filter { t in t.date.map { Day.diff($0, today) >= 7 } ?? false }
        let recent = list.filter { t in !(t.date.map { Day.diff($0, today) >= 7 } ?? false) }
        return TaskSection(title: "逾期", count: list.count, icon: "exclamationmark.circle.fill", tint: .red) {
            Button("全部改到今天") { Task { await model.moveToToday(list) } }
                .buttonStyle(.link).font(.callout).disabled(model.scheduling)
        } content: {
            overdueGroup("拖了很久（7 天以上）", long, first: true)
            overdueGroup("近几天逾期", recent, first: long.isEmpty)
            if list.count > 6 {
                Button("在「日历」里查看全部 \(list.count) 个") { model.section = .calendar }
                    .buttonStyle(.link).font(.callout).padding(.horizontal, 16).padding(.vertical, 9)
            }
        }
    }

    /// 逾期分组：每组标题 + 最多几条（两组合计最多 6 条）
    @ViewBuilder private func overdueGroup(_ title: String, _ items: [DidaTask], first: Bool) -> some View {
        let shown = Array(items.prefix(6))
        if !shown.isEmpty {
            Text("\(title) · \(items.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 2)
            ForEach(Array(shown.enumerated()), id: \.offset) { i, t in
                TaskLine(task: t, overdue: true, focus: focus, compact: true)
            }
        }
    }

    /// 今天 + 结审待办合成一张紧凑的列表：今天的在前，结审里还没排到今天的接在后面
    /// 今天一张卡：日常的在前，结审的另起一组（今天到期的 + 还没排到今天的）
    private var todaySection: some View {
        let later = sjzLater
        let plain = todayTasks.filter { !SjzTasks.owns($0.id) }
        let sjzToday = todayTasks.filter { SjzTasks.owns($0.id) }
        let sjzCount = sjzToday.count + later.count
        let shownLater = showAllSjz ? Array(later.prefix(30)) : Array(later.prefix(3))
        let sjzShown = sjzToday + shownLater
        let grouped = !sjzShown.isEmpty
        return TaskSection(title: "今天", count: todayTasks.count + later.count) {
            EmptyView()
        } content: {
            if todayTasks.isEmpty && later.isEmpty {
                Text(todayDone.isEmpty ? "今天没有待办" : "今天的待办都完成了").font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10)
            }
            if grouped && !plain.isEmpty { GroupLabel(title: "日常", count: plain.count, tint: .secondary) }
            ForEach(Array(plain.enumerated()), id: \.element.id) { i, t in
                TaskLine(task: t, focus: focus, compact: true)
            }
            if grouped {
                GroupLabel(title: "结审", count: sjzCount, tint: Brand.orange)
                ForEach(Array(sjzShown.enumerated()), id: \.element.id) { i, t in
                    TaskLine(task: t, undatedRow: t.date == nil, focus: focus, compact: true)
                }
                if later.count > 3 {
                    Button(showAllSjz ? "收起" : "结审待办还有 \(later.count - 3) 条，展开") { withAnimation(.easeOut(duration: 0.15)) { showAllSjz.toggle() } }
                        .buttonStyle(.link).font(.caption).padding(.horizontal, 16).padding(.vertical, 6)
                }
            }
            if !todayDone.isEmpty {
                Text("已完成 \(todayDone.count)").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 1)
                ForEach(todayDone.prefix(3)) { t in TaskLine(task: t, focus: focus, compact: true) }
            }
        }
    }

    /// 结审里还没排到今天的任务：无日期的，和日期在今天之后的
    private var sjzLater: [DidaTask] {
        guard let ov = model.overview else { return [] }
        let t = today
        return (ov.upcoming + ov.undated).filter { SjzTasks.owns($0.id) && ($0.date == nil || ($0.date ?? "") > t) }
            .sorted { ($0.date ?? "9999") < ($1.date ?? "9999") }
    }

    // MARK: - 右：仪表盘

    /// 此刻各项的进度：今日三环、时薪（今天 / 本周图表）、倒计时、项目、Daily Note 热力图；平铺在同一张底上，用分隔线分段
    @ViewBuilder private func dashboard(weeks: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 正在做的审计项目放在仪表盘上面；它的环并进下面的仪表里
            if model.hasSjz {
                AuditProjectCard { extra in
                    AnyView(PaceDashboard(focus: focus, loaded: loaded, remaining: remaining, todoDone: todayDone.count + sjzDone, todoTotal: todoTotal, extraRings: extra))
                }
            } else {
                PaceDashboard(focus: focus, loaded: loaded, remaining: remaining, todoDone: todayDone.count + sjzDone, todoTotal: todoTotal)
            }
            Divider().padding(.horizontal, 16)
            HourlyRateCard(focus: focus)
            if model.hasIdeashell {
                Divider().padding(.horizontal, 16)
                HeatPanel(weeks: weeks)
            }
        }
        .padding(.horizontal, 8)
        .environment(\.flatPanels, true)
    }
}
