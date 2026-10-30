import Foundation

// 移植自安卓端 `DailyNoteService.kt`（只读部分）、`Timeline.kt`、`ReviewViewModel.kt` 里的范围预设。

/// Daily Note 里的一条：时间 `HH:mm` + 文字（多行合并成一行）。[struck] 表示整条加了删除线（文字里已去掉 `~~`）
struct DailyEntry: Hashable, Codable {
    var time: String
    var text: String
    var struck: Bool = false
}

/// 某一天的 Daily Note：笔记 id + 条目（按写入顺序）
struct DailyDay: Codable, Equatable {
    var noteId: String
    var entries: [DailyEntry]
}

enum DailyFormat {
    /// 读取用的宽松版本：容忍时间戳前后的删除线 / 加粗 / 中括号，日期和时间之间可以是空格或 `T`。
    /// 分组：1 时间戳前的符号，2 时间 HH:mm，3 时间戳后紧跟的符号，4 正文
    private static let looseRE = RX(
        #"^\s*(?:[-*+]\s+)?((?:[*_~\[(（]\s*)*)[0-9]{4}-[0-9]{2}-[0-9]{2}[ T]([0-9]{2}:[0-9]{2})(?::[0-9]{2})?([*_~\])）]*)[ \t:：]*(.*)$"#,
        multiline: false
    )
    private static let numberedRE = RX(#"^\d+[.、)]\s"#, multiline: false)

    private struct Head { var time: String; var rest: String; var struck: Bool }

    private static func head(_ line: String) -> Head? {
        guard let m = looseRE.first(in: line) else { return nil }
        let rest = m.group(4)
        let struck = m.group(1).contains("~~") || m.group(3).contains("~~") || isWholeStruck(rest)
        return Head(time: m.group(2), rest: rest, struck: struck)
    }

    /// 正文整句被一对 `~~` 包住（中间没有别的 `~~`）
    private static func isWholeStruck(_ rest: String) -> Bool {
        let t = rest.trimmed
        guard t.count > 4, t.hasPrefix("~~"), t.hasSuffix("~~") else { return false }
        return !String(t.dropFirst(2).dropLast(2)).contains("~~")
    }

    /// 紧跟在条目后面的、不缩进也不是列表 / 标题 / 引用的文字行，算同一条的后续行
    private static func continues(_ line: String) -> Bool {
        if line.trimmed.isEmpty { return false }
        guard let c = line.first else { return false }
        if c.isWhitespace { return true }
        return !"#>-*+|".contains(c) && !numberedRE.contains(in: line)
    }

    /// 时间戳行（严格版，只用来把旧格式整理成列表）
    private static let strictRE = RX(
        #"^\s*(?:[-*+]\s+)?(?:\*\*)?([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2})(?::[0-9]{2})?(?:\*\*)?[ \t]*(.*)$"#,
        multiline: false
    )

    /// 生成一条列表条目：`- **时间** 内容`，多行内容用缩进保持在同一条目内
    static func formatEntry(_ text: String, stamp: String) -> String {
        let lines = text.trimmed.components(separatedBy: "\n")
        let first = lines.first ?? ""
        let rest = lines.dropFirst().map { $0.trimmed.isEmpty ? "" : "  " + $0 }
        return (["- **\(stamp)** \(first)"] + rest).joined(separator: "\n")
    }

    /// 把旧格式的条目统一整理为列表格式；其余内容原样保留
    static func normalize(_ content: String) -> String {
        content.components(separatedBy: "\n").map { line -> String in
            guard let m = strictRE.first(in: line) else { return line }
            let s = "- **\(m.group(1))** \(m.group(2))"
            return s.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }.joined(separator: "\n").trimmed
    }

    /// 去掉一条日记：时间戳行 + 它的续行；时间和文字（按 entries 同样的方式合并续行后）都对上才删。没找到返回 nil，其余内容原样保留。
    static func removeEntry(_ content: String, time: String, text: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        let wanted = text.trimmed
        var i = 0
        while i < lines.count {
            guard let h = head(lines[i]) else { i += 1; continue }
            var j = i + 1
            var body = h.rest
            while j < lines.count, head(lines[j]) == nil, continues(lines[j]) {
                body += " " + lines[j].trimmed
                j += 1
            }
            let merged = (h.struck ? body.replacingOccurrences(of: "~~", with: "") : body).trimmed
            if h.time == time && merged == wanted {
                return (Array(lines[..<i]) + Array(lines[j...])).joined(separator: "\n").trimmed
            }
            i = j
        }
        return nil
    }

    static func appendEntry(old: String, text: String, stamp: String) -> String {
        let entry = formatEntry(text, stamp: stamp)
        let normalized = normalize(old)
        return normalized.isEmpty ? entry : normalized + "\n" + entry
    }

    /// 解析出全部条目：引用块（今日简报之类）和其他文字跳过
    static func entries(_ content: String) -> [DailyEntry] {
        var out: [DailyEntry] = []
        var time: String?
        var struck = false
        var text = ""
        func flush() {
            if let t = time {
                let body = struck ? text.replacingOccurrences(of: "~~", with: "") : text
                if !body.trimmed.isEmpty { out.append(DailyEntry(time: t, text: body.trimmed, struck: struck)) }
            }
            time = nil
            struck = false
            text = ""
        }
        for line in content.components(separatedBy: "\n") {
            if let h = head(line) {
                flush()
                time = h.time
                struck = h.struck
                text += h.rest
            } else if time != nil && continues(line) {
                text += " " + line.trimmed
            } else {
                flush()
            }
        }
        flush()
        return out
    }
}

// MARK: - 读取

/// Daily Note 文件夹里的 Daily Note → 条目。过去的日子读过就缓存在内存里 10 分钟，只有今天每次重读。
final class DailyService: @unchecked Sendable {
    private let api: IdeashellApi
    private let lock = NSLock()
    private var pastDays: [String: (at: Date, day: DailyDay)] = [:]
    /// 昨天和今天的 Daily Note 容易有改动（10 分钟内认为还新）；更早的日子基本不会再变，缓存 12 小时，并且存在本机，重启后不用重读
    private static let recentTTL: TimeInterval = 600
    private static let oldTTL: TimeInterval = 12 * 3600
    private var diskLoaded = false

    private struct Stored: Codable { var at: Date; var day: DailyDay }

    private static func ttl(_ day: String) -> TimeInterval { day >= Day.add(Day.today(), days: -1) ? recentTTL : oldTTL }

    private func loadDiskIfNeeded() {
        lock.withLock {
            guard !diskLoaded else { return }
            diskLoaded = true
            guard let text = LocalStore.read("daily-past.json"), let data = text.data(using: .utf8),
                  let stored = try? JSONDecoder().decode([String: Stored].self, from: data) else { return }
            for (d, s) in stored where pastDays[d] == nil { pastDays[d] = (s.at, s.day) }
        }
    }

    private func saveDisk() {
        let snapshot: [String: Stored] = lock.withLock { pastDays.mapValues { Stored(at: $0.at, day: $0.day) } }
        if let d = try? JSONEncoder().encode(snapshot), let text = String(data: d, encoding: .utf8) {
            LocalStore.write("daily-past.json", text)
        }
    }

    /// 手动刷新时：过去的日子也重读
    func clearPast() {
        lock.withLock { pastDays.removeAll(); diskLoaded = true }
        LocalStore.remove("daily-past.json")
    }
    private static let parallel = 4

    init(api: IdeashellApi) { self.api = api }

    private static func normalize(_ name: String) -> String {
        let a = RX(#"[\s_\-·]+"#, multiline: false).replace(in: name.lowercased(), with: "")
        return RX("s$", multiline: false).replace(in: a, with: "")
    }

    private func findFolder() async throws -> IdeashellApi.Folder? {
        let folders = try await api.listFolders()
        let wanted = Self.normalize("Daily Notes")
        return folders.first { Self.normalize($0.name) == wanted }
            ?? folders.first { Self.normalize($0.name) == "dailynote" }
    }

    /// 追加一条到 [at] 那天的 Daily Note（没有就创建，文件夹也按需创建）。条目时间用「记录时间」
    func append(_ text: String, at: Date, images: [(name: String, data: Data)] = []) async throws {
        let date = Day.string(at)
        let c = Day.cal.dateComponents([.hour, .minute], from: at)
        let stamp = date + " " + String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        loadDiskIfNeeded()
        lock.withLock { _ = pastDays.removeValue(forKey: date) }
        saveDisk()

        let folder = try await findFolder()
        if let folder {
            let dateRE = RX("[0-9]{4}-[0-9]{2}-[0-9]{2}", multiline: false)
            let notes = try await api.notesInFolder(folder.id)
            if let hit = notes.first(where: { dateRE.first(in: $0.title)?.group(0) == date }) {
                let detail = try await api.noteFull(hit.id)
                try await api.updateNoteBody(hit.id, body: DailyFormat.appendEntry(old: detail.content, text: text, stamp: stamp), images: images)
                return
            }
        }
        var folderId = folder?.id
        if folderId == nil {
            let result = try await api.createFolder("Daily Notes")
            folderId = RX(#"folder_id[:\s"]*([a-f0-9]+)"#, multiline: false, ignoreCase: true).first(in: result)?.group(1)
                ?? RX("[a-f0-9]{32}", multiline: false, ignoreCase: true).first(in: result)?.group(0)
        }
        try await api.createNote(title: date, body: DailyFormat.formatEntry(text, stamp: stamp), tags: ["daily-note"], folderId: folderId, inlineTags: false, images: images)
    }

    /// 删除 [date] 那天 Daily Note 里的一条日记；返回是否真的删掉了
    func deleteEntry(date: String, entry: DailyEntry) async throws -> Bool {
        loadDiskIfNeeded()
        lock.withLock { _ = pastDays.removeValue(forKey: date) }
        saveDisk()
        let ids = try await list(from: date, to: date)
        guard let id = ids[date] else { return false }
        let detail = try await api.noteFull(id)
        guard let updated = DailyFormat.removeEntry(detail.content, time: entry.time, text: entry.text) else { return false }
        try await api.updateNoteBody(id, body: updated)
        return true
    }

    /// 文件夹里按标题日期倒序的 Daily Note：日期 yyyy-MM-dd → 笔记 id
    private func list(from: String, to: String) async throws -> [String: String] {
        guard let folder = try await findFolder() else { return [:] }
        let dateRE = RX("[0-9]{4}-[0-9]{2}-[0-9]{2}", multiline: false)
        var ids: [String: String] = [:]
        for n in try await api.notesInFolder(folder.id) {
            guard let d = dateRE.first(in: n.title).map({ $0.group(0) }), d >= from, d <= to, ids[d] == nil else { continue }
            ids[d] = n.id
        }
        return ids
    }

    /// [from]..[to] 之间每天的 Daily Note（含按时间戳拆开的条目）；没有 Daily Note 的天不在结果里。读失败的那一天跳过
    func days(from: String, to: String) async throws -> [String: DailyDay] {
        loadDiskIfNeeded()
        let ids = try await list(from: from, to: to)
        let today = Day.today()
        let now = Date()
        var result: [String: DailyDay] = [:]
        var missing: [(String, String)] = []
        for (d, id) in ids {
            let hit = lock.withLock { d < today ? pastDays[d] : nil }
            if let hit, hit.day.noteId == id, now.timeIntervalSince(hit.at) < Self.ttl(d) { result[d] = hit.day }
            else { missing.append((d, id)) }
        }
        let api = self.api
        // 每批最多 Self.parallel 个同时读
        var fetched: [(String, DailyDay?)] = []
        var from = 0
        while from < missing.count {
            let batch = Array(missing[from ..< min(from + Self.parallel, missing.count)])
            from += batch.count
            fetched += await runConcurrently(batch.count) { i in
                let (d, id) = batch[i]
                guard let detail = try? await api.noteFull(id) else { return (d, nil as DailyDay?) }
                return (d, DailyDay(noteId: id, entries: DailyFormat.entries(detail.content)) as DailyDay?)
            }
        }
        var cachedNew = false
        for (d, day) in fetched {
            guard let day else { continue }
            result[d] = day
            if d < today {
                lock.withLock { pastDays[d] = (Date(), day) }
                cachedNew = true
            }
        }
        if cachedNew { saveDisk() }
        return result
    }
}

// MARK: - 范围预设

enum RangePreset: String, CaseIterable, Identifiable {
    case today = "今天", yesterday = "昨天", last7 = "最近 7 天", thisWeek = "本周", lastWeek = "上周", thisMonth = "本月", lastMonth = "上月"
    var id: String { rawValue }

    /// 闭区间 [from, to]（yyyy-MM-dd）
    func range() -> (from: String, to: String) {
        let today = Day.today()
        let cal = Day.cal
        let now = Date()
        func weekStart(_ d: Date) -> Date {
            let wd = cal.component(.weekday, from: d)           // 1 = 周日
            return cal.date(byAdding: .day, value: -((wd + 5) % 7), to: Day.startOfDay(d)) ?? d
        }
        switch self {
        case .today: return (today, today)
        case .yesterday: let y = Day.add(today, days: -1); return (y, y)
        case .last7: return (Day.add(today, days: -6), today)
        case .thisWeek:
            let s = weekStart(now)
            return (Day.string(s), Day.string(cal.date(byAdding: .day, value: 6, to: s) ?? s))
        case .lastWeek:
            let s = cal.date(byAdding: .day, value: -7, to: weekStart(now)) ?? now
            return (Day.string(s), Day.string(cal.date(byAdding: .day, value: 6, to: s) ?? s))
        case .thisMonth, .lastMonth:
            let base = self == .thisMonth ? now : (cal.date(byAdding: .month, value: -1, to: now) ?? now)
            let first = cal.date(from: cal.dateComponents([.year, .month], from: base)) ?? base
            let last = cal.date(byAdding: DateComponents(month: 1, day: -1), to: first) ?? first
            return (Day.string(first), Day.string(last))
        }
    }
}

// MARK: - 时间河数据

struct DayBucket: Identifiable, Codable {
    var date: String
    /// 新的在前
    var notes: [NoteInfo]
    var todos: [DidaTask]
    var daily: [DailyEntry]
    var dailyNoteId: String?
    var id: String { date }
}

struct TimelineData: Codable {
    var from: String
    var to: String
    /// 新的一天在前
    var days: [DayBucket]
    var noteCount: Int
    var todoDone: Int
    var todoTotal: Int
    var dailyCount: Int
    var truncated: Bool
    var todoNote: String?

    var isEmpty: Bool { days.isEmpty }

    /// 把笔记、待办和 Daily Note 条目按天分组（新的在前）。
    /// 待办归属哪一天：未完成按计划日期；已完成按完成时间（今天做完的事算在今天），没有完成时间再用计划日期。无日期的待办不属于任何一天。
    static func build(from: String, to: String, notes: [NoteInfo], tasks: [DidaTask], truncated: Bool, todoNote: String?, daily: [String: DailyDay]) -> TimelineData {
        func taskDay(_ t: DidaTask) -> String? {
            if t.done, let c = t.completedDate { return Day.string(c) }
            return t.date
        }
        let todoDays: [(String, DidaTask)] = tasks.compactMap { t in
            guard let d = taskDay(t), d >= from, d <= to else { return nil }
            return (d, t)
        }
        // Daily Note 成功拆成日记行之后，不再作为「笔记」出现；没拆成的照旧显示成一条笔记
        let dailyIds = Set(daily.values.filter { !$0.entries.isEmpty }.map(\.noteId))
        let noteDays: [(String, NoteInfo)] = notes.filter { !dailyIds.contains($0.id) }.compactMap { n in n.day.map { ($0, n) } }
        let dailyDays = daily.filter { !$0.value.entries.isEmpty && $0.key >= from && $0.key <= to }

        let dates = Set(noteDays.map(\.0) + todoDays.map(\.0) + Array(dailyDays.keys)).sorted(by: >)
        let days = dates.map { date in
            DayBucket(
                date: date,
                notes: noteDays.filter { $0.0 == date }.map(\.1).sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") },
                todos: todoDays.filter { $0.0 == date }.map(\.1).sorted {
                    if $0.done != $1.done { return !$0.done }
                    return ($0.time ?? "99:99") < ($1.time ?? "99:99")
                },
                daily: dailyDays[date]?.entries ?? [],
                dailyNoteId: dailyDays[date]?.noteId
            )
        }
        let todos = todoDays.map(\.1)
        return TimelineData(
            from: from, to: to, days: days,
            noteCount: noteDays.count,
            todoDone: todos.filter(\.done).count,
            todoTotal: todos.count,
            dailyCount: dailyDays.values.reduce(0) { $0 + $1.entries.count },
            truncated: truncated, todoNote: todoNote
        )
    }

    /// 生成可直接贴进日报 / 周报的 Markdown
    func report(label: String) -> String {
        var summary = ["\(noteCount) 条笔记"]
        if dailyCount > 0 { summary.append("\(dailyCount) 条日记") }
        summary.append("待办完成 \(todoDone)/\(todoTotal)")
        var lines = ["# \(label) 回顾", "", "> " + summary.joined(separator: " · ")]
        for day in days {
            lines += ["", "## \(day.date) \(Day.label(day.date))"]
            if !day.daily.isEmpty {
                lines += ["", "**日记**", ""]
                for e in day.daily { lines.append("- \(e.time) \(e.text.prefix(120))") }
            }
            if !day.notes.isEmpty {
                lines += ["", "**笔记**", ""]
                for n in day.notes.reversed() {
                    let time = n.clock.map { "\($0) " } ?? ""
                    let sum = (n.summary?.nonEmpty).map { " — \($0.prefix(80))" } ?? ""
                    lines.append("- \(time)**\(n.title)**\(sum)")
                }
            }
            if !day.todos.isEmpty {
                lines += ["", "**待办**", ""]
                for t in day.todos { lines.append("- [\(t.done ? "x" : " ")] \(t.title)" + (t.time.map { "（\($0)）" } ?? "")) }
            }
        }
        return lines.joined(separator: "\n")
    }
}
