import Foundation

/// 快速启动：把今天的待办、逾期、最近的笔记和 Daily Note 交给 AI，梳理出「今天做什么 / 留意什么 / 怎么无压力地开始」。
struct QuickStartPlan {
    struct Focus: Identifiable {
        let id = UUID()
        let title: String
        let why: String
        let task: DidaTask?
    }

    var greeting: String
    var focus: [Focus]
    var watch: [String]
    var later: [String]
    /// 无压启动：从哪件事、用多少分钟、第一步做什么
    var startTask: DidaTask?
    var startTitle: String
    var startMinutes: Int
    var startStep: String
    var tip: String
    var madeAt = Date()
}

enum QuickStartPlanner {
    private static let system = """
    你是用户的私人晨间助理，帮他「无压力地开始今天」。你会拿到：今天的待办、逾期的待办、最近的笔记、最近几天的 Daily Note（随手记）、进行中的项目和今天已有的专注时长。

    请梳理出：
    1. focus：今天真正值得做的 1~3 件事（不是把所有待办罗列一遍）。优先考虑：今天到期的、高优先级的、逾期很久的、笔记 / Daily Note 里反复出现或写着「要做 / 别忘了 / 卡住了」的事。每件给一句不超过 30 字的理由或做法。如果是某个待办，带上它的 id（t1、t2…），不是待办就不带。
    2. watch：需要留意的事项（0~3 条），比如笔记里提到的担心、没有收尾的想法、逾期很久的、时间冲突、今天很满等。每条不超过 40 字。
    3. later：可以放心先放一放的（0~3 条，每条不超过 20 字），帮用户减压。
    4. start：「无压启动」——从 focus 里挑最容易开头的一件，给出 10~25 分钟的小目标：taskId（待办 id，可为空）、title（这一步的名称）、minutes（10~25 的整数）、step（第一步具体做什么，足够小、马上能动手，不超过 40 字）、tip（一句不超过 30 字、让人放松的话）。
    5. greeting：一句温和、不说教的开场白，不超过 30 字，可以结合时间段（现在几点会告诉你）。

    原则：语气温和，不责备，不制造焦虑；逾期不要用「拖延」这种词；信息不足时宁可少说，不要编造用户没写过的内容。

    只输出一个 JSON 对象，不要其他文字：
    {"greeting":"","focus":[{"title":"","why":"","taskId":"t1"}],"watch":[""],"later":[""],"start":{"taskId":"t1","title":"","minutes":15,"step":"","tip":""}}
    """

    @MainActor
    static func plan(model: AppModel) async throws -> QuickStartPlan {
        guard model.hasLlm else { throw LlmError(message: "还没配置 AI 模型，请先到「设置 → AI 模型」填写接口地址和 Key。") }
        let today = Day.today()
        let ov = model.overview

        // 待办：今天 + 逾期（最久的 10 条）+ 收集箱（5 条），用 t1、t2… 的短 id
        let todayTasks = (ov?.todayTasks(today) ?? []).sorted { ($0.time ?? "99:99") < ($1.time ?? "99:99") }
        let overdue = (ov?.overdue ?? []).sorted { ($0.date ?? "") < ($1.date ?? "") }.prefix(10)
        let inbox = (ov?.undated ?? []).prefix(5)
        var idMap: [String: DidaTask] = [:]
        var n = 0
        func encode(_ t: DidaTask, kind: String) -> [String: Any] {
            n += 1
            let sid = "t\(n)"
            idMap[sid] = t
            var o: [String: Any] = ["id": sid, "title": t.cleanTitle, "kind": kind]
            if let tm = t.time { o["time"] = tm }
            if t.priority > 0 { o["priority"] = t.priority >= 5 ? "高" : (t.priority >= 3 ? "中" : "低") }
            if let d = t.date, d < today { o["overdueDays"] = max(1, Day.diff(d, today)) }
            if let p = ov?.projectName(t.projectId) { o["list"] = p }
            let note = t.content.trimmed.replacingOccurrences(of: "\n", with: " ")
            if !note.isEmpty { o["note"] = String(note.prefix(60)) }
            return o
        }
        let todayJson = todayTasks.map { encode($0, kind: "今天") }
        let overdueJson = overdue.map { encode($0, kind: "逾期") }
        let inboxJson = inbox.map { encode($0, kind: "无日期") }
        let doneToday = (ov?.done ?? []).filter { $0.completedDate.map { Day.string($0) == today } ?? false }.map(\.cleanTitle)

        // 最近的笔记（最多 8 条）
        let notes: [[String: Any]] = model.timeline.prefix(8).map { nt in
            var o: [String: Any] = ["title": nt.title]
            if let d = nt.day { o["day"] = d }
            let body = (nt.summary ?? nt.text ?? "").trimmed.replacingOccurrences(of: "\n", with: " ")
            if !body.isEmpty { o["summary"] = String(body.prefix(120)) }
            if !nt.tags.isEmpty { o["tags"] = nt.tags }
            return o
        }

        // 最近 3 天的 Daily Note
        var dailyJson: [[String: Any]] = []
        if model.hasIdeashell,
           let days = try? await model.daily.days(from: Day.add(today, days: -2), to: today) {
            for d in days.keys.sorted() {
                let entries = (days[d]?.entries ?? []).filter { !$0.struck }.suffix(12)
                guard !entries.isEmpty else { continue }
                dailyJson.append(["day": d, "entries": entries.map { String("\($0.time) \($0.text)".replacingOccurrences(of: "\n", with: " ").prefix(120)) }])
            }
        }

        // 进行中的项目和它的下一步
        let projects: [[String: Any]] = model.projects.filter { $0.projectStatus != .PAUSED }.prefix(8).map { p in
            var o: [String: Any] = ["name": p.keyword, "status": p.projectStatus.label]
            if let nx = p.next?.trimmed, !nx.isEmpty { o["next"] = String(nx.prefix(60)) }
            return o
        }

        let c = Day.cal.dateComponents([.hour, .minute, .weekday], from: Date())
        let wk = ["日", "一", "二", "三", "四", "五", "六"]
        let payload: [String: Any] = [
            "now": String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0),
            "today": today, "weekday": "周" + wk[((c.weekday ?? 1) - 1) % 7],
            "todayTasks": todayJson, "overdueTasks": overdueJson, "inboxTasks": inboxJson,
            "doneToday": Array(doneToday.prefix(8)),
            "focusMinutesToday": model.focus.summary?.todayMin ?? 0,
            "focusGoalMinutes": model.focusGoalMin,
            "recentNotes": notes, "dailyNotes": dailyJson, "projects": projects,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let reply = try await model.llm.chatJSON(system: system, user: String(data: data, encoding: .utf8) ?? "{}")
        guard let obj = LlmClient.extractJSON(reply) else { throw LlmError(message: "AI 返回的内容格式不对，请重试") }

        func strings(_ k: String) -> [String] { (obj[k] as? [Any])?.compactMap { ($0 as? String)?.trimmed }.filter { !$0.isEmpty } ?? [] }
        let focus: [QuickStartPlan.Focus] = ((obj["focus"] as? [[String: Any]]) ?? []).prefix(3).compactMap { f in
            guard let t = (f["title"] as? String)?.trimmed, !t.isEmpty else { return nil }
            return .init(title: t, why: (f["why"] as? String)?.trimmed ?? "", task: (f["taskId"] as? String).flatMap { idMap[$0] })
        }
        guard !focus.isEmpty else { throw LlmError(message: "AI 没有梳理出内容，请重试") }
        let st = obj["start"] as? [String: Any] ?? [:]
        let startTask = (st["taskId"] as? String).flatMap { idMap[$0] } ?? focus.first?.task
        let minsRaw = (st["minutes"] as? Int) ?? Int((st["minutes"] as? Double) ?? 15)
        return QuickStartPlan(
            greeting: (obj["greeting"] as? String)?.trimmed ?? "",
            focus: focus, watch: strings("watch"), later: strings("later"),
            startTask: startTask,
            startTitle: (st["title"] as? String)?.trimmed.nonEmpty ?? focus[0].title,
            startMinutes: min(max(minsRaw, 5), 30),
            startStep: (st["step"] as? String)?.trimmed ?? "",
            tip: (st["tip"] as? String)?.trimmed ?? ""
        )
    }
}
