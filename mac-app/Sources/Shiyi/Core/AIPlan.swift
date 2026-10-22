import Foundation

/// AI 排期：把要排的任务、每天已有的安排、每天上限交给大模型，让它给出每件任务排到哪天和理由，再汇总成一段说明。
/// 只返回方案，不写入滴答；写入前由重新规划弹窗里的「确认应用」决定。
struct AIPlanResult {
    struct Item { let id: String; let date: String; let reason: String }
    var items: [Item]
    var summary: String
    /// AI 没排的（或给了无效日期的）任务数
    var skipped: Int
}

enum AIPlanner {
    private static let system = """
    你是一个靠谱的个人日程助理，帮用户重新安排「逾期」和「还没排日期」的待办。严格按下面的规则输出。

    规则：
    1. 只能把任务排到 today 或之后的日期，绝不排到过去；日期格式 yyyy-MM-dd。
    2. 每天新排进去的任务加上 busy 里该天已有的任务数，不要超过 perDay；超了就顺延到后面最近有空的一天。
    3. 逾期越久、优先级越高的越先排，尽量排在最近的日子；优先级低、没有紧迫性的可以靠后。
    4. 同一天不要把同一个项目的任务堆满，尽量穿插；有「约 Xh」之类的时长信息时，一天的总量别太满。
    5. skipWeekends 为 true 时不要排周六、周日。
    6. 每个任务都要给出一句不超过 20 个字的理由。
    7. 最后用 summary 写 2~4 句话（不超过 120 字）向用户说明整体安排：先处理了什么、哪几天比较满、有什么需要留意的。
    8.【任务的延续性，必须遵守】有先后顺序的任务属于同一个「系列」，不能打乱：
       - 判断：标题里带「第 N 章 / 节 / 讲 / 课 / 篇 / 回 / 周 / 天」「Chapter N」「Part N」「Day N」「上 / 中 / 下」「（1/3）」等序号，并且书名、课程名、标签或项目相同（例如同一本书的各章）。
       - 编号小的必须排在编号大的前面，并且排在更早的日期：第 2 章没读完之前，不能先排第 3 章。同一个系列同一天最多排一个，除非每个都很短（约 30 分钟以内）。
       - 同一个系列里，有的任务在 tasks 里（待重排），有的已经排好在 scheduled 里（有 date 和标题）。排 tasks 里的任务时要看 scheduled：编号更小的已经排在某天，那么编号更大的必须排在那天之后；编号更大的已经排在某天，那么编号更小的必须排在那天之前。
       - 如果某个系列前面的任务没法排进去（比如 perDay 排满了），后面的任务也不要排，不要跳着排。
       - 同一个系列的任务之间尽量保持连续（隔天或隔几天推进），不要把第 1 章排今天、第 2 章排一个月后。
       - 理由里可以写「接着第 N 章」这样的话，让用户一眼看出衔接关系。

    只输出一个 JSON 对象，不要任何其他文字：
    {"plan":[{"id":"任务的 id","date":"yyyy-MM-dd","reason":"理由"}],"summary":"整体说明"}
    """

    static func plan(
        client: LlmClient, tasks: [DidaTask], busy: [DidaTask], perDay: Int, skipWeekends: Bool,
        projectName: (String) -> String?
    ) async throws -> AIPlanResult {
        let today = Day.today()
        let wk = ["日", "一", "二", "三", "四", "五", "六"]
        func weekday(_ d: String) -> String {
            guard let date = Day.parse(d) else { return "" }
            return "周" + wk[(Day.cal.component(.weekday, from: date) - 1) % 7]
        }

        // 任务用 t1、t2… 的短 id，省 token，也避免模型抄错
        var idMap: [String: String] = [:]
        var list: [[String: Any]] = []
        for (i, t) in tasks.enumerated() {
            let sid = "t\(i + 1)"
            idMap[sid] = t.id
            var o: [String: Any] = [
                "id": sid, "title": t.cleanTitle,
                "priority": ["高", "中", "低"][t.priority >= 5 ? 0 : (t.priority >= 3 ? 1 : 2)],
            ]
            if t.priority == 0 { o["priority"] = "无" }
            if let d = t.date {
                o["originalDate"] = d
                if d < today { o["overdueDays"] = max(1, Day.diff(d, today)) }
            } else {
                o["originalDate"] = "无"
            }
            if let p = projectName(t.projectId) { o["project"] = p }
            let note = t.content.trimmed.replacingOccurrences(of: "\n", with: " ")
            if !note.isEmpty { o["note"] = String(note.prefix(80)) }
            list.append(o)
        }

        // 未来 28 天每天已有的任务（只给数量和前几条标题）
        let end = Day.add(today, days: 28)
        var byDay: [String: [DidaTask]] = [:]
        for t in busy { if let d = t.date, d >= today, d <= end { byDay[d, default: []].append(t) } }
        var busyJson: [[String: Any]] = []
        for d in byDay.keys.sorted() {
            let ts = byDay[d] ?? []
            busyJson.append(["date": d, "weekday": weekday(d), "count": ts.count, "titles": ts.prefix(3).map { String($0.cleanTitle.prefix(20)) }])
        }

        // 已经排好的任务逐条给标题（最多 150 条），模型才能看出「第 5 章已经排在哪天」
        var scheduled: [[String: Any]] = []
        for d in byDay.keys.sorted() {
            for t in byDay[d] ?? [] where scheduled.count < 150 {
                scheduled.append(["date": d, "title": String(t.cleanTitle.prefix(36))])
            }
        }

        let payload: [String: Any] = [
            "today": today, "weekday": weekday(today), "perDay": perDay, "skipWeekends": skipWeekends,
            "tasks": list, "busy": busyJson, "scheduled": scheduled,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let reply = try await client.chatJSON(system: system, user: String(data: data, encoding: .utf8) ?? "{}")
        guard let obj = LlmClient.extractJSON(reply), let arr = obj["plan"] as? [[String: Any]] else {
            throw LlmError(message: "AI 返回的排期方案格式不对，请重试")
        }

        var items: [AIPlanResult.Item] = []
        var seen = Set<String>()
        for a in arr {
            guard let sid = a["id"] as? String, let id = idMap[sid], let date = a["date"] as? String,
                  Day.parse(date) != nil, date >= today, seen.insert(id).inserted else { continue }
            if skipWeekends, let d = Day.parse(date), [1, 7].contains(Day.cal.component(.weekday, from: d)) { continue }
            items.append(.init(id: id, date: date, reason: (a["reason"] as? String)?.trimmed ?? ""))
        }
        // 模型偶尔还是会打乱顺序，这里再按系列的先后顺序兜一次底
        items = enforceSeriesOrder(items, tasks: tasks, busy: busy)
        guard !items.isEmpty else { throw LlmError(message: "AI 没有给出可用的排期，请重试") }
        let summary = (obj["summary"] as? String)?.trimmed ?? ""
        return AIPlanResult(items: items, summary: summary, skipped: tasks.count - items.count)
    }

    // MARK: - 系列（第 N 章…）的先后顺序

    /// 同一个系列里编号小的必须不晚于编号大的：
    /// 1. 前面的任务没排上，后面的也不排；
    /// 2. 已经排好的同系列任务（busy）里，编号更小的在更晚的日子，后面的就不能排在它前面；
    /// 3. 其余的，把这批任务拿到的日期按从早到晚重新发给编号从小到大的任务。
    static func enforceSeriesOrder(_ items: [AIPlanResult.Item], tasks: [DidaTask], busy: [DidaTask]) -> [AIPlanResult.Item] {
        var out = items
        var groups: [String: [(task: DidaTask, n: Int)]] = [:]
        for t in tasks { if let s = Series.parse(t) { groups[s.key, default: []].append((t, s.n)) } }
        var busyGroups: [String: [(date: String, n: Int)]] = [:]
        for t in busy where !t.done {
            if let s = Series.parse(t), let d = t.date { busyGroups[s.key, default: []].append((d, s.n)) }
        }

        for (key, members) in groups {
            let sorted = members.sorted { $0.n < $1.n }
            // 1. 前面没排上的，后面的也不排
            var firstMissing: Int?
            for m in sorted where !out.contains(where: { $0.id == m.task.id }) {
                firstMissing = m.n
                break
            }
            if let cut = firstMissing {
                let drop = Set(sorted.filter { $0.n > cut }.map { $0.task.id })
                out.removeAll { drop.contains($0.id) }
            }
            // 2. 编号更小、已经排在某天的同系列任务：后面的不能比它早
            for m in sorted {
                guard let idx = out.firstIndex(where: { $0.id == m.task.id }) else { continue }
                let floor = (busyGroups[key] ?? []).filter { $0.n < m.n }.map(\.date).max()
                if let floor, out[idx].date < floor { out.remove(at: idx) }
            }
            // 3. 日期按编号重新分配
            let planned = sorted.filter { m in out.contains { $0.id == m.task.id } }
            guard planned.count > 1 else { continue }
            let dates = planned.compactMap { m in out.first { $0.id == m.task.id }?.date }.sorted()
            for (m, d) in zip(planned, dates) {
                if let i = out.firstIndex(where: { $0.id == m.task.id }), out[i].date != d {
                    out[i] = .init(id: out[i].id, date: d, reason: out[i].reason + "（按章节顺序调整）")
                }
            }
        }
        return out
    }
}

/// 从标题里认出「第 N 章」这类序号：同一本书 / 课程（标签或项目相同）的同一种单位算一个系列
enum Series {
    private static let unit = "章|节|讲|课|篇|回|集|话|部分|单元|周|卷|册|期"
    private static let cn: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]

    static func parse(_ t: DidaTask) -> (key: String, n: Int)? {
        let title = t.cleanTitle
        let ns = title as NSString
        let patterns = [
            "(.*?)第\\s*([0-9]+|[零一二两三四五六七八九十百]+)\\s*(" + unit + ")",
            "(?i)(.*?)\\b(?:chapter|ch\\.?|lesson|part|day|week|unit|episode|ep\\.?)\\s*([0-9]+)()",
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 3 else { continue }
            let prefix = ns.substring(with: m.range(at: 1)).trimmed
            let num = ns.substring(with: m.range(at: 2))
            let u = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : "x"
            guard let n = number(num) else { continue }
            let scope: String
            if !t.tags.isEmpty {
                scope = t.tags.sorted().joined(separator: ",")
            } else {
                // 没有标签：用前缀（去掉「阅读 / 精读 / 学习」这类动词）加清单区分
                let verbs = ["阅读", "精读", "泛读", "学习", "复习", "预习", "整理", "看", "读", "刷", "做", "完成"]
                var s = prefix
                for v in verbs where s.hasPrefix(v) { s = String(s.dropFirst(v.count)) }
                scope = s.trimmed + "@" + t.projectId
            }
            return (u + "|" + scope, n)
        }
        return nil
    }

    private static func number(_ s: String) -> Int? {
        if let n = Int(s) { return n }
        // 十一 / 二十 / 二十三 / 一百零五
        var total = 0, cur = 0
        for c in s {
            if let d = cn[c] { cur = d }
            else if c == "十" { total += (cur == 0 ? 1 : cur) * 10; cur = 0 }
            else if c == "百" { total += (cur == 0 ? 1 : cur) * 100; cur = 0 }
        }
        total += cur
        return total > 0 ? total : nil
    }
}
