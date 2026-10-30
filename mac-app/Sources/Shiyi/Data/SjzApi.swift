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
        // 写入类调用成功后通知界面：拾忆里「来自拾忆」的列表立刻重读，不用等轮询
        if !tool.hasPrefix("list_") && !tool.hasPrefix("get_") {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .sjzCapturesChanged, object: nil) }
        }
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
        if let e = r["evidence"] as? JSON {
            pin.evidencePath = (e["path"] as? String) ?? ""
            pin.evidenceTitle = (e["title"] as? String) ?? ""
        }
        if let c = r["clue"] as? JSON {
            pin.clueId = (c["id"] as? String) ?? ""
            pin.clueTitle = (c["title"] as? String) ?? ""
        }
        pin.snapshot = (r["snapshot"] as? Bool) ?? true
        return pin
    }

    /// 钉住项目 / 取证单 / 法规 / 线索；note、regulation、clue 传 NSNull 表示取消钉住
    func setPin(project: String? = nil, note: Any? = nil, evidence: Any? = nil, regulation: Any? = nil, clue: Any? = nil) async throws {
        var a: JSON = [:]
        if let project { a["project"] = project }
        if let note { a["note"] = note }
        if let evidence { a["evidence"] = evidence }
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
                                         detail: (x["description"] as? String) ?? "",
                                         startDate: (x["startDate"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                         phase: (x["phase"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
            }
        }
        ov.projects = ((r["projects"] as? [JSON]) ?? []).map { p in
            let t = (p["tasks"] as? JSON) ?? [:]
            let name = (p["name"] as? String) ?? ""
            return SjzProjectStat(name: name, title: (p["title"] as? String) ?? name,
                                  open: (t["open"] as? Int) ?? 0, overdue: (t["overdue"] as? Int) ?? 0,
                                  dueToday: (t["dueToday"] as? Int) ?? 0, pendingReviews: (p["pendingReviews"] as? Int) ?? 0,
                                  type: p["type"] as? String, phase: p["phase"] as? String, status: p["status"] as? String,
                                  auditedUnit: p["auditedUnit"] as? String, period: p["period"] as? String, planRange: p["planRange"] as? String,
                                  typeLabel: p["typeLabel"] as? String, phaseLabel: p["phaseLabel"] as? String, statusLabel: p["statusLabel"] as? String)
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

    /// 在结审项目里新建任务，返回任务编号
    @discardableResult
    func createTask(project: String, subject: String, description: String = "", startDate: String = "", dueDate: String = "", priority: String = "medium") async throws -> String {
        var a: JSON = ["project": project, "subject": subject, "priority": priority]
        if !startDate.isEmpty { a["startDate"] = startDate }
        if !description.isEmpty { a["description"] = description }
        if !dueDate.isEmpty { a["dueDate"] = dueDate }
        let r = try await call("create_task", a)
        return ((r["task"] as? JSON)?["id"] as? String) ?? ""
    }

    /// 批量改 / 删任务（后台打包同步用）：一次请求，返回逐条结果 `(project, id, ok, error)`
    func syncTasks(updates: [JSON], deletes: [JSON]) async throws -> [(project: String, id: String, ok: Bool, error: String)] {
        let r = try await call("sync_tasks", ["updates": updates, "deletes": deletes])
        return ((r["results"] as? [JSON]) ?? []).map {
            (($0["project"] as? String) ?? "", ($0["id"] as? String) ?? "", ($0["ok"] as? Bool) ?? false, ($0["error"] as? String) ?? "")
        }
    }

    /// 删除结审任务（不可恢复；由线索 / 想法转出的任务，对应记录的「已转任务」标记会一并清除）
    func deleteTask(project: String, id: String) async throws {
        _ = try await call("delete_task", ["project": project, "id": id])
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

    /// 已生成的工作小结（存在项目工作日志里），最新在前
    func summaries(project: String, limit: Int = 5) async throws -> [SjzSummary] {
        let r = try await call("list_summaries", ["project": project, "limit": limit])
        return ((r["summaries"] as? [JSON]) ?? []).compactMap { c in
            guard let path = c["path"] as? String else { return nil }
            return SjzSummary(path: path, title: (c["title"] as? String) ?? "", kind: (c["kind"] as? String) ?? "",
                              period: (c["period"] as? String) ?? "", updatedAt: (c["updatedAt"] as? String) ?? "",
                              auto: (c["auto"] as? Bool) ?? false, ai: (c["generatedBy"] as? String) == "ai",
                              manual: (c["generatedBy"] as? String) == "manual")
        }
    }

    /// 小结的原文（Markdown，含附录），编辑用
    func summarySource(project: String, path: String) async throws -> String {
        let r = try await call("get_summary", ["project": project, "path": path])
        return (r["source"] as? String) ?? (r["content"] as? String) ?? ""
    }

    /// 导出成公文版式的 Word，返回文件的绝对路径
    func exportSummary(project: String, path: String) async throws -> URL {
        let r = try await call("export_summary", ["project": project, "path": path])
        guard let p = r["absPath"] as? String else { throw McpError.tool("导出失败") }
        return URL(fileURLWithPath: p)
    }

    /// 保存手动修改后的小结；保存后这份小结标记为「手写」
    func saveSummary(project: String, path: String, markdown: String) async throws {
        _ = try await call("update_summary", ["project": project, "path": path, "markdown": markdown])
    }

    /// 生成一份工作小结（按事实汇总）。同一统计期间已有时 exists 为 true，不覆盖，除非 overwrite
    func generateSummary(project: String, kind: String, overwrite: Bool = false) async throws -> (exists: Bool, summary: SjzSummary?, message: String) {
        let r = try await call("generate_summary", ["project": project, "kind": kind, "overwrite": overwrite])
        let msg = (r["message"] as? String) ?? ""
        guard let path = r["path"] as? String else { return (false, nil, msg) }
        let s = SjzSummary(path: path, title: (r["title"] as? String) ?? "", kind: (r["kind"] as? String) ?? kind,
                           period: (r["period"] as? String) ?? "", updatedAt: (r["updatedAt"] as? String) ?? "")
        return ((r["exists"] as? Bool) ?? false, s, msg)
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
                              at: (c["at"] as? String) ?? "", editedAt: (c["editedAt"] as? String) ?? "",
                              clueIds: (c["clueIds"] as? [String]) ?? [], logRel: (c["logRel"] as? String) ?? "",
                              toClue: (c["toClue"] as? String) ?? "", parentId: (c["parentId"] as? String) ?? "",
                              originals: (c["originals"] as? [String]) ?? [], listIds: (c["listIds"] as? [String]) ?? [])
        }
    }

    /// 正文、是否可编辑，以及正文里引用的图片（`imgN` → 图片数据）
    func captureDetail(project: String, id: String) async throws -> (content: String, editable: Bool, images: [String: Data], files: [SjzFile], times: [String: String]) {
        // 工作小结（id 形如 summary:logs/xx.md）：读小结正文，只读、没有图片和原件
        if id.hasPrefix(SjzSummary.idPrefix) {
            let r = try await call("get_summary", ["project": project, "path": String(id.dropFirst(SjzSummary.idPrefix.count))])
            return ((r["content"] as? String) ?? "", false, [:], [], [:])
        }
        let r = try await call("get_capture", ["project": project, "id": id])
        var imgs: [String: Data] = [:]
        for (k, v) in (r["images"] as? [String: String]) ?? [:] { if let d = Data(base64Encoded: v) { imgs[k] = d } }
        let files = ((r["files"] as? [JSON]) ?? []).compactMap { f -> SjzFile? in
            guard let rel = f["rel"] as? String, let abs = f["abs"] as? String else { return nil }
            return SjzFile(rel: rel, name: (f["name"] as? String) ?? rel, ext: (f["ext"] as? String) ?? "", abs: abs, size: (f["size"] as? Int) ?? 0, role: (f["role"] as? String) ?? "original")
        }
        let times = ((r["times"] as? JSON) ?? [:]).compactMapValues { $0 as? String }
        return ((r["content"] as? String) ?? "", (r["editable"] as? Bool) ?? false, imgs, files, times)
    }

    /// 二次编辑写回：title / source / content / status / linkNote
    func updateCapture(project: String, id: String, fields: JSON) async throws -> String {
        var a = fields
        a["project"] = project
        a["id"] = id
        return ((try await call("update_capture", a))["message"] as? String) ?? "已更新"
    }

    /// 线索直接生成取证单草稿（不再经过疑点）
    func clueToNote(project: String, id: String) async throws -> String {
        ((try await call("clue_to_note", ["project": project, "id": id]))["message"] as? String) ?? "已生成取证单草稿"
    }

    /// 撤回线索的转换：线索恢复待核实，取证单草稿删除
    func clueRevert(project: String, id: String) async throws -> String {
        ((try await call("clue_revert", ["project": project, "id": id]))["message"] as? String) ?? "已撤回"
    }

    /// 删除台账里的一项（想法 / 证据 / 法规 / 数据 / 线索），不可恢复
    func deleteCapture(project: String, id: String) async throws -> String {
        ((try await call("delete_capture", ["project": project, "id": id]))["message"] as? String) ?? "已删除"
    }

    /// 新建资料清单：写进结审文书中心的「资料清单」分类，并登记到来自拾忆
    func addDatalist(project: String, title: String, items: String, dueDate: String) async throws -> String {
        var a: JSON = ["project": project, "title": title, "items": items]
        if !dueDate.isEmpty { a["dueDate"] = dueDate }
        return ((try await call("add_datalist", a))["message"] as? String) ?? "已新建资料清单"
    }

    /// 想法转为线索：想法保留，生成一条新的待核实线索
    func ideaToClue(project: String, id: String) async throws -> String {
        ((try await call("idea_to_clue", ["project": project, "id": id]))["message"] as? String) ?? "已转为线索"
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
                     startDate: (p["startDate"] as? String) ?? "", endDate: (p["endDate"] as? String) ?? "", plan: (p["plan"] as? String) ?? "",
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

    /// 已发出还没收回的取证单（按发出时间从早到晚）
    func outstanding(project: String) async throws -> [SjzOutstanding] {
        let r = try await call("list_outstanding", ["project": project])
        return ((r["items"] as? [JSON]) ?? []).compactMap { i in
            guard let path = i["path"] as? String else { return nil }
            return SjzOutstanding(path: path, no: (i["no"] as? String) ?? "", title: (i["title"] as? String) ?? "",
                                  unit: (i["unit"] as? String) ?? "", matter: (i["matter"] as? String) ?? "",
                                  sentAt: (i["sentAt"] as? String) ?? "", sentLabel: (i["sentLabel"] as? String) ?? "",
                                  kind: (i["kind"] as? String) ?? "evidence_note", dueAt: (i["dueAt"] as? String) ?? "")
        }
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
    /// 钉住的已有证据（项目内 evidence/ 下的文件）：新证据追加到它
    var evidencePath = ""
    var evidenceTitle = ""
    var regulation = ""
    var clueId = ""
    var clueTitle = ""
    var snapshot = true

    var noteLabel: String { [noteNo, noteTitle].filter { !$0.isEmpty }.joined(separator: " ") }
    /// 证据行显示的内容：钉住了已有证据显示它，否则显示钉住的取证单
    var evidenceLabel: String {
        if !evidencePath.isEmpty { return evidenceTitle.isEmpty ? (evidencePath as NSString).lastPathComponent : evidenceTitle }
        return noteLabel
    }
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
    var subject: String
    var dueDate: String
    var priority: String
    var detail: String = ""
    var startDate: String? = nil
    var phase: String? = nil
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
    /// 基本信息（可能为空；旧缓存里没有这些字段）
    var type: String? = nil
    var phase: String? = nil
    var status: String? = nil
    var auditedUnit: String? = nil
    var period: String? = nil
    var planRange: String? = nil
    /// 结审给出的中文名（优先用；老版本结审没有时退回下面的本地对照）
    var typeLabel: String? = nil
    var phaseLabel: String? = nil
    var statusLabel: String? = nil
    var id: String { name }

    /// 项目基本信息标签：类型 · 阶段 · 状态 · 被审计单位 · 审计期间（有什么显示什么）
    var infoTags: [String] {
        var t: [String] = []
        if let x = typeLabel, !x.isEmpty { t.append(x) }
        else if let x = type, !x.isEmpty { t.append(x == "special" ? "专项审计" : "普通审计") }
        if let x = phaseLabel, !x.isEmpty { t.append(x) }
        else if let x = phase, !x.isEmpty {
            t.append(["preparation": "审前准备", "implementation": "审计实施", "reporting": "报告与处理", "rectification": "整改跟踪"][x] ?? x)
        }
        if let x = statusLabel, !x.isEmpty { t.append(x) }
        else if let x = status, !x.isEmpty, x != "in_progress" {
            t.append(["planning": "筹划中", "reporting": "报告中", "completed": "已完成", "archived": "已归档"][x] ?? x)
        }
        if let x = auditedUnit, !x.isEmpty { t.append(x) }
        // 审计期间和计划起止只显示一个：有审计期间用期间，没填再用计划
        if let x = period, !x.isEmpty { t.append("期间 " + x) }
        else if let x = planRange, !x.isEmpty { t.append("计划 " + x) }
        return t
    }
}

/// 已发出但还没收回的取证单
struct SjzOutstanding: Identifiable, Hashable {
    let path: String
    let no: String
    let title: String
    let unit: String
    let matter: String
    /// yyyy-MM-dd，没有记录发出日期时为空
    let sentAt: String
    let sentLabel: String
    /// evidence_note（取证单）/ data_request（资料清单）
    var kind: String = "evidence_note"
    /// 资料清单的要求提供日期 yyyy-MM-dd
    var dueAt: String = ""
    var id: String { path }
    var sentDate: Date? { Day.parse(sentAt) }
}

/// 一条记录名下的原件（pdf / word / excel / 图片…），abs 是本机上的绝对路径，可直接用系统预览
struct SjzFile: Identifiable, Hashable {
    let rel: String
    let name: String
    let ext: String
    let abs: String
    let size: Int
    /// original = 这条记录自己的原件；source = 摘录出处指向的文件
    var role = "original"
    var id: String { rel }
    var url: URL { URL(fileURLWithPath: abs) }
    var isPDF: Bool { ext == "pdf" }
    var icon: String {
        switch ext {
        case "pdf": return "doc.richtext"
        case "doc", "docx", "wps", "rtf": return "doc.text"
        case "xls", "xlsx", "csv", "et": return "tablecells"
        case "ppt", "pptx": return "rectangle.on.rectangle"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tif", "tiff": return "photo"
        default: return "doc"
        }
    }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
}

/// 结审里生成的一份工作小结（日报 / 周报 / 阶段报告 / 项目小结）
struct SjzSummary: Identifiable, Hashable {
    let path: String
    let title: String
    let kind: String
    let period: String
    let updatedAt: String
    /// 定时自动生成的 / 用 AI 润色过的
    var auto = false
    var ai = false
    /// 手写的（自己写或手动改过）
    var manual = false
    static let idPrefix = "summary:"
    var id: String { path }
    /// 套成一条「记录」：这样就能用拾忆已有的预览窗口打开
    var asCapture: SjzCapture {
        SjzCapture(id: Self.idPrefix + path, kind: "summary", title: "\(kindLabel) · \(shortPeriod)", summary: title, source: "结审",
                   path: path, noteNo: "", notePath: "", status: "", taskId: "", at: updatedAt, editedAt: "")
    }
    var kindLabel: String { ["daily": "日报", "weekly": "周报", "phase": "阶段报告", "project": "项目小结"][kind] ?? "小结" }
    /// 「10-26 ~ 11-01」：去掉年份；单日只留一个日期
    var shortPeriod: String {
        let parts = period.components(separatedBy: " ~ ").map { String($0.dropFirst(5)) }
        guard let a = parts.first, !a.isEmpty else { return "" }
        return parts.count > 1 && parts[1] != a ? "\(a) ~ \(parts[1])" : a
    }
    var date: Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: updatedAt) ?? ISO8601DateFormatter().date(from: updatedAt)
    }
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
    /// 证据 / 法规 / 想法关联的线索（台账编号）
    var clueIds: [String] = []
    /// 想法所在的工作日志文件（项目内相对路径）
    var logRel: String = ""
    /// 想法已转成的线索（台账编号），空表示还没转
    var toClue: String = ""
    /// 追加记录挂在哪个证据（台账编号）名下，空表示是独立的一项
    var parentId: String = ""
    /// 这一项带的原件（PDF / Word / Excel…）
    var originals: [String] = []
    /// 证据 / 想法关联的资料清单（台账编号）
    var listIds: [String] = []

    var kindLabel: String { ["evidence": "证据", "regulation": "法规", "clue": "线索", "idea": "想法", "data": "数据", "datalist": "资料清单", "summary": "工作小结"][kind] ?? kind }
    var icon: String { ["evidence": "doc.text.image", "regulation": "book.closed", "clue": "lightbulb", "idea": "text.bubble", "data": "tablecells", "datalist": "list.clipboard", "summary": "doc.richtext"][kind] ?? "doc" }
    /// 结审的工作小结（只读，不能编辑）
    var isSummary: Bool { kind == "summary" }
    var statusLabel: String { ["pending": "待核实", "verified": "已核实", "excluded": "已排除", "converted": "已出取证单", "draft": "草稿", "sent": "已发出", "recalled": "已收回"][status] ?? "" }
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
    /// 审计计划里这个阶段的起止日期（结审「编辑项目 → 审计计划」，可能为空）和工作内容
    var startDate = ""
    var endDate = ""
    var plan = ""
    let items: [SjzDocType]
    var id: String { key }

    /// 「10/19 – 11/13」；跨年带年份；都没填返回空串
    var range: String {
        func parse(_ s: String) -> (Int, String)? {
            let nums = s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard nums.count >= 3 else { return nil }
            return (nums[0], "\(nums[1])/\(nums[2])")
        }
        let a = parse(startDate), b = parse(endDate)
        if a == nil && b == nil { return "" }
        let cross = a != nil && b != nil && a!.0 != b!.0
        func f(_ x: (Int, String)?) -> String { x.map { cross ? "\($0.0)/\($0.1)" : $0.1 } ?? "?" }
        return "\(f(a)) – \(f(b))"
    }
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
        case "clue.task_done": return "checkmark.circle.fill"
        case "clue.verified_idle": return "clock.badge.exclamationmark"
        case "evidence.gap": return "doc.badge.ellipsis"
        case "summary.new": return "doc.richtext.fill"
        default: return "checkmark.shield.fill"
        }
    }
}

extension Notification.Name {
    /// 结审里的拾忆来源台账有变化（刚保存 / 编辑 / 删除了内容）
    static let sjzCapturesChanged = Notification.Name("sjz.capturesChanged")
    /// 预览窗口里按回车：编辑这份工作小结（object 为 "项目|记录编号"）
    static let sjzSummaryEdit = Notification.Name("sjz.summaryEdit")
}
