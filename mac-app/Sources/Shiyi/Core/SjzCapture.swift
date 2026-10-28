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
        sjzError = nil
        do {
            if let msg = try await work() { showNotice(msg) }
        } catch {
            // 万能输入是悬浮窗，看不到主窗口的提示条：错误同时记到 sjzError，由输入窗自己显示
            sjzError = error.localizedDescription
            showNotice(error.localizedDescription)
        }
        await refreshSjzTarget()
    }

    func sjzSetProject(_ name: String) async {
        let changed = name != sjzPin.project
        if changed { sjzPendingNote = "" }
        await sjzAct { try await sjz.setPin(project: name, regulation: changed ? NSNull() : nil); return nil }
        await refreshSjzOverview(force: true)
    }

    func sjzPin(note hit: SjzNoteHit) async {
        sjzPendingNote = ""
        await sjzAct {
            try await sjz.setPin(note: ["path": hit.path, "no": hit.no, "title": hit.title] as JSON, evidence: NSNull())
            return nil
        }
    }

    func sjzPin(regulation name: String) async {
        await sjzAct { try await sjz.setPin(regulation: ["name": name] as JSON); return nil }
    }

    /// 钉住一份已有证据：之后保存的证据追加到它里面（和钉住取证单二选一）
    func sjzPin(evidence hit: SjzCapture) async {
        sjzPendingNote = ""
        await sjzAct {
            try await sjz.setPin(note: NSNull(), evidence: ["path": hit.path, "title": hit.title] as JSON)
            return nil
        }
    }

    /// 取消「证据」行的钉住（钉住的取证单 / 已有证据都清掉）
    func sjzUnpinNote() async {
        sjzPendingNote = ""
        await sjzAct { try await sjz.setPin(note: NSNull(), evidence: NSNull()); return nil }
    }
    func sjzUnpinRegulation() async { await sjzAct { try await sjz.setPin(regulation: NSNull()); return nil } }

    /// 钉住一条已有线索：之后记的线索追加到它
    func sjzPin(clue hit: SjzCapture) async {
        await sjzAct { try await sjz.setPin(clue: ["id": hit.id, "title": hit.title] as JSON); return nil }
    }

    func sjzUnpinClue() async { await sjzAct { try await sjz.setPin(clue: NSNull()); return nil } }

    func sjzCreateNote(_ title: String) async {
        sjzPendingNote = ""
        await sjzAct { try await sjz.createNote(title: title) }
    }

    /// 保存证据前确保取证单存在并已钉住：结审里已经有同标题（或同编号）的就直接钉住它，没有才新建。
    /// 这样发件箱因为网络问题重试时，不会重复建出好几份同名取证单。
    func sjzEnsureNote(_ title: String) async throws {
        let t = title.trimmed
        guard !t.isEmpty else { return }
        let hits = (try? await sjz.searchNotes(t)) ?? []
        if let n = hits.first(where: { $0.title == t || $0.no == t }) {
            try await sjz.setPin(note: ["path": n.path, "no": n.no, "title": n.title] as JSON, evidence: NSNull())
        } else {
            _ = try await sjz.createNote(title: t)
        }
        await refreshSjzTarget()
    }

    // MARK: 结审任务（合并进待办，只存本机）

    /// 拉取结审的未完成任务，合并进拾忆的待办 / 今天；不写入滴答清单 / 闪念贝壳
    func refreshSjzOverview(force: Bool = false) async {
        guard hasSjz else {
            if sjzOverview != nil { sjzOverview = nil; applySjzTasks() }
            return
        }
        // 还有改动没发给结审：强制刷新就先发完；普通刷新先别读，免得把刚改的界面盖回旧数据
        if SjzSyncQueue.shared.isBusy {
            guard force else { return }
            guard await SjzSyncQueue.shared.flushNow() else { return }
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

    /// 每天小结：到了设置的时刻（默认 21:00）后，把当天从拾忆写进结审的内容、专注和完成任务汇总写进项目工作日志（每天每个项目一次）
    func sjzDailySummaryIfDue() async {
        let ud = UserDefaults.standard
        let at = ud.object(forKey: "sjz.summaryMin") as? Int ?? 21 * 60
        let cal = Calendar.current
        let nowMin = cal.component(.hour, from: Date()) * 60 + cal.component(.minute, from: Date())
        guard ud.object(forKey: "sjz.summary") as? Bool ?? true,
              nowMin >= at,
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

    /// 打开结审。带上项目和页面路径时，直接定位到结审里的明确位置（`sjz://open?team=…&to=…`），
    /// 比如某个任务、某条线索、某份文书；没装结审 App 时退回用浏览器打开本机 Web 服务。
    func openSjzApp(project: String? = nil, to path: String = "/") {
        let query = "team=\(Self.urlEnc(project ?? ""))&to=\(Self.urlEnc(path))"
        if let url = URL(string: "sjz://open?" + query), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
            return
        }
        if project == nil && path == "/" {
            let fm = FileManager.default
            for app in [NSHomeDirectory() + "/Applications/结审.app", "/Applications/结审.app"] where fm.fileExists(atPath: app) {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        let base = sjzEndpoint.replacingOccurrences(of: "/mcp", with: "")
        if let u = URL(string: base + "/open?" + query) { NSWorkspace.shared.open(u) }
    }

    static func urlEnc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    /// 在结审里打开某个任务（拾忆待办里的 `sjz:<项目>:<任务>`）
    func openSjzTask(_ taskId: String) {
        guard let t = SjzTasks.parse(taskId) else { openSjzApp(); return }
        openSjzApp(project: t.project, to: "/tasks?task=" + Self.urlEnc(t.task))
    }

    /// 在结审里打开台账里的一项：线索 → 线索编辑；证据 / 法规 / 数据 → 对应文件；想法 → 当天工作日志
    func openSjzCapture(project: String, _ c: SjzCapture) {
        switch c.kind {
        case "clue":
            openSjzApp(project: project, to: "/suspicious?clue=" + Self.urlEnc(c.id))
        case "idea":
            openSjzApp(project: project, to: c.logRel.isEmpty ? "/" : "/documents?open=" + Self.urlEnc(c.logRel))
        default:
            openSjzApp(project: project, to: c.path.isEmpty ? "/documents" : "/documents?open=" + Self.urlEnc(c.path))
        }
    }

    /// 提醒事件 → 结审里对应的页面
    func openSjzEvent(_ e: SjzEvent) {
        let page: String
        if e.type.hasPrefix("research") { page = "/research" }
        else if e.type.hasPrefix("task") { page = "/tasks" }
        else if e.type.hasPrefix("clue") { page = "/suspicious?tab=clues" }
        else if e.type.hasPrefix("evidence") { page = "/evidence?tab=note" }
        else { page = "/" }
        openSjzApp(project: e.project.isEmpty ? nil : e.project, to: page)
    }

    /// 结审 → 拾忆：`shiyi://task?project=&id=` 打开任务，`shiyi://project?project=` 打开审计项目
    func handleDeepLink(_ url: URL) {
        guard url.scheme == "shiyi" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ k: String) -> String { items.first { $0.name == k }?.value ?? "" }
        let project = q("project")
        MainWindow.show()
        guard !project.isEmpty else { return }
        switch url.host ?? "" {
        case "task":
            let tid = "\(SjzTasks.prefix)\(project):\(q("id"))"
            Task {
                if localTask(tid) == nil { await refreshSjzOverview(force: true) }
                if let t = localTask(tid) {
                    openTask(t)
                } else {
                    // 已完成或不在待办里：退回到项目页
                    section = .focus
                    selectedProject = SjzTasks.prefix + project
                    showNotice("这个任务不在未完成的待办里，已打开所在项目")
                }
            }
        default:
            section = .focus
            selectedProject = SjzTasks.prefix + project
        }
    }

    /// 在结审里打开一份文书（项目内相对路径）
    func openSjzDoc(project: String, path: String) {
        openSjzApp(project: project, to: "/documents?open=" + Self.urlEnc(path))
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
        var raw = await input.receivingPromises(into: FileManager.default.temporaryDirectory.appendingPathComponent("shiyi-drop", isDirectory: true))
        // 文件地址读不到（常见于微信容器目录）：改用文件承诺接收一份副本
        let unreadableURL = raw.fileURLs.contains { u in
            guard let h = try? FileHandle(forReadingFrom: u) else { return true }
            try? h.close()
            return false
        }
        if unreadableURL, !raw.altPromises.isEmpty {
            raw = await raw.receivingAlt(into: FileManager.default.temporaryDirectory.appendingPathComponent("shiyi-drop", isDirectory: true))
        }
        if target == .data {
            await refreshSjzTarget()
            return try await submitSjzData(raw)
        }
        let current = raw
        let prepared = await Task.detached(priority: .userInitiated) { DropImages.prepare(current) }.value
        var texts: [String] = []
        if !raw.text.trimmed.isEmpty { texts.append(raw.text.trimmed) }
        texts.append(contentsOf: prepared.texts.map(\.trimmed).filter { !$0.isEmpty })
        let body = texts.joined(separator: "\n\n")
        // 以结审里钉住的为准：先读一次最新的（岛外可能刚改过）
        await refreshSjzTarget()
        let project: String? = nil
        let place = sjzTargetTitle.isEmpty ? "" : "（\(sjzTargetTitle)）"

        if target == .clue {
            // 线索是独立的 Markdown，可以带图片；钉住了线索就追加到它
            var clueItems: [JSON] = prepared.images.map { ["type": "image", "name": $0.name, "data": $0.data.base64EncodedString()] }
            if !body.isEmpty { clueItems.append(["type": "text", "text": body]) }
            guard !clueItems.isEmpty else {
                if !prepared.files.isEmpty { throw McpError.tool("线索只收文字和图片，PDF / Word 请拖到「证据」或「法规」格") }
                throw McpError.tool(DropImages.failure(prepared, types: raw.types))
            }
            let msg = try await sjz.addClue(project: project, items: clueItems)
            return msg + place
        }
        guard !body.isEmpty || !prepared.images.isEmpty || !prepared.files.isEmpty else {
            throw McpError.tool(DropImages.failure(prepared, types: raw.types))
        }

        var items: [JSON] = prepared.images.map { ["type": "image", "name": $0.name, "data": $0.data.base64EncodedString()] }
        // PDF / Word 等原件：结审存原件，并解析出文字（可在结审里选取摘录）
        items.append(contentsOf: prepared.files.map { f -> JSON in
            var d: JSON = ["type": "file", "name": f.name]
            if let data = f.data { d["data"] = data.base64EncodedString() } else if let path = f.path { d["path"] = path }
            return d
        })
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

    /// 万能输入 → 结审（线索 / 想法 / 证据 / 法规）。文字和图片按输入框里的先后顺序混排保存。
    /// `text` 里每个 U+FFFC 对应 `images` 里的一张图。线索 / 证据 / 法规钉住了对象就追加到它，想法写进当天工作日志。
    func submitSjzCompose(text: String, tags: [String], images: [ComposerImage], kind: CaptureKind, newNote: String? = nil) async throws -> String {
        guard hasSjz else { throw McpError.tool("先到「设置」开启并连接结审") }
        // 证据 + 选了「新建取证单」：先建（或找到同名的）并钉住，下面的保存就会追加到它里面
        if kind == .evidence, let title = newNote?.trimmed, !title.isEmpty {
            try await sjzEnsureNote(title)
        }
        await refreshSjzTarget()
        let place = sjzTargetTitle.isEmpty ? "" : "（\(sjzTargetTitle)）"
        let fitted = await Task.detached(priority: .userInitiated) {
            images.map { DropImages.fit($0.data, name: $0.name) }
        }.value
        var items: [JSON] = []
        var texts: [String] = []
        let parts = text.components(separatedBy: ComposerImage.marker)
        var next = 0
        for (i, part) in parts.enumerated() {
            let t = part.trimmed
            if !t.isEmpty { items.append(["type": "text", "text": t]); texts.append(t) }
            if i < parts.count - 1 {
                if next < fitted.count, let img = fitted[next] {
                    items.append(["type": "image", "name": img.name, "data": img.data.base64EncodedString()])
                }
                next += 1
            }
        }
        guard !items.isEmpty else { throw McpError.tool("没有读到可以保存的内容") }
        let body = texts.joined(separator: "\n\n")
        let hasImage = items.contains { ($0["type"] as? String) == "image" }

        switch kind {
        case .clue:
            return try await sjz.addClue(project: nil, items: items, tags: tags) + place
        case .idea:
            return try await sjz.addIdea(project: nil, items: items) + place
        default:
            break
        }

        // 证据 / 法规：单独一个网址 → 存成「网址」并抓取网页快照
        let link = hasImage ? nil : Self.singleLink(body)
        if let link, let i = items.firstIndex(where: { ($0["type"] as? String) == "text" }) { items[i]["url"] = link }
        let source: String
        if let link, let host = URL(string: link)?.host { source = host.replacingOccurrences(of: "www.", with: "") }
        else if hasImage && body.isEmpty { source = "屏幕截图" }
        else { source = "拾忆" }
        let first = body.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmed ?? ""
        var title = link == nil ? String(first.prefix(30)) : ""
        if kind == .regulation {
            title = sjzPin.regulation.isEmpty ? Self.guessRegulationName(body: body, link: link, file: nil) : ""
        }
        do {
            let msg = try await sjz.save(regulation: kind == .regulation, project: nil, items: items, title: title,
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
        guard !files.isEmpty else {
            throw McpError.tool(raw.fileURLs.isEmpty ? "数据区只接收文件（Excel / CSV / PDF 等）" : "读不到拖入的文件（没有权限或已被移走）。请到 系统设置 → 隐私与安全性 → 完全磁盘访问 允许拾忆，或先把文件拖到桌面再拖入")
        }
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

/// 当天从拾忆做的事的本机计数（专注分钟、完成任务数），供每天工作小结使用
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
        case start(String?)
        case phase(String)
        case delete
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
                        date: t.dueDate.isEmpty ? nil : t.dueDate, priority: level, tags: ["结审"], startDate: t.startDate, phase: t.phase)
    }

    static func parse(_ id: String) -> (project: String, task: String)? {
        let rest = id.dropFirst(prefix.count)
        guard let i = rest.firstIndex(of: ":") else { return nil }
        return (String(rest[..<i]), String(rest[rest.index(after: i)...]))
    }

    /// 改结审任务：界面和本机缓存先动，改动记进 `SjzSyncQueue`，停手后在后台打包一次发给结审
    @MainActor
    static func apply(_ task: DidaTask, _ change: Change) async throws {
        guard let model = AppModel.current, parse(task.id) != nil else { throw McpError.tool("找不到这条结审任务") }
        SjzSyncQueue.shared.enqueue(task, change, model: model)
    }
}
