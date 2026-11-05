import Foundation

// 自动派活规则：到点 / 滴答任务带标签 → 自动派给命令行 Agent。
// 原则（来自 agent-autoloop）：默认全部关闭、默认只读；指令和资料分离；同一件事不重复派；规则派出的活不会再触发规则；
// 默认安静——跑完没有要你拍板的事就不弹验收卡，只留在「调度」页的记录里。

struct DispatchRule: Codable, Identifiable, Hashable {
    enum Trigger: String, Codable, CaseIterable {
        case daily, workdays, weekly, todoTag, noteTag, overdue, sjzDue

        var label: String {
            switch self {
            case .daily: return "每天"
            case .workdays: return "工作日"
            case .weekly: return "每周"
            case .todoTag: return "待办标签"
            case .noteTag: return "笔记标签"
            case .overdue: return "逾期巡检"
            case .sjzDue: return "结审临近截止"
            }
        }
    }

    /// 定时规则可以带的资料；标签规则固定带「那条任务」
    enum Material: String, Codable, CaseIterable {
        case none, yesterdayDaily, todayDaily, weekDaily, todayTodos

        var label: String {
            switch self {
            case .none: return "不带"
            case .yesterdayDaily: return "昨天的 Daily Note"
            case .todayDaily: return "今天的 Daily Note"
            case .weekDaily: return "最近 7 天的 Daily Note"
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
    /// 每周几（Calendar 的 weekday：1 = 周日 … 7 = 周六），只有「每周」用；后加的字段，用可选，老文件照样能读
    var weekday: Int?
    /// 结审任务截止前几天开始派，默认 3
    var leadDays: Int?
    var lastAt: Date?
    var lastNote: String?

    /// 到点才查的（每天 / 工作日 / 每周 / 逾期巡检）；其余是随时盯着数据变化的
    var isTimed: Bool { [.daily, .workdays, .weekly, .overdue].contains(trigger) }
    /// 带标签的（待办 / 笔记）
    var isTagged: Bool { trigger == .todoTag || trigger == .noteTag }
    /// 资料由用户选的；逾期清单由规则自己生成，标签 / 结审规则固定带那条任务或笔记
    var pickMaterial: Bool { trigger == .daily || trigger == .workdays || trigger == .weekly }
    var lead: Int { leadDays ?? 3 }
    var weekdayName: String { Self.weekdayNames[max(0, min(6, (weekday ?? 1) - 1))] }
    static let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    /// 一行小字：什么时候触发 · 谁来干 · 在哪 · 什么权限
    var baseSummary: String {
        var parts: [String] = []
        switch trigger {
        case .daily: parts.append("每天 \(time)")
        case .workdays: parts.append("工作日 \(time)")
        case .weekly: parts.append("每\(weekdayName) \(time)")
        case .todoTag: parts.append("待办标签 #\(tag)")
        case .noteTag: parts.append("笔记标签 #\(tag)")
        case .overdue: parts.append("逾期巡检 \(time)")
        case .sjzDue: parts.append("结审截止前 \(lead) 天")
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
    private var lastPoll = Date.distantPast
    /// 最近一次检查的时间（界面上显示，让人知道它在盯着）
    @Published private(set) var lastCheck: Date?
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
            if r.isTimed, r.pickMaterial ? (r.material != .none && material == nil) : material == nil {
                note(r.id, r.trigger == .overdue ? "试跑：现在没有逾期任务" : "试跑：没有可带的资料")
                return
            }
            send(r, material: material, tag: "试跑", subject: "试跑")
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
        // 盯着数据的规则开着：别干等 5 分钟一次的全局刷新，自己每分钟读一次，在滴答里刚加的标签很快就能认出来
        let enabled = rules.filter(\.enabled)
        if Date().timeIntervalSince(lastPoll) > 55 {
            let needTodos = enabled.contains { [.todoTag, .sjzDue, .overdue].contains($0.trigger) }
            let needNotes = enabled.contains { $0.trigger == .noteTag }
            if needTodos || needNotes {
                lastPoll = Date()
                if needTodos { await model.loadOverview(silent: true) }
                if needNotes { await model.loadTimeline(silent: true) }
            }
        }
        let now = Date()
        let day = Day.today()
        for rule in rules where rule.enabled {
            switch rule.trigger {
            case .daily, .workdays, .weekly, .overdue:
                guard remaining(rule, day) > 0 else { continue }
                if rule.trigger == .workdays, Calendar.current.isDateInWeekend(now) { continue }
                if rule.trigger == .weekly, Calendar.current.component(.weekday, from: now) != (rule.weekday ?? 1) { continue }
                guard let due = Self.due(rule.time, now), now >= due, now.timeIntervalSince(due) < Double(Self.graceMinutes * 60) else { continue }
                // 逾期巡检要读到待办才能判断，没读到先等下一次，不占今天的名额
                if rule.trigger == .overdue, model.overview == nil { continue }
                let key = "\(rule.id.uuidString)|\(day)"
                guard !hasFired(key) else { continue }
                record(rule, key, day)
                let material = await buildMaterial(rule, model)
                if rule.trigger == .overdue, material == nil {
                    note(rule.id, "今天没有逾期，不打扰")
                    continue
                }
                if rule.pickMaterial, rule.material != .none, material == nil {
                    note(rule.id, "今天没有可带的资料，已跳过")
                    continue
                }
                send(rule, material: material, tag: nil, subject: nil)
            case .todoTag, .sjzDue:
                guard let ov = model.overview else { continue }
                for t in pendingTasks(rule, ov, now) {
                    guard remaining(rule, day) > 0 else { break }
                    record(rule, Self.taskKey(rule, t), day)
                    var m = "# " + t.cleanTitle
                    if !t.content.trimmed.isEmpty { m += "\n\n" + t.content.trimmed }
                    if let p = ov.projectName(t.projectId) { m += "\n\n（\(SjzTasks.owns(t.id) ? "" : "滴答清单：")\(p)）" }
                    if let d = t.date { m += "\n\n截止：" + d + (t.time.map { " " + $0 } ?? "") }
                    send(rule, material: m, tag: nil, subject: "任务「\(Self.brief(t.cleanTitle))」")
                }
            case .noteTag:
                for n in pendingNotes(rule, model, now) {
                    guard remaining(rule, day) > 0 else { break }
                    record(rule, Self.noteKey(rule, n), day)
                    var m = "# " + n.title
                    if let d = try? await model.noteDetail(n.id), !d.content.trimmed.isEmpty {
                        m += "\n\n" + d.content.trimmed
                    } else if let t = n.text?.trimmed, !t.isEmpty {
                        m += "\n\n" + t
                    } else if let t = n.summary?.trimmed, !t.isEmpty {
                        m += "\n\n" + t
                    }
                    send(rule, material: m, tag: nil, subject: "笔记「\(Self.brief(n.title))」")
                }
            }
        }
        lastCheck = Date()
    }

    private static func brief(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmed
        return one.count > 18 ? String(one.prefix(18)) + "…" : one
    }

    private static func taskKey(_ rule: DispatchRule, _ t: DidaTask) -> String { "\(rule.id.uuidString)|\(t.id)|\(t.date ?? "-")" }
    private static func noteKey(_ rule: DispatchRule, _ n: NoteInfo) -> String { "\(rule.id.uuidString)|note|\(n.id)" }

    /// 该派还没派的任务：待办标签（带了标签、已到期）/ 结审临近截止（结审任务、截止日在 N 天内）
    private func pendingTasks(_ rule: DispatchRule, _ ov: DidaOverview, _ now: Date) -> [DidaTask] {
        if rule.trigger == .sjzDue {
            let limit = Day.add(Day.string(now), days: rule.lead)
            return (ov.overdue + ov.upcoming).filter { t in
                guard SjzTasks.owns(t.id), !t.done, let d = t.date, d <= limit else { return false }
                return !hasFired(Self.taskKey(rule, t))
            }
        }
        let want = Self.norm(rule.tag)
        guard !want.isEmpty, want != Self.norm(Self.reminderTag) else { return [] }
        return (ov.overdue + ov.upcoming + ov.undated).filter { t in
            guard !t.done, Self.isDue(t, now) else { return false }
            let tags = t.tags.map(Self.norm)
            // 标签没解析出来、但标题里直接写了 #派活 的，也算
            let hit = tags.contains(want) || t.title.lowercased().contains("#" + want)
            return hit && !tags.contains(Self.norm(Self.reminderTag)) && !hasFired(Self.taskKey(rule, t))
        }
    }

    /// 带了规则标签、最近 7 天写的、还没派过的笔记（太老的不翻旧账，免得一开规则就把历史笔记全派一遍）
    private func pendingNotes(_ rule: DispatchRule, _ model: AppModel, _ now: Date) -> [NoteInfo] {
        let want = Self.norm(rule.tag)
        guard !want.isEmpty else { return [] }
        let cutoff = now.addingTimeInterval(-7 * 86400)
        return model.timeline.filter { n in
            guard n.tags.map(Self.norm).contains(want), (n.date ?? now) >= cutoff else { return false }
            return !hasFired(Self.noteKey(rule, n))
        }
    }

    /// 预览：现在会派哪几条（不真派）
    func preview(_ r: DispatchRule) -> String {
        guard let model = AppModel.current else { return "拾忆还没准备好" }
        let now = Date()
        func list(_ titles: [String]) -> String {
            if titles.isEmpty { return "现在没有符合的，等着。" }
            let shown = titles.prefix(8).map { "· " + $0 }.joined(separator: "\n")
            return "现在会派 \(titles.count) 条（每天最多 \(r.dailyLimit) 条）：\n" + shown + (titles.count > 8 ? "\n…" : "")
        }
        switch r.trigger {
        case .todoTag, .sjzDue:
            guard let ov = model.overview else { return "还没读到待办（滴答 / 结审没连上？）" }
            return list(pendingTasks(r, ov, now).map { Self.brief($0.cleanTitle) })
        case .noteTag:
            return list(pendingNotes(r, model, now).map { Self.brief($0.title) })
        case .overdue:
            guard let ov = model.overview else { return "还没读到待办" }
            let od = ov.overdue.filter { !SjzTasks.owns($0.id) }
            if od.isEmpty { return "现在没有逾期（结审任务不计入），到点也不会打扰。" }
            return "现在有 \(od.count) 条逾期，到点会派一轮整理。\n" + od.prefix(6).map { "· " + Self.brief($0.cleanTitle) }.joined(separator: "\n")
        case .daily, .workdays, .weekly:
            return "下一次：" + nextText(r)
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
        if !r.isTimed {
            let n: Int?
            switch r.trigger {
            case .noteTag: n = AppModel.current.map { pendingNotes(r, $0, now).count }
            default: n = AppModel.current?.overview.map { pendingTasks(r, $0, now).count }
            }
            let what = r.trigger == .noteTag ? "笔记" : "任务"
            if let n, n > 0 { return "\(n) 条\(what)等着派" }
            if r.trigger == .sjzDue { return "等结审任务临近截止" }
            return "等待带 #\(r.tag) 的\(what)"
        }
        let cal = Calendar.current
        for offset in 0...14 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            if r.trigger == .workdays, cal.isDateInWeekend(day) { continue }
            if r.trigger == .weekly, cal.component(.weekday, from: day) != (r.weekday ?? 1) { continue }
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
    private func send(_ r: DispatchRule, material: String?, tag: String?, subject: String?) {
        guard let target = DispatchTarget(rawValue: r.profileId), target.isCommand else {
            note(r.id, "没派成：目标已不可用")
            return
        }
        let prompt = r.prompt.trimmed.isEmpty ? "请处理资料，需要我拍板的地方直接问我。" : r.prompt.trimmed
        // 来源写清「哪条规则、因为谁」，详情里一眼能看出为什么派了这条
        let origin = "规则·" + (r.name.isEmpty ? "未命名" : r.name) + (subject.map { " ← " + $0 } ?? "")
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
        if r.trigger == .overdue {
            // 隔离：结审任务不进逾期清单，只有结审临近截止规则、或用户亲手给它打了本地标签才会交给 Agent
            guard let ov = model.overview else { return nil }
            let overdue = ov.overdue.filter { !SjzTasks.owns($0.id) }
            guard !overdue.isEmpty else { return nil }
            let lines = overdue.map { t -> String in
                var s = "- [ ] " + t.cleanTitle
                if let p = ov.projectName(t.projectId) { s += "（\(p)）" }
                return s + " · 已逾期 " + (t.date ?? "")
            }
            return "# 逾期待办（\(Day.today())）\n\n" + lines.joined(separator: "\n")
        }
        switch r.material {
        case .none:
            return nil
        case .yesterdayDaily, .todayDaily:
            let y = r.material == .todayDaily ? Day.today() : Day.add(Day.today(), days: -1)
            guard let d = try? await model.daily.days(from: y, to: y), let day = d[y] else { return nil }
            let lines = day.entries.filter { !$0.struck }.map { "\($0.time) \($0.text)" }
            return lines.isEmpty ? nil : "# \(y) 的 Daily Note\n\n" + lines.joined(separator: "\n")
        case .weekDaily:
            let from = Day.add(Day.today(), days: -6)
            guard let d = try? await model.daily.days(from: from, to: Day.today()) else { return nil }
            var parts: [String] = []
            for k in d.keys.sorted() {
                guard let day = d[k] else { continue }
                let lines = day.entries.filter { !$0.struck }.map { "\($0.time) \($0.text)" }
                if !lines.isEmpty { parts.append("## \(k)\n" + lines.joined(separator: "\n")) }
            }
            return parts.isEmpty ? nil : "# 最近 7 天的 Daily Note\n\n" + parts.joined(separator: "\n\n")
        case .todayTodos:
            guard let ov = model.overview else { return nil }
            func line(_ t: DidaTask, _ tag: String) -> String {
                var s = "- [ ] " + t.cleanTitle
                if let p = ov.projectName(t.projectId) { s += "（\(p)）" }
                return s + " " + tag + (t.time.map { " " + $0 } ?? "")
            }
            // 隔离：结审任务不会自动交给 Agent
            let late = ov.overdue.filter { !SjzTasks.owns($0.id) }.map { line($0, "· 已逾期 " + ($0.date ?? "")) }
            let today = ov.todayTasks().filter { !SjzTasks.owns($0.id) }.map { line($0, "· 今天") }
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
            id: "tag", title: "标签派活", icon: "tag", detail: "给滴答任务（或结审任务）加「派活」标签，就自动交给 Agent",
            rule: {
                var r = DispatchRule()
                r.name = "滴答标签派活"
                r.trigger = .todoTag
                r.tag = "派活"
                r.prompt = "资料是一条待办任务。按任务的要求处理；不确定的地方在回执里向我提问，不要自己猜。"
                return r
            }()),
        DispatchRuleTemplate(
            id: "weekly", title: "每周复盘", icon: "calendar.badge.clock", detail: "每周日 20:00，回顾最近 7 天的 Daily Note，写周复盘",
            rule: {
                var r = DispatchRule()
                r.name = "每周复盘"
                r.trigger = .weekly
                r.weekday = 1
                r.time = "20:00"
                r.material = .weekDaily
                r.prompt = "回顾资料里最近 7 天的记录：做成了什么、卡在哪、重复出现的问题，以及下周最值得做的三件事。只在回复里给出，不要改动任何文件。"
                return r
            }()),
        DispatchRuleTemplate(
            id: "overdue", title: "逾期巡检", icon: "exclamationmark.triangle", detail: "每天 10:00 检查，有逾期待办才派活，给出今天先清哪几件",
            rule: {
                var r = DispatchRule()
                r.name = "逾期巡检"
                r.trigger = .overdue
                r.time = "10:00"
                r.prompt = "资料是已经逾期的待办。按影响和紧迫程度排序，指出哪些可以直接划掉、哪些该改期、哪些今天必须先做，给出具体的处理顺序。只在回复里给出，不要改动任何文件。"
                return r
            }()),
        DispatchRuleTemplate(
            id: "note", title: "笔记标签调研", icon: "lightbulb", detail: "闪念贝壳里的笔记带「调研」标签，就自动展开成调研笔记",
            rule: {
                var r = DispatchRule()
                r.name = "笔记标签调研"
                r.trigger = .noteTag
                r.tag = "调研"
                r.prompt = "资料是我随手记下的一条想法。围绕它做一次调研：要点、可行性、风险和建议的下一步；不确定的地方在回执里向我提问，不要自己猜。只在回复里给出，不要改动任何文件。"
                return r
            }()),
        DispatchRuleTemplate(
            id: "sjzDue", title: "结审临近截止", icon: "checkmark.seal", detail: "结审任务截止前 3 天，自动出风险清单和初稿",
            rule: {
                var r = DispatchRule()
                r.name = "结审临近截止"
                r.trigger = .sjzDue
                r.leadDays = 3
                r.prompt = "资料是一条快到截止日的结审任务。列出做完它还差哪些步骤和风险，并给出能直接使用的初稿或提纲；不确定的地方在回执里向我提问，不要自己猜。只在回复里给出，不要改动任何文件。"
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
