import SwiftUI

struct TodosView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var showDone = true
    @State private var selectedId: String?
    /// 正在被拖着的任务悬在哪个目标上（日期 yyyy-MM-dd，或 "none" = 无日期）
    @State private var dropKey: String?

    private func filtered(_ list: [DidaTask]) -> [DidaTask] {
        let q = query.trimmed.lowercased()
        guard !q.isEmpty else { return list }
        return list.filter { $0.title.lowercased().contains(q) || $0.tags.contains { $0.lowercased().contains(q) } || $0.content.lowercased().contains(q) }
    }

    private func sorted(_ list: [DidaTask]) -> [DidaTask] {
        list.sorted {
            let a = ($0.date ?? "", $0.time ?? "00:00"), b = ($1.date ?? "", $1.time ?? "00:00")
            if a != b { return a < b }
            return $0.priority > $1.priority
        }
    }

    var body: some View {
        TwoPane(leadingFraction: 0.44, leadingMin: 300, leadingMax: 560, trailingMin: 340) {
            listPane
        } trailing: {
            Group {
                if let id = selectedId, let t = model.localTask(id) {
                    TaskDetailView(task: t).id(id)
                } else {
                    EmptyHint(icon: "checklist", title: "选一个任务查看详情", detail: "详情里会融合这个任务的任务笔记")
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "筛选待办")
        .overlay(alignment: .bottom) { UndoToast().padding(.bottom, 16) }
    }

    private var listPane: some View {
        Group {
            if !model.hasDida {
                EmptyHint(icon: "key", title: "还没有填写滴答清单 API 口令", detail: "到「设置」里填写后即可查看待办")
            } else if let ov = model.overview {
                VStack(spacing: 0) {
                    dropBar
                    list(ov)
                }
            } else if model.todosLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack {
                    if let e = model.todosError { ErrorBanner(text: e) { Task { await model.loadOverview() } }.padding() }
                    EmptyHint(icon: "checklist", title: "暂无数据")
                }
            }
        }
    }

    /// 一行待办：没做完的可以拖；落在同一天的其他行上等于改到那天
    private func row(_ t: DidaTask, overdue: Bool = false, droppable: Bool = false, day: String? = nil) -> some View {
        let r = TaskRow(task: t, overdue: overdue, opensDetail: false)
            .modifier(DraggableWhenOpen(task: t))
            .tag(t.id)
        return Group {
            if droppable { r.modifier(TodoDrop(day: day, key: $dropKey)) } else { r }
        }
    }

    /// 顶部的「拖到这里改期」：今天 / 明天 / 后天 / 下周一 / 无日期。列表里没有「今天」这一组时也能把任务拖到今天
    private var dropBar: some View {
        let today = Day.today()
        let nextMonday: String = {
            let wd = Day.cal.component(.weekday, from: Day.parse(today) ?? Date())  // 1 = 周日
            return Day.add(today, days: (9 - wd) % 7 == 0 ? 7 : (9 - wd) % 7)
        }()
        let targets: [(label: String, day: String?)] = [
            ("今天", today), ("明天", Day.add(today, days: 1)), ("后天", Day.add(today, days: 2)),
            ("下周一", nextMonday), ("无日期", nil),
        ]
        return HStack(spacing: 8) {
            Image(systemName: "hand.draw").font(.caption).foregroundStyle(.tertiary)
            Text("拖到这里改期").font(.caption).foregroundStyle(.tertiary)
            ForEach(targets, id: \.label) { t in
                let key = t.day ?? "none"
                Text(t.label)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(dropKey == key ? Brand.orange.opacity(0.35) : Color.primary.opacity(0.07), in: Capsule())
                    .overlay(Capsule().strokeBorder(dropKey == key ? Brand.orange : .clear, lineWidth: 1.5))
                    .modifier(TodoDrop(day: t.day, key: $dropKey))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func list(_ ov: DidaOverview) -> some View {
        let overdue = sorted(filtered(ov.overdue))
        let upcoming = sorted(filtered(ov.upcoming))
        let byDate = Dictionary(grouping: upcoming) { $0.date ?? "" }
        let undated = filtered(ov.undated)
        let done = filtered(ov.done)
        return List(selection: $selectedId) {
            if let e = model.todosError { ErrorBanner(text: e) { Task { await model.loadOverview() } }.listRowSeparator(.hidden) }

            if !overdue.isEmpty {
                Section { ForEach(overdue) { row($0, overdue: true) } } header: {
                    SectionTitle(text: "逾期", count: overdue.count, tint: .red)
                }
            }
            ForEach(byDate.keys.sorted(), id: \.self) { day in
                Section {
                    ForEach(byDate[day] ?? []) { row($0, droppable: true, day: day) }
                } header: {
                    HStack(spacing: 6) {
                        SectionTitle(text: Day.label(day), count: byDate[day]?.count)
                        Text(day.dropFirst(5)).font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(TodoDrop(day: day, key: $dropKey))
                }
            }
            if !undated.isEmpty {
                Section { ForEach(undated) { row($0, droppable: true, day: nil) } } header: {
                    SectionTitle(text: "无日期（收集箱）", count: undated.count)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(TodoDrop(day: nil, key: $dropKey))
                }
            }
            if overdue.isEmpty && upcoming.isEmpty && undated.isEmpty {
                EmptyHint(icon: "checkmark.seal", title: "没有待办", detail: query.isEmpty ? "近 7 天没有要做的事" : "没有匹配的待办")
                    .frame(height: 200)
            }
            if !done.isEmpty {
                Section {
                    if showDone {
                        ForEach(done) { t in
                            HStack {
                                TaskRow(task: t, opensDetail: false)
                                Button("撤销") { Task { await model.undoComplete(t) } }
                                    .buttonStyle(.link).font(.caption)
                            }
                            .tag(t.id)
                        }
                    }
                } header: {
                    Button { showDone.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showDone ? "chevron.down" : "chevron.right").font(.caption)
                            SectionTitle(text: "最近完成（3 天）", count: done.count)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

/// 完成任务后的短暂「撤销」提示
struct UndoToast: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let t = model.lastUndo {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("已完成「\(t.cleanTitle)」").lineLimit(1)
                Button("撤销") { Task { await model.undoComplete(t) } }.buttonStyle(.link)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassCapsule()
            .shadow(radius: 6, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// 待办页的落点：把拖来的任务改到某一天（day 为 nil = 清除日期）；保留原来的时间点
private struct TodoDrop: ViewModifier {
    @EnvironmentObject var model: AppModel
    let day: String?
    @Binding var key: String?

    func body(content: Content) -> some View {
        let mine = day ?? "none"
        content
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first, let task = model.localTask(id), !task.done else { return false }
                if let day {
                    if day < Day.today() { model.showNotice("不能把任务安排到过去"); return false }
                    if task.date == day { return true }
                    Task { await model.edit(task, .schedule(date: day, time: task.time)) }
                } else {
                    if task.date == nil { return true }
                    Task { await model.edit(task, .clearDate) }
                }
                return true
            } isTargeted: { over in
                if over { key = mine } else if key == mine { key = nil }
            }
    }
}
