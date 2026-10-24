import Foundation

/// AI 规划助手：先看一眼待办和冲突，问用户几个问题（今天想做什么、有多少时间、冲突怎么取舍…），
/// 再给出一份计划：总结 + 冲突的处理 + 需要改期的待办 + 拆解出来的新任务（含日期 / 时间）。
/// 只返回方案，不写入滴答；写入前由规划弹窗里的「应用」决定。

// MARK: - 数据

/// 系统检测到的冲突
struct PlanConflict: Identifiable {
    let id = UUID()
    let date: String
    let text: String
}

struct AIQuestion: Identifiable {
    let id: String
    /// 属于方法论的哪一步：目标（OKR）/ 澄清（GTD）/ 优先级（重要紧急 · MIT）/ 容量（时间精力）/ 取舍（冲突逾期）
    let stage: String
    let text: String
    var options: [String]
    var multi: Bool
}

struct AIAsk {
    var intro: String
    var questions: [AIQuestion]
}

struct AIMove: Identifiable {
    var id: String { task.id }
    let task: DidaTask
    let date: String
    let time: String?
    let reason: String
}

struct AINewTask: Identifiable {
    let id = UUID()
    let title: String
    let date: String
    let time: String?
    let priority: Int
    let minutes: Int
    let reason: String
    /// 从哪件待办 / 目标拆出来的
    let parent: String?
    /// 属于哪个项目（项目关键词）
    let project: String?
}

struct AIConflictFix: Identifiable {
    let id = UUID()
    let text: String
    let resolution: String
}

struct AIDayPlan {
    var summary: String
    /// 今天最重要的 3 件事（MIT）：标题 + 为什么
    var topThree: [String]
    var conflicts: [AIConflictFix]
    var moves: [AIMove]
    var newTasks: [AINewTask]
}

/// 交给 AI 的上下文：待办（短 id）、冲突、项目
struct PlanContext {
    var today: String
    var tasks: [DidaTask]
    var idMap: [String: DidaTask]
    var sidOf: [String: String]
    var locked: Set<String>
    var conflicts: [PlanConflict]
    var overdueCount: Int
    var todayCount: Int
    var undatedCount: Int
    var payload: [String: Any]
}

// MARK: - 冲突检测

enum ConflictFinder {
    /// 从标题 / 备注里读「约 2h」「1.5 小时」「30 分钟」，没有就按 30 分钟
    static func estimateMinutes(_ t: DidaTask) -> Int {
        let text = t.title + " " + t.content
        guard let re = try? NSRegularExpression(pattern: #"(?i)约\s*([0-9]+(?:\.[0-9]+)?)\s*(h|小时|min|分钟|分|m)\b?"#) else { return 30 }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 3,
              let v = Double(ns.substring(with: m.range(at: 1))) else { return 30 }
        let unit = ns.substring(with: m.range(at: 2)).lowercased()
        return Int(unit == "h" || unit == "小时" ? v * 60 : v)
    }

    private static func minutes(_ hhmm: String) -> Int? {
        let p = hhmm.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return h * 60 + m
    }

    static func find(tasks: [DidaTask], today: String, perDay: Int = 6) -> [PlanConflict] {
        var out: [PlanConflict] = []
        let end = Day.add(today, days: 14)
        var byDay: [String: [DidaTask]] = [:]
        for t in tasks where !t.done { if let d = t.date, d >= today, d <= end { byDay[d, default: []].append(t) } }
        for d in byDay.keys.sorted() {
            let ts = byDay[d] ?? []
            // 时间重叠
            let timed = ts.compactMap { t -> (DidaTask, Int, Int)? in
                guard let tm = t.time, let s = minutes(tm) else { return nil }
                return (t, s, s + max(estimateMinutes(t), 15))
            }.sorted { $0.1 < $1.1 }
            for i in 0 ..< max(timed.count - 1, 0) {
                let a = timed[i], b = timed[i + 1]
                if b.1 < a.2 {
                    out.append(PlanConflict(date: d, text: "\(Day.label(d)) \(a.0.time ?? "")「\(String(a.0.cleanTitle.prefix(18)))」和 \(b.0.time ?? "")「\(String(b.0.cleanTitle.prefix(18)))」时间重叠"))
                }
            }
            // 太满
            let total = ts.reduce(0) { $0 + estimateMinutes($1) }
            if ts.count > perDay {
                out.append(PlanConflict(date: d, text: "\(Day.label(d)) 有 \(ts.count) 件待办，偏多"))
            } else if total > 8 * 60 {
                out.append(PlanConflict(date: d, text: "\(Day.label(d)) 预计要做约 \(String(format: "%.1f", Double(total) / 60)) 小时，排太满"))
            }
        }
        return out
    }
}

// MARK: - 提示词与调用

enum AIAssistant {
    private static let askSystem = """
    你是用户的私人日程教练，把经典的时间管理方法用在他真实的待办上：GTD（收集 → 澄清 → 整理 → 回顾 → 执行）、OKR（目标与关键结果）、艾森豪威尔矩阵（重要 / 紧急）、MIT（每天最重要的 1~3 件事）、GTD 四准则（时间、精力、情境、优先级）。
    你会拿到：现在的日期时间、待办（逾期 / 今天 / 未来 4 周 / 无日期，每条有 id、标题、日期、时间、优先级、清单）、系统检测到的冲突、进行中的项目、最近的笔记标题。
    在规划之前，用最多 5 个简短的问题带他过一遍。每个问题属于下面一个阶段，按这个顺序，不适用的阶段直接跳过（不要凑数）：

    1. stage「目标」（OKR）：这段时间（今天 / 本周）最想达成的 1~2 个目标是什么、做到什么程度算成功。选项优先用他进行中的项目名和待办里反复出现的主题，不要空泛。
    2. stage「澄清」（GTD）：挑出 1~2 个看起来很大、很含糊、没有明确下一步的待办（点名），问他「第一步具体要做什么」或「想拆到什么程度」。没有这样的待办就跳过。
    3. stage「优先级」（艾森豪威尔 / MIT）：如果今天 + 逾期的待办超过 3 件，问「今天只能完成最重要的 3 件，选哪几件」，选项直接用具体待办的标题（multi 为 true，最多 4 个选项）；也可问哪些是重要但不紧急、可以安排但不必今天做的。
    4. stage「容量」：今天实际可用的时间和精力——几点之后有空、有没有固定会议或外出、现在状态（精力充沛 / 一般 / 疲惫），选项要具体（比如「全天都有空」「只有晚上」「碎片时间」）。
    5. stage「取舍」：如果有冲突（时间重叠、某天太满）或逾期堆积，点名具体的几件，问先保哪个、哪些可以推迟或放弃。没有冲突和逾期就跳过。

    要求：问题要点名具体的待办 / 项目，不要泛泛地问「你今天想做什么」；每个问题给 2~4 个简短选项（每个不超过 14 字，方便点选）；不要问待办里已经写明白的事；text 不超过 40 字，语气像朋友，不说教。
    intro：一句不超过 50 字的话，概括你看到的情况（逾期几件、哪天冲突或太满等），语气温和、不制造焦虑。

    只输出一个 JSON 对象，不要其他文字：
    {"intro":"","questions":[{"id":"q1","stage":"目标","text":"","options":["",""],"multi":false}]}
    """

    private static let planSystem = """
    你是用户的私人日程规划助理。根据待办、冲突、项目，以及用户对你提问的回答和他自己写的「想做的事」，给出一份可以直接执行的计划：总结 + 冲突的处理 + 需要改期的待办 + 拆解出来的新任务。严格遵守下面的规则。

    规则：
    1. 日期只能是 today 或之后，格式 yyyy-MM-dd；time 格式 HH:mm，可以为 null（全天）。只给确实需要固定时间的任务设 time；今天的 time 必须晚于 now，并留出缓冲。
    2. reschedule（改期）：处理逾期的、没有日期的、以及冲突涉及的待办；不需要动的不要动。带 locked 的待办（重复任务等）不能动。用户在回答里说「可以放一放」的往后推，说「重要」的往前放。每条给不超过 20 字的理由。
    3. 冲突：同一天时间重叠的，错开时间或改到别的日子；每天不要超过 perDay 件，也别超过约 7 小时的工作量（标题里的「约 Xh」是时间估计）。优先级高、逾期久、用户强调的先排。
    4. 拆解（newTasks）：用户写的「想做的事」，以及他在回答里说要拆的大任务，拆成具体可执行的小任务：动词开头，标题不超过 25 字，每个 15~90 分钟（minutes），要有 date，需要时有 time，priority 用 0 / 1 / 3 / 5。reason 不超过 20 字。parent 填它来自哪条待办（id，如 t5）或写一个简短的目标名；project 只在匹配 projects 列表里某个关键词时才填。原来的待办保留，不要删除。最多新增 8 个任务。
    5. 不要重复：已经有的待办（同标题同一天）不要再新建。用户没提到的事不要自己编造新任务。
    6.【任务的延续性，必须遵守】有先后顺序的任务属于同一个系列，编号小的必须排在编号大的前面（第 2 章没读完，不能先排第 3 章），同系列同一天最多排一个（每个都很短除外）；已排好的同系列任务看 scheduled 里的日期来衔接。拆解出来的步骤也要按先后顺序排日期。
    7. summary：3~5 句话（不超过 200 字）：先点明他这段时间的目标（OKR 的 O），再说今天的重点、你做了哪些调整、冲突怎么处理、哪几天比较满。语气温和，不责备。
    8. topThree：今天最重要的 1~3 件事（MIT，来自今天要做的待办或新拆出的任务；用户在「优先级」回答里选的优先）。每条 {"ref":"待办 id（如 t5）或新任务标题","why":"为什么今天要做（不超过 24 字）"}。其余的事今天不用硬扛。
    9. 方法：新拆出的任务遵循 GTD 的「下一步行动」——以具体的动词开头、一看就知道怎么动手；按 OKR 的思路让每个任务服务于用户说的目标；重要但不紧急的事要安排进日程，而不是一直拖着；今天排满不超过 perDay 件，并给至少 20% 的缓冲时间；有精力要求的重活排在用户精力好的时段。
    10. conflicts：对输入里 conflicts 的每一条，给一句处理方式：{"text":"冲突描述","resolution":"怎么处理的（不超过 40 字）"}；没有冲突就给空数组。

    只输出一个 JSON 对象，不要其他文字：
    {"summary":"","topThree":[{"ref":"t5","why":""}],"conflicts":[{"text":"","resolution":""}],"reschedule":[{"id":"t3","date":"yyyy-MM-dd","time":null,"reason":""}],"newTasks":[{"title":"","date":"yyyy-MM-dd","time":null,"minutes":30,"priority":3,"reason":"","parent":"t5","project":""}]}
    """

    private static let wk = ["日", "一", "二", "三", "四", "五", "六"]

    private static func weekday(_ d: String) -> String {
        guard let date = Day.parse(d) else { return "" }
        return "周" + wk[(Day.cal.component(.weekday, from: date) - 1) % 7]
    }

    /// 汇总上下文。[extra] 是弹窗里额外读到的未来 4 周待办；[movable] 不为 nil 时，只有这些待办能改期（项目内规划）
    @MainActor
    static func context(model: AppModel, extra: [DidaTask], movable: Set<String>?) -> PlanContext {
        let today = Day.today()
        let ov = model.overview
        var all: [DidaTask] = []
        var seen = Set<String>()
        for t in (ov?.overdue ?? []) + (ov?.upcoming ?? []) + extra + (ov?.undated ?? []) where !t.done && !SjzTasks.owns(t.id) && seen.insert(t.id).inserted {
            all.append(t)
        }
        let overdue = all.filter { ($0.date ?? "9999") < today }.sorted { ($0.date ?? "") < ($1.date ?? "") }.prefix(25)
        let upcoming = all.filter { ($0.date ?? "") >= today && $0.date != nil }
            .sorted { ($0.date ?? "", $0.time ?? "99") < ($1.date ?? "", $1.time ?? "99") }.prefix(80)
        let undated = all.filter { $0.date == nil }.prefix(20)
        let picked = Array(overdue) + Array(upcoming) + Array(undated)

        var idMap: [String: DidaTask] = [:]
        var sidOf: [String: String] = [:]
        var locked = Set<String>()
        var list: [[String: Any]] = []
        for (i, t) in picked.enumerated() {
            let sid = "t\(i + 1)"
            idMap[sid] = t
            sidOf[t.id] = sid
            var o: [String: Any] = ["id": sid, "title": t.cleanTitle]
            o["priority"] = t.priority >= 5 ? "高" : (t.priority >= 3 ? "中" : (t.priority >= 1 ? "低" : "无"))
            if let d = t.date {
                o["date"] = d
                if d < today { o["overdueDays"] = max(1, Day.diff(d, today)) }
            } else { o["date"] = "无" }
            if let tm = t.time { o["time"] = tm }
            if let p = ov?.projectName(t.projectId) { o["list"] = p }
            let note = t.content.trimmed.replacingOccurrences(of: "\n", with: " ")
            if !note.isEmpty { o["note"] = String(note.prefix(60)) }
            let isLocked = !(t.repeatFlag ?? "").isEmpty || (movable.map { !$0.contains(t.id) } ?? false)
            if isLocked { o["locked"] = true; locked.insert(t.id) }
            list.append(o)
        }

        let conflicts = ConflictFinder.find(tasks: picked, today: today)

        // 已排好的任务逐条给标题（最多 120 条），AI 才能看出「第 5 章排在哪天」
        var scheduled: [[String: Any]] = []
        for t in upcoming.prefix(120) { scheduled.append(["date": t.date ?? "", "title": String(t.cleanTitle.prefix(34))]) }

        let projects: [[String: Any]] = model.projects.filter { $0.projectStatus != .PAUSED }.prefix(10).map { p in
            var o: [String: Any] = ["keyword": p.keyword, "status": p.projectStatus.label]
            if let nx = p.next?.trimmed, !nx.isEmpty { o["next"] = String(nx.prefix(50)) }
            return o
        }
        let notes = model.timeline.prefix(6).map { String($0.title.prefix(30)) }
        let c = Day.cal.dateComponents([.hour, .minute], from: Date())

        let payload: [String: Any] = [
            "today": today, "weekday": weekday(today), "now": String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0),
            "perDay": 6, "tasks": list, "scheduled": scheduled,
            "conflicts": conflicts.map(\.text), "projects": projects, "recentNotes": notes,
        ]
        return PlanContext(
            today: today, tasks: picked, idMap: idMap, sidOf: sidOf, locked: locked, conflicts: conflicts,
            overdueCount: overdue.count, todayCount: upcoming.filter { $0.date == today }.count, undatedCount: undated.count,
            payload: payload
        )
    }

    private static func json(_ obj: [String: Any]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
    }

    /// 第一步：根据数据提几个问题
    @MainActor
    static func ask(model: AppModel, ctx: PlanContext, scopeName: String?) async throws -> AIAsk {
        guard model.hasLlm else { throw LlmError(message: "还没配置 AI 模型，请先到「设置 → AI 模型」填写接口地址和 Key。") }
        var payload = ctx.payload
        if let scopeName { payload["scope"] = "只规划项目「\(scopeName)」里的待办" }
        let reply = try await model.llm.chatJSON(system: askSystem, user: try json(payload), timeout: 90)
        guard let obj = LlmClient.extractJSON(reply) else { throw LlmError(message: "AI 返回的内容格式不对，请重试") }
        let qs: [AIQuestion] = ((obj["questions"] as? [[String: Any]]) ?? []).prefix(5).enumerated().compactMap { i, q in
            guard let text = (q["text"] as? String)?.trimmed, !text.isEmpty else { return nil }
            let opts = ((q["options"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmed }.filter { !$0.isEmpty }
            return AIQuestion(
                id: "q\(i + 1)", stage: (q["stage"] as? String)?.trimmed ?? "", text: text,
                options: Array(opts.prefix(4)), multi: (q["multi"] as? Bool) ?? false
            )
        }
        guard !qs.isEmpty else { throw LlmError(message: "AI 没有给出问题，请重试") }
        return AIAsk(intro: (obj["intro"] as? String)?.trimmed ?? "", questions: qs)
    }

    /// 第二步：结合回答生成计划
    @MainActor
    static func plan(model: AppModel, ctx: PlanContext, goals: String, answers: [(question: String, answer: String)], scopeName: String?) async throws -> AIDayPlan {
        guard model.hasLlm else { throw LlmError(message: "还没配置 AI 模型，请先到「设置 → AI 模型」填写接口地址和 Key。") }
        var payload = ctx.payload
        payload["userGoals"] = goals.trimmed
        payload["answers"] = answers.filter { !$0.answer.trimmed.isEmpty }.map { ["question": $0.question, "answer": $0.answer] }
        if let scopeName { payload["scope"] = "只规划项目「\(scopeName)」；新任务的 project 填「\(scopeName)」" }
        let reply = try await model.llm.chatJSON(system: planSystem, user: try json(payload), timeout: 150)
        guard let obj = LlmClient.extractJSON(reply) else { throw LlmError(message: "AI 返回的计划格式不对，请重试") }
        let today = ctx.today

        func validDate(_ s: String?) -> String? {
            guard let s, Day.parse(s) != nil, s >= today else { return nil }
            return s
        }
        func validTime(_ s: Any?) -> String? {
            guard let s = (s as? String)?.trimmed, s.count == 5, let m = ConflictFinderTime.minutes(s) else { return nil }
            return m < 24 * 60 ? s : nil
        }

        // 改期
        var items: [AIPlanResult.Item] = []
        var times: [String: String] = [:]
        var seen = Set<String>()
        for r in (obj["reschedule"] as? [[String: Any]]) ?? [] {
            guard let sid = r["id"] as? String, let t = ctx.idMap[sid], !ctx.locked.contains(t.id),
                  let date = validDate(r["date"] as? String), seen.insert(t.id).inserted else { continue }
            if t.date == date && (validTime(r["time"]) ?? t.time) == t.time { continue }
            items.append(.init(id: t.id, date: date, reason: (r["reason"] as? String)?.trimmed ?? ""))
            if let tm = validTime(r["time"]) { times[t.id] = tm }
        }
        let movedTasks = items.compactMap { i in ctx.tasks.first { $0.id == i.id } }
        let busy = ctx.tasks.filter { t in t.date != nil && !items.contains { $0.id == t.id } }
        items = AIPlanner.enforceSeriesOrder(items, tasks: movedTasks, busy: busy)
        let moves: [AIMove] = items.compactMap { i in
            guard let t = ctx.tasks.first(where: { $0.id == i.id }) else { return nil }
            // 没给时间：原来有时间、日期没过期的保留时间点，其余当全天
            let time = times[t.id] ?? ((t.date ?? "") >= today ? t.time : nil)
            return AIMove(task: t, date: i.date, time: time, reason: i.reason)
        }

        // 新任务
        let projectKeys = Set(model.projects.map(\.keyword))
        var existingKeys = Set(ctx.tasks.map { ($0.date ?? "") + "|" + $0.cleanTitle })
        var newTasks: [AINewTask] = []
        for n in (obj["newTasks"] as? [[String: Any]]) ?? [] {
            guard newTasks.count < 8, let title = (n["title"] as? String)?.trimmed, !title.isEmpty,
                  let date = validDate(n["date"] as? String) else { continue }
            let short = String(title.prefix(40))
            guard existingKeys.insert(date + "|" + short).inserted else { continue }
            let pr = (n["priority"] as? Int) ?? Int((n["priority"] as? Double) ?? 0)
            let mins = (n["minutes"] as? Int) ?? Int((n["minutes"] as? Double) ?? 30)
            var parent = (n["parent"] as? String)?.trimmed
            if let p = parent, let t = ctx.idMap[p] { parent = t.cleanTitle }
            var project = (n["project"] as? String)?.trimmed
            if let scopeName { project = scopeName } else if let p = project, !projectKeys.contains(p) { project = nil }
            newTasks.append(AINewTask(
                title: short, date: date, time: validTime(n["time"]),
                priority: [0, 1, 3, 5].contains(pr) ? pr : 0, minutes: min(max(mins, 10), 180),
                reason: (n["reason"] as? String)?.trimmed ?? "", parent: parent?.nonEmpty, project: project?.nonEmpty
            ))
        }

        let fixes: [AIConflictFix] = ((obj["conflicts"] as? [[String: Any]]) ?? []).compactMap { c in
            guard let text = (c["text"] as? String)?.trimmed, !text.isEmpty else { return nil }
            return AIConflictFix(text: text, resolution: (c["resolution"] as? String)?.trimmed ?? "")
        }
        let summary = (obj["summary"] as? String)?.trimmed ?? ""
        let top: [String] = ((obj["topThree"] as? [[String: Any]]) ?? []).prefix(3).compactMap { t in
            guard var ref = (t["ref"] as? String)?.trimmed, !ref.isEmpty else { return nil }
            if let task = ctx.idMap[ref] { ref = task.cleanTitle }
            let why = (t["why"] as? String)?.trimmed ?? ""
            return why.isEmpty ? ref : ref + "｜" + why
        }
        guard !moves.isEmpty || !newTasks.isEmpty || !summary.isEmpty else { throw LlmError(message: "AI 没有给出可用的计划，请重试") }
        return AIDayPlan(summary: summary, topThree: top, conflicts: fixes, moves: moves, newTasks: newTasks)
    }
}

private enum ConflictFinderTime {
    static func minutes(_ hhmm: String) -> Int? {
        let p = hhmm.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), m < 60 else { return nil }
        return h * 60 + m
    }
}

// MARK: - 应用

extension AppModel {
    /// 把 AI 计划里勾选的改期 + 新任务写进滴答
    func applyAIPlan(moves: [AIMove], newTasks: [AINewTask]) async {
        guard hasDida else { showNotice("先到「设置」填写滴答清单的凭证"); return }
        var moved = 0
        if !moves.isEmpty {
            await applyMoves(moves.map { ($0.task, $0.date, $0.time) })
            moved = moves.count
        }
        var ok = 0, failed = 0
        for n in newTasks {
            var notes = ["预计 \(n.minutes) 分钟"]
            if let p = n.parent { notes.append("来自：" + p) }
            if !n.reason.isEmpty { notes.append(n.reason) }
            do {
                _ = try await dida.createTask(
                    title: n.title, date: n.date, time: n.time, priority: n.priority,
                    content: "AI 规划：" + notes.joined(separator: " · "), tags: n.project.map { [$0] } ?? []
                )
                ok += 1
            } catch { failed += 1 }
        }
        invalidateHistory()
        var parts: [String] = []
        if moved > 0 { parts.append("改期 \(moved) 件") }
        if ok > 0 { parts.append("新建 \(ok) 个任务") }
        if failed > 0 { parts.append("\(failed) 个新任务没建成功") }
        showNotice("已应用 AI 规划：" + parts.joined(separator: "，"))
        await loadOverview(silent: true)
        if section == .calendar { await loadCalendar() }
    }
}
