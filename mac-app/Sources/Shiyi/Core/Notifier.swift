import AppKit
import Foundation
import UserNotifications

/// 通知开关（设置页的「通知」卡片用 @AppStorage 读写同一批键）
enum NotifyPrefs {
    static func register() {
        UserDefaults.standard.register(defaults: [
            "notify.focus": true,    // 专注 / 休息：结束、还剩 5 分钟、暂停太久
            "notify.goal": true,     // 今日专注目标达成
            "notify.due": true,      // 待办到点
            "notify.lead": 10,       // 提前几分钟再提醒一次（0 = 不提前）
            "notify.digest": true,   // 早间简报 + 晚间收尾
            "notify.overdue": true,  // 逾期提醒
            "notify.sjz": true,      // 结审提醒：调研完成、任务到期、待复核
        ])
    }

    static func on(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
}

/// 系统通知：
/// - 专注：番茄完成 / 休息结束 / 还剩 5 分钟 / 暂停太久 / 今日目标达成（FocusStore 里发）
/// - 待办：到点提醒、提前提醒、早间简报、晚间收尾、逾期提醒（待办刷新后重新排一遍，应用退出后也会响）
/// 应用在前台时也显示横幅（默认前台不显示）。
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()
    private var syncTask: Task<Void, Never>?
    private var setupDone = false

    func setup() {
        guard !setupDone else { return }
        setupDone = true
        NotifyPrefs.register()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    // MARK: - 发送

    /// 立刻发一条（相同 id 会替换上一条）
    nonisolated static func post(id: String, title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    /// `secs` 秒之后发一条
    nonisolated static func schedule(id: String, title: String, body: String, after secs: TimeInterval) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let t = UNTimeIntervalNotificationTrigger(timeInterval: max(secs, 1), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: t))
    }

    nonisolated static func cancel(_ ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// 设置页的「发送测试通知」
    func sendTest() {
        setup()
        Self.post(id: "shiyi.test", title: "拾忆", body: "通知正常。到点的待办、专注结束都会这样提醒你。")
    }

    // MARK: - 待办提醒

    /// 待办变化后调用：稍等一下（合并连续的刷新）再把待办相关的通知整体重排
    func syncTodos(_ ov: DidaOverview?) {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.rebuildTodos(ov)
        }
    }

    private func at(_ day: String, _ time: String) -> Date? {
        let p = time.split(separator: ":").compactMap { Int($0) }
        guard p.count >= 2, let d = Day.parse(day) else { return nil }
        return Day.cal.date(bySettingHour: p[0], minute: p[1], second: 0, of: d)
    }

    private func request(_ id: String, _ title: String, _ body: String, _ date: Date) -> UNNotificationRequest {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let comps = Day.cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return UNNotificationRequest(identifier: id, content: c, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
    }

    private func rebuildTodos(_ ov: DidaOverview?) async {
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("shiyi.todo.") })
        guard let ov, !(NotifyPrefs.on("notify.due") == false && NotifyPrefs.on("notify.digest") == false && NotifyPrefs.on("notify.overdue") == false) else { return }

        let now = Date()
        let today = Day.today()
        let cal = Day.cal
        var reqs: [(Date, UNNotificationRequest)] = []
        func add(_ r: UNNotificationRequest, _ d: Date) { reqs.append((d, r)) }
        func project(_ t: DidaTask) -> String { ov.projectName(t.projectId).map { " · " + $0 } ?? "" }

        // 1) 到点 / 提前提醒（只排最近 3 天有具体时间的）
        if NotifyPrefs.on("notify.due") {
            let lead = UserDefaults.standard.integer(forKey: "notify.lead")
            for t in ov.upcoming where !t.done {
                guard let d = t.date, d <= Day.add(today, days: 2), let tm = t.time, let when = at(d, tm) else { continue }
                if when > now { add(request("shiyi.todo.due.\(t.id)", "待办到点了", t.cleanTitle + project(t), when), when) }
                let early = when.addingTimeInterval(-Double(lead) * 60)
                if lead > 0, early > now { add(request("shiyi.todo.lead.\(t.id)", "\(lead) 分钟后：\(t.cleanTitle)", "\(tm) 开始" + project(t), early), early) }
            }
        }

        func next(_ hour: Int, _ minute: Int) -> (Date, String) {
            let t = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
            return t > now ? (t, today) : (cal.date(byAdding: .day, value: 1, to: t) ?? t, Day.add(today, days: 1))
        }

        // 2) 早间简报（8:30）：当天的待办 + 逾期
        if NotifyPrefs.on("notify.digest") {
            let (when, day) = next(8, 30)
            let n = ov.upcoming.filter { $0.date == day }.count
            let late = day == today ? ov.overdue.count : ov.overdue.count + ov.upcoming.filter { ($0.date ?? "") <= today }.count
            if n + late > 0 {
                var body = "\(n) 件待办"
                if late > 0 { body += "，\(late) 件逾期" }
                if let first = ov.upcoming.filter({ $0.date == day }).sorted(by: { ($0.time ?? "99") < ($1.time ?? "99") }).first {
                    body += "。最早：" + (first.time.map { $0 + " " } ?? "") + first.cleanTitle
                }
                add(request("shiyi.todo.morning", day == today ? "早上好，今天的安排" : "明天的安排", body, when), when)
            }
            // 3) 晚间收尾（21:00）：今天还剩几件
            let (eve, eveDay) = next(21, 0)
            if eveDay == today {
                let left = ov.upcoming.filter { $0.date == today }.count + ov.overdue.count
                if left > 0 { add(request("shiyi.todo.evening", "今天还有 \(left) 件没完成", "要不要在拾忆里「重新规划」，把它们改到明天？", eve), eve) }
            }
        }

        // 4) 逾期提醒（10:00）：点名最久的两件
        if NotifyPrefs.on("notify.overdue"), !ov.overdue.isEmpty {
            let (when, _) = next(10, 0)
            let top = ov.overdue.sorted { ($0.date ?? "") < ($1.date ?? "") }.prefix(2).map(\.cleanTitle).joined(separator: "、")
            add(request("shiyi.todo.overdue", "有 \(ov.overdue.count) 件逾期", top + (ov.overdue.count > 2 ? " 等" : "") + "。可以一键重新规划。", when), when)
        }

        // 系统最多同时排 64 条：按时间留最近的 50 条
        for (_, r) in reqs.sorted(by: { $0.0 < $1.0 }).prefix(50) {
            try? await center.add(r)
        }
    }

    // MARK: - 资料清单到期提醒

    /// 已发出、还没收回的资料清单：到「要求提供日期」前一天、当天、过了一天（还没收回）的 9:00 各提醒一次。
    /// 收回后它就不在列表里了，重排时自然取消。已经过了 9:00 的当天 / 逾期提醒，补一条 10 秒后的（每条只补一次）
    func syncDatalists(_ list: [(project: String, title: String, item: SjzOutstanding)]) async {
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("shiyi.sjzlist.") })
        guard NotifyPrefs.on("notify.sjz") else { return }
        let ud = UserDefaults.standard
        var told = Set(ud.stringArray(forKey: "notify.sjzlist.told") ?? [])
        let now = Date()
        let cal = Day.cal
        var reqs: [(Date, UNNotificationRequest)] = []
        for (_, ptitle, it) in list where it.kind == "data_request" {
            guard let due = Day.parse(it.dueAt), let nineDue = cal.date(bySettingHour: 9, minute: 0, second: 0, of: due) else { continue }
            let name = [it.no, it.matter.isEmpty ? it.title : it.matter].filter { !$0.isEmpty }.joined(separator: " ")
            let who = it.unit.isEmpty ? "" : "向 \(it.unit) 要的"
            let plan: [(String, Date, String, String)] = [
                ("before", cal.date(byAdding: .day, value: -1, to: nineDue) ?? nineDue, "资料清单明天到期", "\(who)\(name)（\(ptitle)）明天要收回"),
                ("day", nineDue, "资料清单今天到期", "\(who)\(name)（\(ptitle)）今天要收回"),
                ("late", cal.date(byAdding: .day, value: 1, to: nineDue) ?? nineDue, "资料清单已逾期", "\(who)\(name)（\(ptitle)）过了要求提供日期，还没收回"),
            ]
            for (tag, when, title, body) in plan {
                let id = "shiyi.sjzlist.\(tag).\(it.path)"
                if when > now {
                    reqs.append((when, request(id, title, body, when)))
                } else if cal.isDate(when, inSameDayAs: now) {
                    let key = "\(tag)|\(it.path)|\(it.dueAt)"
                    if !told.contains(key) {
                        told.insert(key)
                        Self.schedule(id: id, title: title, body: body, after: 10)
                    }
                }
            }
        }
        ud.set(Array(told.suffix(200)), forKey: "notify.sjzlist.told")
        for (_, r) in reqs.sorted(by: { $0.0 < $1.0 }).prefix(12) { try? await center.add(r) }
    }
}
