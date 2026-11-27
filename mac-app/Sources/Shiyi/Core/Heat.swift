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

    /// 项目的进展：普通项目（搁置的不算）各自相关任务的完成率（完成 ÷ 完成 + 未完成），加上在办审计项目的阶段进度，一起求平均；没有可算的数据为 nil
    var projectProgress: Double? {
        let all = projectRatios
        return all.isEmpty ? nil : all.reduce(0, +) / Double(all.count)
    }

    /// 每个项目一个完成率：普通项目（算得慢，按版本缓存）在前，审计项目（几个而已，每次现算）在后
    var projectRatios: [Double] { plainProjectRatios + auditStages.map(\.ratio) }

    private var plainProjectRatios: [Double] {
        if let memo = projectProgressMemo { return memo }
        var each: [Double] = []
        if let ov = overview {
            let open = ov.overdue + ov.upcoming + ov.undated
            each = projects.filter { $0.projectStatus != .PAUSED }.compactMap { p in
                let o = open.filter { p.matches($0.title, tags: $0.tags) }.count
                let d = ov.done.filter { p.matches($0.title, tags: $0.tags) }.count
                return o + d == 0 ? nil : Double(d) / Double(o + d)
            }
        }
        projectProgressMemo = each
        return each
    }

    /// 在办（活跃）审计项目走到了第几个阶段（审前准备 → 审计实施 → 报告与处理 → 整改跟踪）；阶段进度 = 已走完的阶段数 ÷ 4
    var auditStages: [AuditStage] {
        guard hasSjz else { return [] }
        let order = ["preparation", "implementation", "reporting", "rectification"]
        let labels = ["preparation": "审前准备", "implementation": "审计实施", "reporting": "报告与处理", "rectification": "整改跟踪"]
        return (sjzOverview?.projects ?? []).compactMap { p in
            guard let ph = p.phase, let i = order.firstIndex(of: ph) else { return nil }
            if let s = p.status, !s.isEmpty, s != "in_progress" { return nil }
            // 非活跃的项目（没有未完成任务、也不是当前钉住的）不算：和「项目」页一致
            guard p.open > 0 || p.name == sjzPin.project else { return nil }
            let label = (p.phaseLabel?.isEmpty == false ? p.phaseLabel : nil) ?? labels[ph] ?? ph
            return AuditStage(name: p.name, title: p.title.isEmpty ? p.name : p.title, label: label, index: i, total: order.count)
        }
    }

    /// 今天在拾忆里完成的结审任务数（完成后任务就从待办里消失了，待办环要把它们算作「已完成」）
    var sjzDoneToday: Int {
        guard hasSjz else { return 0 }
        return (sjzOverview?.projects ?? []).reduce(0) { $0 + SjzDaily.get($1.name, "done") }
    }
}

/// 一个在办审计项目的阶段进度
struct AuditStage {
    let name: String
    let title: String
    /// 当前阶段名
    let label: String
    /// 当前阶段的序号（0 起）
    let index: Int
    let total: Int
    var ratio: Double { Double(index) / Double(total) }
}
