import AppKit
import Foundation

/// 灵动岛投放到结审的去向
enum SjzTarget {
    case evidence, regulation, clue, data

    var label: String {
        switch self {
        case .evidence: return "证据"
        case .regulation: return "法规"
        case .clue: return "线索"
        case .data: return "数据"
        }
    }
}

/// 需要法规名却没有：调用方把内容放进暂存架，并提示去钉住 / 新建法规
enum SjzError: LocalizedError {
    case needRegulation
    var errorDescription: String? { "还没钉住法规" }
}

extension AppModel {
    private static var sjzEventTimer: Timer?
    private static var lastOverview: Date = .distantPast

    // MARK: 钉住状态

    /// 读取结审里钉住的项目 / 取证单 / 法规（岛展开、投放前都会刷新）
    func refreshSjzTarget() async {
        guard hasSjz else { sjzTargetTitle = ""; sjzPin = SjzPin(); return }
        if let pin = try? await sjz.capturePin() {
            if pin != sjzPin { sjzPin = pin }
            sjzTargetTitle = pin.projectTitle.isEmpty ? pin.project : pin.projectTitle
        } else {
            sjzTargetTitle = ""
        }
    }

    func refreshSjzProjects() async {
        guard hasSjz, let r = try? await sjz.listProjects() else { return }
        sjzProjects = r.projects
    }

    /// 动作失败时在岛 / 窗口上提示，然后重读钉住状态
    private func sjzAct(_ work: () async throws -> String?) async {
        do {
            if let msg = try await work() { showNotice(msg) }
        } catch {
            showNotice(error.localizedDescription)
        }
        await refreshSjzTarget()
    }

    func sjzSetProject(_ name: String) async {
        let changed = name != sjzPin.project
        await sjzAct { try await sjz.setPin(project: name, regulation: changed ? NSNull() : nil); return nil }
        await refreshSjzOverview(force: true)
    }

    func sjzPin(note hit: SjzNoteHit) async {
        await sjzAct {
            try await sjz.setPin(note: ["path": hit.path, "no": hit.no, "title": hit.title] as JSON)
            return nil
        }
    }

    func sjzPin(regulation name: String) async {
        await sjzAct { try await sjz.setPin(regulation: ["name": name] as JSON); return nil }
    }

    func sjzUnpinNote() async { await sjzAct { try await sjz.setPin(note: NSNull()); return nil } }
    func sjzUnpinRegulation() async { await sjzAct { try await sjz.setPin(regulation: NSNull()); return nil } }

    func sjzCreateNote(_ title: String) async {
        await sjzAct { try await sjz.createNote(title: title) }
    }

    // MARK: 结审任务（合并进待办，只存本机）

    /// 拉取结审的未完成任务，合并进拾忆的待办 / 今天；不写入滴答清单 / 闪念贝壳
    func refreshSjzOverview(force: Bool = false) async {
        guard hasSjz else {
            if sjzOverview != nil { sjzOverview = nil; applySjzTasks() }
            return
        }
        if !force, Date().timeIntervalSince(Self.lastOverview) < 20 { return }
        Self.lastOverview = Date()
        guard let ov = try? await sjz.overview() else { return }
        let changed = ov != sjzOverview
        sjzOverview = ov
        AppModel.writeCache("sjz-overview.json", ov)
        if changed { applySjzTasks() }
    }

    /// 把当前的结审任务重新合并进待办
    func applySjzTasks() {
        if let ov = overview {
            overview = mergeSjz(ov)
        } else if hasSjz, sjzOverview != nil {
            overview = mergeSjz(DidaOverview())
        }
    }

    func mergeSjz(_ ov: DidaOverview) -> DidaOverview {
        var o = ov
        o.overdue.removeAll { SjzTasks.owns($0.id) }
        o.upcoming.removeAll { SjzTasks.owns($0.id) }
        o.undated.removeAll { SjzTasks.owns($0.id) }
        o.projects = o.projects.filter { !$0.key.hasPrefix(SjzTasks.prefix) }
        guard hasSjz, let tasks = sjzOverview?.next, !tasks.isEmpty else { return o }
        let today = Day.today()
        for t in tasks {
            let d = SjzTasks.make(t)
            o.projects[d.projectId] = "结审 · " + t.projectTitle
            if let date = d.date { if date < today { o.overdue.append(d) } else { o.upcoming.append(d) } } else { o.undated.append(d) }
        }
        // 稳定排序：只按日期归位，同一天里保持原来的顺序
        o.overdue.sort { ($0.date ?? "") < ($1.date ?? "") }
        o.upcoming.sort { ($0.date ?? "") < ($1.date ?? "") }
        return o
    }

    // MARK: 提醒事件（轮询结审，弹到灵动岛）

    func startSjzEvents() {
        guard Self.sjzEventTimer == nil else { return }
        let t = Timer(timeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollSjzEvents() }
        }
        RunLoop.main.add(t, forMode: .common)
        Self.sjzEventTimer = t
        Task { try? await Task.sleep(nanoseconds: 4_000_000_000); await pollSjzEvents() }
    }

    /// 每晚小结：21 点后，把当天从拾忆写进结审的内容、专注和完成任务汇总写进项目工作日志（每天每个项目一次）
    func sjzDailySummaryIfDue() async {
        let ud = UserDefaults.standard
        guard ud.object(forKey: "sjz.summary") as? Bool ?? true,
              Calendar.current.component(.hour, from: Date()) >= 21,
              let projects = sjzOverview?.projects else { return }
        let day = Day.today()
        guard ud.string(forKey: "sjz.summary.day") != day else { return }
        let start = Calendar.current.startOfDay(for: Date())
        var failed = false
        for p in projects {
            let caps = (try? await sjz.captures(project: p.name, since: start)) ?? []
            let focus = SjzDaily.get(p.name, "focus"), done = SjzDaily.get(p.name, "done")
            guard !caps.isEmpty || focus > 0 || done > 0 else { continue }
            var parts: [String] = []
            let kinds = [("evidence", "证据"), ("regulation", "法规"), ("clue", "线索"), ("data", "数据")]
            let wrote = kinds.compactMap { k, label -> String? in
                let n = caps.filter { $0.kind == k }.count
                return n > 0 ? "\(label) \(n)" : nil
            }
            if !wrote.isEmpty { parts.append("写入 " + wrote.joined(separator: " · ")) }
            if focus > 0 { parts.append("专注 \(focus) 分钟") }
            if done > 0 { parts.append("完成任务 \(done) 项") }
            do { try await sjz.addWorkLog(project: p.name, text: "[工作小结] 拾忆今日：" + parts.joined(separator: "；")) } catch { failed = true }
        }
        if !failed { ud.set(day, forKey: "sjz.summary.day") }
    }

    func pollSjzEvents() async {
        guard hasSjz else { return }
        await refreshSjzOverview()
        await sjzDailySummaryIfDue()
        let key = "sjz.eventsSince"
        guard let since = UserDefaults.standard.string(forKey: key) else {
            // 第一次连接：只关心从现在起发生的事
            UserDefaults.standard.set(ISO8601DateFormatter().string(from: Date()), forKey: key)
            return
        }
        guard let r = try? await sjz.events(since: since) else { return }
        UserDefaults.standard.set(r.now, forKey: key)
        guard !r.events.isEmpty, NotifyPrefs.on("notify.sjz") else { return }
        for e in r.events {
            Notifier.post(id: "sjz-" + e.id, title: e.title, body: "\(e.projectTitle) · \(e.detail)")
        }
        if let last = r.events.last { IslandController.shared.presentAudit(last) }
        await refreshSjzOverview(force: true)
    }

    /// 绑定结审任务的专注：时长写回结审任务
    func sjzRecordFocus(_ p: PendingFocus) async throws {
        guard hasSjz, let t = SjzTasks.parse(p.taskId ?? "") else { throw McpError.noCredential }
        let mins = max(Int((Double(p.endMs - p.startMs) / 60000).rounded()), 1)
        SjzDaily.add(t.project, "focus", mins)
        try await sjz.recordTaskActivity(project: t.project, id: t.task, minutes: mins,
                                         at: Date(timeIntervalSince1970: Double(p.startMs) / 1000))
    }

    func openSjzApp() {
        let fm = FileManager.default
        for path in [NSHomeDirectory() + "/Applications/结审.app", "/Applications/结审.app"] where fm.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
            return
        }
        if let u = URL(string: sjzEndpoint.replacingOccurrences(of: "/mcp", with: "")) { NSWorkspace.shared.open(u) }
    }

    func saveSjz() async {
        credentials.setSjzKey(sjzKeyInput.trimmed)
        let e = sjzEndpoint.trimmed.isEmpty ? SjzApi.defaultEndpoint : sjzEndpoint.trimmed
        sjzEndpoint = e
        UserDefaults.standard.set(e, forKey: SjzApi.endpointKey)
        let cred = credentials
        sjz = SjzApi.make(endpoint: e) { cred.sjzKey }
        CaptureParser.sjzOn = hasSjz
        objectWillChange.send()
        await refreshSjzTarget()
        await refreshSjzProjects()
        await refreshSjzOverview(force: true)
    }

    /// 灵动岛投放 / 截图提示 → 结审（证据 / 法规 / 线索）
    func submitSjz(_ input: RawDrop, to target: SjzTarget) async throws -> String {
        guard hasSjz else { throw McpError.noCredential }
        let raw = await input.receivingPromises(into: FileManager.default.temporaryDirectory.appendingPathComponent("shiyi-drop", isDirectory: true))
        if target == .data {
            await refreshSjzTarget()
            return try await submitSjzData(raw)
        }
        let prepared = await Task.detached(priority: .userInitiated) { DropImages.prepare(raw) }.value

        var texts: [String] = []
        if !raw.text.trimmed.isEmpty { texts.append(raw.text.trimmed) }
        texts.append(contentsOf: prepared.texts.map(\.trimmed).filter { !$0.isEmpty })
        let body = texts.joined(separator: "\n\n")
        // 以结审里钉住的为准：先读一次最新的（岛外可能刚改过）
        await refreshSjzTarget()
        let project: String? = nil
        let place = sjzTargetTitle.isEmpty ? "" : "（\(sjzTargetTitle)）"

        if target == .clue {
            guard !body.isEmpty else { throw McpError.tool("线索只能记录文字，图片请存为证据") }
            _ = try await sjz.addClue(project: project, text: body)
            return "已记入线索" + place
        }
        guard !body.isEmpty || !prepared.images.isEmpty else {
            throw McpError.tool(prepared.skipped > 0 ? "暂不支持这类文件（支持图片和文本文件）" : "没有读到可以保存的内容")
        }

        var items: [JSON] = prepared.images.map { ["type": "image", "name": $0.name, "data": $0.data.base64EncodedString()] }
        // 单独一个网址：存成「网址」并抓取网页快照；其余文字原样保存
        let link = Self.singleLink(body)
        if !body.isEmpty { items.append(["type": "text", "text": body, "url": link ?? ""]) }

        let source: String
        if let link, let host = URL(string: link)?.host { source = host.replacingOccurrences(of: "www.", with: "") }
        else if let f = raw.fileURLs.first { source = f.lastPathComponent }
        else if !prepared.images.isEmpty && body.isEmpty { source = "屏幕截图" }
        else { source = "拾忆" }

        let first = body.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmed ?? ""
        var title = link == nil ? String(first.prefix(30)) : ""
        if target == .regulation {
            // 法规名：钉住的法规优先；没钉住就依次取《…》、首行文字、文件名、网址域名，最后用时间兜底，不再要求先钉住
            if sjzPin.regulation.isEmpty {
                title = Self.guessRegulationName(body: body, link: link, file: raw.fileURLs.first?.deletingPathExtension().lastPathComponent)
            } else {
                title = ""
            }
        }
        do {
            let msg = try await sjz.save(regulation: target == .regulation, project: project, items: items, title: title,
                                         source: source, url: link, snapshot: link != nil)
            return msg + place
        } catch let McpError.tool(m) where m.contains("法规名称") {
            throw SjzError.needRegulation
        }
    }

    /// 数据文件（Excel / CSV / PDF 等）→ 结审原始材料
    private func submitSjzData(_ raw: RawDrop) async throws -> String {
        var files: [(name: String, data: Data)] = []
        for u in raw.fileURLs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
            if size > 25 * 1024 * 1024 { throw McpError.tool("\(u.lastPathComponent) 超过 25MB，请直接在结审里导入") }
            guard let d = try? Data(contentsOf: u), !d.isEmpty else { continue }
            files.append((u.lastPathComponent, d))
        }
        guard !files.isEmpty else { throw McpError.tool("数据区只接收文件（Excel / CSV / PDF 等）") }
        let msg = try await sjz.saveData(project: nil, files: files)
        return msg + (sjzTargetTitle.isEmpty ? "" : "（\(sjzTargetTitle)）")
    }

    /// 没有指定法规名时，从内容里猜一个
    static func guessRegulationName(body: String, link: String?, file: String?) -> String {
        if let m = RX("《([^》\n]{2,60})》", multiline: false).first(in: String(body.prefix(300)))?.group(1), !m.trimmed.isEmpty { return m.trimmed }
        if link == nil {
            let first = body.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmed ?? ""
            let cleaned = first.trimmingCharacters(in: CharacterSet(charactersIn: "#*> -\t")).trimmed
            if cleaned.count >= 2 { return String(cleaned.prefix(40)) }
        }
        if let file, file.trimmed.count >= 2 { return String(file.trimmed.prefix(40)) }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        if let link, let host = URL(string: link)?.host { return "\(host.replacingOccurrences(of: "www.", with: "")) 法规 \(f.string(from: Date()))" }
        return "未命名法规 \(f.string(from: Date()))"
    }

    /// 内容只有一个 http(s) 网址时返回它
    static func singleLink(_ s: String) -> String? {
        let t = s.trimmed
        guard t.hasPrefix("http"), !t.contains(" "), !t.contains("\n"), URL(string: t)?.host != nil else { return nil }
        return t
    }
}

/// 当天从拾忆做的事的本机计数（专注分钟、完成任务数），供每晚小结使用
enum SjzDaily {
    private static func key(_ project: String, _ kind: String) -> String { "sjz.day.\(Day.today()).\(project).\(kind)" }
    static func add(_ project: String, _ kind: String, _ n: Int) {
        UserDefaults.standard.set(get(project, kind) + n, forKey: key(project, kind))
    }
    static func get(_ project: String, _ kind: String) -> Int { UserDefaults.standard.integer(forKey: key(project, kind)) }
}

/// 结审任务在拾忆待办里的身份：id 形如 `sjz:<项目>:<任务>`，改动直接写回结审，不经过滴答
enum SjzTasks {
    static let prefix = "sjz:"

    enum Change {
        case complete, reopen
        case due(String)
        case priority(Int)
        case details(title: String?, content: String)
    }

    static func owns(_ id: String) -> Bool { id.hasPrefix(prefix) }

    static func readonly(_ what: String) -> Error { McpError.tool("结审任务请到结审里\(what)") }

    static func make(_ t: SjzTaskLite) -> DidaTask {
        let level: Int
        switch t.priority {
        case "urgent", "high": level = 5
        case "low": level = 1
        default: level = 3
        }
        return DidaTask(id: "\(prefix)\(t.project):\(t.id)", projectId: "\(prefix)\(t.project)", title: t.subject, content: t.detail,
                        date: t.dueDate.isEmpty ? nil : t.dueDate, priority: level, tags: ["结审"])
    }

    static func parse(_ id: String) -> (project: String, task: String)? {
        let rest = id.dropFirst(prefix.count)
        guard let i = rest.firstIndex(of: ":") else { return nil }
        return (String(rest[..<i]), String(rest[rest.index(after: i)...]))
    }

    @MainActor
    static func apply(_ task: DidaTask, _ change: Change) async throws {
        guard let model = AppModel.current, let p = parse(task.id) else { throw McpError.tool("找不到这条结审任务") }
        switch change {
        case .complete:
            try await model.sjz.completeTask(project: p.project, id: p.task)
            SjzDaily.add(p.project, "done", 1)
        case .reopen:
            try await model.sjz.updateTask(project: p.project, id: p.task, fields: ["status": "pending"])
        case let .due(d):
            try await model.sjz.updateTask(project: p.project, id: p.task, fields: ["dueDate": d])
        case let .priority(n):
            try await model.sjz.updateTask(project: p.project, id: p.task, fields: ["priority": n >= 5 ? "high" : n >= 3 ? "medium" : "low"])
        case let .details(title, content):
            var f: JSON = ["description": content]
            if let title { f["subject"] = title }
            try await model.sjz.updateTask(project: p.project, id: p.task, fields: f)
        }
        await model.refreshSjzOverview(force: true)
    }
}
