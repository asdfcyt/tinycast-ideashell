import Foundation

let heatWeeks = 26

extension AppModel {
    /// 热力图第一天（最近 [heatWeeks] 周里最早那周的周一）和最后一天（今天）
    static func heatRange(weeks: Int = heatWeeks, today: Date = Date()) -> (first: Date, last: Date) {
        let cal = Day.cal
        let t = Day.startOfDay(today)
        let offset = (cal.component(.weekday, from: t) + 5) % 7
        let weekStart = cal.date(byAdding: .day, value: -offset, to: t) ?? t
        return (cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: weekStart) ?? weekStart, t)
    }

    /// 读近半年每天 Daily Note 的条数（过去的日子 DailyService 里有缓存，结果也存本机，下次启动先显示）
    func loadHeat(ifStale: Bool = true) async {
        guard hasIdeashell else { heat = [:]; return }
        let key = Day.today()
        if ifStale, isFresh("heat", key: key, within: 1800) { return }
        guard beginLoad("heat", ifStale: ifStale) else { return }
        defer { endLoad("heat") }
        heatLoading = true
        defer { heatLoading = false }
        let r = Self.heatRange()
        do {
            let days = try await daily.days(from: Day.string(r.first), to: Day.string(r.last))
            var counts: [String: Int] = [:]
            for (d, day) in days where !day.entries.isEmpty { counts[d] = day.entries.count }
            heat = counts
            Self.writeCache("heat.json", counts)
            stamp("heat", key: key)
        } catch {
            // 读失败就沿用上次的，不打扰
        }
    }

    /// 项目（搁置的不算）的进展：各项目相关任务的完成率（完成 ÷ 完成 + 未完成）求平均；没有可算的数据为 nil
    var projectProgress: Double? {
        if let memo = projectProgressMemo { return memo }
        let v = computeProjectProgress()
        projectProgressMemo = .some(v)
        return v
    }

    private func computeProjectProgress() -> Double? {
        guard let ov = overview else { return nil }
        let open = ov.overdue + ov.upcoming + ov.undated
        let each: [Double] = projects.filter { $0.projectStatus != .PAUSED }.compactMap { p in
            let o = open.filter { p.matches($0.title, tags: $0.tags) }.count
            let d = ov.done.filter { p.matches($0.title, tags: $0.tags) }.count
            return o + d == 0 ? nil : Double(d) / Double(o + d)
        }
        return each.isEmpty ? nil : each.reduce(0, +) / Double(each.count)
    }
}
