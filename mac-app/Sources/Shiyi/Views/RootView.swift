import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var agents = ApprovalCenter.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(AppSection.allCases.filter { $0 != .settings }) { s in sideRow(s) }
                    Spacer().frame(height: 14)
                    sideRow(.settings)
                }
                .padding(.horizontal, 10).padding(.top, 6)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { MiniCalendar() }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            // 右边的内容栏是 SwiftUI 自己套的一层宿主视图，页面里任何一处刷新（每秒的专注计时）都会让它把整页再量一遍：
            // 用同一个「不量内容」的容器包住，量尺寸时直接用提议的大小（见 App.swift 的 CheapMeasureLayout）
            CheapMeasureLayout { detail }
                .navigationTitle(navTitle)
                .overlay(alignment: .bottom) { NoticeToast().padding(.bottom, 64) }
                .sheet(isPresented: $model.showQuickAdd) {
                    QuickAddView(onDone: { model.showQuickAdd = false }).environmentObject(model).dismissOnOutsideClick()
                }
                .toolbar {
                    // 加号在标题栏最前面
                    ToolbarItem(placement: .navigation) {
                        if model.section == .reading {
                            // 信息页：这里换成「今日信息」，把所有订阅里今天的新内容聚在一起
                            Button {
                                let on = UserDefaults.standard.string(forKey: "reader.source") == "today"
                                UserDefaults.standard.set("today", forKey: "reader.source")
                                if on { Task { await TodayStore.shared.reload(force: true) } }
                            } label: { Image(systemName: "sun.max") }
                                .help("今日信息：聚合财新、三联、AI 日报和订阅里今天的新内容")
                        } else {
                            Button { model.openQuickAddHere() } label: { Image(systemName: "plus") }
                                .help(model.section == .calendar ? "添加待办（⌘N）" : "万能输入（⌘N）")
                        }
                    }
                    // 刷新放在右边；搜索框由页面自己的 .searchable 放在最右边
                    // 开始专注：单独一个圈，放在这一组的最左边
                    if model.section == .today {
                        ToolbarItem(placement: .primaryAction) { FocusToolbarButton(focus: model.focus) }
                        if #available(macOS 26.0, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        if model.section == .today && model.hasDida {
                            Button { model.showReplan = true } label: { Image(systemName: "calendar.badge.clock") }
                                .disabled(model.scheduling || model.overview == nil)
                                .help("重新规划：把待办重新排进今天")
                            Button { model.quickStartTick += 1 } label: { Image(systemName: "bolt.fill") }
                                .disabled(model.overview == nil)
                                .help("重新梳理快速启动：让 AI 再梳理一遍今天的待办、最近的笔记和 Daily Note")
                        }
                        Button {
                            Task { await model.refreshAll() }
                        } label: {
                            if isLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                        }
                        .help("刷新（⌘R）")
                    }
                }
        }
        .modifier(SplitWindowBehavior(visibility: $columnVisibility, detailMin: 760, sidebarWidth: 210))
        .sheet(isPresented: Binding(get: { !model.sheetStack.isEmpty }, set: { if !$0 { model.closeSheets() } })) {
            DetailSheet().environmentObject(model).dismissOnOutsideClick()
        }
        .sheet(item: $model.newNoteDraft) { draft in
            NewNoteSheet(draft: draft).environmentObject(model).dismissOnOutsideClick()
        }
        .animation(.easeInOut(duration: 0.2), value: model.lastUndo?.id)
        .animation(.easeInOut(duration: 0.2), value: model.notice)
    }

    /// 今天页的标题栏直接写今天的日期和星期
    private static let todayTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f
    }()

    private var navTitle: String {
        switch model.section {
        case .reading: return ""
        case .today: return Self.todayTitle.string(from: Date())
        default: return model.section.title
        }
    }

    private func sideRow(_ s: AppSection) -> some View {
        SidebarRow(title: s.title, selected: model.section == s, badge: badge(s), fontSize: 14, action: { model.section = s }) { on in
            Image(systemName: s.icon).font(.system(size: 15))
                .foregroundStyle(on ? Color.white : Brand.orange)
                .frame(width: 22)
        }
    }

    private var isLoading: Bool { model.notesLoading || model.todosLoading || model.backupLoading || model.calendarLoading }

    private func badge(_ s: AppSection) -> Int {
        switch s {
        case .calendar: return model.overview?.overdue.count ?? 0
        // 等你拍板的审批 + 没处理的验收卡
        case .workbench: return agents.pending.count + agents.completions.count
        default: return 0
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .today: TodayView()
        case .calendar: CalendarView()
        case .insights: InsightsView()
        case .reading: ReadingView()
        case .focus: ProjectsView()
        case .workbench: AIWorkbenchView()
        case .settings: EmptyView()
        }
    }
}

/// 标题栏上的「开始专注 X 分钟」+ 小下拉：点按钮按上次的时长直接开始，下拉里选别的时长；专注中点一下回到专注页
private struct FocusToolbarButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var focus: FocusStore

    private var running: Bool { focus.run != nil && !(focus.run?.kind.isBreak ?? true) }

    var body: some View {
        let breakKind = focus.pendingBreak
        let title = running ? "专注中" : (breakKind != nil ? "休息 \(focus.minutes) 分钟" : "开始专注 \(focus.minutes) 分钟")
        let icon = running ? "timer" : (breakKind != nil ? "cup.and.saucer.fill" : "play.fill")
        // 自己拼：按钮 + 小下拉，中间不画分隔线，图标和文字之间留一点距离
        HStack(spacing: 10) {
            Button {
                if running { model.selectedProject = nil; model.section = .focus }
                else if breakKind != nil { focus.start() }
                else { focus.quickFocus(focus.minutes) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                    Text(title)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 6)
        .help(running ? "专注进行中，点击打开专注页"
              : breakKind != nil ? "开始\(breakKind!.label) \(focus.minutes) 分钟（右边的箭头选时长）"
              : "开始专注 \(focus.minutes) 分钟（右边的箭头选时长）")
    }
}
