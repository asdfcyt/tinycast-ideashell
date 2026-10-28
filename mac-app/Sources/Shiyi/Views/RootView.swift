import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
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
                .navigationTitle(model.section.title)
                .overlay(alignment: .bottom) { NoticeToast().padding(.bottom, 64) }
                .sheet(isPresented: $model.showQuickAdd) {
                    QuickAddView(onDone: { model.showQuickAdd = false }).environmentObject(model).dismissOnOutsideClick()
                }
                .toolbar {
                    // 加号在标题栏最前面
                    ToolbarItem(placement: .navigation) {
                        Button { model.openQuickAddHere() } label: { Image(systemName: "plus") }
                            .help(model.section == .calendar ? "添加待办（⌘N）" : "万能输入（⌘N）")
                    }
                    // 刷新放在右边；搜索框由页面自己的 .searchable 放在最右边
                    ToolbarItemGroup(placement: .primaryAction) {
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
        .overlay {
            // 空格快速预览：盖在整个窗口上（含侧栏），面板居中、宽 620，窗口小时四周留 24 的边距
            if let q = model.sjzQuick {
                GeometryReader { geo in
                    ZStack {
                        Color.black.opacity(0.07).ignoresSafeArea().contentShape(Rectangle())
                            .onTapGesture { model.closeSjzQuick() }
                        SjzQuickLook(api: model.sjz, project: q.project, capture: q.capture,
                                     size: CGSize(width: max(360, min(620, geo.size.width - 48)), height: max(320, min(720, geo.size.height - 48))),
                                     onClose: { model.closeSjzQuick() },
                                     onEdit: { model.sjzEdit = q; model.sjzQuick = nil })
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.lastUndo?.id)
        .animation(.easeInOut(duration: 0.2), value: model.notice)
    }

    private func sideRow(_ s: AppSection) -> some View {
        SidebarRow(title: s.title, selected: model.section == s, badge: badge(s), fontSize: 14, action: { model.section = s }) { on in
            Image(systemName: s.icon).font(.system(size: 15))
                .foregroundStyle(on ? Color.white : Brand.orange)
                .frame(width: 22)
        }
    }

    private var isLoading: Bool { model.notesLoading || model.todosLoading || model.backupLoading || model.riverLoading || model.calendarLoading }

    private func badge(_ s: AppSection) -> Int {
        switch s {
        case .todos: return model.overview?.overdue.count ?? 0
        default: return 0
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .today: TodayView()
        case .todos: TodosView()
        case .calendar: CalendarView()
        case .review: ReviewView()
        case .insights: InsightsView()
        case .focus: ProjectsView()
        case .settings: EmptyView()
        }
    }
}
