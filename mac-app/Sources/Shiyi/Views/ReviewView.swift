import SwiftUI

/// 回顾：把原来的「笔记」页并进来。左边是时间河（含语义搜索结果），单击一条在右边展开详情，双击弹出页面。
struct ReviewView: View {
    @EnvironmentObject var model: AppModel

    private var noData: Bool { !model.hasIdeashell && !model.hasDida }

    var body: some View {
        riverTab
        .background(AmbientBackground())
        .overlay(alignment: .bottom) { UndoToast().padding(.bottom, 16) }
        .searchable(text: $model.searchQuery, placement: .toolbar, prompt: "语义搜索笔记")
        .onSubmit(of: .search) { Task { await model.searchAndShow() } }
        .onChange(of: model.searchQuery) { _, new in if new.isEmpty { model.clearSearch() } }
        .toolbar { ToolbarItem(placement: .primaryAction) { rangeMenu } }
        .task { await model.loadRiver(ifStale: true) }
    }

    // MARK: - 时间河

    private var riverTab: some View {
        TwoPane(leadingFraction: 0.52, leadingMin: 380, leadingMax: 660, trailingMin: 340) {
            ScrollView {
                riverColumn
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
            }
        } trailing: {
            PaneDetail()
        }
    }

    private var riverColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            if noData {
                EmptyHint(icon: "key", title: "先到「设置」填写凭证").frame(height: 240)
            } else if let results = model.searchResults {
                searchList(results)
            } else {
                if let e = model.riverError { ErrorBanner(text: e) { Task { await model.loadRiver() } } }
                if let r = model.river {
                    riverSummary(r)
                    if r.truncated {
                        Text("某个小时内的笔记太多，没有取全；缩小时间范围可以看到更完整的结果。").font(.caption).foregroundStyle(.tertiary)
                    }
                    if let t = r.todoNote { Text(t).font(.caption).foregroundStyle(.orange) }
                    if r.isEmpty {
                        EmptyHint(icon: "water.waves", title: "这段时间没有记录", detail: "换个范围看看，或者点右上角的「+」写下第一条。").frame(height: 220)
                    } else {
                        RiverView(data: r)
                    }
                } else if model.riverLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
        }
    }

    private func riverSummary(_ r: TimelineData) -> some View {
        var parts = ["\(r.noteCount) 笔记"]
        if r.dailyCount > 0 { parts.append("\(r.dailyCount) 日记") }
        parts.append("待办完成 \(r.todoDone)/\(r.todoTotal)")
        return Text(parts.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
    }

    /// 语义搜索结果：替换河。单击右侧展开，双击弹出
    private func searchList(_ results: [NoteInfo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("搜索「\(model.searchQuery)」· \(results.count) 条").font(.callout.weight(.semibold))
                if model.searching { ProgressView().controlSize(.small) }
                Spacer()
                Button("退出搜索") { model.clearSearch() }.buttonStyle(.link)
            }
            if results.isEmpty {
                EmptyHint(icon: "magnifyingglass", title: "没有找到相关笔记").frame(height: 200)
            }
            ForEach(results) { n in
                PaneSelection(pane: model.pane, match: { $0.isNote(n.id) }) { selected in
                    NoteRow(note: n, showDay: true)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(selected ? Brand.orange.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { model.paneNote(n.id, title: n.title) }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { model.openNote(n.id, title: n.title) })
                }
            }
        }
    }

    /// 标题栏里的范围菜单；复制日报也在这个菜单里
    private var rangeMenu: some View {
        Menu {
            ForEach(RangePreset.allCases) { p in
                Button {
                    model.selectRiverPreset(p)
                } label: {
                    if p == model.riverPreset { Label(p.rawValue, systemImage: "checkmark") } else { Text(p.rawValue) }
                }
            }
            Divider()
            Button("刷新") { Task { await model.loadRiver() } }
            Button("复制为日报 / 周报") {
                if let r = model.river {
                    model.copy(r.report(label: model.riverPreset.rawValue))
                    model.showNotice("已复制，可直接贴进日报 / 周报")
                }
            }
            .disabled(model.river?.isEmpty ?? true)
        } label: {
            Label(model.riverPreset.rawValue, systemImage: "calendar")
        }
        .help("时间范围")
    }
}

// MARK: - 右侧详情

/// 时间河右侧：单击展开的笔记 / 任务详情。右上角可以弹出成页面或关闭
struct PaneDetail: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        PaneDetailBody(pane: model.pane)
    }
}

struct PaneDetailBody: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var pane: PaneState

    var body: some View {
        VStack(spacing: 0) {
            if let page = pane.page {
                HStack(spacing: 10) {
                    Text(label(page)).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.sheetStack = [page]
                    } label: {
                        Label("弹出", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .help("在弹出的页面里打开（也可以双击河里的条目）")
                    Button { pane.clear() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("关闭")
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
                Group {
                    switch page {
                    case let .note(r): NoteDetailView(noteId: r.id, fallbackTitle: r.fallbackTitle).id(r.id)
                    case let .task(t): TaskDetailView(task: t).id(t.id)
                    }
                }
            } else {
                EmptyHint(icon: "sidebar.right", title: "点一条记录，在这里展开", detail: "单击在右边查看，双击弹出页面")
            }
        }
    }

    private func label(_ page: SheetPage) -> String {
        switch page {
        case .note: return "笔记"
        case .task: return "待办"
        }
    }
}
