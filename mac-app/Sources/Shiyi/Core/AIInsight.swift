import Foundation

/// AI 洞察（参考 flomo 的「洞察」）：把这段时间的笔记、Daily Note、完成的待办和专注交给 AI，
/// 帮用户看见「这段时间在想什么、有什么变化、哪些值得回头看、接下来可以怎么做」。
struct AIInsight: Codable {
    struct NoteRef: Codable, Hashable, Identifiable {
        let id: String
        let title: String
    }

    struct Theme: Codable, Identifiable {
        var id: String { name }
        let name: String
        let detail: String
        let notes: [NoteRef]
    }

    struct Revisit: Codable, Identifiable {
        var id: String { note.id }
        let note: NoteRef
        let reason: String
    }

    var days: Int
    var madeAt: Date
    var summary: String
    var themes: [Theme]
    var mood: String
    var revisit: [Revisit]
    var suggestions: [String]
    var questions: [String]
    /// 这次分析了多少条笔记 / 完成的待办
    var noteCount: Int
    var doneCount: Int
}

enum AIInsightPlanner {
    private static let system = """
    你是用户的私人「笔记洞察」助手，类似 flomo 的 AI 洞察。你会拿到用户最近一段时间写下的笔记（含 Daily Note 随手记）、完成的待办、专注数据和统计。请像一位细心、不评判的朋友，帮他看见自己。

    请输出：
    1. summary：2~3 句话（不超过 120 字）概括这段时间他在关注什么、整体状态如何。要具体，引用他真正写过的内容，不要空话。
    2. themes：2~5 个反复出现的主题。每个：name（不超过 8 字）、detail（不超过 50 字：具体在想 / 做什么，以及有什么变化或推进）、noteIds（相关笔记的 id，最多 3 个，只能用输入里给的 n1、n2…）。
    3. mood：一句话（不超过 50 字）观察情绪、精力或节奏的变化。只依据文字里的线索；看不出来就写「从文字里看不太出来」；不要下诊断，不要贴标签。
    4. revisit：值得回头再看的 1~3 条笔记（想法没收尾、有延展价值、前后想法有出入等）。每个：noteId、reason（不超过 30 字）。
    5. suggestions：1~3 条具体、小而可执行的建议（每条不超过 40 字），和他写的内容、待办直接相关。
    6. questions：1~2 个引发思考的问题（每个不超过 30 字），像朋友随口一问，不说教。

    原则：语气温和、不责备、不制造焦虑；没写过的事不要编造；信息太少时宁可少说（themes 可以只给 1~2 个）；不要照抄统计数字，要说统计背后的意思。

    只输出一个 JSON 对象，不要其他文字：
    {"summary":"","themes":[{"name":"","detail":"","noteIds":["n1"]}],"mood":"","revisit":[{"noteId":"n1","reason":""}],"suggestions":[""],"questions":[""]}
    """

    @MainActor
    static func generate(model: AppModel, days: Int) async throws -> AIInsight {
        guard model.hasLlm else { throw LlmError(message: "还没配置 AI 模型，请先到「设置 → AI 模型」填写接口地址和 Key。") }
        let today = Day.today()
        let from = Day.add(today, days: -(days - 1))

        // 笔记：最多 70 条，按时间从早到晚，用 n1、n2… 的短 id
        var notes: [NoteInfo] = []
        if model.hasIdeashell {
            let start = Day.startOfDay(Day.parse(from) ?? Date())
            let r = try await model.ideashell.notesInRange(start, Date().addingTimeInterval(120))
            notes = r.notes.filter { !BackupService.isBackupNote($0) }.sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
        }
        var done: [DidaTask] = []
        if model.hasDida { done = (try? await model.dida.completedInRange(from, today)) ?? [] }
        guard !notes.isEmpty || !done.isEmpty else { throw LlmError(message: "这段时间还没有笔记或完成的待办，没法分析") }

        let picked = Array(notes.suffix(70))
        var idMap: [String: NoteInfo] = [:]
        let notesJson: [[String: Any]] = picked.enumerated().map { i, n in
            let sid = "n\(i + 1)"
            idMap[sid] = n
            var o: [String: Any] = ["id": sid, "title": n.title]
            if let c = n.createdAt { o["time"] = String(NoteTime.day(c) ?? "") + " " + (NoteTime.clock(c) ?? "") }
            let body = (n.summary ?? n.text ?? "").trimmed.replacingOccurrences(of: "\n", with: " ")
            if !body.isEmpty && body != n.title { o["text"] = String(body.prefix(160)) }
            let tags = n.tags.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }.filter { !$0.isEmpty }
            if !tags.isEmpty { o["tags"] = tags }
            return o
        }
        let doneJson: [[String: Any]] = done.sorted { ($0.completedDate ?? .distantPast) < ($1.completedDate ?? .distantPast) }
            .suffix(50).map { t in
                var o: [String: Any] = ["title": t.cleanTitle]
                if let d = t.completedDate { o["day"] = Day.string(d) }
                if t.priority >= 5 { o["priority"] = "高" }
                return o
            }

        var stats: [String: Any] = ["days": days, "notes": notes.count, "doneTasks": done.count]
        if let r = model.review, r.days == days {
            stats["activeDays"] = r.activeDays
            stats["streak"] = r.streak
            if let p = r.peakLabel { stats["peakHours"] = p }
            stats["topTags"] = r.topTags.prefix(6).map { "\($0.tag)×\($0.count)" }
            stats["focusMinutes"] = r.focusTotalMin
            if let p = r.prev { stats["previousPeriod"] = ["notes": p.notes, "doneTasks": p.done, "focusMinutes": p.focusMin, "activeDays": p.activeDays] }
            stats["onTimeDone"] = r.onTime
            stats["lateDone"] = r.lateDone
        }
        if let o = model.overview { stats["overdueNow"] = o.overdue.count }

        let payload: [String: Any] = ["range": "\(from) ~ \(today)", "stats": stats, "notes": notesJson, "completedTasks": doneJson]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let reply = try await model.llm.chatJSON(system: system, user: String(data: data, encoding: .utf8) ?? "{}", timeout: 120)
        guard let obj = LlmClient.extractJSON(reply) else { throw LlmError(message: "AI 返回的内容格式不对，请重试") }

        func ref(_ id: String?) -> AIInsight.NoteRef? {
            guard let id, let n = idMap[id] else { return nil }
            return .init(id: n.id, title: n.title)
        }
        func strings(_ k: String) -> [String] { (obj[k] as? [Any])?.compactMap { ($0 as? String)?.trimmed }.filter { !$0.isEmpty } ?? [] }

        let summary = (obj["summary"] as? String)?.trimmed ?? ""
        guard !summary.isEmpty else { throw LlmError(message: "AI 没有给出分析，请重试") }
        let themes: [AIInsight.Theme] = ((obj["themes"] as? [[String: Any]]) ?? []).prefix(5).compactMap { t in
            guard let name = (t["name"] as? String)?.trimmed, !name.isEmpty else { return nil }
            var seen = Set<String>()
            let refs = ((t["noteIds"] as? [Any]) ?? []).compactMap { ref($0 as? String) }.filter { seen.insert($0.id).inserted }.prefix(3)
            return .init(name: name, detail: (t["detail"] as? String)?.trimmed ?? "", notes: Array(refs))
        }
        var seenRevisit = Set<String>()
        let revisit: [AIInsight.Revisit] = ((obj["revisit"] as? [[String: Any]]) ?? []).prefix(3).compactMap { r in
            guard let n = ref(r["noteId"] as? String), seenRevisit.insert(n.id).inserted else { return nil }
            return .init(note: n, reason: (r["reason"] as? String)?.trimmed ?? "")
        }
        return AIInsight(
            days: days, madeAt: Date(), summary: summary, themes: themes,
            mood: (obj["mood"] as? String)?.trimmed ?? "", revisit: revisit,
            suggestions: Array(strings("suggestions").prefix(3)), questions: Array(strings("questions").prefix(2)),
            noteCount: notes.count, doneCount: done.count
        )
    }
}

extension AppModel {
    func loadAIInsights() {
        guard aiInsights.isEmpty, let json = LocalStore.read("ai-insight.json"), let d = json.data(using: .utf8),
              let m = try? JSONDecoder().decode([String: AIInsight].self, from: d) else { return }
        aiInsights = Dictionary(uniqueKeysWithValues: m.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    /// 生成当前范围的 AI 洞察；结果存在本机，下次进来直接显示
    func generateAIInsight() async {
        guard !aiInsightLoading else { return }
        let days = reviewDays
        aiInsightLoading = true
        aiInsightError = nil
        defer { aiInsightLoading = false }
        do {
            let r = try await AIInsightPlanner.generate(model: self, days: days)
            aiInsights[days] = r
            let store = Dictionary(uniqueKeysWithValues: aiInsights.map { (String($0.key), $0.value) })
            if let d = try? JSONEncoder().encode(store), let text = String(data: d, encoding: .utf8) {
                LocalStore.write("ai-insight.json", text)
            }
        } catch {
            aiInsightError = error.localizedDescription
        }
    }
}
