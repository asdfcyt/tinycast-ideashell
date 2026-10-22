import Foundation

extension RX {
    /// 逐个匹配替换（闭包返回替换文字）
    func replace(in s: String, using f: (RXMatch) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in all(in: s) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += f(m)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}

struct ParsedTodo {
    var content: String
    /// yyyy-MM-dd
    var date: String?
    /// HH:mm
    var time: String?
}

/// 待办自然语言日期 / 时间解析，移植自安卓端 `TodoParser.kt`（和桌面插件 `todo-parse.ts` 一致）：
/// 「明天 15:00 开会」「下周五下午3点半 交周报」「10月9日 买票」。识别到的日期 / 时间会从内容里移除；只有时间没有日期时取最近有效的那一刻。
/// 重复说法（每周一 …）这一版不识别。
enum TodoParser {
    private static let weekdayIndex: [Character: Int] = ["一": 0, "二": 1, "三": 2, "四": 3, "五": 4, "六": 5, "日": 6, "天": 6]
    private static let cnDigit: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]

    /// 阿拉伯数字或中文数字（一 ~ 九十九）
    private static let N = "(?:[0-9]{1,2}|[零〇一二三四五六七八九十两]{1,3})"

    private static func rx(_ p: String) -> RX { RX(p, multiline: false) }

    private static let reISO = rx(#"([0-9]{4})[-/.]([0-9]{1,2})[-/.]([0-9]{1,2})"#)
    private static let reSlashDate = rx(#"(?<![0-9/\-.:：])([0-9]{1,2})[/\-]([0-9]{1,2})(?![0-9/\-.:：])"#)
    private static let reMonthDay = rx(#"(\#(N))月\s*(\#(N))[日号]"#)
    private static let reMonthDayBare = rx(#"([0-9]{1,2})月\s*([0-9]{1,2})(?![0-9点時时:：])"#)
    private static let reMonth = rx(#"(\#(N))月份?"#)
    private static let reRelative = rx("大后天|后天|明天|明日|今天|今日")
    private static let reWeekday = rx("(下下|下)?(?:周|星期|礼拜)([一二三四五六日天])")
    private static let reWeekend = rx("(下下|下|这|本)?(?:个)?周末")
    private static let reAfter = rx(#"(\#(N))\s*(?:个)?(天|日|周|星期|礼拜|月|年)(?:之)?后"#)
    private static let reAfterHours = rx(#"(\#(N))\s*个?\s*(半)?\s*小时(?:\s*(半)|\s*(\#(N))\s*分钟?)?\s*(?:之)?后"#)
    private static let reAfterHalfHour = rx(#"半\s*个?\s*小时\s*(?:之)?后"#)
    private static let reAfterMinutes = rx(#"(\#(N))\s*分钟\s*(?:之)?后"#)
    private static let reMonthEdge = rx(#"(?:(下)个?|(本|这个)|(\#(N)))月份?(底|末|初)|月(底|末|初)"#)
    private static let reYearEnd = rx("年底|年末")
    private static let reNextMonthDay = rx(#"(?:(下)个?月|(?:本|这个)月)\s*(\#(N))\s*[日号]"#)
    private static let reDayOnly = rx(#"(?<![0-9月年/\-.])(\#(N))\s*号(?![线楼院店室厅层栋])"#)
    private static let reFestival = rx(
        "国庆(?:节)?|元旦(?:节)?|春节|除夕|清明(?:节)?|劳动节|五一|端午(?:节)?|中秋(?:节)?|元宵(?:节)?|情人节|圣诞(?:节)?|平安夜|"
            + "七夕|重阳(?:节)?|腊八(?:节)?|妇女节|儿童节|教师节|建党节|建军节|青年节|植树节|母亲节|父亲节|龙抬头"
    )

    private static let period = "(凌晨|早上|早晨|上午|中午|下午|晚上|傍晚)?\\s*"
    private static let reTimeColon = rx(period + #"([0-9]{1,2})[:：]([0-9]{2})"#)
    private static let reTimeDian = rx(period + #"(\#(N))\s*[点時时](?:\s*(半)|\s*([0-9]{1,2})\s*分?|\s*([零〇一二三四五六七八九十]{1,3})分)?"#)
    private static let rePeriodOnly = rx("(凌晨|早上|早晨|上午|中午|下午|晚上|傍晚)(?![茶饭餐])")

    private static let periodDefault: [String: String] = [
        "凌晨": "03:00", "早上": "07:00", "早晨": "07:00", "上午": "09:00",
        "中午": "12:00", "下午": "14:30", "傍晚": "17:00", "晚上": "20:00",
    ]

    private static let reSpaces = rx(#"\s+"#)
    private static let reEdgePunct = rx(#"^[\s,，、:：;；\-—]+|[\s,，、:：;；\-—]+$"#)
    private static let reLeadingPrep = rx(#"^(?:在|于|到)\s*"#)
    private static let reDayPeriod = rx("(今|明)(?:(晚|夜)(?![上间])|(早|晨)(?![上晨餐饭间]))")

    /// 「12」「九」「十二」「二十三」→ 数字；认不出返回 nil
    private static func num(_ s: String) -> Int? {
        if let n = Int(s) { return n }
        if s.isEmpty { return nil }
        let chars = Array(s)
        guard let ten = chars.firstIndex(of: "十") else { return chars.count == 1 ? cnDigit[chars[0]] : nil }
        let head = chars[..<ten], tail = chars[(ten + 1)...]
        let tens: Int
        if head.isEmpty { tens = 1 } else if head.count == 1, let d = cnDigit[head.first!] { tens = d } else { return nil }
        let ones: Int
        if tail.isEmpty { ones = 0 } else if tail.count == 1, let d = cnDigit[tail.first!] { ones = d } else { return nil }
        return tens * 10 + ones
    }

    private static func expandDayPeriod(_ s: String) -> String {
        reDayPeriod.replace(in: s) { m in
            let day = m.group(1) == "今" ? "今天" : "明天"
            return day + (m.hasGroup(2) ? "晚上" : "早上")
        }
    }

    private static func replaceFirst(_ text: String, _ hit: String, with r: String = " ") -> String {
        guard let range = text.range(of: hit) else { return text }
        return text.replacingCharacters(in: range, with: r)
    }

    private static func cleanup(_ text: String) -> String {
        var t = reSpaces.replace(in: text, with: " ")
        t = reEdgePunct.replace(in: t, with: "")
        t = reLeadingPrep.replace(in: t, with: "")
        return t.trimmed
    }

    // MARK: - 日期工具

    private static let cal = Day.cal

    private static func safeDate(_ y: Int, _ m: Int, _ d: Int) -> Date? {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        guard let date = cal.date(from: c) else { return nil }
        let back = cal.dateComponents([.year, .month, .day], from: date)
        return back.year == y && back.month == m && back.day == d ? date : nil
    }

    private static func add(_ d: Date, days: Int = 0, months: Int = 0, years: Int = 0) -> Date {
        var c = DateComponents(); c.day = days; c.month = months; c.year = years
        return cal.date(byAdding: c, to: d) ?? d
    }

    private static func nearestDate(_ today: Date, _ month: Int, _ day: Int) -> Date? {
        let y = cal.component(.year, from: today)
        guard let d = safeDate(y, month, day) else { return nil }
        return d < today ? safeDate(y + 1, month, day) : d
    }

    private static func nearestMonth(_ today: Date, _ month: Int, end: Bool) -> Date? {
        guard (1 ... 12).contains(month) else { return nil }
        let y = cal.component(.year, from: today)
        guard let first = safeDate(y, month, 1) else { return nil }
        let last = add(add(first, months: 1), days: -1)
        let keep = end ? last >= today : first >= today
        return keep ? first : safeDate(y + 1, month, 1)
    }

    private static func lastOfMonth(_ d: Date) -> Date {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
        return add(add(first, months: 1), days: -1)
    }

    private static func firstOfMonth(_ d: Date) -> Date { cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d }

    private static func mondayIndex(_ d: Date) -> Int { (cal.component(.weekday, from: d) + 5) % 7 }

    // MARK: - 节日

    private static let aliases: [String: String] = ["五一": "劳动节", "三八": "妇女节", "六一": "儿童节"]

    /// 下一个这个节日（今天或以后）。往后逐天找 400 天，农历 / 公历节日和清明都按名字对
    static func nextFestival(_ rawName: String, today: Date) -> Date? {
        func norm(_ s: String) -> String { s.hasSuffix("节") ? String(s.dropLast()) : s }
        let want = norm(aliases[rawName] ?? rawName)
        for i in 0 ..< 400 {
            let d = add(today, days: i)
            let s = Day.string(d)
            let names = [LunarCalendar.lunarFestival(s), LunarCalendar.solarFestival(s), LunarCalendar.solarTerm(s) == "清明" ? "清明" : nil]
            if names.contains(where: { $0.map(norm) == want }) { return d }
        }
        return nil
    }

    // MARK: - 解析

    /// 「半小时后 / 两小时后 / 十分钟后」这类相对现在的说法：返回（那一刻, 命中的原文）
    static func findAfterDuration(_ text: String, now: Date) -> (Date, String)? {
        if let m = reAfterHours.first(in: text), let hours = num(m.group(1)) {
            var minutes = hours * 60
            if m.hasGroup(2) || m.hasGroup(3) { minutes += 30 }
            if m.hasGroup(4), let extra = num(m.group(4)) { minutes += extra }
            if (1 ... 72 * 60).contains(minutes) { return (now.addingTimeInterval(Double(minutes) * 60), m.group(0)) }
        }
        if let m = reAfterHalfHour.first(in: text) { return (now.addingTimeInterval(30 * 60), m.group(0)) }
        if let m = reAfterMinutes.first(in: text), let minutes = num(m.group(1)), (1 ... 72 * 60).contains(minutes) {
            return (now.addingTimeInterval(Double(minutes) * 60), m.group(0))
        }
        return nil
    }

    static func parse(_ input: String, now: Date = Date()) -> ParsedTodo {
        let today = Day.startOfDay(now)
        var text = expandDayPeriod(input.trimmed)
        var date: String?
        var time: String?

        if let (when, hit) = findAfterDuration(text, now: now) {
            let c = cal.dateComponents([.hour, .minute], from: when)
            text = replaceFirst(text, hit)
            let content = cleanup(text)
            return ParsedTodo(content: content.isEmpty ? input.trimmed : content, date: Day.string(when), time: String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))
        }

        if let (d, hit) = matchDate(text, today: today) {
            date = d
            text = replaceFirst(text, hit)
        }
        if let (t, hit) = matchTime(text) {
            time = t
            text = replaceFirst(text, hit)
        }
        // 只有时间没有日期：取最近有效的那一刻——今天这个点还没到就是今天，已过就是明天
        if let t = time, date == nil {
            let nowC = cal.dateComponents([.hour, .minute], from: now)
            let nowStr = String(format: "%02d:%02d", nowC.hour ?? 0, nowC.minute ?? 0)
            date = Day.string(t > nowStr ? today : add(today, days: 1))
        }
        let content = cleanup(text)
        return ParsedTodo(content: content.isEmpty ? input.trimmed : content, date: date, time: time)
    }

    private static func matchDate(_ text: String, today: Date) -> (String, String)? {
        let year = cal.component(.year, from: today)

        if let m = reISO.first(in: text), let d = safeDate(Int(m.group(1))!, Int(m.group(2))!, Int(m.group(3))!) {
            return (Day.string(d), m.group(0))
        }

        if let m = reFestival.first(in: text) {
            let name = m.group(0)
            if let d = nextFestival(name, today: today) { return (Day.string(d), name) }
        }

        if let m = reAfter.first(in: text), let n = num(m.group(1)), (1 ... 99).contains(n) {
            let d: Date
            switch m.group(2) {
            case "天", "日": d = add(today, days: n)
            case "周", "星期", "礼拜": d = add(today, days: 7 * n)
            case "月": d = add(today, months: n)
            default: d = add(today, years: n)
            }
            return (Day.string(d), m.group(0))
        }

        if let m = reMonthEdge.first(in: text) {
            let next = m.hasGroup(1)
            let monthN = m.hasGroup(3) ? num(m.group(3)) : nil
            let suffix = m.hasGroup(4) ? m.group(4) : (m.hasGroup(5) ? m.group(5) : "")
            if !suffix.isEmpty {
                let end = suffix != "初"
                let base: Date?
                if let monthN { base = nearestMonth(today, monthN, end: end) }
                else if next { base = add(firstOfMonth(today), months: 1) }
                else if end { base = today }
                else { base = cal.component(.day, from: today) == 1 ? today : add(firstOfMonth(today), months: 1) }
                if let base {
                    return (Day.string(end ? lastOfMonth(base) : firstOfMonth(base)), m.group(0))
                }
            }
        }
        if let m = reYearEnd.first(in: text), let d = safeDate(year, 12, 31) {
            return (Day.string(d), m.group(0))
        }

        if let m = reNextMonthDay.first(in: text), let day = num(m.group(2)) {
            let month = m.hasGroup(1) ? add(today, months: 1) : today
            let c = cal.dateComponents([.year, .month], from: month)
            if let d = safeDate(c.year ?? year, c.month ?? 1, day) { return (Day.string(d), m.group(0)) }
        }

        if let m = reWeekend.first(in: text) {
            let weeks: Int
            switch m.hasGroup(1) ? m.group(1) : "" {
            case "下下": weeks = 2
            case "下": weeks = 1
            default: weeks = 0
            }
            let monday = add(today, days: -mondayIndex(today))
            var target = add(monday, days: 5 + weeks * 7)
            if target < today { target = today }
            return (Day.string(target), m.group(0))
        }

        for re in [reMonthDay, reMonthDayBare] {
            if let m = re.first(in: text), let month = num(m.group(1)), let day = num(m.group(2)), let d = nearestDate(today, month, day) {
                return (Day.string(d), m.group(0))
            }
        }

        if let m = reSlashDate.first(in: text), let mo = Int(m.group(1)), let da = Int(m.group(2)), let d = nearestDate(today, mo, da) {
            return (Day.string(d), m.group(0))
        }

        if let m = reDayOnly.first(in: text), let day = num(m.group(1)), (1 ... 31).contains(day) {
            for offset in 0 ... 2 {
                let c = cal.dateComponents([.year, .month], from: add(today, months: offset))
                if let d = safeDate(c.year ?? year, c.month ?? 1, day), d >= today { return (Day.string(d), m.group(0)) }
            }
        }

        if let m = reMonth.first(in: text), let month = num(m.group(1)), let d = nearestDate(today, month, 1) {
            return (Day.string(d), m.group(0))
        }

        if let m = reRelative.first(in: text) {
            let offset: Int
            switch m.group(0) {
            case "今天", "今日": offset = 0
            case "明天", "明日": offset = 1
            case "后天": offset = 2
            default: offset = 3
            }
            return (Day.string(add(today, days: offset)), m.group(0))
        }

        if let m = reWeekday.first(in: text), let idx = weekdayIndex[Array(m.group(2))[0]] {
            let weeks: Int
            switch m.hasGroup(1) ? m.group(1) : "" {
            case "下下": weeks = 2
            case "下": weeks = 1
            default: weeks = 0
            }
            let monday = add(today, days: -mondayIndex(today))
            var target = add(monday, days: idx + weeks * 7)
            if weeks == 0 && target < today { target = add(target, days: 7) }
            return (Day.string(target), m.group(0))
        }
        return nil
    }

    /// 识别时间：15:30 / 下午3点 / 3点半 / 晚上8点15分，返回 (HH:mm, 命中的原文)
    private static func matchTime(_ text: String) -> (String, String)? {
        var per: String?
        var hour: Int
        let minute: Int
        let hit: String

        if let colon = reTimeColon.first(in: text) {
            per = colon.hasGroup(1) ? colon.group(1) : nil
            hour = Int(colon.group(2)) ?? 0
            minute = Int(colon.group(3)) ?? 0
            hit = colon.group(0)
        } else {
            guard let dian = reTimeDian.first(in: text) else {
                // 只说了时段（「下午」「晚上」…）：用该时段的默认时间
                guard let only = rePeriodOnly.first(in: text), let t = periodDefault[only.group(1)] else { return nil }
                return (t, only.group(0))
            }
            per = dian.hasGroup(1) ? dian.group(1) : nil
            guard let h = num(dian.group(2)) else { return nil }
            hour = h
            if dian.hasGroup(3) { minute = 30 }
            else if dian.hasGroup(4) { minute = Int(dian.group(4)) ?? 0 }
            else if dian.hasGroup(5) { guard let mm = num(dian.group(5)) else { return nil }; minute = mm }
            else { minute = 0 }
            hit = dian.group(0)
            // 「一点东西」「买一点」不是 1 点：中文的「一点」没有时段、也没有半 / 分时不当作时间
            let chinese = Int(dian.group(2)) == nil
            if chinese && per == nil && hour == 1 && !dian.hasGroup(3) && !dian.hasGroup(4) && !dian.hasGroup(5) { return nil }
        }
        if (per == "下午" || per == "晚上" || per == "傍晚") && hour < 12 { hour += 12 }
        if per == "中午" && hour < 11 { hour += 12 }
        if hour > 23 || minute > 59 { return nil }
        return (String(format: "%02d:%02d", hour, minute), hit)
    }
}
