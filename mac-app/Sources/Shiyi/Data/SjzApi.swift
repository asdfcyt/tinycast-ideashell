import Foundation

/// 结审（审计工作台）的 MCP 服务封装。协议与闪念贝壳 / 滴答清单一致（Streamable HTTP + Bearer），
/// 地址默认本机 `http://127.0.0.1:3000/mcp`，API Key 在结审「设置 → 外部应用」里生成。
struct SjzApi {
    static let endpointKey = "sjz.endpoint"
    static let defaultEndpoint = "http://127.0.0.1:3000/mcp"

    let mcp: McpClient

    /// 地址不合法时退回默认值（McpClient 要求有效 URL）
    static func make(endpoint: String, token: @escaping @Sendable () -> String?) -> SjzApi {
        let e = URL(string: endpoint.trimmed).flatMap { $0.scheme != nil && $0.host != nil ? endpoint.trimmed : nil } ?? defaultEndpoint
        return SjzApi(mcp: McpClient(endpoint: e, tokenProvider: token))
    }

    struct Project: Hashable { let name: String; let title: String }

    /// 调用工具，把返回的 JSON 文本解析成字典
    func call(_ tool: String, _ args: JSON = [:]) async throws -> JSON {
        let text = try await mcp.callText(tool, args)
        guard let d = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? JSON else {
            return ["message": text]
        }
        return obj
    }

    func listProjects() async throws -> (pinned: String, projects: [Project]) {
        let r = try await call("list_projects")
        let list = ((r["projects"] as? [JSON]) ?? []).compactMap { p -> Project? in
            guard let n = p["name"] as? String else { return nil }
            return Project(name: n, title: (p["title"] as? String) ?? n)
        }
        return ((r["pinnedProject"] as? String) ?? "", list)
    }

    func capturePin() async throws -> SjzPin {
        let r = try await call("get_capture_pin")
        var pin = SjzPin()
        pin.project = (r["project"] as? String) ?? ""
        pin.projectTitle = (r["projectTitle"] as? String) ?? ""
        pin.regulation = ((r["regulation"] as? JSON)?["name"] as? String) ?? ""
        if let n = r["note"] as? JSON {
            pin.notePath = (n["path"] as? String) ?? ""
            pin.noteNo = (n["no"] as? String) ?? ""
            pin.noteTitle = (n["title"] as? String) ?? ""
        }
        if let c = r["clue"] as? JSON {
            pin.clueId = (c["id"] as? String) ?? ""
            pin.clueTitle = (c["title"] as? String) ?? ""
        }
        pin.snapshot = (r["snapshot"] as? Bool) ?? true
        return pin
    }

    /// 钉住项目 / 取证单 / 法规 / 线索；note、regulation、clue 传 NSNull 表示取消钉住
    func setPin(project: String? = nil, note: Any? = nil, regulation: Any? = nil, clue: Any? = nil) async throws {
        var a: JSON = [:]
        if let project { a["project"] = project }
        if let note { a["note"] = note }
        if let regulation { a["regulation"] = regulation }
        if let clue { a["clue"] = clue }
        _ = try await call("set_capture_pin", a)
    }

    func searchNotes(_ query: String) async throws -> [SjzNoteHit] {
        let r = try await call("list_evidence_notes", ["query": query])
        return ((r["notes"] as? [JSON]) ?? []).compactMap { n in
            guard let path = n["path"] as? String else { return nil }
            return SjzNoteHit(path: path, no: (n["no"] as? String) ?? "", title: (n["title"] as? String) ?? "", status: (n["status"] as? String) ?? "")
        }
    }

    func searchRegulations(_ query: String) async throws -> [SjzRegHit] {
        let r = try await call("list_regulations", ["query": query])
        return ((r["regulations"] as? [JSON]) ?? []).compactMap { n in
            guard let name = n["name"] as? String else { return nil }
            return SjzRegHit(name: name, clause: (n["clause"] as? String) ?? "", capturedAt: (n["capturedAt"] as? String) ?? "")
        }
    }

    /// 新建取证单并钉住
    func createNote(title: String) async throws -> String {
        let r = try await call("create_evidence_note", ["title": title])
        return (r["message"] as? String) ?? "已新建取证单"
    }

    func overview() async throws -> SjzOverview {
        let r = try await call("get_overview", ["limit": 200])
        let t = (r["total"] as? JSON) ?? [:]
        var ov = SjzOverview()
        ov.open = (t["open"] as? Int) ?? 0
        ov.overdue = (t["overdue"] as? Int) ?? 0
        ov.dueToday = (t["dueToday"] as? Int) ?? 0
        ov.pendingReviews = (t["pendingReviews"] as? Int) ?? 0
        var tasks: [SjzTaskLite] = []
        for p in (r["projects"] as? [JSON]) ?? [] {
            let pn = (p["name"] as? String) ?? ""
            let pt = (p["title"] as? String) ?? pn
            for x in (p["next"] as? [JSON]) ?? [] {
                guard let id = x["id"] as? String else { continue }
                tasks.append(SjzTaskLite(id: id, project: pn, projectTitle: pt, subject: (x["subject"] as? String) ?? "",
                                         dueDate: (x["dueDate"] as? String) ?? "", priority: (x["priority"] as? String) ?? "medium",
                                         detail: (x["description"] as? String) ?? ""))
            }
        }
        ov.projects = ((r["projects"] as? [JSON]) ?? []).map { p in
            let t = (p["tasks"] as? JSON) ?? [:]
            let name = (p["name"] as? String) ?? ""
            return SjzProjectStat(name: name, title: (p["title"] as? String) ?? name,
                                  open: (t["open"] as? Int) ?? 0, overdue: (t["overdue"] as? Int) ?? 0,
                                  dueToday: (t["dueToday"] as? Int) ?? 0, pendingReviews: (p["pendingReviews"] as? Int) ?? 0)
        }
        ov.next = tasks.sorted { ($0.dueDate.isEmpty ? "9999" : $0.dueDate) < ($1.dueDate.isEmpty ? "9999" : $1.dueDate) }
        return ov
    }

    /// 改结审任务（status / dueDate / priority / subject / description）
    func updateTask(project: String, id: String, fields: JSON) async throws {
        var a = fields
        a["project"] = project
        a["id"] = id
        _ = try await call("update_task", a)
    }

    /// 把专注时长 / 专注中的记录写回结审任务（只存结审，不走滴答和闪念贝壳）
    func recordTaskActivity(project: String, id: String, minutes: Int = 0, text: String = "", at: Date? = nil) async throws {
        var a: JSON = ["project": project, "id": id]
        if minutes > 0 { a["minutes"] = minutes }
        if !text.isEmpty { a["text"] = text }
        if let at { a["at"] = ISO8601DateFormatter().string(from: at) }
        _ = try await call("record_task_activity", a)
    }

    /// 项目的审前调研摘要；没有调研时返回 nil
    func researchDigest(project: String) async throws -> SjzDigest? {
        let r = try await call("get_research_digest", ["project": project])
        guard (r["found"] as? Bool) == true else { return nil }
        var d = SjzDigest()
        d.direction = (r["direction"] as? String) ?? ""
        d.status = (r["status"] as? String) ?? ""
        d.updatedAt = (r["updatedAt"] as? String) ?? ""
        d.written = ((r["stats"] as? JSON)?["written"] as? Int) ?? 0
        d.rounds = ((r["rounds"] as? [JSON]) ?? []).map { ($0["direction"] as? String) ?? "" }
        d.summary = ((r["digest"] as? JSON)?["summary"] as? String) ?? ""
        d.focusPoints = ((r["digest"] as? JSON)?["focusPoints"] as? [String]) ?? []
        d.gaps = ((r["progress"] as? JSON)?["gaps"] as? [String]) ?? []
        return d
    }

    func completeTask(project: String, id: String) async throws {
        _ = try await call("complete_task", ["project": project, "id": id])
    }

    /// 自 since 以来的提醒事件，返回事件与服务端当前时间（下次从这里继续）
    func events(since: String) async throws -> (now: String, events: [SjzEvent]) {
        let r = try await call("get_events", ["since": since])
        let list = ((r["events"] as? [JSON]) ?? []).compactMap { e -> SjzEvent? in
            guard let id = e["id"] as? String else { return nil }
            return SjzEvent(id: id, type: (e["type"] as? String) ?? "", project: (e["project"] as? String) ?? "",
                            projectTitle: (e["projectTitle"] as? String) ?? "", title: (e["title"] as? String) ?? "",
                            detail: (e["detail"] as? String) ?? "", at: (e["at"] as? String) ?? "")
        }
        return ((r["now"] as? String) ?? since, list)
    }

    /// 记线索（items 可以文字图片混排）。结审里钉住了线索就追加到它，否则新建一条
    func addClue(project: String?, items: [JSON], tags: [String] = []) async throws -> String {
        var a: JSON = ["items": items, "tags": tags]
        if let project, !project.isEmpty { a["project"] = project }
        let r = try await call("add_clue", a)
        return (r["message"] as? String) ?? "已记录线索"
    }

    /// 记想法：写进项目当天的工作日志（不进线索）
    func addIdea(project: String?, items: [JSON]) async throws -> String {
        var a: JSON = ["items": items]
        if let project, !project.isEmpty { a["project"] = project }
        let r = try await call("add_idea", a)
        return (r["message"] as? String) ?? "已记入工作日志"
    }

    // MARK: 拾忆来源台账

    func captures(project: String, kind: String? = nil, query: String = "", since: Date? = nil, limit: Int = 300) async throws -> [SjzCapture] {
        var a: JSON = ["project": project, "limit": limit]
        if let kind { a["kind"] = kind }
        if !query.trimmed.isEmpty { a["query"] = query.trimmed }
        if let since { a["since"] = ISO8601DateFormatter().string(from: since) }
        let r = try await call("list_captures", a)
        return ((r["captures"] as? [JSON]) ?? []).compactMap { c in
            guard let id = c["id"] as? String, let k = c["kind"] as? String else { return nil }
            return SjzCapture(id: id, kind: k, title: (c["title"] as? String) ?? "", summary: (c["summary"] as? String) ?? "",
                              source: (c["source"] as? String) ?? "", path: (c["path"] as? String) ?? "",
                              noteNo: (c["noteNo"] as? String) ?? "", notePath: (c["notePath"] as? String) ?? "",
                              status: (c["status"] as? String) ?? "", taskId: (c["taskId"] as? String) ?? "",
                              at: (c["at"] as? String) ?? "", editedAt: (c["editedAt"] as? String) ?? "")
        }
    }

    /// 正文、是否可编辑，以及正文里引用的图片（`imgN` → 图片数据）
    func captureDetail(project: String, id: String) async throws -> (content: String, editable: Bool, images: [String: Data]) {
        let r = try await call("get_capture", ["project": project, "id": id])
        var imgs: [String: Data] = [:]
        for (k, v) in (r["images"] as? [String: String]) ?? [:] { if let d = Data(base64Encoded: v) { imgs[k] = d } }
        return ((r["content"] as? String) ?? "", (r["editable"] as? Bool) ?? false, imgs)
    }

    /// 二次编辑写回：title / source / content / status / linkNote
    func updateCapture(project: String, id: String, fields: JSON) async throws -> String {
        var a = fields
        a["project"] = project
        a["id"] = id
        return ((try await call("update_capture", a))["message"] as? String) ?? "已更新"
    }

    func clueToTask(project: String, id: String) async throws -> String {
        ((try await call("clue_to_task", ["project": project, "id": id]))["message"] as? String) ?? "已转为任务"
    }

    func saveData(project: String?, files: [(name: String, data: Data)], note: String = "") async throws -> String {
        var a: JSON = ["files": files.map { ["name": $0.name, "data": $0.data.base64EncodedString()] as JSON }]
        if let project, !project.isEmpty { a["project"] = project }
        if !note.isEmpty { a["note"] = note }
        return ((try await call("save_data", a))["message"] as? String) ?? "已存入原始材料"
    }

    func addWorkLog(project: String, text: String) async throws {
        _ = try await call("add_work_log", ["project": project, "text": text])
    }

    func createTask(project: String, subject: String, description: String = "") async throws -> String {
        var a: JSON = ["project": project, "subject": subject]
        if !description.isEmpty { a["description"] = description }
        let r = try await call("create_task", a)
        return ((r["task"] as? JSON)?["id"] as? String) ?? ""
    }

    /// 项目文书中心：当前审计阶段 + 按阶段列出各类文书的成果（只有编号 / 标题 / 状态，不含正文）
    func documents(project: String) async throws -> SjzDocs {
        let r = try await call("list_documents", ["project": project])
        var d = SjzDocs()
        d.phase = (r["phase"] as? String) ?? ""
        d.phases = ((r["phases"] as? [JSON]) ?? []).map { p in
            SjzPhase(key: (p["key"] as? String) ?? "", label: (p["label"] as? String) ?? "", current: (p["current"] as? Bool) ?? false,
                     items: ((p["items"] as? [JSON]) ?? []).map { i in
                SjzDocType(code: (i["code"] as? String) ?? "", label: (i["label"] as? String) ?? "",
                           required: (i["required"] as? Bool) ?? false, count: (i["count"] as? Int) ?? 0, issued: (i["issued"] as? Int) ?? 0,
                           docs: ((i["docs"] as? [JSON]) ?? []).compactMap { x in
                    guard let path = x["path"] as? String else { return nil }
                    return SjzDocItem(path: path, title: (x["title"] as? String) ?? "", docNo: (x["docNo"] as? String) ?? "",
                                      statusLabel: (x["statusLabel"] as? String) ?? "", updated: (x["updated"] as? String) ?? "")
                })
            })
        }
        return d
    }

    /// 保存为证据 / 法规；items 里每项是 `{type: text, text}` 或 `{type: image, name, data(base64)}`
    func save(regulation: Bool, project: String?, items: [JSON], title: String, source: String, url: String?, snapshot: Bool) async throws -> String {
        var a: JSON = ["items": items, "title": title, "source": source, "snapshot": snapshot]
        if let project, !project.isEmpty { a["project"] = project }
        if let url, !url.isEmpty { a["url"] = url }
        let r = try await call(regulation ? "save_regulation" : "save_evidence", a)
        return (r["message"] as? String) ?? "已保存"
    }
}

struct SjzPin: Equatable {
    var project = ""
    var projectTitle = ""
    var notePath = ""
    var noteNo = ""
    var noteTitle = ""
    var regulation = ""
    var clueId = ""
    var clueTitle = ""
    var snapshot = true

    var noteLabel: String { [noteNo, noteTitle].filter { !$0.isEmpty }.joined(separator: " ") }
    var clueLabel: String { [clueId, clueTitle].filter { !$0.isEmpty }.joined(separator: " ") }
}

struct SjzNoteHit: Identifiable, Hashable {
    let path: String
    let no: String
    let title: String
    let status: String
    var id: String { path }
}

struct SjzRegHit: Identifiable, Hashable {
    let name: String
    let clause: String
    let capturedAt: String
    var id: String { name }
}

struct SjzTaskLite: Identifiable, Hashable, Codable {
    let id: String
    let project: String
    let projectTitle: String
    let subject: String
    let dueDate: String
    let priority: String
    var detail: String = ""
}

/// 结审的任务概览（只缓存在本机，不会同步到滴答清单 / 闪念贝壳）。`next` 是全部未完成任务，已合并进拾忆的待办
struct SjzOverview: Equatable, Codable {
    var open = 0
    var overdue = 0
    var dueToday = 0
    var pendingReviews = 0
    var next: [SjzTaskLite] = []
    var projects: [SjzProjectStat] = []
}

/// 一个审计项目的任务统计（拾忆「项目」页用）
struct SjzProjectStat: Equatable, Hashable, Codable, Identifiable {
    let name: String
    let title: String
    var open = 0
    var overdue = 0
    var dueToday = 0
    var pendingReviews = 0
    var id: String { name }
}

/// 拾忆写进结审项目的一条记录（证据 / 法规 / 线索 / 数据）
struct SjzCapture: Identifiable, Hashable {
    let id: String
    let kind: String
    let title: String
    let summary: String
    let source: String
    let path: String
    let noteNo: String
    let notePath: String
    let status: String
    let taskId: String
    let at: String
    let editedAt: String

    var kindLabel: String { ["evidence": "证据", "regulation": "法规", "clue": "线索", "idea": "想法", "data": "数据"][kind] ?? kind }
    var icon: String { ["evidence": "doc.text.image", "regulation": "book.closed", "clue": "lightbulb", "idea": "text.bubble", "data": "tablecells"][kind] ?? "doc" }
    var statusLabel: String { ["pending": "待核实", "verified": "已核实", "excluded": "已排除", "converted": "已转疑点"][status] ?? "" }
    var date: Date? { ISO8601DateFormatter().date(from: at) ?? SjzCapture.fallback.date(from: at) }
    private static let fallback: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

struct SjzDocs {
    var phase = ""
    var phases: [SjzPhase] = []
    var total: Int { phases.reduce(0) { $0 + $1.count } }
}

struct SjzPhase: Identifiable, Hashable {
    let key: String
    let label: String
    let current: Bool
    let items: [SjzDocType]
    var id: String { key }
    var count: Int { items.reduce(0) { $0 + $1.count } }
    var issued: Int { items.reduce(0) { $0 + $1.issued } }
    /// 必备但还没建立的文书
    var missing: [SjzDocType] { items.filter { $0.required && $0.count == 0 } }
}

struct SjzDocType: Identifiable, Hashable {
    let code: String
    let label: String
    let required: Bool
    let count: Int
    let issued: Int
    let docs: [SjzDocItem]
    var id: String { code }
}

struct SjzDocItem: Identifiable, Hashable {
    let path: String
    let title: String
    let docNo: String
    let statusLabel: String
    let updated: String
    var id: String { path }
}

struct SjzDigest {
    var direction = ""
    var status = ""
    var updatedAt = ""
    var written = 0
    var rounds: [String] = []
    var summary = ""
    var focusPoints: [String] = []
    var gaps: [String] = []
}

struct SjzEvent: Identifiable, Equatable {
    let id: String
    let type: String
    let project: String
    let projectTitle: String
    let title: String
    let detail: String
    let at: String

    var icon: String {
        switch type {
        case "research.done": return "magnifyingglass.circle.fill"
        case "task.overdue": return "exclamationmark.circle.fill"
        case "task.due_today": return "bell.badge.fill"
        case "clue.stale": return "lightbulb.slash"
        case "evidence.gap": return "doc.badge.ellipsis"
        default: return "checkmark.shield.fill"
        }
    }
}
