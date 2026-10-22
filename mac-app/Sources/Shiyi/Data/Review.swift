import Foundation

struct DayCount: Identifiable, Codable {
    let day: String
    let notes: Int
    let done: Int
    var id: String { day }
    var total: Int { notes + done }
}

struct TagCount: Identifiable, Codable {
    let tag: String
    let count: Int
    var id: String { tag }
}

struct HourCount: Identifiable, Codable {
    let hour: Int
    let count: Int
    var id: Int { hour }
}

struct FocusDay: Identifiable, Codable {
    let day: String
    let minutes: Int
    var id: String { day }
}

/// 一段时间的汇总（用来和上一个同样长度的时间段比较）
struct PeriodTotals: Codable {
    var notes = 0
    var done = 0
    var focusMin = 0
    var activeDays = 0
}

struct WeekdayStat: Identifiable, Codable {
    /// 0 = 周一 … 6 = 周日
    let index: Int
    let total: Int
    let occurrences: Int
    var id: Int { index }
    var avg: Double { occurrences > 0 ? Double(total) / Double(occurrences) : 0 }
    var label: String { ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][index] }
    var short: String { ["一", "二", "三", "四", "五", "六", "日"][index] }
}

struct HourSplit: Identifiable, Codable {
    let hour: Int
    let notes: Int
    let done: Int
    var id: Int { hour }
}

struct ProjectStat: Identifiable, Codable {
    let keyword: String
    var notes = 0
    var done = 0
    var focusMin = 0
    var id: String { keyword }
    var total: Int { notes + done }
}

struct FocusStats: Codable {
    var sessions = 0
    var avgMin = 0
    var longestMin = 0
    var bestDay: String?
    var bestDayMin = 0
}

/// 回顾：由「时间范围内的笔记」+「完成的待办」+「备份里的专注记录」算出的几条发现
struct ReviewData: Codable {
    var days: Int
    var counts: [DayCount]
    var totalNotes: Int
    var totalDone: Int
    var activeDays: Int
    var streak: Int
    var breakDay: String?
    var hours: [HourCount]
    var peakStart: Int?
    var topTags: [TagCount]
    var onTime: Int
    var lateDone: Int
    var focus: [FocusDay]
    var focusTotalMin: Int
    var truncated: Bool
    var todoError: String?
    /// 上一个同样长度的时间段（后台补读，读到之前为 nil）
    var prev: PeriodTotals?
    var hoursSplit: [HourSplit] = []
    var weekdays: [WeekdayStat] = []
    var bestDay: DayCount?
    var longestStreak = 0
    var projects: [ProjectStat] = []
    var focusStats = FocusStats()
    /// 完成待办按优先级：下标 0 无 / 1 低 / 2 中 / 3 高
    var donePriority = [0, 0, 0, 0]
    /// 专注按开始的小时（分钟数）
    var focusHours = [Int](repeating: 0, count: 24)
    /// 最长一段没有任何记录的连续天数
    var longestGap = 0

    var peakLabel: String? {
        guard let s = peakStart else { return nil }
        return "\(s)–\(s + 2) 点"
    }

    var peakVerb: String {
        guard let s = peakStart else { return "记录" }
        if s >= 19 { return "收尾一天" }
        if s <= 10 { return "开始一天" }
        return "记录"
    }

    static func compute(
        days: Int,
        notes: [NoteInfo],
        done: [DidaTask],
        focusLog: [FocusLogEntry],
        projects: [Project] = [],
        truncated: Bool,
        todoError: String?
    ) -> ReviewData {
        let today = Day.today()
        let dayList = (0 ..< days).map { Day.add(today, days: -(days - 1 - $0)) }
        let first = dayList.first ?? today

        var noteBy: [String: Int] = [:]
        var doneBy: [String: Int] = [:]
        var hours = [Int](repeating: 0, count: 24)
        var hoursN = [Int](repeating: 0, count: 24)
        var hoursD = [Int](repeating: 0, count: 24)
        var projBy: [String: ProjectStat] = [:]
        for p in projects { projBy[p.keyword] = ProjectStat(keyword: p.keyword) }
        var tagBy: [String: Int] = [:]

        for n in notes {
            guard let d = n.date, let day = n.day, day >= first, day <= today else { continue }
            noteBy[day, default: 0] += 1
            hours[d.hourOfDay] += 1
            hoursN[d.hourOfDay] += 1
            let body = n.title + " " + (n.text ?? n.summary ?? "")
            for p in projects where p.matches(body, tags: n.tags) { projBy[p.keyword]?.notes += 1 }
            for t in n.tags {
                let tag = t.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                if !tag.isEmpty && tag != BackupService.tag { tagBy[tag, default: 0] += 1 }
            }
        }

        var onTime = 0
        var late = 0
        var totalDone = 0
        var donePri = [0, 0, 0, 0]
        for t in done {
            guard let when = t.completedDate else { continue }
            let day = Day.string(when)
            guard day >= first, day <= today else { continue }
            doneBy[day, default: 0] += 1
            hours[when.hourOfDay] += 1
            hoursD[when.hourOfDay] += 1
            for p in projects where p.matches(t.title, tags: t.tags) { projBy[p.keyword]?.done += 1 }
            totalDone += 1
            donePri[t.priority >= 5 ? 3 : (t.priority >= 3 ? 2 : (t.priority >= 1 ? 1 : 0))] += 1
            if let planned = t.date { if day <= planned { onTime += 1 } else { late += 1 } }
        }

        let counts = dayList.map { DayCount(day: $0, notes: noteBy[$0] ?? 0, done: doneBy[$0] ?? 0) }
        let active = counts.filter { $0.total > 0 }.count

        // 连续：今天还没记时从昨天往回数
        var streak = 0
        var idx = counts.count - 1
        if idx >= 0, counts[idx].total == 0 { idx -= 1 }
        while idx >= 0, counts[idx].total > 0 { streak += 1; idx -= 1 }
        let breakDay = idx >= 0 ? counts[idx].day : nil

        // 连续 3 小时的高峰窗口
        var peak: Int?
        if hours.reduce(0, +) >= 6 {
            var best = -1
            for s in 0 ... 21 {
                let sum = hours[s] + hours[s + 1] + hours[s + 2]
                if sum > best { best = sum; peak = s }
            }
        }

        let tags = tagBy.map { TagCount(tag: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }

        var focusBy: [String: Int] = [:]
        var fs = FocusStats()
        var focusTotal = 0
        var focusHours = [Int](repeating: 0, count: 24)
        for f in focusLog {
            let day = Day.string(f.startDate)
            guard day >= first && day <= today else { continue }
            focusBy[day, default: 0] += f.minutes
            focusHours[f.startDate.hourOfDay] += f.minutes
            fs.sessions += 1
            focusTotal += f.minutes
            fs.longestMin = max(fs.longestMin, f.minutes)
            let key = f.project.lowercased()
            if let k = projBy.keys.first(where: { $0.lowercased() == key }) { projBy[k]?.focusMin += f.minutes }
        }
        fs.avgMin = fs.sessions > 0 ? Int((Double(focusTotal) / Double(fs.sessions)).rounded()) : 0
        if let b = focusBy.max(by: { $0.value < $1.value }), b.value > 0 { fs.bestDay = b.key; fs.bestDayMin = b.value }
        let focus = dayList.map { FocusDay(day: $0, minutes: focusBy[$0] ?? 0) }

        // 星期分布
        var wTotal = [Int](repeating: 0, count: 7)
        var wOcc = [Int](repeating: 0, count: 7)
        for c in counts {
            guard let d = Day.parse(c.day) else { continue }
            let w = (Day.cal.component(.weekday, from: d) + 5) % 7
            wTotal[w] += c.total
            wOcc[w] += 1
        }
        // 最长连续
        var longest = 0, run = 0
        var gap = 0, longestGap = 0
        for c in counts {
            if c.total > 0 { run += 1; longest = max(longest, run); gap = 0 }
            else { run = 0; gap += 1; longestGap = max(longestGap, gap) }
        }

        var out = ReviewData(
            days: days,
            counts: counts,
            totalNotes: noteBy.values.reduce(0, +),
            totalDone: totalDone,
            activeDays: active,
            streak: streak,
            breakDay: breakDay,
            hours: hours.enumerated().map { HourCount(hour: $0.offset, count: $0.element) },
            peakStart: peak,
            topTags: Array(tags.prefix(10)),
            onTime: onTime,
            lateDone: late,
            focus: focus,
            focusTotalMin: focus.reduce(0) { $0 + $1.minutes },
            truncated: truncated,
            todoError: todoError
        )
        out.hoursSplit = (0 ..< 24).map { HourSplit(hour: $0, notes: hoursN[$0], done: hoursD[$0]) }
        out.weekdays = (0 ..< 7).map { WeekdayStat(index: $0, total: wTotal[$0], occurrences: wOcc[$0]) }
        out.bestDay = counts.max(by: { $0.total < $1.total }).flatMap { $0.total > 0 ? $0 : nil }
        out.longestStreak = longest
        out.longestGap = longestGap
        out.donePriority = donePri
        out.focusHours = focusHours
        out.projects = projBy.values.filter { $0.total + $0.focusMin > 0 }
            .sorted { ($0.total * 10 + $0.focusMin / 6) > ($1.total * 10 + $1.focusMin / 6) }
        out.projects = Array(out.projects.prefix(5))
        out.focusStats = fs
        return out
    }

    /// 某一段时间的汇总（比较用）
    static func totals(from: String, to: String, notes: [NoteInfo], done: [DidaTask], focusLog: [FocusLogEntry]) -> PeriodTotals {
        var t = PeriodTotals()
        var active = Set<String>()
        for n in notes {
            guard let day = n.day, day >= from, day <= to else { continue }
            t.notes += 1
            active.insert(day)
        }
        for d in done {
            guard let when = d.completedDate else { continue }
            let day = Day.string(when)
            guard day >= from, day <= to else { continue }
            t.done += 1
            active.insert(day)
        }
        for f in focusLog {
            let day = Day.string(f.startDate)
            if day >= from && day <= to { t.focusMin += f.minutes }
        }
        t.activeDays = active.count
        return t
    }
}
