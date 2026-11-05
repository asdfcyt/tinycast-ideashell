import AppKit
import Foundation

/// 万能输入框的「全能搜索」里的一条结果。来源有四个：
/// - 结审：走结审 MCP 的 `search` 工具（任务 / 文书全文 / 取证单 / 台账 / 日志小结 / 法规库，可选数据中心）
/// - 笔记：走闪念贝壳 MCP 的 `note_search`
/// - 待办：滴答清单（本机已缓存的任务 + 滴答 MCP 的关键词搜索，搜得到老任务和已完成的）+ 闪念贝壳自带的待办（`todo_list`）
/// - 日记：Daily Note 里的单条日记（本机读过的 Daily Note，不发请求）
struct SearchItem: Identifiable, Hashable {
    enum Source: String, CaseIterable, Hashable {
        case sjz = "结审", note = "笔记", todo = "待办", daily = "日记"
    }

    enum Payload: Hashable {
        case sjz(SjzSearchHit)
        case note(NoteInfo)
        case todo(DidaTask)
        case ideaTodo(String)
        case daily(noteId: String, date: String)
    }

    let id: String
    let source: Source
    let kind: String
    let kindLabel: String
    let title: String
    let snippet: String
    /// 小字：项目名 / 日期
    let context: String
    let score: Double
    let icon: String
    let payload: Payload

    /// 属于数据中心（表 / 行）
    var isData: Bool { kind == "table" || kind == "row" }
}

@MainActor
final class UniversalSearch: ObservableObject {
    @Published private(set) var items: [SearchItem] = []
    @Published private(set) var loading: Set<SearchItem.Source> = []
    @Published private(set) var errors: [SearchItem.Source: String] = [:]
    /// 已经发出去搜索的关键词（界面据此区分「没有结果」和「还没搜」）
    @Published private(set) var searchedQuery = ""

    private var generation = 0
    private var work: Task<Void, Never>?
    private var bySource: [SearchItem.Source: [SearchItem]] = [:]

    /// 关键词拆成多个词（空格 / 逗号分隔），每个词都要出现
    static func terms(_ q: String) -> [String] {
        q.lowercased().split(whereSeparator: { " ,，;；、　".contains($0) }).map(String.init).filter { !$0.isEmpty }
    }

    /// 输入变化后调用：停一小会儿（等输入稳定）再发请求，旧请求的结果会被丢掉
    func update(_ raw: String, model: AppModel, includeData: Bool, currentOnly: Bool) {
        let q = raw.trimmed
        work?.cancel()
        generation += 1
        let gen = generation
        guard !q.isEmpty else { reset(); return }
        // 本机的来源（待办缓存 / 日记）不用等：立刻出结果，网络来源再等输入稳定
        showLocal(q, gen: gen, model: model)
        work = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            await self?.run(q, gen: gen, model: model, includeData: includeData, currentOnly: currentOnly)
        }
    }

    func reset() {
        work?.cancel()
        generation += 1
        bySource = [:]
        items = []
        loading = []
        errors = [:]
        searchedQuery = ""
    }

    /// 输入时先给本机能匹配的（待办缓存、日记），旧的网络结果保留到新结果回来
    private func showLocal(_ q: String, gen: Int, model: AppModel) {
        bySource[.todo] = Self.localTodoItems(q, model: model)
        if model.hasIdeashell { bySource[.daily] = Self.dailyItems(q, model: model) }
        // 关键词变了：旧关键词的网络结果不再对得上，去掉
        bySource[.sjz] = nil
        bySource[.note] = nil
        publish()
    }

    private func publish() {
        items = bySource.values.flatMap { $0 }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
    }

    private func run(_ q: String, gen: Int, model: AppModel, includeData: Bool, currentOnly: Bool) async {
        var sources: [SearchItem.Source] = []
        if model.hasSjz { sources.append(.sjz) }
        if model.hasIdeashell { sources.append(.note); sources.append(.daily) }
        sources.append(.todo)

        errors = [:]
        loading = Set(sources)
        searchedQuery = q

        let tasks = sources.map { src in
            Task { await self.fetch(src, q: q, gen: gen, model: model, includeData: includeData, currentOnly: currentOnly) }
        }
        for t in tasks { await t.value }
    }

    private func fetch(_ src: SearchItem.Source, q: String, gen: Int, model: AppModel, includeData: Bool, currentOnly: Bool) async {
        var out: [SearchItem] = []
        var err: String?
        do {
            switch src {
            case .sjz:
                var kinds: [String]? = nil
                if includeData { kinds = ["project", "task", "doc", "evidence", "regulation", "clue", "idea", "data", "datalist", "summary", "log", "file", "law", "table", "row"] }
                let hits = try await model.sjz.search(q, kinds: kinds, currentOnly: currentOnly, limit: 40)
                out = hits.map(Self.item(sjz:))
            case .note:
                let terms = Self.terms(q)
                let dailyIds = Set(model.daily.cachedDays().values.map(\.noteId) + [model.dailyToday?.noteId].compactMap { $0 })
                let notes = try await model.ideashell.searchNotes(q, limit: 20)
                    .filter { !BackupService.isBackupNote($0) && !dailyIds.contains($0.id) }
                out = notes.enumerated().map { Self.item(note: $1, rank: $0, terms: terms) }
            case .daily:
                out = Self.dailyItems(q, model: model)
            case .todo:
                out = try await todoItems(q, gen: gen, model: model)
            }
        } catch is CancellationError {
            return
        } catch {
            err = Self.friendly(error)
        }
        guard gen == generation, !Task.isCancelled else { return }
        bySource[src] = out
        errors[src] = err
        loading.remove(src)
        publish()
    }

    private static func friendly(_ error: Error) -> String {
        let msg = error.localizedDescription
        if msg.contains("未知工具") { return "结审版本太旧，请升级后再搜" }
        return msg
    }

    // MARK: - 结果转换

    private static func item(sjz h: SjzSearchHit) -> SearchItem {
        let icon: String
        switch h.kind {
        case "task": icon = "checklist"
        case "doc": icon = "doc.text"
        case "evidence": icon = "doc.text.image"
        case "regulation", "law": icon = "book.closed"
        case "clue": icon = "lightbulb"
        case "idea": icon = "text.bubble"
        case "data", "file": icon = "tablecells"
        case "datalist": icon = "list.clipboard"
        case "summary": icon = "doc.richtext"
        case "log": icon = "text.book.closed"
        case "project": icon = "checkmark.shield"
        case "table", "row": icon = "cylinder.split.1x2"
        default: icon = "doc"
        }
        return SearchItem(id: "sjz|" + h.id, source: .sjz, kind: h.kind, kindLabel: h.kindLabel, title: h.title.isEmpty ? h.ref : h.title,
                          snippet: h.snippet, context: h.projectTitle, score: h.score, icon: icon, payload: .sjz(h))
    }

    private static func item(note n: NoteInfo, rank: Int, terms: [String]) -> SearchItem {
        let body = (n.summary ?? n.text ?? "").replacingOccurrences(of: "\n", with: " ").trimmed
        let title = n.title.isEmpty ? "无标题笔记" : n.title
        // 语义搜索按相关度排；标题里直接带关键词的往前提一点
        let inTitle = !terms.isEmpty && terms.allSatisfy { title.lowercased().contains($0) }
        return SearchItem(id: "note|" + n.id, source: .note, kind: "note", kindLabel: "笔记", title: title,
                          snippet: String(body.prefix(120)), context: n.day ?? "", score: 62 - Double(rank) * 1.5 + (inTitle ? 18 : 0),
                          icon: "note.text", payload: .note(n))
    }

    // MARK: 待办

    private static func matches(_ t: DidaTask, _ terms: [String]) -> Bool {
        let hay = t.cleanTitle.lowercased() + " " + t.content.lowercased() + " " + t.tags.joined(separator: " ").lowercased()
        return terms.allSatisfy { hay.contains($0) }
    }

    private static func item(todo t: DidaTask, terms: [String], projects: [String: String]) -> SearchItem {
        let title = t.cleanTitle.lowercased()
        let inTitle = !terms.isEmpty && terms.allSatisfy { title.contains($0) }
        let score = (inTitle ? 80.0 : 40.0) + (t.done ? -12 : 4)
        let content = t.content.replacingOccurrences(of: "\n", with: " ").trimmed
        var when = t.date.map { Day.label($0) + (t.time.map { " " + $0 } ?? "") } ?? "无日期"
        if let p = projects[t.projectId], !p.isEmpty { when = p + " · " + when }
        return SearchItem(id: "todo|" + t.id, source: .todo, kind: t.done ? "todo.done" : "todo", kindLabel: t.done ? "已完成" : "待办",
                          title: t.cleanTitle, snippet: String(content.prefix(100)), context: when, score: score,
                          icon: t.done ? "checkmark.circle.fill" : "circle", payload: .todo(t))
    }

    /// 本机已经缓存的滴答任务里匹配（逾期 / 近期 / 收集箱 / 最近完成 / 日历里看过的）
    private static func localTodoItems(_ q: String, model: AppModel) -> [SearchItem] {
        let terms = Self.terms(q)
        guard !terms.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [SearchItem] = []
        func scan(_ list: [DidaTask], done: Bool) {
            for var t in list where !t.id.hasPrefix(SjzTasks.prefix) && seen.insert(t.id).inserted && matches(t, terms) {
                if done { t.done = true }
                out.append(item(todo: t, terms: terms, projects: model.overview?.projects ?? [:]))
            }
        }
        if let ov = model.overview {
            scan(ov.overdue, done: false)
            scan(ov.upcoming, done: false)
            scan(ov.undated, done: false)
            scan(ov.done, done: true)
        }
        scan(Array(model.calendarTasks.values), done: false)
        return Array(out.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }.prefix(20))
    }

    /// 待办：本机缓存 + 滴答 MCP 搜索（老任务 / 已完成）+ 闪念贝壳自己的待办。本机的先出，网络的回来再补
    private func todoItems(_ q: String, gen: Int, model: AppModel) async throws -> [SearchItem] {
        let terms = Self.terms(q)
        let local = Self.localTodoItems(q, model: model)
        if gen == generation { bySource[.todo] = local; publish() }

        var merged = local
        var seen = Set(local.map(\.id))
        var firstError: Error?
        let projects = model.overview?.projects ?? [:]

        if model.hasDida {
            do {
                if let remote = try await model.dida.searchTasks(q) {
                    for t in remote where !t.id.hasPrefix(SjzTasks.prefix) {
                        let it = Self.item(todo: t, terms: terms, projects: projects)
                        if seen.insert(it.id).inserted { merged.append(it) }
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 滴答搜索失败不算错：本机缓存里的照样能用
                if local.isEmpty { firstError = error }
            }
        }
        if model.hasIdeashell {
            do {
                let ideas = try await model.ideashell.searchTodos(q)
                // 带日期的待办会同步到闪念贝壳：和滴答里同名同日的算同一条
                let known = Set(merged.compactMap { it -> String? in
                    if case let .todo(t) = it.payload { return t.cleanTitle.lowercased() + "|" + (t.date ?? "") }
                    return nil
                })
                for t in ideas {
                    guard !known.contains(t.content.trimmed.lowercased() + "|" + (t.date ?? "")) else { continue }
                    let inTitle = terms.allSatisfy { t.content.lowercased().contains($0) }
                    let when = t.date.map { Day.label($0) + (t.time.map { " " + $0 } ?? "") } ?? "无日期"
                    let it = SearchItem(id: "idea-todo|" + t.id, source: .todo, kind: t.done ? "todo.done" : "todo", kindLabel: t.done ? "闪念已完成" : "闪念待办",
                                        title: t.content, snippet: "", context: when, score: (inTitle ? 76.0 : 38.0) + (t.done ? -12 : 4),
                                        icon: t.done ? "checkmark.circle.fill" : "circle.dashed", payload: .ideaTodo(t.content))
                    if seen.insert(it.id).inserted { merged.append(it) }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if merged.isEmpty, firstError == nil { firstError = error }
            }
        }
        if merged.isEmpty, let e = firstError { throw e }
        return Array(merged.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }.prefix(30))
    }

    // MARK: 日记

    /// Daily Note 里的单条日记：本机读过的过去日子 + 今天
    private static func dailyItems(_ q: String, model: AppModel) -> [SearchItem] {
        let terms = Self.terms(q)
        guard !terms.isEmpty else { return [] }
        var days = model.daily.cachedDays()
        if let d = model.dailyToday { days[Day.today()] = d }
        var hits: [(date: String, entry: DailyEntry, noteId: String, index: Int)] = []
        for (date, day) in days {
            for (i, e) in day.entries.enumerated() where terms.allSatisfy({ e.text.lowercased().contains($0) }) {
                hits.append((date, e, day.noteId, i))
            }
        }
        hits.sort { $0.date != $1.date ? $0.date > $1.date : $0.entry.time > $1.entry.time }
        return hits.prefix(20).enumerated().map { rank, h in
            SearchItem(id: "daily|\(h.date)|\(h.index)", source: .daily, kind: "daily", kindLabel: "日记",
                       title: String(h.entry.text.prefix(60)), snippet: h.entry.text.count > 60 ? String(h.entry.text.dropFirst(60).prefix(100)) : "",
                       context: String(h.date.dropFirst(5)) + " " + h.entry.time, score: 58 - Double(rank) * 0.8,
                       icon: "book.pages", payload: .daily(noteId: h.noteId, date: h.date))
        }
    }
}

// MARK: - 打开结果

extension AppModel {
    /// 打开一条搜索结果：笔记 / 待办 / 日记在拾忆里打开；结审的台账、小结用拾忆的预览窗口；文书、数据中心等去结审里定位。
    /// `inSjzApp` = true 时一律在结审里打开（⌘↩）。
    func openSearchItem(_ item: SearchItem, inSjzApp: Bool = false) {
        switch item.payload {
        case let .note(n):
            MainWindow.show()
            openNote(n.id, title: n.title)
        case let .todo(task):
            MainWindow.show()
            openTask(localTask(task.id) ?? task)
        case let .ideaTodo(content):
            // 闪念贝壳自带的待办拾忆里没有详情页：打开闪念贝壳网页版，并把内容放进剪贴板方便搜
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
            showNotice("已复制待办内容，闪念贝壳里粘贴即可定位")
            if let url = URL(string: "https://ideashell.site") { NSWorkspace.shared.open(url) }
        case let .daily(noteId, date):
            MainWindow.show()
            openNote(noteId, title: date)
        case let .sjz(h):
            if inSjzApp { openSjzApp(project: h.project.isEmpty ? nil : h.project, to: h.to.isEmpty ? "/" : h.to) } else { openSjzHit(h) }
        }
    }

    private func openSjzHit(_ h: SjzSearchHit) {
        // 台账编号（E-0001 这类）才能走 get_capture；带路径的是普通文件，只能去结审里看
        let isLedgerId = !h.ref.contains("/") && !h.ref.lowercased().hasSuffix(".md")
        switch h.kind {
        case "task":
            if let t = localTask(SjzTasks.prefix + h.project + ":" + h.ref) {
                MainWindow.show()
                openTask(t)
            } else {
                openSjzApp(project: h.project, to: h.to)
            }
        case "evidence", "regulation", "clue", "idea", "data", "datalist":
            if isLedgerId, !h.project.isEmpty {
                openSjzPreview(project: h.project, capture: SjzCapture(id: h.ref, kind: h.kind, title: h.title, summary: h.snippet, source: "结审",
                                                                       path: h.path, noteNo: "", notePath: "", status: "", taskId: "", at: h.updatedAt, editedAt: ""))
            } else {
                openSjzApp(project: h.project.isEmpty ? nil : h.project, to: h.to.isEmpty ? "/" : h.to)
            }
        case "summary":
            let kind = h.ref.contains("日报") ? "daily" : h.ref.contains("周报") ? "weekly" : h.ref.contains("阶段") ? "phase" : "project"
            openSjzPreview(project: h.project, capture: SjzSummary(path: h.ref, title: h.title, kind: kind, period: "", updatedAt: h.updatedAt).asCapture)
        case "project":
            MainWindow.show()
            closeSheets()
            selectedProject = SjzTasks.prefix + h.project
            section = .focus
        default:
            openSjzApp(project: h.project.isEmpty ? nil : h.project, to: h.to.isEmpty ? "/" : h.to)
        }
    }
}
