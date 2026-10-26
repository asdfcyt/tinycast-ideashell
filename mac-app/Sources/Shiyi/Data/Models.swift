import Foundation

// MARK: - 闪念贝壳笔记

struct NoteInfo: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var summary: String?
    var tags: [String] = []
    var createdAt: String?
    var text: String?

    var date: Date? { NoteTime.parse(createdAt) }
    var day: String? { NoteTime.day(createdAt) }
    var clock: String? { NoteTime.clock(createdAt) }
}

struct NoteDetail {
    let id: String
    var title: String
    var createdAt: String?
    var tags: [String]
    var summary: String?
    /// Markdown 正文（已去掉 memo 标题行与重复的 summary 行）
    var content: String
    var raw: String

    var day: String? { NoteTime.day(createdAt) }
    var clock: String? { NoteTime.clock(createdAt) }
}

struct NotesInRange {
    var notes: [NoteInfo]
    var truncated: Bool
}

func noteURL(_ noteId: String) -> URL { URL(string: "https://ideashell.site/boards/\(noteId)")! }

// MARK: - 滴答任务

struct DidaTask: Identifiable, Hashable, Codable {
    let id: String
    var projectId: String
    var title: String
    var content: String = ""
    /// yyyy-MM-dd（本地日期，无日期为 nil）
    var date: String?
    /// HH:mm（全天任务为 nil）
    var time: String?
    /// 0 无 / 1 低 / 3 中 / 5 高
    var priority: Int = 0
    var tags: [String] = []
    var done: Bool = false
    var completedAt: Int64?
    var createdAt: Int64?
    var repeatFlag: String?
    /// 结审任务的计划开始日 yyyy-MM-dd（只有结审任务有；甘特图用）
    var startDate: String?
    /// 结审任务所属的审计阶段 key（preparation / implementation / reporting / rectification）
    var phase: String?

    var completedDate: Date? { completedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

    /// 旧版本写在标题里的 `!重要` `!紧急` 标记不显示
    var cleanTitle: String {
        // 绝大多数标题没有标记：先用字符判断挡掉，别每次都跑正则（列表每重绘一次，每一行都会调用）
        guard title.contains(where: { $0 == "!" || $0 == "！" }) else { return title }
        let a = Self.importantRE.replace(in: title, with: "")
        let b = Self.urgentRE.replace(in: a, with: "").trimmed
        return b.isEmpty ? title : b
    }

    private static let importantRE = RX(#"\s*[!！]重要"#, multiline: false)
    private static let urgentRE = RX(#"\s*[!！]紧急"#, multiline: false)
}

struct DidaOverview: Codable, Equatable {
    var overdue: [DidaTask] = []
    var upcoming: [DidaTask] = []
    var undated: [DidaTask] = []
    var done: [DidaTask] = []
    var projects: [String: String] = [:]
    var warning: String?

    var openCount: Int { overdue.count + upcoming.count + undated.count }

    func todayTasks(_ today: String = Day.today()) -> [DidaTask] { upcoming.filter { $0.date == today } }

    func withoutTask(_ id: String) -> DidaOverview {
        var c = self
        c.overdue.removeAll { $0.id == id }
        c.upcoming.removeAll { $0.id == id }
        c.undated.removeAll { $0.id == id }
        return c
    }

    /// 把改过的任务放到它现在该在的分组里（逾期 / 今天起 / 无日期）。分组没变就原位替换，
    /// 这样静默刷新读回来的顺序和这里一致，整份数据「没变」，界面就不用再刷新一遍。
    func placing(_ n: DidaTask, today: String = Day.today()) -> DidaOverview {
        var c = self
        if let i = c.overdue.firstIndex(where: { $0.id == n.id }), let d = n.date, d < today { c.overdue[i] = n; return c }
        if let i = c.upcoming.firstIndex(where: { $0.id == n.id }), let d = n.date, d >= today { c.upcoming[i] = n; return c }
        if let i = c.undated.firstIndex(where: { $0.id == n.id }), n.date == nil { c.undated[i] = n; return c }
        c = c.withoutTask(n.id)
        if let d = n.date {
            if d < today { c.overdue.append(n) } else { c.upcoming.append(n) }
        } else {
            c.undated.append(n)
        }
        return c
    }

    func projectName(_ id: String) -> String? {
        if let n = projects[id] { return n }
        if id.lowercased().hasPrefix("inbox") { return "收集箱" }
        return nil
    }
}

func didaTaskURL(_ projectId: String, _ taskId: String) -> URL {
    URL(string: "https://dida365.com/webapp/#p/\(projectId)/tasks/\(taskId)")!
}

// MARK: - 手机备份（`shiyi-backup`）

enum ProjectStatus: String, Codable {
    case ACTIVE, SHORT, LONG, PAUSED

    var label: String {
        switch self {
        case .ACTIVE: return "进行中"
        case .SHORT: return "短期"
        case .LONG: return "长期"
        case .PAUSED: return "搁置"
        }
    }
}

struct Project: Codable, Hashable, Identifiable {
    var keyword: String
    var addedAt: Int64?
    var staleDays: Int?
    var status: ProjectStatus?
    var next: String?
    var tags: [String]?

    var id: String { keyword }
    var projectStatus: ProjectStatus { status ?? .ACTIVE }
    var stale: Int { staleDays ?? 7 }

    /// 关键词 + 标签（去重，忽略大小写）
    var terms: [String] {
        var seen = Set<String>()
        return ([keyword] + (tags ?? [])).map { $0.trimmed }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static let minTermLength = 2

    /// 任务 / 笔记属于这个项目吗？规则与安卓端 `Project.matches` 一致
    func matches(_ content: String, tags taskTags: [String] = []) -> Bool {
        let text = content.lowercased()
        let tagSet = Set(taskTags.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#")) })
        return terms.contains { Project.termMatches($0.lowercased(), text, tagSet) }
    }

    private static func termMatches(_ term: String, _ text: String, _ tagSet: Set<String>) -> Bool {
        if tagSet.contains(term) { return true }
        if hashMention(text, term) { return true }
        if term.count < minTermLength { return false }
        let ascii = term.unicodeScalars.allSatisfy { $0.value < 128 && CharacterSet.alphanumerics.contains($0) }
        return ascii ? containsWord(text, term) : text.contains(term)
    }

    private static func hashMention(_ text: String, _ term: String) -> Bool {
        let needle = "#" + term
        var search = text.startIndex ..< text.endIndex
        while let r = text.range(of: needle, range: search) {
            if r.upperBound == text.endIndex { return true }
            let next = text[r.upperBound]
            if !(next.isLetter || next.isNumber || next == "_") { return true }
            search = text.index(after: r.lowerBound) ..< text.endIndex
        }
        return false
    }

    private static func containsWord(_ text: String, _ term: String) -> Bool {
        func isAsciiWord(_ c: Character?) -> Bool {
            guard let c, let a = c.asciiValue else { return false }
            return (a >= 48 && a <= 57) || (a >= 65 && a <= 90) || (a >= 97 && a <= 122)
        }
        var search = text.startIndex ..< text.endIndex
        while let r = text.range(of: term, range: search) {
            let before: Character? = r.lowerBound > text.startIndex ? text[text.index(before: r.lowerBound)] : nil
            let after: Character? = r.upperBound < text.endIndex ? text[r.upperBound] : nil
            if !isAsciiWord(before) && !isAsciiWord(after) { return true }
            search = text.index(after: r.lowerBound) ..< text.endIndex
        }
        return false
    }
}

struct TaskNoteRef: Codable, Hashable {
    var noteId: String
    var deliverable: String?
    var project: String?
    var createdAt: Int64?
    var archived: Bool?
}

struct TemplateField: Codable, Hashable {
    var name: String
    var multiline: Bool?
}

struct NoteTemplate: Codable, Hashable {
    var name: String
    var fields: [TemplateField]?
    var tags: [String]?
    var folderName: String?
    var builtin: Bool?
}

struct FocusLogEntry: Codable, Hashable {
    var project: String
    var startMs: Int64
    var endMs: Int64
    var taskId: String?
    var title: String?

    var minutes: Int { max(0, Int((endMs - startMs) / 60_000)) }
    var startDate: Date { Date(timeIntervalSince1970: Double(startMs) / 1000) }
}

struct Workspace: Codable {
    var projects: [Project] = []
    var taskNotes: [String: TaskNoteRef] = [:]
    var homes: [String: String] = [:]
    var templates: [NoteTemplate] = []
    var focusLog: [FocusLogEntry] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = (try? c.decode([Project].self, forKey: .projects)) ?? []
        taskNotes = (try? c.decode([String: TaskNoteRef].self, forKey: .taskNotes)) ?? [:]
        homes = (try? c.decode([String: String].self, forKey: .homes)) ?? [:]
        templates = (try? c.decode([NoteTemplate].self, forKey: .templates)) ?? []
        focusLog = (try? c.decode([FocusLogEntry].self, forKey: .focusLog)) ?? []
    }

    enum CodingKeys: String, CodingKey { case projects, taskNotes, homes, templates, focusLog }
}

/// 重温项（手机端 FSRS 间隔重温；字段与备份里的 RevisitItemBackup 一一对应）
struct RevisitItem: Codable, Identifiable, Hashable {
    var dedupeKey: String
    var kind: String?
    var noteId: String?
    var title: String?
    var text: String?
    var sourceLabel: String?
    var recordedAt: Int64?
    var addedAt: Int64?
    var stability: Double?
    var difficulty: Double?
    var due: Int64?
    var reps: Int?
    var lapses: Int?
    var lastRating: Int?
    var lastReviewAt: Int64?
    var skippedUntil: Int64?
    var archived: Bool?
    var topicNoteId: String?

    var id: String { dedupeKey }
    var isArchived: Bool { archived ?? false }
    var repsN: Int { reps ?? 0 }
    var lapsesN: Int { lapses ?? 0 }
    var stabilityN: Double { stability ?? 0 }
    var dueMs: Int64 { due ?? 0 }
    var lastReviewMs: Int64 { lastReviewAt ?? 0 }
    var displayTitle: String { (title ?? "").nonEmpty ?? "重温卡片" }
    var body: String { text ?? "" }
}

struct RevisitLogLite: Codable {
    var itemKey: String
    var reviewedAt: Int64
    var rating: Int
}

struct BackupSettingsLite: Codable {
    var revisitDailyLimit: Int?
    var revisitRetention: Int?
}

struct BackupFile: Decodable {
    static let format = "shiyi-backup"
    static let supportedVersion = 1

    var format: String
    var version: Int
    var appVersion: String?
    var exportedAt: Int64?
    var workspace: Workspace
    var revisitItems: [RevisitItem]
    var revisitLogs: [RevisitLogLite]
    var settings: BackupSettingsLite?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        appVersion = try? c.decode(String.self, forKey: .appVersion)
        exportedAt = try? c.decode(Int64.self, forKey: .exportedAt)
        workspace = (try? c.decode(Workspace.self, forKey: .workspace)) ?? Workspace()
        revisitItems = Self.lossy(c, .revisitItems)
        revisitLogs = Self.lossy(c, .revisitLogs)
        settings = try? c.decode(BackupSettingsLite.self, forKey: .settings)
    }

    /// 数组里个别元素格式不对时跳过，不让整份备份读不出来
    private static func lossy<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [T] {
        guard var arr = try? c.nestedUnkeyedContainer(forKey: key) else { return [] }
        var out: [T] = []
        while !arr.isAtEnd {
            if let v = try? arr.decode(T.self) { out.append(v) } else { _ = try? arr.decode(Skip.self) }
        }
        return out
    }

    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

    enum CodingKeys: String, CodingKey { case format, version, appVersion, exportedAt, workspace, revisitItems, revisitLogs, settings }

    var exportedDate: Date? { exportedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
}
