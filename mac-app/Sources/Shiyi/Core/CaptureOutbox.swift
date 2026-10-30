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
        /// 混排的图片（落在本机 outbox-images/，重试和重启后也不丢）；旧版本的任务没有这两项
        var imageFiles: [String]?
        var imageNames: [String]?
        /// 证据：保存前先新建（或找到同名的）这份取证单；旧版本的任务没有这一项
        var newNote: String?
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
    func submit(_ a: CaptureAnalysis, kind: CaptureKind, priority: Int, defaultDate: String?, defaultTime: String?, images: [ComposerImage] = [], newNote: String? = nil, model: AppModel) throws -> String {
        loadIfNeeded()
        self.model = model
        let message: String
        if !images.isEmpty, kind == .todo { throw McpError.tool("待办不能带图片，请先切换成笔记 / Daily Note / 结审类型") }
        if !images.isEmpty, kind == .daily || kind == .note, images.count > DropImages.maxImages {
            throw McpError.tool("一次最多带 \(DropImages.maxImages) 张图片")
        }
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
            guard !ComposerImage.stripMarker(a.text).trimmed.isEmpty || !images.isEmpty else { throw McpError.tool("内容为空") }
            message = "已记入今天的 Daily Note"
        case .note:
            guard model.hasIdeashell else { throw McpError.noCredential }
            guard !ComposerImage.stripMarker(a.body).trimmed.isEmpty || !images.isEmpty else { throw McpError.tool("内容为空") }
            message = "已保存笔记"
        case .clue, .idea, .evidence, .regulation:
            guard model.hasSjz else { throw McpError.tool("先到「设置」开启并连接结审") }
            guard !a.text.trimmed.isEmpty || !images.isEmpty else { throw McpError.tool("内容为空") }
            let pin = model.sjzPin
            switch kind {
            case .clue: message = pin.clueId.isEmpty ? "已记入线索" : "已追加到线索 \(pin.clueId)"
            case .idea: message = "已记入工作日志"
            case .evidence:
                if let t = newNote?.trimmed, !t.isEmpty { message = "已新建取证单「\(t)」并保存为证据" }
                else if !pin.evidencePath.isEmpty { message = "已追加到证据「\(pin.evidenceLabel)」" }
                else { message = pin.noteLabel.isEmpty ? "已保存为证据" : "已追加到取证单 \(pin.noteNo.isEmpty ? pin.noteTitle : pin.noteNo)" }
            default: message = pin.regulation.isEmpty ? "已保存为法规" : "已追加到《\(pin.regulation)》"
            }
        }
        var job = Job(
            kind: kind.rawValue, text: a.text, body: a.body, tags: a.tags, folderName: a.folderName,
            todoContent: a.todo.content, todoDate: a.todo.date, todoTime: a.todo.time,
            priority: priority, defaultDate: defaultDate, defaultTime: defaultTime
        )
        if kind == .evidence, let t = newNote?.trimmed, !t.isEmpty { job.newNote = t }
        if !images.isEmpty {
            let dir = Self.imageDir
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var files: [String] = [], names: [String] = []
            for (i, im) in images.enumerated() {
                let f = "\(job.id.uuidString)-\(i).bin"
                guard (try? im.data.write(to: dir.appendingPathComponent(f), options: .atomic)) != nil else { continue }
                files.append(f); names.append(im.name)
            }
            job.imageFiles = files
            job.imageNames = names
        }
        jobs.append(job)
        submittedIds.append(job.id)
        persist()
        drain(model: model)
        return message
    }

    // MARK: 混排图片

    private static var imageDir: URL { LocalStore.dir.appendingPathComponent("outbox-images", isDirectory: true) }

    private func loadImages(_ job: Job) -> [ComposerImage] {
        let names = job.imageNames ?? []
        return (job.imageFiles ?? []).enumerated().compactMap { i, f in
            guard let d = try? Data(contentsOf: Self.imageDir.appendingPathComponent(f)) else { return nil }
            return ComposerImage(name: i < names.count ? names[i] : "图片-\(i + 1)", data: d)
        }
    }

    private func dropImages(_ job: Job) {
        for f in job.imageFiles ?? [] { try? FileManager.default.removeItem(at: Self.imageDir.appendingPathComponent(f)) }
    }

    // MARK: 后台发送

    private func drain(model: AppModel) {
        guard !draining else { return }
        draining = true
        retryWork?.cancel()
        Task { @MainActor in
            defer { draining = false }
            // 稍等一下，让紧接着提交的几条一起发（连着记几个待办 = 一次批量请求）
            if !jobs.isEmpty { try? await Task.sleep(nanoseconds: 1_200_000_000) }
            while let job = jobs.first {
                guard let kind = CaptureKind(rawValue: job.kind) else { jobs.removeFirst(); persist(); continue }
                // 连着的几条待办 → 滴答的批量新建，一次请求发完
                if kind == .todo, model.hasDida, let inbox = model.inboxId {
                    let group = Array(jobs.prefix(while: { $0.kind == CaptureKind.todo.rawValue }).prefix(20))
                    if group.count >= 2 {
                        if await sendTodoBatch(group, inbox: inbox, model: model) { continue } else { return }
                    }
                }
                let analysis = CaptureAnalysis(
                    text: job.text, body: job.body, tags: job.tags, folderName: job.folderName,
                    todo: ParsedTodo(content: job.todoContent, date: job.todoDate, time: job.todoTime),
                    forced: kind, recommended: kind
                )
                do {
                    model.lastCreated = nil
                    inflight = job.id
                    _ = try await model.submitCapture(analysis, kind: kind, priority: job.priority, defaultDate: job.defaultDate, defaultTime: job.defaultTime, images: loadImages(job), newNote: job.newNote)
                    inflight = nil
                    jobs.removeAll { $0.id == job.id }
                    dropImages(job)
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
                    dropImages(job)
                    persist()
                    fail(job, error, model: model)
                }
            }
        }
    }

    /// 一批待办一次发完。返回 false = 遇到网络问题，已安排重试，本轮先停
    private func sendTodoBatch(_ group: [Job], inbox: String, model: AppModel) async -> Bool {
        struct Spec { let title: String; let date: String?; let time: String? }
        let specs = group.map { j -> Spec in
            let date = j.todoDate ?? j.defaultDate
            let time = date == nil ? nil : (j.todoTime ?? (j.todoDate == nil ? j.defaultTime : nil))
            return Spec(title: j.todoContent.trimmed, date: date, time: time)
        }
        let json = zip(group, specs).map { DidaApi.newTaskJSON(projectId: inbox, title: $1.title, date: $1.date, time: $1.time, priority: $0.priority) }
        do {
            inflight = group.first?.id
            let ids = try await model.dida.batchAdd(json)
            inflight = nil
            for (i, j) in group.enumerated() {
                // 发的过程中被撤销了（已经不在队列里）：发完立刻删掉
                let wasRetracted = !jobs.contains { $0.id == j.id } || retracted.remove(j.id) != nil
                jobs.removeAll { $0.id == j.id }
                if let id = ids[i] {
                    let t = DidaTask(id: id, projectId: inbox, title: specs[i].title, date: specs[i].date, time: specs[i].time, priority: j.priority)
                    if wasRetracted {
                        await model.deleteTask(t)
                    } else {
                        completed[j.id] = .todo(t)
                        completedOrder.append(j.id)
                        if completedOrder.count > 60 { completed.removeValue(forKey: completedOrder.removeFirst()) }
                    }
                } else {
                    fail(j, McpError.tool("滴答没有接受这条待办"), model: model)
                }
            }
            persist()
            model.invalidateHistory()
            Task { await model.syncSettled() }
            return true
        } catch {
            inflight = nil
            for j in group { retracted.remove(j.id) }
            if Self.isTransient(error), (group.map(\.attempts).max() ?? 0) + 1 < Self.maxAttempts {
                let attempt = group.map(\.attempts).max() ?? 0
                for j in group { if let i = jobs.firstIndex(where: { $0.id == j.id }) { jobs[i].attempts += 1 } }
                persist()
                scheduleRetry(model: model, attempt: attempt)
                return false
            }
            for j in group { jobs.removeAll { $0.id == j.id }; fail(j, error, model: model) }
            persist()
            return true
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
            } else if let queued = jobs.first(where: { $0.id == id }) {
                dropImages(queued)
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
        let brief = ComposerImage.stripMarker(job.todoContent.isEmpty ? job.text : job.todoContent).trimmed.prefix(24)
        let msg = "「\(brief)」没有保存成功：\(error.localizedDescription)"
        model.showNotice(msg)
        Notifier.post(id: "shiyi.outbox", title: "记到拾忆失败", body: msg)
        QuickAddPanelController.shared.showResult(msg, ok: false)
    }
}
