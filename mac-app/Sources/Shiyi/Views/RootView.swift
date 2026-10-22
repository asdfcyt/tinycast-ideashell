import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<AppSection?>(get: { model.section }, set: { if let v = $0 { model.section = v } })) {
                ForEach(AppSection.allCases.filter { $0 != .settings }) { s in
                    Label(s.title, systemImage: s.icon)
                        .badge(badge(s))
                        .tag(s)
                }
                Section {
                    Label(AppSection.settings.title, systemImage: AppSection.settings.icon).tag(AppSection.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            detail
                .navigationTitle(model.section.title)
                .overlay(alignment: .bottom) { NoticeToast().padding(.bottom, 64) }
                .sheet(isPresented: $model.showQuickAdd) {
                    QuickAddView(onDone: { model.showQuickAdd = false }).environmentObject(model)
                }
                .background {
                    // ⌘N 一直可用（侧边栏收起时加号按钮也跟着收起）
                    Button("") { model.openQuickAddHere() }
                        .keyboardShortcut("n", modifiers: .command)
                        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
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
                        .keyboardShortcut("r", modifiers: .command)
                    }
                }
        }
        .sheet(isPresented: Binding(get: { !model.sheetStack.isEmpty }, set: { if !$0 { model.closeSheets() } })) {
            DetailSheet().environmentObject(model)
        }
        .animation(.easeInOut(duration: 0.2), value: model.lastUndo?.id)
        .animation(.easeInOut(duration: 0.2), value: model.notice)
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
        case .settings: SettingsView()
        }
    }
}
