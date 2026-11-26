import Foundation

/*
 * 「工作节奏」：从第一性原理看自己的时间。
 *   可支配的自由时间 = 总时间 − 把「固定工作」做完所需的时间。
 * 固定工作的量是定的（目标：每周 N 天、每天 g 小时专注），所以自由时间只能靠两件事变多：
 *   1. 做得更快（效率）：压缩做完固定工作所需的时间；
 *   2. 做得更早（前置）：趁一周的前几天、一天里精力最好的上午做完，后面的时间才真正属于自己。
 * 依据：帕金森定律（工作会膨胀到占满给它的时间，所以期限越短越好）、《每周工作 4 小时》（80/20，只做最重要的）、
 * Cal Newport 的「固定日程生产力」（先定好下班时间，再倒推怎么做完）、多数人的专注力在上午最好。
 * 这里只看专注账本里的「工作」专注；上班 / 下班时间用来算倒计时，放假用法定节假日表。
 */

struct WorkPace {
    enum Phase { case off, before, working, after }

    struct Countdown {
        var name: String
        /// 还有几天（明天 = 1）
        var days: Int
        /// 连休几天
        var length: Int
    }

    struct Insight: Identifiable {
        let id = UUID()
        var icon: String
        var text: String
        var good: Bool
    }

    /// 本周每一天（周一起）：做了多少、是不是自己的工作日，画图用
    struct WeekDay: Identifiable {
        let id: Int
        var label: String
        var work: Int
        var quota: Bool
        var isToday: Bool
        var future: Bool
    }

    /// 今天的一段工作专注（从当天几点几分起，持续多少分钟），画时间轴用
    struct Block: Identifiable {
        let id = UUID()
        var start: Int
        var len: Int
    }

    var phase: Phase = .off
    var startMin = 0
    var endMin = 0
    var weekDays: [WeekDay] = []
    var todayBlocks: [Block] = []
    var minutesToStart = 0
    var minutesToOff = 0
    /// 今天的班上了多少（0...1）
    var dayProgress = 0.0
    var nowMin = 0

    // 目标
    var goalMin = 0
    var workdayCount = 0

    // 今天
    var personalToday = false
    var todayMin = 0
    var todayMorningMin = 0

    // 本周
    var weekQuotaMin = 0
    var weekDoneMin = 0
    /// 本周按「前置」应该已经做完的分钟（之前的工作日各做满目标；今天上午内线性爬升，过了中午算做满）
    var weekExpectedMin = 0
    /// 今天之后本周还剩几个工作日
    var weekDaysLeft = 0

    // 近期习惯
    /// 近 14 天里有专注的工作日，平均每天用了多少分钟
    var avgDayMin: Int?
    /// 近 14 天工作专注里，中午前开始的占比
    var morningShare: Double?
    /// 近 4 周里，前半周（前一半工作日）做完的占比
    var earlyShare: Double?

    // 倒计时
    /// 休息日时：几天后上班
    var daysToWork = 0
    var nextOff: Countdown?
    var nextHoliday: Countdown?

    var insights: [Insight] = []

    static let noon = 12 * 60

    // MARK: 日历

    /// 官方日历：法定假 / 调休表优先，没有就按周六周日休息
    static func isOff(_ day: String, _ h: [String: HolidayEntry]) -> Bool {
        if let e = h[day] { return e.off }
        guard let d = Day.parse(day) else { return false }
        let wd = Day.cal.component(.weekday, from: d)
        return wd == 1 || wd == 7
    }

    static func fmt(_ m: Int) -> String {
        if m < 60 { return "\(max(m, 0)) 分钟" }
        return m % 60 == 0 ? "\(m / 60) 小时" : "\(m / 60) 小时 \(m % 60) 分"
    }

    static func clock(_ m: Int) -> String {
        m < 60 ? "\(max(m, 0))m" : (m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h\(m % 60)m")
    }

    // MARK: 计算

    static func compute(price: TimePrice, entries: [FocusLedgerEntry], holidays h: [String: HolidayEntry],
                        startHour: Double, endHour: Double, now: Date = Date()) -> WorkPace {
        var p = WorkPace()
        let today = Day.string(now)
        let comp = Day.cal.dateComponents([.hour, .minute], from: now)
        let nowMin = (comp.hour ?? 0) * 60 + (comp.minute ?? 0)
        p.nowMin = nowMin
        let s = Int((startHour * 60).rounded())
        var e = Int((endHour * 60).rounded())
        if e <= s { e = s + 8 * 60 }
        p.startMin = s
        p.endMin = e

        // 今天在岗到哪一步
        let offToday = isOff(today, h)
        if offToday { p.phase = .off }
        else if nowMin < s { p.phase = .before; p.minutesToStart = s - nowMin }
        else if nowMin < e { p.phase = .working; p.minutesToOff = e - nowMin; p.dayProgress = Double(nowMin - s) / Double(e - s) }
        else { p.phase = .after; p.dayProgress = 1 }

        // 放假倒计时
        func add(_ i: Int) -> String { Day.add(today, days: i) }
        var i = 1
        if offToday { while i < 400, isOff(add(i), h) { i += 1 }; p.daysToWork = i }
        func runLength(from start: Int) -> Int {
            var n = 0
            while n < 30, isOff(add(start + n), h) { n += 1 }
            return n
        }
        if !offToday {
            var k = 1
            while k < 400, !isOff(add(k), h) { k += 1 }
            if k < 400 {
                let name = h[add(k)].map { $0.name.isEmpty ? "周末" : $0.name } ?? "周末"
                p.nextOff = Countdown(name: name, days: k, length: runLength(from: k))
            }
        }
        var k = i
        while k < 400, h[add(k)]?.off != true { k += 1 }
        if k < 400, let entry = h[add(k)] {
            var start = k
            while start > i, isOff(add(start - 1), h) { start -= 1 }
            p.nextHoliday = Countdown(name: entry.name.isEmpty ? "假期" : entry.name, days: start, length: runLength(from: start))
        }

        // 专注账本 → 每天的工作分钟
        var dayWork: [String: Int] = [:]
        var dayMorning: [String: Int] = [:]
        for en in entries where en.work {
            let m = en.minutes
            guard m > 0 else { continue }
            dayWork[en.day, default: 0] += m
            if en.startDate.hourOfDay * 60 < noon { dayMorning[en.day, default: 0] += m }
        }
        let goal = Int((price.goalHoursPerDay * 60).rounded())
        p.goalMin = goal
        func personal(_ d: String) -> Bool { price.isWorkday(d) && h[d]?.off != true }
        p.personalToday = personal(today)
        p.todayMin = dayWork[today] ?? 0
        p.todayMorningMin = dayMorning[today] ?? 0
        for en in entries where en.work && en.day == today && en.minutes > 0 {
            let c = Day.cal.dateComponents([.hour, .minute], from: en.startDate)
            p.todayBlocks.append(Block(start: (c.hour ?? 0) * 60 + (c.minute ?? 0), len: en.minutes))
        }

        // 本周（周一起）
        let wdIdx = ((Day.parse(today).map { Day.cal.component(.weekday, from: $0) } ?? 2) + 5) % 7
        let monday = Day.add(today, days: -wdIdx)
        var quotaDays = 0, doneDays = 0
        let labels = ["一", "二", "三", "四", "五", "六", "日"]
        for n in 0 ..< 7 {
            let d = Day.add(monday, days: n)
            p.weekDays.append(WeekDay(id: n, label: labels[n], work: dayWork[d] ?? 0, quota: personal(d), isToday: d == today, future: d > today))
            if personal(d) {
                quotaDays += 1
                if d < today { doneDays += 1 } else if d > today { p.weekDaysLeft += 1 }
            }
            if d <= today { p.weekDoneMin += dayWork[d] ?? 0 }
        }
        p.workdayCount = quotaDays
        p.weekQuotaMin = goal * quotaDays
        var expected = goal * doneDays
        if p.personalToday {
            let frac = nowMin >= noon ? 1.0 : (nowMin <= s ? 0 : Double(nowMin - s) / Double(max(noon - s, 1)))
            expected += Int(Double(goal) * frac)
        }
        p.weekExpectedMin = expected

        // 近期习惯
        var sum = 0, cnt = 0, morning = 0
        for n in 0 ..< 14 {
            let d = Day.add(today, days: -n)
            guard personal(d), let m = dayWork[d], m > 0 else { continue }
            sum += m; cnt += 1; morning += dayMorning[d] ?? 0
        }
        if cnt >= 3 { p.avgDayMin = sum / cnt }
        if sum >= 120 { p.morningShare = Double(morning) / Double(sum) }

        var earlySum = 0, weekSum = 0
        for w in 1 ... 4 {
            let mon = Day.add(monday, days: -7 * w)
            let days = (0 ..< 7).map { Day.add(mon, days: $0) }.filter(personal)
            guard days.count >= 2 else { continue }
            let early = Int((Double(days.count) / 2).rounded(.up))
            for (j, d) in days.enumerated() {
                let m = dayWork[d] ?? 0
                weekSum += m
                if j < early { earlySum += m }
            }
        }
        if weekSum >= 180 { p.earlyShare = Double(earlySum) / Double(weekSum) }

        p.insights = p.makeInsights(today: today)
        return p
    }

    // MARK: 洞察（先说此刻最该做的，再说一周的节奏，再说习惯和效率）

    private func makeInsights(today: String) -> [Insight] {
        guard goalMin > 0 else {
            return [Insight(icon: "slider.horizontal.3", text: "先在「洞察 → 时间价格 → 调整」里填每周工作几天、每天目标专注几小时，这里才能告诉你该在什么时候做完。", good: false)]
        }
        var out: [Insight] = []
        let g = Self.fmt(goalMin)
        func put(_ icon: String, _ text: String, _ good: Bool) { out.append(Insight(icon: icon, text: text, good: good)) }
        let pct = { (v: Double) in Int((v * 100).rounded()) }

        // 1. 此刻
        if !personalToday {
            if weekQuotaMin > 0, weekDoneMin >= weekQuotaMin {
                put("party.popper", "本周 \(Self.fmt(weekQuotaMin)) 的固定工作已经做完，今天不用工作。提前做完，换来的就是自己的时间。", true)
            } else if weekQuotaMin > 0 {
                let left = weekQuotaMin - weekDoneMin
                put("flag", weekDaysLeft > 0
                    ? "本周还差 \(Self.fmt(left))。下一个工作日一上班就先做它，别拖到后面。"
                    : "本周没做完的 \(Self.fmt(left))，下周第一个工作日上午先清掉，不要让它渗进周末。", false)
            }
        } else {
            let remain = max(goalMin - todayMin, 0)
            let toNoon = max(Self.noon - nowMin, 0)
            if remain == 0 {
                put("checkmark.seal", "今天的 \(g) 已经做完\(todayMorningMin >= goalMin ? "，还是在上午做完的" : "")。剩下的时间归你，别用杂事把它填满（帕金森定律：工作会膨胀到占满给它的时间）。", true)
            } else if nowMin < Self.noon {
                if phase == .before {
                    put("sunrise", "今天只需要专注 \(g)：上班后头一段（12 点前）一口气做完，整个下午就是自己的。", false)
                } else if remain <= toNoon {
                    put("sun.max", "上午精力最好：还差 \(Self.fmt(remain))，12 点前做完，下午就全归你。先别回消息、别开会，现在就开一个专注。", false)
                } else {
                    put("exclamationmark.triangle", "离 12 点只剩 \(Self.fmt(toNoon))，今天还差 \(Self.fmt(remain))，上午装不下了：把范围缩到最关键的一件，其余的明早先做。", false)
                }
            } else {
                put("exclamationmark.circle", phase == .after
                    ? "今天还差 \(Self.fmt(remain)) 没做完。明天上午第一件事就做它，别带到周末。"
                    : "已过中午，今天还差 \(Self.fmt(remain))。固定工作的量是定的，越晚做越挤占你的自由时间——现在先开一个 25 分钟的专注把它启动。", false)
            }
        }

        // 2. 一周的前置
        if weekQuotaMin > 0 {
            if weekDoneMin >= weekQuotaMin, weekDaysLeft > 0 {
                put("beach.umbrella", "本周的 \(Self.fmt(weekQuotaMin)) 已经提前做完，后面 \(weekDaysLeft) 个工作日可以收工，去做自己想做的事。", true)
            } else if personalToday, weekExpectedMin - weekDoneMin >= 30, weekQuotaMin > goalMin {
                put("calendar.badge.exclamationmark", "按每周 \(workdayCount) 天 × \(g)，到现在本该做完 \(Self.fmt(weekExpectedMin))，实际 \(Self.fmt(weekDoneMin))，落后 \(Self.fmt(weekExpectedMin - weekDoneMin))。重活放在周初，后面才有余地。", false)
            }
        }

        // 3. 习惯：上午 / 周初
        if let m = morningShare {
            if m < 0.5 {
                put("sun.haze", "近两周只有 \(pct(m))% 的工作专注开始在中午前。多数人的认知状态上午最好：把最难、最重要的那件放进上午，下午留给消息、会议这类零碎事。", false)
            } else if m >= 0.7 {
                put("sun.max", "近两周 \(pct(m))% 的工作专注在上午，节奏很对：难事趁早，下午才有余地。", true)
            }
        }
        if let e = earlyShare {
            if e < 0.6 {
                put("calendar", "近 4 周，前半周只完成了一周工作的 \(pct(e))%。把重活堆在周初，后半周就能轻松、甚至提前收工。", false)
            } else if e >= 0.8 {
                put("calendar", "近 4 周，前半周完成了一周工作的 \(pct(e))%，周初发力、周尾从容。", true)
            }
        }

        // 4. 效率：压缩做完固定工作所需的时间
        if let a = avgDayMin {
            if a > Int(Double(goalMin) * 1.15) {
                let over = Int((Double(a) / Double(goalMin) - 1) * 100)
                put("hare", "近 14 天有专注的工作日平均用了 \(Self.fmt(a))，比目标 \(g) 多 \(over)%。自由时间只能靠把同样的活做得更快来换：砍掉不重要的那 80%、给任务设更短的期限、专注时关掉通知。每天少用 30 分钟，一周就多出 \(String(format: "%.1f", Double(max(workdayCount, 1)) * 0.5)) 小时。", false)
            } else {
                put("hare", "有专注的工作日平均 \(Self.fmt(a))，在目标 \(g) 之内。省下的时间别再接新活，留给自己，才算真的提高了效率。", true)
            }
        }
        return out
    }
}
