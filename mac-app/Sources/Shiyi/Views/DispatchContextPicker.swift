import AppKit
import SwiftUI

/// 派活时「带入上下文」的一条资料：想法 / 待办 / Daily Note / 剪贴板
struct ContextItem: Identifiable, Hashable {
    enum Kind { case note, task, daily, text

        var icon: String {
            switch self {
            case .note: return "lightbulb"
            case .task: return "checklist"
            case .daily: return "calendar"
            case .text: return "doc.on.clipboard"
            }
        }
    }

    let id: String
    var kind: Kind
    var title: String
    /// 交给 Agent 的正文
    var body: String

    static func joined(_ items: [ContextItem]) -> String? {
        if items.isEmpty { return nil }
        if items.count == 1, items[0].kind == .text { return items[0].body }
        return items.map { "## " + $0.title + "\n\n" + $0.body }.joined(separator: "\n\n---\n\n")
    }
}

/// 点「带入上下文」弹出的选择器：搜想法、搜待办，或一键带入剪贴板 / Daily Note
struct ContextPicker: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var draft = WorkbenchDraft.shared
    @State private var query = ""
    @State private var noteHits: [NoteInfo] = []
    @State private var searching = false
    @State private var loading: Set<String> = []
    @State private var error: String?
    @FocusState private var focused: Bool
    var done: () -> Void

    private var selected: Set<String> { Set(draft.items.map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            quickRow
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let notes = shownNotes
                    let tasks = shownTasks
                    if !notes.isEmpty { group("想法", notes.count) { ForEach(notes) { noteRow($0) } } }
                    if !tasks.isEmpty { group("待办", tasks.count) { ForEach(tasks) { taskRow($0) } } }
                    if notes.isEmpty && tasks.isEmpty {
                        Text(searching ? "搜索中…" : (query.trimmed.isEmpty ? "输入关键词搜索想法和待办" : "没有找到相关的想法或待办"))
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }
            }
            .frame(height: 280)
            Divider()
            HStack {
                Text(draft.items.isEmpty ? "还没选" : "已选 \(draft.items.count) 项")
                    .font(.caption).foregroundStyle(.secondary)
                if !draft.items.isEmpty {
                    Button("清空") { draft.items = [] }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 400)
        .onAppear { focused = true }
        .task(id: query) { await runSearch() }
    }

    // MARK: 搜索

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索想法、待办", text: $query).textFieldStyle(.plain).focused($focused)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func runSearch() async {
        let q = query.trimmed
        guard !q.isEmpty, model.hasIdeashell else { noteHits = []; searching = false; return }
        searching = true
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        let hits = (try? await model.ideashell.searchNotes(q, limit: 10)) ?? []
        guard !Task.isCancelled else { return }
        noteHits = hits.filter { !BackupService.isBackupNote($0) }
        searching = false
    }

    private var shownNotes: [NoteInfo] {
        query.trimmed.isEmpty ? Array(model.timeline.prefix(6)) : noteHits
    }

    private var shownTasks: [DidaTask] {
        guard let ov = model.overview else { return [] }
        let q = query.trimmed
        if q.isEmpty { return Array((ov.overdue + ov.todayTasks()).prefix(6)) }
        let words = q.lowercased().split(whereSeparator: { $0 == " " || $0 == "　" }).map(String.init)
        let hits = (ov.overdue + ov.upcoming + ov.undated).filter { t in
            let hay = (t.cleanTitle + " " + t.tags.joined(separator: " ") + " " + (ov.projectName(t.projectId) ?? "")).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        return Array(hits.prefix(8))
    }

    // MARK: 快捷来源

    private var quickRow: some View {
        HStack(spacing: 6) {
            chip("剪贴板", "doc.on.clipboard", on: selected.contains("clip")) { toggleClipboard() }
            chip("今天 Daily", "calendar", on: selected.contains("daily.today")) { toggleDaily(.todayDaily, "daily.today") }
            chip("昨天 Daily", "calendar.badge.clock", on: selected.contains("daily.yesterday")) { toggleDaily(.yesterdayDaily, "daily.yesterday") }
            chip("今日待办", "list.bullet", on: selected.contains("todos")) { toggleDaily(.todayTodos, "todos") }
        }
    }

    private func chip(_ text: String, _ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(text).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(on ? Color.white : Color.secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(on ? Brand.orange : Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toggleClipboard() {
        if remove("clip") { return }
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmed, !s.isEmpty else { error = "剪贴板里没有文字"; return }
        error = nil
        draft.items.append(ContextItem(id: "clip", kind: .text, title: "剪贴板", body: s))
    }

    private func toggleDaily(_ m: DispatchRule.Material, _ id: String) {
        if remove(id) { return }
        error = nil
        Task {
            if let s = await DispatchRuleEngine.shared.material(m, model: model) {
                draft.items.append(ContextItem(id: id, kind: id == "todos" ? .task : .daily, title: m.label, body: s))
            } else {
                error = "「\(m.label)」现在是空的"
            }
        }
    }

    @discardableResult
    private func remove(_ id: String) -> Bool {
        guard draft.items.contains(where: { $0.id == id }) else { return false }
        draft.items.removeAll { $0.id == id }
        return true
    }

    // MARK: 列表

    private func group<C: View>(_ title: String, _ n: Int, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(n)").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 2)
            content()
        }
    }

    private func noteRow(_ n: NoteInfo) -> some View {
        let id = "note." + n.id
        let on = selected.contains(id)
        let sub = [n.day.map { Day.label($0) }, n.clock].compactMap { $0 }.joined(separator: " ")
        return row(icon: ContextItem.Kind.note.icon, title: n.title.isEmpty ? (n.summary ?? "无标题") : n.title, sub: sub, on: on, busy: loading.contains(id)) {
            if remove(id) { return }
            loading.insert(id)
            Task {
                defer { loading.remove(id) }
                var body = n.text ?? n.summary ?? ""
                if let d = try? await model.noteDetail(n.id) { body = d.content }
                let title = n.title.isEmpty ? "想法" : n.title
                draft.items.append(ContextItem(id: id, kind: .note, title: title, body: body))
            }
        }
    }

    private func taskRow(_ t: DidaTask) -> some View {
        let id = "task." + t.id
        let sub = t.time ?? t.date.map { Day.label($0) }
        return row(icon: ContextItem.Kind.task.icon, title: t.cleanTitle, sub: sub ?? "", on: selected.contains(id), busy: false) {
            if remove(id) { return }
            var body = "- [ ] " + t.cleanTitle
            if let d = t.date { body += "\n- 日期：" + d + (t.time.map { " " + $0 } ?? "") }
            if !t.tags.isEmpty { body += "\n- 标签：" + t.tags.joined(separator: " ") }
            if let p = model.overview?.projectName(t.projectId) { body += "\n- 清单：" + p }
            if !t.content.trimmed.isEmpty { body += "\n\n" + t.content.trimmed }
            draft.items.append(ContextItem(id: id, kind: .task, title: t.cleanTitle, body: body))
        }
    }

    private func row(icon: String, title: String, sub: String, on: Bool, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 14))
                    .foregroundStyle(on ? Brand.orange : Color.secondary.opacity(0.6))
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                Text(title).font(.callout).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if busy { ProgressView().controlSize(.mini) }
                else if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.tertiary).lineLimit(1).fixedSize() }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Brand.orange.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
