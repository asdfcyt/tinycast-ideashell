import Foundation

typealias JSON = [String: Any]

// MARK: - 正则小工具（NSRegularExpression 的薄封装，行为对齐 Kotlin 的 Regex）

struct RXMatch {
    let source: NSString
    let result: NSTextCheckingResult

    var range: NSRange { result.range }

    func group(_ i: Int) -> String {
        let r = result.range(at: i)
        return r.location == NSNotFound ? "" : source.substring(with: r)
    }

    func hasGroup(_ i: Int) -> Bool { result.range(at: i).location != NSNotFound }
}

struct RX {
    let re: NSRegularExpression

    init(_ pattern: String, multiline: Bool = true, ignoreCase: Bool = false) {
        var opts: NSRegularExpression.Options = []
        if multiline { opts.insert(.anchorsMatchLines) }
        if ignoreCase { opts.insert(.caseInsensitive) }
        re = try! NSRegularExpression(pattern: pattern, options: opts)
    }

    func first(in s: String) -> RXMatch? {
        let ns = s as NSString
        guard let r = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return RXMatch(source: ns, result: r)
    }

    func all(in s: String) -> [RXMatch] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { RXMatch(source: ns, result: $0) }
    }

    func contains(in s: String) -> Bool { first(in: s) != nil }

    func fullMatch(in s: String) -> RXMatch? {
        let ns = s as NSString
        guard let r = re.firstMatch(in: s, options: [.anchored], range: NSRange(location: 0, length: ns.length)),
              r.range.length == ns.length else { return nil }
        return RXMatch(source: ns, result: r)
    }

    func replace(in s: String, with template: String) -> String {
        let ns = s as NSString
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 去掉全部空白（用于 memo 去重比较）
    var noSpace: String { components(separatedBy: .whitespacesAndNewlines).joined() }

    func substr(_ from: Int, _ to: Int) -> String {
        let ns = self as NSString
        return ns.substring(with: NSRange(location: from, length: to - from))
    }

    var nsLength: Int { (self as NSString).length }
}

// MARK: - 日期（本地时区，yyyy-MM-dd 字符串当「日」）

enum Day {
    static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.firstWeekday = 2
        return c
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(_ d: Date) -> String { fmt.string(from: d) }
    static func parse(_ s: String) -> Date? { fmt.date(from: s) }
    static func today() -> String { string(Date()) }
    static func startOfDay(_ d: Date) -> Date { cal.startOfDay(for: d) }

    static func add(_ s: String, days: Int) -> String {
        guard let d = parse(s), let n = cal.date(byAdding: .day, value: days, to: d) else { return s }
        return string(n)
    }

    static func diff(_ a: String, _ b: String) -> Int {
        guard let x = parse(a), let y = parse(b) else { return 0 }
        return cal.dateComponents([.day], from: startOfDay(x), to: startOfDay(y)).day ?? 0
    }

    private static let labelFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = .current
        f.dateFormat = "M月d日 EEE"
        return f
    }()

    /// 「今天 / 明天 / 昨天 / 10月22日 周四」
    static func label(_ s: String) -> String {
        let delta = diff(today(), s)
        switch delta {
        case 0: return "今天"
        case 1: return "明天"
        case -1: return "昨天"
        case 2: return "后天"
        default: break
        }
        guard let d = parse(s) else { return s }
        return labelFmt.string(from: d)
    }

    /// 带 +0800 偏移的字符串：yyyy-MM-dd'T'HH:mm:00.000+0800（滴答接口用）
    static func dueString(_ date: String, time: String? = nil) -> String {
        let t = time ?? "00:00"
        let parts = t.split(separator: ":").compactMap { Int($0) }
        let base = parse(date) ?? Date()
        let dt = cal.date(bySettingHour: parts.first ?? 0, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: base) ?? base
        let secs = TimeZone.current.secondsFromGMT(for: dt)
        let sign = secs >= 0 ? "+" : "-"
        let a = abs(secs)
        return String(format: "%@T%02d:%02d:00.000%@%02d%02d", date, parts.first ?? 0, parts.count > 1 ? parts[1] : 0, sign, a / 3600, (a % 3600) / 60)
    }
}

// MARK: - 笔记时间

enum NoteTime {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let local: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static func utcString(_ d: Date) -> String { isoFrac.string(from: d) }

    /// 接口时间多为 ISO-8601（带 Z / 偏移）；兜底支持无时区的本地时间与纯日期
    static func parse(_ value: String?) -> Date? {
        let s = (value ?? "").trimmed
        if s.isEmpty { return nil }
        if let d = isoFrac.date(from: s) { return d }
        if let d = iso.date(from: s) { return d }
        let t = s.replacingOccurrences(of: " ", with: "T")
        if let d = local.date(from: String(t.prefix(19))), t.count >= 19 { return d }
        if s.count >= 10, let d = Day.parse(String(s.prefix(10))) { return d }
        return nil
    }

    static func day(_ iso: String?) -> String? { parse(iso).map(Day.string) }

    private static let clockFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "HH:mm"
        return f
    }()

    static func clock(_ iso: String?) -> String? { parse(iso).map { clockFmt.string(from: $0) } }
}

extension Date {
    var hourOfDay: Int { Day.cal.component(.hour, from: self) }
}
