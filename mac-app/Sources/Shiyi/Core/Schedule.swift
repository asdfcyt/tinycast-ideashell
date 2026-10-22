import Foundation

/// 改期 / 推迟 / 自动排期。移植并扩展安卓端 `TodoViewModel` 的 reschedule / rescheduleAll / postponeAll。
/// 本地先改（界面立刻动），再逐个写进滴答，最后静默刷新一次；失败的会在提示里写明。

/// 单条任务的「推迟到」选项
enum SnoozeOption: CaseIterable, Identifiable {
    case hour, tomorrow, dayAfter, weekend, nextMonday

    var id: Self { self }

    var label: String {
        switch self {
        case .hour: return "1 小时后"
        case .tomorrow: return "明天"
        case .dayAfter: return "后天"
        case .weekend: return "本周末"
        case .nextMonday: return "下周一"
        }
    }

    var icon: String {
        switch self {
        case .hour: return "clock"
        case .tomorrow: return "sunrise"
        case .dayAfter: return "calendar"
        case .weekend: return "sun.max"
        case .nextMonday: return "arrow.turn.down.right"
        }
    }
}

/// 自动排期方案里的一项：这条任务排到哪天
struct PlanItem: Identifiable {
    let task: DidaTask
    let date: String
    var id: String { task.id }
}

struct SchedulePlan {
    var items: [PlanItem] = []
    /// 排不下的（超出排期窗口）
    var leftover: [DidaTask] = []
    /// 日期 → 这天原来已经有几件（不含本次排进去的）
    var existing: [String: Int] = [:]

    /// 按日期分组，日期升序
    var byDay: [(date: String, items: [PlanItem])] {
        Dictionary(grouping: items, by: \.date).map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }
}

/// 自动排期的参数
struct ScheduleOptions: Equatable {
    var perDay = 5
    var includeOverdue = true
    var skipWeekends = false
}

enum Scheduler {
    static let horizonDays = 28

    private static func weekday(_ date: String) -> Int {
        guard let d = Day.parse(date) else { return 0 }
        return Day.cal.component(.weekday, from: d)
    }

    static func isWeekend(_ date: String) -> Bool {
        let w = weekday(date)
        return w == 1 || w == 7
    }

    /// 今天起第一个周六（今天是周六就是今天）
    static func nextSaturday(from today: String) -> String {
        var d = today
        for _ in 0 ..< 7 where weekday(d) != 7 { d = Day.add(d, days: 1) }
        return d
    }

    /// 明天起第一个周一
    static func nextMonday(from today: String) -> String {
        var d = Day.add(today, days: 1)
        for _ in 0 ..< 7 where weekday(d) != 2 { d = Day.add(d, days: 1) }
        return d
    }

    static func target(_ option: SnoozeOption, for task: DidaTask, now: Date = Date()) -> (date: String, time: String?) {
        let today = Day.string(now)
        switch option {
        case .hour:
            // 1 小时后，向上取整到 5 分钟
            let t = now.addingTimeInterval(3600)
            let c = Day.cal.dateComponents([.hour, .minute], from: t)
            var m = ((c.minute ?? 0) + 4) / 5 * 5
            var h = c.hour ?? 0
            if m >= 60 { m = 0; h += 1 }
            var date = Day.string(t)
            if h >= 24 { h = 0; date = Day.add(date, days: 1) }
            return (date, String(format: "%02d:%02d", h, m))
        case .tomorrow: return (Day.add(today, days: 1), task.time)
        case .dayAfter: return (Day.add(today, days: 2), task.time)
        case .weekend: return (nextSaturday(from: today), task.time)
        case .nextMonday: return (nextMonday(from: today), task.time)
        }
    }

    /// 自动排期：把 [tasks] 按「优先级高 → 日期早 → 先创建」的顺序，依次放进「每天不超过 perDay 件」的最近一天。
    /// [existing] 是已经有日期、不在本次排期里的任务，用来算每天已有几件。晚上 8 点以后今天不再排。
    static func plan(tasks: [DidaTask], existing: [DidaTask], options: ScheduleOptions, now: Date = Date()) -> SchedulePlan {
        let today = Day.string(now)
        let hour = Day.cal.component(.hour, from: now)
        let first = hour >= 20 ? Day.add(today, days: 1) : today
        let planIds = Set(tasks.map(\.id))
        var load: [String: Int] = [:]
        for t in existing where !t.done && !planIds.contains(t.id) {
            if let d = t.date, d >= today { load[d, default: 0] += 1 }
        }
        var plan = SchedulePlan(existing: load)
        let sorted = tasks.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            let a = $0.date ?? "9999-99-99", b = $1.date ?? "9999-99-99"
            if a != b { return a < b }
            return ($0.createdAt ?? 0) < ($1.createdAt ?? 0)
        }
        let cap = max(options.perDay, 1)
        for t in sorted {
            var placed = false
            for i in 0 ... horizonDays {
                let d = Day.add(first, days: i)
                if options.skipWeekends, isWeekend(d) { continue }
                if load[d, default: 0] < cap {
                    load[d, default: 0] += 1
                    plan.items.append(PlanItem(task: t, date: d))
                    placed = true
                    break
                }
            }
            if !placed { plan.leftover.append(t) }
        }
        return plan
    }
}

extension AppModel {
    /// 能自动排期的任务：没有日期的；[includeOverdue] 时再加上逾期的。重复任务不动。
    func schedulable(includeOverdue: Bool) -> [DidaTask] {
        guard let ov = overview else { return [] }
        return (ov.undated + (includeOverdue ? ov.overdue : [])).filter { ($0.repeatFlag ?? "").isEmpty }
    }

    /// 重新规划里确认后的批量改期
    func applyMoves(_ moves: [(DidaTask, String, String?)]) async {
        await move(moves) { ok, failed in
            failed == 0 ? "已重新安排 \(ok) 件待办" : "已安排 \(ok) 件，有 \(failed) 件没有改成功"
        }
    }

    func snooze(_ task: DidaTask, _ option: SnoozeOption) async {
        let t = Scheduler.target(option, for: task)
        await move([(task, t.date, t.time)]) { ok, _ in
            ok == 1 ? "已推迟到 \(Day.label(t.date))" + (t.time.map { " " + $0 } ?? "") : "推迟失败"
        }
    }

    /// 给没有日期的任务定一天
    func schedule(_ task: DidaTask, on date: String) async {
        await move([(task, date, nil)]) { ok, _ in ok == 1 ? "已安排到 \(Day.label(date))" : "安排失败" }
    }

    /// 一键推迟：把有日期的任务整体往后顺延 [days] 天，原来的时间点保留。
    /// 已逾期的从今天起算（顺延后不会还是逾期）；重复任务和没有日期的不动。
    func postpone(_ tasks: [DidaTask], days: Int) async {
        let today = Day.today()
        let moves: [(DidaTask, String, String?)] = tasks.compactMap { t in
            guard let d = t.date, (t.repeatFlag ?? "").isEmpty else { return nil }
            return (t, Day.add(max(d, today), days: days), t.time)
        }
        guard !moves.isEmpty else { showNotice("没有可以推迟的任务"); return }
        let label = days % 7 == 0 ? "\(days / 7) 周" : "\(days) 天"
        await move(moves) { ok, failed in
            failed == 0 ? "已把 \(ok) 件待办推迟 \(label)" : "已推迟 \(ok) 件，有 \(failed) 件没有改成功"
        }
    }

    /// 把一批任务（通常是全部逾期）改到今天，时间清空
    func moveToToday(_ tasks: [DidaTask]) async {
        let today = Day.today()
        let moves: [(DidaTask, String, String?)] = tasks.filter { ($0.repeatFlag ?? "").isEmpty }.map { ($0, today, nil) }
        guard !moves.isEmpty else { return }
        await move(moves) { ok, failed in
            failed == 0 ? "已把 \(ok) 件改到今天" : "已改 \(ok) 件，有 \(failed) 件没有改成功"
        }
    }

    // MARK: - 内部

    /// 先在本地把任务挪到新日期，再逐个写进滴答，最后静默刷新
    private func move(_ moves: [(DidaTask, String, String?)], message: (_ ok: Int, _ failed: Int) -> String) async {
        guard !moves.isEmpty else { return }
        scheduling = true
        defer { scheduling = false }
        if var ov = overview {
            let today = Day.today()
            for (t, d, tm) in moves {
                ov = ov.withoutTask(t.id)
                var n = t
                n.date = d
                n.time = tm
                if d < today { ov.overdue.append(n) } else { ov.upcoming.append(n) }
            }
            overview = ov
        }
        var ok = 0, failed = 0
        for (t, d, tm) in moves {
            do {
                try await dida.reschedule(t, date: d, time: tm)
                ok += 1
            } catch {
                failed += 1
            }
        }
        invalidateHistory()
        showNotice(message(ok, failed))
        await loadOverview(silent: true)
    }
}
