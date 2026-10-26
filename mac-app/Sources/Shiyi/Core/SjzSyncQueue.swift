import Foundation

/// 结审任务修改的「同步队列」（本机先改，后台打包发送）：
///
/// 完成 / 恢复 / 改日期 / 改优先级 / 改标题备注 / 开始日 / 阶段 / 删除，都先改本机界面和缓存并立刻返回，
/// 再记进这个队列；停手 1.5 秒（最多等 5 秒）后，把积攒的改动用结审的 `sync_tasks` **一次请求**发过去：
/// - 同一个任务的多次修改合并成一条（改三次日期只发最后一次；先改后删只发删除）；
/// - 发完只刷新一次概览；队列没发完时，定时刷新不会把界面覆盖回旧数据；
/// - 队列落盘（退出重启后继续发）；网络类失败按 5 / 20 / 60 / 180 秒退避重试，结审拒绝的才放弃并还原。
@MainActor
final class SjzSyncQueue {
    static let shared = SjzSyncQueue()

    struct Entry: Codable, Equatable {
        var project: String
        var taskId: String
        var title: String
        /// 要改的字段（值都是字符串：status / subject / description / dueDate / startDate / priority / phase）
        var fields: [String: String] = [:]
        var delete = false
        var attempts = 0

        var key: String { project + "/" + taskId }

        mutating func apply(_ change: SjzTasks.Change) {
            if case .delete = change { fields = [:]; delete = true; return }
            if delete { return }
            switch change {
            case .delete: break
            case .complete: fields["status"] = "completed"
            case .reopen: fields["status"] = "pending"
            case let .due(d): fields["dueDate"] = d
            case let .priority(n): fields["priority"] = n >= 5 ? "high" : n >= 3 ? "medium" : "low"
            case let .details(t, c):
                if let t { fields["subject"] = t }
                fields["description"] = c
            case let .start(d): fields["startDate"] = d ?? ""
            case let .phase(p): fields["phase"] = p
            }
        }

        /// 把更早的（发送失败退回来的）改动并进来；同一字段以新的为准
        mutating func absorb(_ o: Entry) {
            attempts = max(attempts, o.attempts)
            if delete { return }
            if o.delete { fields = [:]; delete = true; return }
            for (k, v) in o.fields where fields[k] == nil { fields[k] = v }
        }
    }

    static let debounce: TimeInterval = 1.5
    static let maxWait: TimeInterval = 5
    private static let backoff: [TimeInterval] = [5, 20, 60, 180]
    private static let maxAttempts = 6

    private var entries: [Entry] = []
    private var inflight: [Entry] = []
    private var flushing = false
    private var loaded = false
    private var timer: Task<Void, Never>?
    private var firstAt: Date?
    private weak var model: AppModel?

    private var fileURL: URL { LocalStore.dir.appendingPathComponent("sjz-sync-queue.json") }

    var isBusy: Bool { loadIfNeeded(); return flushing || !entries.isEmpty }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: fileURL), let list = try? JSONDecoder().decode([Entry].self, from: data) { entries = list }
    }

    private func persist() {
        let all = inflight + entries
        if all.isEmpty { try? FileManager.default.removeItem(at: fileURL); return }
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// 启动 / 回到前台：把上次没发完的继续发
    func resume(model: AppModel) {
        self.model = model
        loadIfNeeded()
        if !entries.isEmpty, !flushing { schedule(after: 2) }
    }

    // MARK: 入队

    func enqueue(_ task: DidaTask, _ change: SjzTasks.Change, model: AppModel) {
        guard let p = SjzTasks.parse(task.id) else { return }
        self.model = model
        loadIfNeeded()
        if case .complete = change { SjzDaily.add(p.project, "done", 1) }
        let key = p.project + "/" + p.task
        let idx = entries.firstIndex { $0.key == key }
        var e = idx.map { entries[$0] } ?? Entry(project: p.project, taskId: p.task, title: task.cleanTitle)
        e.apply(change)
        if let idx { entries[idx] = e } else { entries.append(e) }
        persist()
        patchLocal(e, task: task, model: model)
        schedule(after: Self.debounce)
    }

    /// 本机缓存里的结审任务先改好（界面马上是新的；之后后台刷新也不会闪回旧值）
    private func patchLocal(_ e: Entry, task: DidaTask, model: AppModel) {
        guard var ov = model.sjzOverview else { return }
        guard let i = ov.next.firstIndex(where: { $0.project == e.project && $0.id == e.taskId }) else {
            // 恢复为未完成：这条不在未完成列表里，先放回去
            guard e.fields["status"] == "pending", !e.delete else { return }
            let title = ov.projects.first { $0.name == e.project }?.title ?? e.project
            let level = task.priority >= 5 ? "high" : task.priority >= 3 ? "medium" : "low"
            ov.next.append(SjzTaskLite(id: e.taskId, project: e.project, projectTitle: title, subject: task.cleanTitle,
                                       dueDate: task.date ?? "", priority: level, detail: task.content,
                                       startDate: task.startDate, phase: task.phase))
            ov.open += 1
            if let pi = ov.projects.firstIndex(where: { $0.name == e.project }) { ov.projects[pi].open += 1 }
            model.sjzOverview = ov
            model.applySjzTasks()
            return
        }
        if e.delete || e.fields["status"] == "completed" {
            ov.next.remove(at: i)
            ov.open = max(0, ov.open - 1)
            if let pi = ov.projects.firstIndex(where: { $0.name == e.project }) { ov.projects[pi].open = max(0, ov.projects[pi].open - 1) }
        } else {
            var t = ov.next[i]
            if let v = e.fields["subject"] { t.subject = v }
            if let v = e.fields["description"] { t.detail = v }
            if let v = e.fields["dueDate"] { t.dueDate = v }
            if let v = e.fields["priority"] { t.priority = v }
            if let v = e.fields["startDate"] { t.startDate = v.isEmpty ? nil : v }
            if let v = e.fields["phase"] { t.phase = v }
            ov.next[i] = t
        }
        model.sjzOverview = ov
        model.applySjzTasks()
    }

    private func schedule(after delay: TimeInterval) {
        timer?.cancel()
        if firstAt == nil { firstAt = Date() }
        let waited = Date().timeIntervalSince(firstAt ?? Date())
        let wait = max(0.2, min(delay, Self.maxWait - waited))
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            _ = await self?.flushNow()
        }
    }

    // MARK: 发送

    /// 立刻把队列里的改动打包发出去；返回队列是否已清空
    @discardableResult
    func flushNow() async -> Bool {
        loadIfNeeded()
        while flushing { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard !entries.isEmpty else { return true }
        guard let model, model.hasSjz else { return false }
        timer?.cancel()
        firstAt = nil
        flushing = true
        inflight = entries
        entries = []
        let batch = inflight

        var retry: [Entry] = []
        var hard: [(Entry, String)] = []
        do {
            let updates: [JSON] = batch.filter { !$0.delete && !$0.fields.isEmpty }.map { e in
                var j: JSON = ["project": e.project, "id": e.taskId]
                for (k, v) in e.fields { j[k] = v }
                return j
            }
            let deletes: [JSON] = batch.filter { $0.delete }.map { ["project": $0.project, "id": $0.taskId] }
            let results = try await model.sjz.syncTasks(updates: updates, deletes: deletes)
            for r in results where !r.ok {
                if let e = batch.first(where: { $0.project == r.project && $0.taskId == r.id }) { hard.append((e, r.error)) }
            }
        } catch {
            for var e in batch {
                e.attempts += 1
                if Self.isTransient(error), e.attempts < Self.maxAttempts { retry.append(e) }
                else { hard.append((e, error.localizedDescription)) }
            }
        }

        for r in retry {
            if let i = entries.firstIndex(where: { $0.key == r.key }) {
                var n = entries[i]
                n.absorb(r)
                entries[i] = n
            } else {
                entries.append(r)
            }
        }
        inflight = []
        persist()
        flushing = false

        if !entries.isEmpty {
            let attempt = max(0, (entries.map(\.attempts).max() ?? 1) - 1)
            schedule(after: Self.backoff[min(attempt, Self.backoff.count - 1)])
        }
        if !hard.isEmpty {
            let names = hard.prefix(2).map { "「\(String($0.0.title.prefix(16)))」" }.joined()
            let more = hard.count > 2 ? "等 \(hard.count) 项" : ""
            model.showNotice("\(names)\(more)没有同步到结审：\(hard[0].1)")
        }
        // 发完（或放弃）才刷新一次；还在退避重试就先别刷，免得盖掉界面
        if entries.isEmpty { await model.refreshSjzOverview(force: true) }
        return entries.isEmpty
    }

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
}
