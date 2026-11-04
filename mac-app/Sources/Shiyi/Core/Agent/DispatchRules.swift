import Foundation

// 自动派活规则：到点 / 滴答任务带标签 → 自动派给命令行 Agent。
// 原则（来自 agent-autoloop）：默认全部关闭、默认只读；指令和资料分离；同一件事不重复派；规则派出的活不会再触发规则；
// 默认安静——跑完没有要你拍板的事就不弹验收卡，只留在「调度」页的记录里。

struct DispatchRule: Codable, Identifiable, Hashable {
    enum Trigger: String, Codable, CaseIterable {
        case daily, workdays, todoTag

        var label: String {
            switch self {
            case .daily: return "每天"
            case .workdays: return "工作日"
            case .todoTag: return "滴答标签"
            }
        }
    }

    /// 定时规则可以带的资料；标签规则固定带「那条任务」
    enum Material: String, Codable, CaseIterable {
        case none, yesterdayDaily, todayDaily, todayTodos

        var label: String {
            switch self {
            case .none: return "不带"
            case .yesterdayDaily: return "昨天的 Daily Note"
            case .todayDaily: return "今天的 Daily Note"
            case .todayTodos: return "今天和逾期的待办"
            }
        }
    }

    var id = UUID()
    var name = ""
    var enabled = false
    var trigger: Trigger = .daily
    /// HH:mm（每天 / 工作日）
    var time = "09:00"
    /// 滴答任务标签（不带 #）
    var tag = "派活"
    var profileId = ""
    var cwd = ""
    var prompt = ""
    var material: Material = .none
    var access: AgentAccess = .read
    /// 每天最多触发几次（防失控）
    var dailyLimit = 3
    var lastAt: Date?
    var lastNote: String?

    var isTimed: Bool { trigger != .todoTag }

    /// 一行小字：什么时候触发 · 谁来干 · 在哪 · 什么权限
    var baseSummary: String {
        var parts: [String] = []
        switch trigger {
        case .daily: parts.append("每天 \(time)")
        case .workdays: parts.append("工作日 \(time)")
        case .todoTag: parts.append("滴答标签 #\(tag)")
        }
        parts.append(DispatchTarget(rawValue: profileId)?.title ?? "目标已不可用")
        if !cwd.isEmpty { parts.append((cwd as NSString).lastPathComponent) }
        parts.append(access.label)
        return parts.joined(separator: " · ")
    }

    var summary: String {
        var parts = [baseSummary]
        if let n = lastNote, !n.isEmpty {
            parts.append(n)
        } else if let t = lastAt {
            parts.append("上次 " + Self.clock(t))
        }
        return parts.joined(separator: " · ")
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M月d日 HH:mm"
        return f.string(from: d)
    }
}

@MainActor
final class DispatchRuleEngine: ObservableObject {
    static let shared = DispatchRuleEngine()

    @Published private(set) var rules: [DispatchRule] = []

    private struct Fired: Codable {
        var key: String
        var rule: UUID
        var day: String
    }

    private var fired: [Fired] = []
    private var started = false
    private var timer: Timer?
    private var busy = false
    /// 定时规则错过了点（拾忆没开）：3 小时内补派，再晚就算了，免得半夜突然开跑
    private static let graceMinutes = 180
    /// 待办提醒（验收卡的「稍后复查」）用的标签：永远不当触发源，规则派出去的活也就不会再引出新活
    static let reminderTag = "调度台"

    // MARK: 持久化

    private static var rulesURL: URL { dir.appendingPathComponent("dispatch-rules.json") }
    private static var firedURL: URL { dir.appendingPathComponent("dispatch-rules-fired.json") }

    private static var dir: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Shiyi", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func start() {
        guard !started else { return }
        started = true
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        if let d = try? Data(contentsOf: Self.rulesURL) { rules = (try? dec.decode([DispatchRule].self, from: d)) ?? [] }
        if let d = try? Data(contentsOf: Self.firedURL) { fired = (try? dec.decode([Fired].self, from: d)) ?? [] }
        let cutoff = Day.add(Day.today(), days: -45)
        fired.removeAll { $0.day < cutoff }
        let t = Timer(timeInterval: 30, repeats: true) { _ in
            Task { @MainActor in DispatchRuleEngine.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            tick()
        }
    }

    private func saveRules() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(rules) { try? d.write(to: Self.rulesURL, options: .atomic) }
    }

    private func saveFired() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(fired) { try? d.write(to: Self.firedURL, options: .atomic) }
    }

    // MARK: 增删改

    func upsert(_ r: DispatchRule) {
        if let i = rules.firstIndex(where: { $0.id == r.id }) { rules[i] = r } else { rules.append(r) }
        saveRules()
        tick()
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        fired.removeAll { $0.rule == id }
        saveRules()
        saveFired()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].enabled = on
        saveRules()
        if on { tick() }
    }

    /// 现在就跑一次（试跑）：不看时间、不占每天的次数
    func runNow(_ id: UUID) {
        guard let r = rules.first(where: { $0.id == id }), let model = AppModel.current else { return }
        Task {
            let material = r.isTimed ? await buildMaterial(r, model) : nil
            if r.isTimed, r.material != .none, material == nil {
                note(r.id, "试跑：没有可带的资料")
                return
            }
            send(r, material: material, tag: "试跑")
        }
    }

    // MARK: 触发

    /// 每 30 秒、拾忆回到前台、待办刷新之后各检查一次
    func tick() {
        guard started, !busy, rules.contains(where: \.enabled), let model = AppModel.current else { return }
        busy = true
        Task {
            await evaluate(model)
            busy = false
        }
    }

    private func evaluate(_ model: AppModel) async {
        let now = Date()
        let day = Day.today()
        for rule in rules where rule.enabled {
            switch rule.trigger {
            case .daily, .workdays:
                guard remaining(rule, day) > 0 else { continue }
                if rule.trigger == .workdays, Calendar.current.isDateInWeekend(now) { continue }
                guard let due = Self.due(rule.time, now), now >= due, now.timeIntervalSince(due) < Double(Self.graceMinutes * 60) else { continue }
                let key = "\(rule.id.uuidString)|\(day)"
                guard !hasFired(key) else { continue }
                record(rule, key, day)
                let material = await buildMaterial(rule, model)
                if rule.material != .none, material == nil {
                    note(rule.id, "今天没有可带的资料，已跳过")
                    continue
                }
                send(rule, material: material, tag: nil)
            case .todoTag:
                guard let ov = model.overview else { continue }
                for t in pendingTagTasks(rule, ov, now) {
                    guard remaining(rule, day) > 0 else { break }
                    let key = Self.taskKey(rule, t)
                    record(rule, key, day)
                    var m = "# " + t.cleanTitle
                    if !t.content.trimmed.isEmpty { m += "\n\n" + t.content.trimmed }
                    if let p = ov.projectName(t.projectId) { m += "\n\n（滴答清单：\(p)）" }
                    send(rule, material: m, tag: nil)
                }
            }
        }
    }

    private static func taskKey(_ rule: DispatchRule, _ t: DidaTask) -> String { "\(rule.id.uuidString)|\(t.id)|\(t.date ?? "-")" }

    /// 带了规则标签、已经到期、还没派过的任务
    private func pendingTagTasks(_ rule: DispatchRule, _ ov: DidaOverview, _ now: Date) -> [DidaTask] {
        let want = Self.norm(rule.tag)
        guard !want.isEmpty, want != Self.norm(Self.reminderTag) else { return [] }
        return (ov.overdue + ov.upcoming + ov.undated).filter { t in
            guard !t.done, Self.isDue(t, now) else { return false }
            let tags = t.tags.map(Self.norm)
            return tags.contains(want) && !tags.contains(Self.norm(Self.reminderTag)) && !hasFired(Self.taskKey(rule, t))
        }
    }

    // MARK: 给界面看的状态

    func firedToday(_ r: DispatchRule) -> Int {
        let day = Day.today()
        return fired.filter { $0.rule == r.id && $0.day == day }.count
    }

    /// 下一次会在什么时候触发（界面上的一行小字）
    func nextText(_ r: DispatchRule) -> String {
        guard r.enabled else { return "已关闭" }
        let now = Date()
        if r.trigger == .todoTag {
            guard let ov = AppModel.current?.overview else { return "等待带 #\(r.tag) 的任务" }
            let n = pendingTagTasks(r, ov, now).count
            return n > 0 ? "\(n) 条任务等着派" : "等待带 #\(r.tag) 的任务"
        }
        let cal = Calendar.current
        for offset in 0...8 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            if r.trigger == .workdays, cal.isDateInWeekend(day) { continue }
            guard let due = Self.due(r.time, day) else { return "时间格式不对" }
            if offset == 0 {
                if hasFired("\(r.id.uuidString)|\(Day.string(now))") { continue }
                if due < now && now.timeIntervalSince(due) >= Double(Self.graceMinutes * 60) { continue }
                if due < now { return "即将补派" }
            }
            switch offset {
            case 0: return "今天 \(r.time)"
            case 1: return "明天 \(r.time)"
            default:
                let f = DateFormatter()
                f.locale = Locale(identifier: "zh_CN")
                f.dateFormat = "EEE"
                return "\(f.string(from: day)) \(r.time)"
            }
        }
        return "—"
    }

    private func remaining(_ r: DispatchRule, _ day: String) -> Int {
        max(r.dailyLimit - fired.filter { $0.rule == r.id && $0.day == day }.count, 0)
    }

    private func hasFired(_ key: String) -> Bool { fired.contains { $0.key == key } }

    private func record(_ r: DispatchRule, _ key: String, _ day: String) {
        fired.append(Fired(key: key, rule: r.id, day: day))
        saveFired()
    }

    private func note(_ id: UUID, _ text: String) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].lastAt = Date()
        rules[i].lastNote = Self.clockNote(text)
        saveRules()
    }

    private static func clockNote(_ s: String) -> String { DispatchRule.clock(Date()) + " " + s }

    /// 排进账本；账本负责并发 / 重试 / 回执。出错（目录没了、命令没装）也记下来，不反复重试
    private func send(_ r: DispatchRule, material: String?, tag: String?) {
        guard let target = DispatchTarget(rawValue: r.profileId), target.isCommand else {
            note(r.id, "没派成：目标已不可用")
            return
        }
        let prompt = r.prompt.trimmed.isEmpty ? "请处理资料，需要我拍板的地方直接问我。" : r.prompt.trimmed
        let origin = "规则·" + (r.name.isEmpty ? "未命名" : r.name)
        if let e = DispatchLedger.shared.enqueue(target: target, prompt: prompt, material: material, cwd: r.cwd, sessionId: nil, origin: origin, access: r.access) {
            note(r.id, "没派成：" + e)
        } else {
            note(r.id, (tag ?? "已派出"))
        }
    }

    // MARK: 资料

    /// 手动派活时「带入上下文」也用这套取数
    func material(_ m: DispatchRule.Material, model: AppModel) async -> String? {
        var r = DispatchRule()
        r.material = m
        return await buildMaterial(r, model)
    }

    private func buildMaterial(_ r: DispatchRule, _ model: AppModel) async -> String? {
        switch r.material {
        case .none:
            return nil
        case .yesterdayDaily, .todayDaily:
            let y = r.material == .todayDaily ? Day.today() : Day.add(Day.today(), days: -1)
            guard let d = try? await model.daily.days(from: y, to: y), let day = d[y] else { return nil }
            let lines = day.entries.filter { !$0.struck }.map { "\($0.time) \($0.text)" }
            return lines.isEmpty ? nil : "# \(y) 的 Daily Note\n\n" + lines.joined(separator: "\n")
        case .todayTodos:
            guard let ov = model.overview else { return nil }
            func line(_ t: DidaTask, _ tag: String) -> String {
                var s = "- [ ] " + t.cleanTitle
                if let p = ov.projectName(t.projectId) { s += "（\(p)）" }
                return s + " " + tag + (t.time.map { " " + $0 } ?? "")
            }
            let late = ov.overdue.map { line($0, "· 已逾期 " + ($0.date ?? "")) }
            let today = ov.todayTasks().map { line($0, "· 今天") }
            let all = late + today
            return all.isEmpty ? nil : "# 待办（\(Day.today())）\n\n" + all.joined(separator: "\n")
        }
    }

    // MARK: 时间

    private static func due(_ hhmm: String, _ now: Date) -> Date? {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: now)
    }

    /// 无日期 = 一加标签就算到期；有日期：今天以前，或今天且时间已到
    private static func isDue(_ t: DidaTask, _ now: Date) -> Bool {
        guard let d = t.date else { return true }
        let today = Day.string(now)
        if d < today { return true }
        if d > today { return false }
        guard let time = t.time, let at = due(time, now) else { return true }
        return now >= at
    }

    private static func norm(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)).lowercased()
    }
}


/// 场景模板：从 agent-autoloop 的「拿来即用」思路改来，只用拾忆自己的数据（Daily Note / 滴答），默认只读、只在回复里给结果
struct DispatchRuleTemplate: Identifiable {
    let id: String
    let title: String
    let icon: String
    let detail: String
    let rule: DispatchRule

    static let all: [DispatchRuleTemplate] = [
        DispatchRuleTemplate(
            id: "morning", title: "每日早报", icon: "sun.max", detail: "每天 8:30，读昨天的 Daily Note，给出今天的早报",
            rule: {
                var r = DispatchRule()
                r.name = "每日早报"
                r.trigger = .daily
                r.time = "08:30"
                r.material = .yesterdayDaily
                r.prompt = "读资料里昨天的记录，写一份今天的早报：昨天做了什么、遗留了什么、今天最该先做的三件事。只在回复里给出，不要改动任何文件。"
                return r
            }()),
        DispatchRuleTemplate(
            id: "todos", title: "待办梳理", icon: "checklist", detail: "工作日 9:00，把今天和逾期的待办排出执行顺序",
            rule: {
                var r = DispatchRule()
                r.name = "待办梳理"
                r.trigger = .workdays
                r.time = "09:00"
                r.material = .todayTodos
                r.prompt = "把资料里的待办按优先级排序，指出可以合并、拆小或今天不该做的，给出今天的执行顺序。只在回复里给出，不要改动任何文件。"
                return r
            }()),
        DispatchRuleTemplate(
            id: "tag", title: "标签派活", icon: "tag", detail: "给滴答任务加「派活」标签，就自动交给 Agent",
            rule: {
                var r = DispatchRule()
                r.name = "滴答标签派活"
                r.trigger = .todoTag
                r.tag = "派活"
                r.prompt = "资料是一条待办任务。按任务的要求处理；不确定的地方在回执里向我提问，不要自己猜。"
                return r
            }()),
        DispatchRuleTemplate(
            id: "evening", title: "晚间复盘", icon: "moon.stars", detail: "每天 21:30，回顾今天的 Daily Note，提炼要点",
            rule: {
                var r = DispatchRule()
                r.name = "晚间复盘"
                r.trigger = .daily
                r.time = "21:30"
                r.material = .todayDaily
                r.prompt = "回顾资料里今天的记录，提炼三个要点，并说明明天最该先做的一件事。只在回复里给出，不要改动任何文件。"
                return r
            }()),
    ]
}
