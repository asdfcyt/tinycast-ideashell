import Foundation

/// 万能输入的「发件箱」：按下回车 → 先把这条记到本机（立刻返回结果）→ 后台再慢慢写进滴答 / 闪念贝壳。
/// 写失败（断网、服务暂时不可用）会留在发件箱里按退避重试，重启应用后也会继续；
/// 凭证没填、内容为空这类重试也没用的错误，当场就在提交时报出来，不进发件箱。
/// 刚创建出来的东西，足够把它撤销掉（笔记没有删除接口，不在内）
enum UndoRecord {
    case todo(DidaTask)
    case daily(date: String, entry: DailyEntry)
}

@MainActor
final class CaptureOutbox {
    static let shared = CaptureOutbox()

    private struct Job: Codable, Identifiable {
        var id = UUID()
        var kind: String
        var text: String
        var body: String
        var tags: [String]
        var folderName: String?
        var todoContent: String
        var todoDate: String?
        var todoTime: String?
        var priority: Int
        var defaultDate: String?
        var defaultTime: String?
        var attempts = 0
        var createdAt = Date()
    }

    private var jobs: [Job] = []
    private var loaded = false
    private var draining = false
    private var retryWork: DispatchWorkItem?
    private weak var model: AppModel?
    /// 自上次 `takeSubmitted()` 以来新提交的任务 id（HUD 的「撤销」按钮用）
    private var submittedIds: [UUID] = []
    private var inflight: UUID?
    private var retracted = Set<UUID>()
    /// 已经发送成功的：id → 能撤销的记录；不能撤销的（笔记）不在里面
    private var completed: [UUID: UndoRecord] = [:]
    private var completedOrder: [UUID] = []

    func takeSubmitted() -> [UUID] {
        defer { submittedIds = [] }
        return submittedIds
    }
    private static let backoff: [TimeInterval] = [5, 20, 60, 180, 600]
    private static let maxAttempts = 8

    private var fileURL: URL { LocalStore.dir.appendingPathComponent("outbox.json") }

    /// 还在排队的条数（设置 / 界面想显示时用）
    var pending: Int { loadIfNeeded(); return jobs.count }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: fileURL), let list = try? JSONDecoder().decode([Job].self, from: data) { jobs = list }
    }

    private func persist() {
        if jobs.isEmpty { try? FileManager.default.removeItem(at: fileURL); return }
        if let data = try? JSONEncoder().encode(jobs) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// 启动时 / 回到前台时调用：把上次没发出去的继续发
    func resume(model: AppModel) {
        self.model = model
        loadIfNeeded()
        if !jobs.isEmpty { drain(model: model) }
    }

    /// 提交一条：同步检查 + 落本机，立刻返回给用户看的文案；真正写入在后台。检查不过会抛错。
    func submit(_ a: CaptureAnalysis, kind: CaptureKind, priority: Int, defaultDate: String?, defaultTime: String?, model: AppModel) throws -> String {
        loadIfNeeded()
        self.model = model
        let message: String
        switch kind {
        case .todo:
            let title = a.todo.content.trimmed
            guard !title.isEmpty else { throw McpError.tool("待办内容为空") }
            guard model.hasDida || model.hasIdeashell else { throw McpError.noCredential }
            let date = a.todo.date ?? defaultDate
            let time = date == nil ? nil : (a.todo.time ?? (a.todo.date == nil ? defaultTime : nil))
            message = "已添加待办" + (date.map { " · " + Day.label($0) + (time.map { " " + $0 } ?? "") } ?? "")
        case .daily:
            guard model.hasIdeashell else { throw McpError.noCredential }
            guard !a.text.trimmed.isEmpty else { throw McpError.tool("内容为空") }
            message = "已记入今天的 Daily Note"
        case .note:
            guard model.hasIdeashell else { throw McpError.noCredential }
            guard !a.body.trimmed.isEmpty else { throw McpError.tool("内容为空") }
            message = "已保存笔记"
        case .clue, .evidence, .regulation:
            guard model.hasSjz else { throw McpError.tool("先到「设置」开启并连接结审") }
            guard !a.text.trimmed.isEmpty else { throw McpError.tool("内容为空") }
            message = kind == .clue ? "已记入线索" : (kind == .evidence ? "已保存为证据" : "已保存为法规")
        }
        let job = Job(
            kind: kind.rawValue, text: a.text, body: a.body, tags: a.tags, folderName: a.folderName,
            todoContent: a.todo.content, todoDate: a.todo.date, todoTime: a.todo.time,
            priority: priority, defaultDate: defaultDate, defaultTime: defaultTime
        )
        jobs.append(job)
        submittedIds.append(job.id)
        persist()
        drain(model: model)
        return message
    }

    // MARK: 后台发送

    private func drain(model: AppModel) {
        guard !draining else { return }
        draining = true
        retryWork?.cancel()
        Task { @MainActor in
            defer { draining = false }
            while let job = jobs.first {
                guard let kind = CaptureKind(rawValue: job.kind) else { jobs.removeFirst(); persist(); continue }
                let analysis = CaptureAnalysis(
                    text: job.text, body: job.body, tags: job.tags, folderName: job.folderName,
                    todo: ParsedTodo(content: job.todoContent, date: job.todoDate, time: job.todoTime),
                    forced: kind, recommended: kind
                )
                do {
                    model.lastCreated = nil
                    inflight = job.id
                    _ = try await model.submitCapture(analysis, kind: kind, priority: job.priority, defaultDate: job.defaultDate, defaultTime: job.defaultTime)
                    inflight = nil
                    jobs.removeAll { $0.id == job.id }
                    persist()
                    let record = model.lastCreated
                    model.lastCreated = nil
                    if retracted.remove(job.id) != nil {
                        // 发的过程中用户点了撤销：发完立刻撤掉
                        if let record { await perform(record, model) } else { model.showNotice("已经保存了，这一条需要手动删除") }
                    } else if let record {
                        completed[job.id] = record
                        completedOrder.append(job.id)
                        if completedOrder.count > 60 { completed.removeValue(forKey: completedOrder.removeFirst()) }
                    }
                } catch {
                    inflight = nil
                    retracted.remove(job.id)
                    if Self.isTransient(error), job.attempts + 1 < Self.maxAttempts {
                        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i].attempts += 1 }
                        persist()
                        scheduleRetry(model: model, attempt: job.attempts)
                        return
                    }
                    jobs.removeAll { $0.id == job.id }
                    persist()
                    fail(job, error, model: model)
                }
            }
        }
    }

    // MARK: 撤销

    private func perform(_ r: UndoRecord, _ model: AppModel) async {
        switch r {
        case let .todo(t): await model.deleteTask(t)
        case let .daily(date, entry): await model.deleteDaily(date: date, entry: entry, noteId: nil)
        }
    }

    /// 撤销刚提交的几条：还没发出去的直接撤销，已经发出去的待办 / 日记删掉；笔记没有删除接口，算作无法撤销
    func retract(_ ids: [UUID]) async -> (undone: Int, unsupported: Int) {
        guard let model else { return (0, ids.count) }
        var undone = 0, unsupported = 0
        for id in ids {
            if inflight == id {
                retracted.insert(id)
                undone += 1
            } else if jobs.contains(where: { $0.id == id }) {
                jobs.removeAll { $0.id == id }
                persist()
                undone += 1
            } else if let rec = completed.removeValue(forKey: id) {
                completedOrder.removeAll { $0 == id }
                await perform(rec, model)
                undone += 1
            } else {
                unsupported += 1
            }
        }
        return (undone, unsupported)
    }

    private func scheduleRetry(model: AppModel, attempt: Int) {
        let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
        let w = DispatchWorkItem { [weak self, weak model] in
            guard let self, let model else { return }
            self.drain(model: model)
        }
        retryWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// 网络类问题值得重试；凭证无效 / 内容有问题重试也没用
    private static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let e = error as? McpError {
            switch e {
            case .sessionExpired, .proto: return true
            case let .http(code, _): return code >= 500 || code == 429 || code == 408
            default: return false
            }
        }
        return false
    }

    private func fail(_ job: Job, _ error: Error, model: AppModel) {
        let brief = (job.todoContent.isEmpty ? job.text : job.todoContent).trimmed.prefix(24)
        let msg = "「\(brief)」没有保存成功：\(error.localizedDescription)"
        model.showNotice(msg)
        Notifier.post(id: "shiyi.outbox", title: "记到拾忆失败", body: msg)
        QuickAddPanelController.shared.showResult(msg, ok: false)
    }
}
