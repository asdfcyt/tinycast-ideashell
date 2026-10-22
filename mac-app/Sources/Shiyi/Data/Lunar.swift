import Foundation

/// 农历、节气、传统节日与公历节日（用系统自带的农历，不需要联网）。移植自安卓端 `LunarCalendar.kt` / `DayInfo.kt`。
struct LunarDate {
    var month: Int   // 1...12
    var day: Int     // 1...30
    var leap: Bool
}

enum LunarCalendar {
    private static let cal: Calendar = {
        var c = Calendar(identifier: .chinese)
        c.timeZone = .current
        return c
    }()
    nonisolated(unsafe) private static var cache: [String: LunarDate] = [:]
    private static let lock = NSLock()

    /// [day] 是 yyyy-MM-dd
    static func of(_ day: String) -> LunarDate {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[day] { return c }
        let base = Day.parse(day) ?? Date()
        let noon = Day.cal.date(bySettingHour: 12, minute: 0, second: 0, of: base) ?? base
        let comps = cal.dateComponents([.month, .day], from: noon)
        let l = LunarDate(month: comps.month ?? 1, day: comps.day ?? 1, leap: comps.isLeapMonth ?? false)
        cache[day] = l
        return l
    }

    private static let monthNames = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
    private static let dayNames = [
        "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
    ]

    static func monthName(_ l: LunarDate) -> String { (l.leap ? "闰" : "") + monthNames[max(0, min(11, l.month - 1))] + "月" }
    /// 日历格子里的农历：初一显示月份（正月 / 闰四月），其余显示日（初二 … 三十）
    static func dayText(_ l: LunarDate) -> String { l.day == 1 ? monthName(l) : dayNames[max(0, min(29, l.day - 1))] }
    /// 完整农历：九月初九 / 闰六月十五
    static func fullText(_ l: LunarDate) -> String { monthName(l) + dayNames[max(0, min(29, l.day - 1))] }

    /// 干支纪年 + 农历月日：丙午年九月十三
    static func yearAndDay(_ day: String) -> String {
        let base = Day.parse(day) ?? Date()
        let noon = Day.cal.date(bySettingHour: 12, minute: 0, second: 0, of: base) ?? base
        let n = cal.component(.year, from: noon)  // 1...60 的甲子序号
        let stems = Array("甲乙丙丁戊己庚辛壬癸"), branches = Array("子丑寅卯辰巳午未申酉戌亥")
        let name = n >= 1 ? String(stems[(n - 1) % 10]) + String(branches[(n - 1) % 12]) + "年" : ""
        return name + fullText(of(day))
    }

    /// 传统节日（农历）；除夕按「正月初一的前一天」算，因为腊月有 29 天也有 30 天
    static func lunarFestival(_ day: String) -> String? {
        let l = of(day)
        if !l.leap {
            switch (l.month, l.day) {
            case (1, 1): return "春节"
            case (1, 15): return "元宵"
            case (2, 2): return "龙抬头"
            case (5, 5): return "端午"
            case (7, 7): return "七夕"
            case (7, 15): return "中元"
            case (8, 15): return "中秋"
            case (9, 9): return "重阳"
            case (12, 8): return "腊八"
            case (12, 23): return "小年"
            default: break
            }
        }
        if l.month == 12 && l.day >= 29 {
            let next = of(Day.add(day, days: 1))
            if next.month == 1 && next.day == 1 { return "除夕" }
        }
        return nil
    }

    /// 公历节日 / 纪念日
    static func solarFestival(_ day: String) -> String? {
        guard let d = Day.parse(day) else { return nil }
        let m = Day.cal.component(.month, from: d), dd = Day.cal.component(.day, from: d)
        switch (m, dd) {
        case (1, 1): return "元旦"
        case (2, 14): return "情人节"
        case (3, 8): return "妇女节"
        case (3, 12): return "植树节"
        case (5, 1): return "劳动节"
        case (5, 4): return "青年节"
        case (6, 1): return "儿童节"
        case (7, 1): return "建党节"
        case (8, 1): return "建军节"
        case (9, 10): return "教师节"
        case (10, 1): return "国庆节"
        case (12, 24): return "平安夜"
        case (12, 25): return "圣诞节"
        default: break
        }
        // 母亲节（5 月第 2 个周日）/ 父亲节（6 月第 3 个周日）
        if Day.cal.component(.weekday, from: d) == 1 {
            let nth = (dd - 1) / 7 + 1
            if m == 5 && nth == 2 { return "母亲节" }
            if m == 6 && nth == 3 { return "父亲节" }
        }
        return nil
    }

    private static let terms = [
        "小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨", "立夏", "小满", "芒种", "夏至",
        "小暑", "大暑", "立秋", "处暑", "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至",
    ]
    /// 21 世纪的 24 节气「寿星公式」常数：小寒 … 冬至
    private static let c21: [Double] = [
        5.4055, 20.12, 3.87, 18.73, 5.63, 20.646, 4.81, 20.1, 5.52, 21.04, 5.678, 21.37,
        7.108, 22.83, 7.5, 23.13, 7.646, 23.042, 8.318, 23.438, 7.438, 22.36, 7.18, 21.94,
    ]

    /// 当天是不是节气（公式算的，极个别年份可能差一天）
    static func solarTerm(_ day: String) -> String? {
        guard let d = Day.parse(day) else { return nil }
        let year = Day.cal.component(.year, from: d)
        let m = Day.cal.component(.month, from: d), dd = Day.cal.component(.day, from: d)
        let y = year % 100
        for i in [2 * (m - 1), 2 * (m - 1) + 1] {
            let v = Int(Double(y) * 0.2422 + c21[i]) - (m <= 2 ? (y - 1) / 4 : y / 4)
            if v == dd { return terms[i] }
        }
        return nil
    }
}

// MARK: - 法定节假日 / 调休

struct HolidayEntry: Equatable {
    var off: Bool       // true 休息，false 调休上班
    var name: String    // 国庆节、春节…
}

/// 日历格子里一天要显示的东西：左上小字（节日 > 节气 > 农历）和「休 / 班」
struct DayInfo {
    var label: String
    /// label 是节日 / 节气（用强调色显示）
    var highlight: Bool
    var holiday: HolidayEntry?
    var lunarFull: String

    /// 选中某天时那行说明：「九月初九 重阳 · 休息（国庆节）」
    func detail() -> String {
        var parts = [lunarFull]
        if highlight { parts.append(label) }
        if let h = holiday { parts.append(h.off ? "休息（\(h.name)）" : "调休上班（\(h.name)）") }
        return parts.joined(separator: " · ")
    }

    static func of(_ day: String, holiday: HolidayEntry?) -> DayInfo {
        let lunar = LunarCalendar.of(day)
        let festival = LunarCalendar.lunarFestival(day) ?? LunarCalendar.solarFestival(day)
        let term = LunarCalendar.solarTerm(day)
        let (label, highlight): (String, Bool)
        if let f = festival { (label, highlight) = (f, true) }
        else if let t = term { (label, highlight) = (t, true) }
        else { (label, highlight) = (LunarCalendar.dayText(lunar), false) }
        return DayInfo(label: label, highlight: highlight, holiday: holiday, lunarFull: LunarCalendar.fullText(lunar))
    }
}

/// 法定节假日数据：从开源数据集 holiday-cn 按年份拉取 JSON，缓存在本机（和安卓端 `HolidayRepository` 同一套数据源、同一套过期规则）。
/// 当年、上一年、下一年各一份；拉不到就用旧缓存，都没有就只显示农历 / 节日。
enum HolidayStore {
    private struct YearDto: Decodable {
        var year: Int
        var days: [DayDto]
        struct DayDto: Decodable {
            var name: String
            var date: String
            var isOffDay: Bool
            enum CodingKeys: String, CodingKey { case name, date, isOffDay }
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: CodingKeys.self)
                name = (try? c.decode(String.self, forKey: .name)) ?? ""
                date = (try? c.decode(String.self, forKey: .date)) ?? ""
                isOffDay = (try? c.decode(Bool.self, forKey: .isOffDay)) ?? false
            }
        }
        enum CodingKeys: String, CodingKey { case year, days }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            year = (try? c.decode(Int.self, forKey: .year)) ?? 0
            days = (try? c.decode([DayDto].self, forKey: .days)) ?? []
        }
    }

    private static let mirrors = [
        "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/%d.json",
        "https://fastly.jsdelivr.net/gh/NateScarlet/holiday-cn@master/%d.json",
        "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/%d.json",
    ]

    /// 读缓存、必要时联网更新，返回全部休 / 班日（日期 yyyy-MM-dd → 条目）
    static func load() async -> [String: HolidayEntry] {
        let thisYear = Calendar.current.component(.year, from: Date())
        var out: [String: HolidayEntry] = [:]
        for year in [thisYear - 1, thisYear, thisYear + 1] {
            let name = "holiday-\(year).json"
            var dto = read(name)
            if isStale(name, dto), let fresh = await download(year) {
                LocalStore.write(name, fresh.1)
                dto = fresh.0
            }
            guard let d = dto else { continue }
            for day in d.days where !day.date.isEmpty {
                out[day.date] = HolidayEntry(off: day.isOffDay, name: day.name)
            }
        }
        return out
    }

    private static func read(_ name: String) -> YearDto? {
        guard let text = LocalStore.read(name), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(YearDto.self, from: data)
    }

    /// 缓存没有、或太旧就该更新：已公布的 2 周；还没公布（days 为空）的 2 天
    private static func isStale(_ name: String, _ cached: YearDto?) -> Bool {
        guard let cached else { return true }
        let url = LocalStore.dir.appendingPathComponent(name)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mod = attrs[.modificationDate] as? Date else { return true }
        let limit: TimeInterval = (cached.days.isEmpty ? 2 : 14) * 86400
        return Date().timeIntervalSince(mod) > limit
    }

    private static func download(_ year: Int) async -> (YearDto, String)? {
        for base in mirrors {
            guard let url = URL(string: String(format: base, year)) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let dto = try? JSONDecoder().decode(YearDto.self, from: data),
                  dto.year == year,
                  let text = String(data: data, encoding: .utf8) else { continue }
            return (dto, text)
        }
        return nil
    }
}
