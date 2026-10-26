import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
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
            detail
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
        .sheet(isPresented: Binding(get: { !model.sheetStack.isEmpty }, set: { if !$0 { model.closeSheets() } })) {
            DetailSheet().environmentObject(model).dismissOnOutsideClick()
        }
        .sheet(item: $model.newNoteDraft) { draft in
            NewNoteSheet(draft: draft).environmentObject(model).dismissOnOutsideClick()
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
