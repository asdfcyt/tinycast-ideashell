import Foundation

/// 解析滴答 MCP 返回的文本：可能是单个 JSON、数组，或多个 JSON 对象首尾相接（移植自安卓端 `DidaParser`）
enum DidaParser {
    private static let dateRe = RX(
        #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?)?\s*(Z|[+-]\d{2}:?\d{2})?$"#,
        multiline: false
    )

    /// 把文本里所有顶层 JSON 值依次解析出来（跳过无法解析的片段）
    static func parseAny(_ text: String) -> [Any] {
        let chars = Array(text.utf8)
        var values: [Any] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c != UInt8(ascii: "{") && c != UInt8(ascii: "[") { i += 1; continue }
            var depth = 0
            var inStr = false
            var esc = false
            var end = -1
            var j = i
            while j < chars.count {
                let ch = chars[j]
                if inStr {
                    if esc { esc = false }
                    else if ch == UInt8(ascii: "\\") { esc = true }
                    else if ch == UInt8(ascii: "\"") { inStr = false }
                } else if ch == UInt8(ascii: "\"") {
                    inStr = true
                } else if ch == UInt8(ascii: "{") || ch == UInt8(ascii: "[") {
                    depth += 1
                } else if ch == UInt8(ascii: "}") || ch == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 { end = j; break }
                }
                j += 1
            }
            if end < 0 { break }
            let slice = Data(chars[i ... end])
            if let v = try? JSONSerialization.jsonObject(with: slice, options: [.fragmentsAllowed]) { values.append(v) }
            i = end + 1
        }
        return values
    }

    /// 深度优先收集满足条件的对象（命中后不再往里找）
    static func collectObjects(_ value: Any, _ pred: (JSON) -> Bool, _ out: inout [JSON]) {
        if let arr = value as? [Any] {
            for v in arr { collectObjects(v, pred, &out) }
        } else if let obj = value as? JSON {
            if pred(obj) { out.append(obj) } else { for v in obj.values { collectObjects(v, pred, &out) } }
        }
    }

    static func str(_ o: JSON, _ key: String) -> String? {
        switch o[key] {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        default: return nil
        }
    }

    private static func int(_ o: JSON, _ key: String) -> Int? {
        if let n = o[key] as? NSNumber { return n.intValue }
        if let s = o[key] as? String { return Int(s) }
        return nil
    }

    static func extractTasks(_ text: String) -> [DidaTask] {
        var found: [JSON] = []
        for v in parseAny(text) { collectObjects(v, { str($0, "id") != nil && str($0, "title") != nil }, &found) }
        var seen = Set<String>()
        var tasks: [DidaTask] = []
        for o in found {
            guard let id = str(o, "id"), seen.insert(id).inserted else { continue }
            let allDay = (o["isAllDay"] as? NSNumber)?.boolValue == true
            let due = parseDate(str(o, "dueDate") ?? str(o, "startDate"), isAllDay: allDay)
            let status = int(o, "status")
            let completed = str(o, "completedTime")
            let tags = (o["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
            let repeatFlag = str(o, "repeatFlag").flatMap { $0.trimmed.isEmpty ? nil : $0 }
            tasks.append(DidaTask(
                id: id,
                projectId: str(o, "projectId") ?? "",
                title: str(o, "title") ?? "",
                content: str(o, "content") ?? str(o, "desc") ?? "",
                date: due.date,
                time: due.time,
                priority: int(o, "priority") ?? 0,
                tags: tags,
                // 重复任务完成一次后仍是未完成，但 completedTime 会保留，所以以 status 为准
                done: status == 2 || (status == nil && completed != nil),
                completedAt: parseMs(completed),
                createdAt: parseMs(str(o, "createdTime")),
                repeatFlag: repeatFlag
            ))
        }
        return tasks
    }

    /// 项目列表：id → 名称；收集箱 id 形如 inbox1011888736
    static func extractProjects(_ text: String) -> [String: String] {
        var found: [JSON] = []
        for v in parseAny(text) { collectObjects(v, { str($0, "id") != nil && str($0, "name") != nil }, &found) }
        var names: [String: String] = [:]
        for o in found { names[str(o, "id")!] = str(o, "name")! }
        for (id, name) in names where id.lowercased().hasPrefix("inbox") && name.lowercased().contains("inbox") {
            names[id] = "收集箱"
        }
        return names
    }

    /// 滴答返回的日期可能是 UTC，也可能带 +0800 / +08:00，统一换算成本地日期 / 时间
    static func parseDate(_ value: String?, isAllDay: Bool) -> (date: String?, time: String?) {
        guard let value, let m = dateRe.fullMatch(in: value.trimmed) else { return (nil, nil) }
        if !m.hasGroup(4) { return ("\(m.group(1))-\(m.group(2))-\(m.group(3))", nil) }

        var offsetMin = 0
        let off = m.group(7)
        if !off.isEmpty && off != "Z" {
            let sign = off.hasPrefix("-") ? -1 : 1
            let digits = String(off.dropFirst()).replacingOccurrences(of: ":", with: "")
            offsetMin = sign * ((Int(digits.prefix(2)) ?? 0) * 60 + (Int(digits.dropFirst(2).prefix(2)) ?? 0))
        }
        var comps = DateComponents()
        comps.year = Int(m.group(1)); comps.month = Int(m.group(2)); comps.day = Int(m.group(3))
        comps.hour = Int(m.group(4)); comps.minute = Int(m.group(5)); comps.second = Int(m.group(6)) ?? 0
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        guard let asUtc = utcCal.date(from: comps) else { return (nil, nil) }
        let instant = asUtc.addingTimeInterval(-Double(offsetMin) * 60)
        let local = Day.cal.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
        let date = String(format: "%04d-%02d-%02d", local.year ?? 0, local.month ?? 0, local.day ?? 0)
        let time = isAllDay ? nil : String(format: "%02d:%02d", local.hour ?? 0, local.minute ?? 0)
        return (date, time)
    }

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

    private static let offsetFix = RX(#"([+-]\d{2})(\d{2})$"#, multiline: false)

    static func parseMs(_ v: String?) -> Int64? {
        guard let v else { return nil }
        // 2026-10-09T10:00:00+0800 → 补冒号
        let fixed = offsetFix.replace(in: v, with: "$1:$2")
        if let d = iso.date(from: fixed) ?? isoFrac.date(from: fixed) {
            return Int64(d.timeIntervalSince1970 * 1000)
        }
        return nil
    }
}
