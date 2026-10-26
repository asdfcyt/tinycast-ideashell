import Foundation

/// 待办修改的「同步队列」（本机先改，后台打包推送）：
///
/// 完成 / 恢复 / 改日期 / 改优先级 / 标签 / 标题备注 / 换清单 / 删除，都先改本机界面并立刻返回，
/// 再记进这个队列；停手 1.5 秒（最多等 5 秒）后，把积攒的改动**一次性**用批量接口发给滴答清单：
/// - 同一个任务的多次修改合并成一条（改三次日期只发最后一次；完成后又恢复，什么都不用发；先改后删，只发删除）；
/// - 字段修改 → `batch_update_tasks`，完成 → `complete_tasks_in_project`（按清单分组），换清单 → `move_task`，
///   删除没有批量接口，并发发；
/// - 发完只刷新一次；队列没发完时，定时刷新不会把界面覆盖回旧数据；
/// - 队列落盘（退出重启后继续发）；网络类失败按 5 / 20 / 60 / 180 / 600 秒退避重试，
///   凭证无效、服务端拒绝这类重试没用的错误才放弃，并从服务器重新读一遍把界面还原。
@MainActor
final class SyncQueue {
    static let shared = SyncQueue()

    // MARK: 数据

    enum Op {
        case complete, reopen, delete
        case priority(Int)
        case schedule(date: String, time: String?)
        case clearDate
        case tags([String])
        case details(title: String, content: String, tags: [String])
        case content(String)
        case move(String)
    }

    struct Parts: OptionSet {
        let rawValue: Int
        static let patch = Parts(rawValue: 1)
        static let move = Parts(rawValue: 2)
        static let complete = Parts(rawValue: 4)
        static let delete = Parts(rawValue: 8)
    }

    /// 一个任务排队中的全部改动
    struct Entry: Codable, Equatable {
        struct Schedule: Codable, Equatable {
            var date: String?   // nil = 清除日期
            var time: String?
        }

        var taskId: String
        /// 服务器上现在所在的清单（第一次改动时的）
        var projectId: String
        var title: String
        var priority: Int?
        var schedule: Schedule?
        var tags: [String]?
        var newTitle: String?
        var content: String?
        var reopen = false
        var moveTo: String?
        var complete = false
        var delete = false
        var attempts = 0

        var hasPatch: Bool { priority != nil || schedule != nil || tags != nil || newTitle != nil || content != nil || reopen }
        var isEmpty: Bool { !hasPatch && moveTo == nil && !complete && !delete }

        mutating func apply(_ op: Op) {
            if case .delete = op {
                priority = nil; schedule = nil; tags = nil; newTitle = nil; content = nil
                reopen = false; moveTo = nil; complete = false; delete = true
                return
            }
            if delete { return }
            switch op {
            case .delete: break
            case .complete: complete = true; reopen = false
            case .reopen:
                // 完成还没发出去就恢复了：互相抵消
                if complete { complete = false } else { reopen = true }
            case let .priority(p): priority = p
            case let .schedule(d, t): schedule = Schedule(date: d, time: t)
            case .clearDate: schedule = Schedule(date: nil, time: nil)
            case let .tags(t): tags = t
            case let .details(title, c, t): newTitle = title; content = c; tags = t
            case let .content(c): content = c
            case let .move(p): moveTo = (p == projectId) ? nil : p
            }
        }

        /// 把更早的（发送失败退回来的）改动并进来；同一字段以新的为准
        mutating func absorb(_ o: Entry) {
            attempts = max(attempts, o.attempts)
            if delete { return }
            if o.delete { apply(.delete); return }
            priority = priority ?? o.priority
            schedule = schedule ?? o.schedule
            tags = tags ?? o.tags
            newTitle = newTitle ?? o.newTitle
            content = content ?? o.content
            moveTo = moveTo ?? o.moveTo
            if !complete && !reopen { complete = o.complete; reopen = o.reopen }
        }

        func only(_ p: Parts) -> Entry {
            var e = self
            if !p.contains(.patch) { e.priority = nil; e.schedule = nil; e.tags = nil; e.newTitle = nil; e.content = nil; e.reopen = false }
            if !p.contains(.move) { e.moveTo = nil }
            if !p.contains(.complete) { e.complete = false }
            if !p.contains(.delete) { e.delete = false }
            return e
        }

        /// 字段修改部分（`batch_update_tasks` 的一项）
        func updateJSON() -> JSON {
            let tz = TimeZone.current.identifier
            var t: JSON = ["id": taskId, "projectId": projectId]
            if let priority { t["priority"] = priority }
            if let s = schedule {
                if let d = s.date {
                    let due = Day.dueString(d, time: s.time)
                    t["startDate"] = due
                    t["dueDate"] = due
                    t["isAllDay"] = (s.time == nil)
                    t["timeZone"] = tz
                    t["reminders"] = [s.time != nil ? "TRIGGER:PT0S" : "TRIGGER:P0DT9H0M0S"]
                } else {
                    // 滴答约定：日期设成 1970-01-01 表示清除
                    t["startDate"] = "1970-01-01T00:00:00.000+0000"
                    t["dueDate"] = "1970-01-01T00:00:00.000+0000"
                }
            }
            if let tags { t["tags"] = tags }
            if let newTitle { t["title"] = newTitle }
            if let content { t["content"] = content }
            if reopen { t["status"] = 0 }
            return t
        }
    }

    // MARK: 状态

    static let debounce: TimeInterval = 1.5
    static let maxWait: TimeInterval = 5
    private static let backoff: [TimeInterval] = [5, 20, 60, 180, 600]
    private static let maxAttempts = 8
    private static let chunkSize = 20

    private var entries: [Entry] = []
    private var inflight: [Entry] = []
    private var flushing = false
    private var retrying = false
    private var loaded = false
    private var timer: Task<Void, Never>?
    private var firstAt: Date?
    private weak var model: AppModel?

    private var fileURL: URL { LocalStore.dir.appendingPathComponent("sync-queue.json") }

    /// 还有改动没发完（排队中或正在发）
    var isBusy: Bool { loadIfNeeded(); return flushing || !entries.isEmpty }
    var pending: Int { loadIfNeeded(); return entries.count + inflight.count }

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

    /// 启动时：把上次没发完的继续发
    func resume(model: AppModel) {
        self.model = model
        loadIfNeeded()
        if !entries.isEmpty { schedule(after: 2) }
    }

    // MARK: 入队

    func enqueue(_ task: DidaTask, _ op: Op, model: AppModel) {
        self.model = model
        loadIfNeeded()
        let idx = entries.firstIndex { $0.taskId == task.id }
        var e = idx.map { entries[$0] } ?? Entry(taskId: task.id, projectId: task.projectId, title: task.cleanTitle)
        e.apply(op)
        if let idx {
            if e.isEmpty { entries.remove(at: idx) } else { entries[idx] = e }
        } else if !e.isEmpty {
            entries.append(e)
        }
        persist()
        if entries.isEmpty {
            timer?.cancel()
            firstAt = nil
        } else {
            schedule(after: Self.debounce)
        }
    }

    /// 滴答任务是不是走队列（结审任务在本机，直接走原来的写法）
    static func handles(_ task: DidaTask) -> Bool { !SjzTasks.owns(task.id) }

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

    /// 读数据前先调用：队列里还有没发出去的改动，先发完（一次性），免得读回旧数据把界面盖掉。
    /// 返回 false = 没发完（断网退避中等），这次读取应该跳过
    func settle() async -> Bool {
        if !isBusy { return true }
        if retrying && !flushing { return false }
        return await flushNow()
    }

    /// 立刻把队列里的改动打包发出去；返回队列是否已清空
    @discardableResult
    func flushNow() async -> Bool {
        loadIfNeeded()
        while flushing { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard !entries.isEmpty else { return true }
        guard let model else { return false }
        timer?.cancel()
        firstAt = nil
        retrying = false
        flushing = true
        inflight = entries
        entries = []
        let batch = inflight
        let out = await send(batch, model: model)

        for var r in out.retry {
            r.attempts += 1
            if let i = entries.firstIndex(where: { $0.taskId == r.taskId }) {
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
            retrying = true
            let attempt = max(0, (entries.map(\.attempts).max() ?? 1) - 1)
            schedule(after: Self.backoff[min(attempt, Self.backoff.count - 1)])
        }
        if !out.hard.isEmpty {
            let names = out.hard.prefix(2).map { "「\(String($0.0.title.prefix(16)))」" }.joined()
            let more = out.hard.count > 2 ? "等 \(out.hard.count) 项" : ""
            model.showNotice("\(names)\(more)没有同步成功，已还原：\(out.hard[0].1)")
        }
        // 全部发完（或放弃）才刷新一次；还在退避重试就先别刷，免得盖掉界面
        if entries.isEmpty { await model.syncSettled() }
        return entries.isEmpty
    }

    @MainActor private final class Outcome {
        var retry: [Entry] = []
        var hard: [(Entry, String)] = []

        /// 失败的部分：网络类退回队列重试，其余放弃
        func fail(_ part: Entry, _ error: Error) {
            if SyncQueue.isTransient(error), part.attempts + 1 < SyncQueue.maxAttempts { retry.append(part) }
            else { hard.append((part, error.localizedDescription)) }
        }
    }

    private func send(_ batch: [Entry], model: AppModel) async -> Outcome {
        let out = Outcome()
        guard model.hasDida else {
            out.hard = batch.map { ($0, "还没有填写滴答清单口令") }
            return out
        }
        let dida = model.dida

        // 1. 改字段（一次请求最多 20 条）
        let upd = batch.filter { !$0.delete && $0.hasPatch }
        for chunk in Self.chunks(upd) {
            do {
                let failed = try await dida.batchUpdate(chunk.map { $0.updateJSON() })
                for e in chunk { if let why = failed[e.taskId] { out.hard.append((e.only(.patch), "服务器拒绝了修改（\(why)）")) } }
            } catch {
                for e in chunk { out.fail(e.only(.patch), error) }
            }
        }

        // 2. 换清单；换失败的，后面的完成 / 删除也先不发
        var blocked = Set<String>()
        let mv = batch.filter { !$0.delete && $0.moveTo != nil }
        if !mv.isEmpty {
            do {
                try await dida.moveMany(mv.map { ($0.projectId, $0.moveTo!, $0.taskId) })
            } catch {
                for e in mv {
                    blocked.insert(e.taskId)
                    out.fail(e.only([.move, .complete]), error)
                }
            }
        }

        // 3. 完成：按（换完以后的）清单分组，一次最多 20 条
        let comp = batch.filter { $0.complete && !$0.delete && !blocked.contains($0.taskId) }
        let byProject = Dictionary(grouping: comp) { $0.moveTo ?? $0.projectId }
        for (project, items) in byProject {
            for chunk in Self.chunks(items) {
                do {
                    let failed = try await dida.completeMany(projectId: project, taskIds: chunk.map(\.taskId))
                    for e in chunk where failed.contains(e.taskId) { out.hard.append((e.only(.complete), "服务器拒绝了完成")) }
                } catch {
                    for e in chunk { out.fail(e.only(.complete), error) }
                }
            }
        }

        // 4. 删除：没有批量接口，并发发
        let del = batch.filter { $0.delete }
        let results: [Error?] = await runConcurrently(del.count) { i in
            do { try await dida.deleteRaw(projectId: del[i].projectId, taskId: del[i].taskId); return nil }
            catch { return error }
        }
        for (i, r) in results.enumerated() {
            guard let err = r else { continue }
            // 已经被别处删掉了就当成功
            let msg = err.localizedDescription.lowercased()
            if msg.contains("not found") || msg.contains("不存在") { continue }
            out.fail(del[i].only(.delete), err)
        }
        return out
    }

    private static func chunks(_ list: [Entry]) -> [[Entry]] {
        stride(from: 0, to: list.count, by: chunkSize).map { Array(list[$0 ..< min($0 + chunkSize, list.count)]) }
    }

    /// 网络类问题值得重试；凭证无效 / 服务端拒绝重试也没用
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

extension AppModel {
    /// 同步队列发完一批以后：只重新读一次最新数据对齐（以服务器为准）
    func syncSettled() async {
        invalidateHistory()
        await loadOverview(silent: true)
        if section == .calendar { await loadCalendar() }
        if section == .review { await loadRiver(silent: true) }
    }
}
