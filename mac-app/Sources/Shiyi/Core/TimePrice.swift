import Foundation

/*
 * 洞察页「时间价格」的数据层。思路来自《每周工作 4 小时》（ELI 有效时薪、80/20 时间审计）和《要钱还是要生活》（真实时薪）：
 * - 时间价格：有效时薪（ELI）= 净收入 ÷ 实际专注工作的时间（做得越快越值钱）；在岗时薪 = 净收入 ÷ (有薪 + 无薪工时)，是坐在岗位上的底价，两者之差就是浪费；设置只存本机；
 * - 工作时间：结审里的任务一律算工作；其他待办带「工作」标签才算工作；其余是普通时间；
 * - 专注账本：每次专注结束都记一笔（本机），洞察按它统计时间花在哪、值多少钱。
 */

// MARK: - 时间价格

struct TimePrice: Equatable {
    var monthlyPay: Double = 0
    var paidHoursPerWeek: Double = 40
    var unpaidHoursPerWeek: Double = 0
    var monthlyJobCost: Double = 0

    static let weeksPerMonth = 52.0 / 12.0

    var configured: Bool { monthlyPay > 0 }
    private var paidMonthlyHours: Double { paidHoursPerWeek * Self.weeksPerMonth }
    var totalMonthlyHours: Double { (paidHoursPerWeek + max(unpaidHoursPerWeek, 0)) * Self.weeksPerMonth }

    /// 名义时薪：月收入 ÷ 有薪工时
    var nominalHourly: Double { paidMonthlyHours > 0 ? monthlyPay / paidMonthlyHours : 0 }
    /// 在岗时薪（底价）：扣掉为工作付出的花费，再把无薪的通勤 / 加班算进工时。按「坐在岗位上的时间」算，摸鱼的时间也算在里面
    var realHourly: Double { totalMonthlyHours > 0 ? max(monthlyPay - max(monthlyJobCost, 0), 0) / totalMonthlyHours : 0 }

    /// 一段时间（天数）里的净收入：月收入 − 工作花费，按天折算
    func periodNet(days: Int) -> Double { max(monthlyPay - max(monthlyJobCost, 0), 0) * Double(days) * 12 / 365 }
    /// 一段时间里「在岗」的分钟数（按每周有薪工时折算）
    func onDutyMinutes(days: Int) -> Double { max(paidHoursPerWeek, 0) * 60 * Double(days) / 7 }

    /// 有效时薪（《每周工作 4 小时》的 ELI）：净收入 ÷ 真正专注工作的时间。同样的收入，花的时间越少越值钱。工作专注不足 30 分钟时算不出来
    func effectiveHourly(workMin: Int, days: Int) -> Double? {
        guard configured, workMin >= 30 else { return nil }
        return periodNet(days: days) / (Double(workMin) / 60)
    }

    static func money(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1000 { return "¥" + String(format: "%.0f", v).groupedDigits }
        if a >= 100 { return "¥" + String(format: "%.0f", v) }
        if a >= 1 { return "¥" + String(format: "%.1f", v) }
        return "¥" + String(format: "%.2f", v)
    }
}

private extension String {
    /// 千分位：12345 → 12,345
    var groupedDigits: String {
        var out = "", n = 0
        let neg = hasPrefix("-")
        for ch in (neg ? String(dropFirst()) : self).reversed() {
            if n > 0, n % 3 == 0 { out.append(",") }
            out.append(ch); n += 1
        }
        return (neg ? "-" : "") + String(out.reversed())
    }
}

// MARK: - 专注账本

struct FocusLedgerEntry: Codable, Hashable {
    var startMs: Int64
    var endMs: Int64
    var title: String
    var project: String
    /// 工作时间（结审任务，或带「工作」标签的待办）；false = 普通时间
    var work: Bool

    var minutes: Int { max(0, Int((endMs - startMs) / 60_000)) }
    var startDate: Date { Date(timeIntervalSince1970: Double(startMs) / 1000) }
    var day: String { Day.string(startDate) }
}

@MainActor
final class FocusLedger {
    static let shared = FocusLedger()

    private struct Store: Codable {
        var items: [FocusLedgerEntry] = []
        var seeded = false
    }

    private(set) var items: [FocusLedgerEntry] = []
    private var seeded = false
    private static let file = "focus-ledger.json"

    private init() {
        if let s = LocalStore.read(Self.file), let d = s.data(using: .utf8), let st = try? JSONDecoder().decode(Store.self, from: d) {
            items = st.items
            seeded = st.seeded
        }
    }

    private func save() {
        let st = Store(items: items, seeded: seeded)
        if let d = try? JSONEncoder().encode(st), let s = String(data: d, encoding: .utf8) { LocalStore.write(Self.file, s) }
    }

    private func key(_ e: FocusLedgerEntry) -> Int64 { e.startMs / 60_000 }

    func add(_ e: FocusLedgerEntry) {
        guard e.minutes >= 1 else { return }
        let k = key(e)
        if items.contains(where: { key($0) == k }) { return }
        items.append(e)
        items.sort { $0.startMs < $1.startMs }
        save()
    }

    /// 一次专注结束时记账
    func record(startMs: Int64, endMs: Int64, taskId: String?, title: String) {
        let c = AppModel.current?.focusClass(taskId: taskId, title: title) ?? (work: false, project: title.isEmpty ? "自由专注" : "其他")
        add(FocusLedgerEntry(startMs: startMs, endMs: endMs, title: title, project: c.project, work: c.work))
    }

    /// 第一次打开洞察时，把已有的专注（本机小票、手机备份里的专注记录）补进账本，之后只靠实时记账
    func seedIfNeeded(model: AppModel) {
        guard !seeded else { return }
        seeded = true
        var known = Set(items.map(key))
        var added: [FocusLedgerEntry] = []
        func put(_ e: FocusLedgerEntry) {
            guard e.minutes >= 1, known.insert(key(e)).inserted else { return }
            added.append(e)
        }
        for c in TicketStore.shared.items where c.minutes > 0 {
            let end = Int64(c.postedAt.timeIntervalSince1970 * 1000)
            let cls = model.focusClass(taskId: nil, title: c.title)
            put(FocusLedgerEntry(startMs: end - Int64(c.minutes) * 60_000, endMs: end, title: c.title, project: cls.project, work: cls.work))
        }
        for f in model.backup?.workspace.focusLog ?? [] {
            let title = f.title ?? f.project
            var cls = model.focusClass(taskId: f.taskId, title: f.title ?? "")
            if cls.project == "自由专注" || cls.project == "其他" { cls.project = f.project.isEmpty ? "其他" : f.project }
            put(FocusLedgerEntry(startMs: f.startMs, endMs: f.endMs, title: title, project: cls.project, work: cls.work))
        }
        items = (items + added).sorted { $0.startMs < $1.startMs }
        save()
    }
}

// MARK: - 工作 / 普通时间的归类

extension AppModel {
    /// 「工作」标签的名字（洞察页设置里可改）
    var workTag: String {
        let t = (UserDefaults.standard.string(forKey: "tp.workTag") ?? "").trimmed
        return t.isEmpty ? "工作" : t
    }

    /// 结审里的任务一律是工作；其他待办带「工作」标签才算
    func isWorkTask(_ t: DidaTask) -> Bool {
        if SjzTasks.owns(t.id) { return true }
        let tag = workTag
        return t.tags.contains { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) == tag }
    }

    /// 一次专注属于工作还是普通时间，以及显示在哪个「项目」下
    func focusClass(taskId: String?, title: String) -> (work: Bool, project: String) {
        if let id = taskId, let p = SjzTasks.parse(id) {
            let t = sjzOverview?.projects.first { $0.name == p.project }?.title ?? p.project
            return (true, "结审 · " + t)
        }
        var task: DidaTask?
        if let id = taskId { task = localTask(id) }
        if task == nil, !title.isEmpty, let ov = overview {
            for list in [ov.overdue, ov.upcoming, ov.undated, ov.done] {
                if let t = list.first(where: { $0.cleanTitle == title || $0.title == title }) { task = t; break }
            }
        }
        guard let t = task else { return (false, title.isEmpty ? "自由专注" : "其他") }
        let name = overview?.projectName(t.projectId) ?? (SjzTasks.owns(t.id) ? "结审" : "滴答清单")
        return (isWorkTask(t), name)
    }
}

// MARK: - 统计

struct WorkStats {
    struct DayMin: Identifiable {
        let day: String
        var work = 0
        var normal = 0
        var id: String { day }
    }

    struct Item: Identifiable {
        let name: String
        let work: Bool
        var minutes = 0
        var sessions = 0
        var id: String { (work ? "w:" : "n:") + name }
    }

    var days = 7
    var workMin = 0
    var normalMin = 0
    var sessions = 0
    var daily: [DayMin] = []
    /// 按项目（清单）汇总，时间多的在前
    var projects: [Item] = []
    /// 按任务汇总，时间多的在前（做 80/20 用）
    var tasks: [Item] = []
    /// 按开始的小时汇总的专注分钟
    var hours = [Int](repeating: 0, count: 24)
    var goldenStart: Int?
    /// 80/20：前 20% 的任务占了多少时间（任务不足 4 个时为 nil）
    var paretoShare: Double?
    var paretoTop = 0

    var totalMin: Int { workMin + normalMin }
    var avgSessionMin: Int { sessions > 0 ? Int((Double(totalMin) / Double(sessions)).rounded()) : 0 }

    /// `ending`：统计区间的最后一天（默认今天；算上一期时传上一期的最后一天）
    static func compute(days: Int, entries: [FocusLedgerEntry], ending: String? = nil) -> WorkStats {
        let today = ending ?? Day.today()
        let first = Day.add(today, days: -(days - 1))
        var out = WorkStats(days: days)
        out.daily = (0 ..< days).map { DayMin(day: Day.add(first, days: $0)) }
        var dayIndex: [String: Int] = [:]
        for (i, d) in out.daily.enumerated() { dayIndex[d.day] = i }
        var projBy: [String: Item] = [:]
        var taskBy: [String: Item] = [:]
        var workHours = [Int](repeating: 0, count: 24)

        for e in entries {
            let day = e.day
            guard day >= first, day <= today, let i = dayIndex[day] else { continue }
            let m = e.minutes
            guard m > 0 else { continue }
            out.sessions += 1
            if e.work { out.workMin += m; out.daily[i].work += m; workHours[e.startDate.hourOfDay] += m }
            else { out.normalMin += m; out.daily[i].normal += m }
            out.hours[e.startDate.hourOfDay] += m

            let pk = (e.work ? "w:" : "n:") + e.project
            var p = projBy[pk] ?? Item(name: e.project, work: e.work)
            p.minutes += m; p.sessions += 1
            projBy[pk] = p

            let name = e.title.isEmpty ? "自由专注" : e.title
            let tk = (e.work ? "w:" : "n:") + name
            var t = taskBy[tk] ?? Item(name: name, work: e.work)
            t.minutes += m; t.sessions += 1
            taskBy[tk] = t
        }
        out.projects = projBy.values.sorted { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.name < $1.name }
        out.tasks = taskBy.values.sorted { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.name < $1.name }

        if out.tasks.count >= 4, out.totalMin > 0 {
            let top = max(1, Int((Double(out.tasks.count) * 0.2).rounded(.up)))
            out.paretoTop = top
            out.paretoShare = Double(out.tasks.prefix(top).reduce(0) { $0 + $1.minutes }) / Double(out.totalMin)
        }

        // 黄金时段：优先看工作时间的专注，没有就看全部；连续 3 小时里专注最多的
        let src = workHours.reduce(0, +) >= 60 ? workHours : out.hours
        if src.reduce(0, +) >= 30 {
            var best = -1
            for s in 0 ... 21 {
                let sum = src[s] + src[s + 1] + src[s + 2]
                if sum > best { best = sum; out.goldenStart = s }
            }
        }
        return out
    }
}
