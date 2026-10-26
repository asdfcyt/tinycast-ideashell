import Foundation

enum CaptureKind: String, CaseIterable, Identifiable {
    case todo = "待办", daily = "Daily Note", note = "笔记"
    /// 结审（开启并连接后才出现），直接存进当前钉住的审计项目：
    /// 线索（独立 Markdown，可转疑点）/ 想法（阅读笔记，写进当天工作日志）/ 证据 / 法规
    case idea = "结审想法", evidence = "结审证据", regulation = "结审法规", clue = "结审线索"
    var id: String { rawValue }

    var isSjz: Bool { self == .clue || self == .idea || self == .evidence || self == .regulation }

    static func available(sjz: Bool) -> [CaptureKind] { allCases.filter { sjz || !$0.isSjz } }

    var icon: String {
        switch self {
        case .todo: return "checkmark.circle"
        case .daily: return "text.append"
        case .note: return "note.text"
        case .clue: return "lightbulb"
        case .idea: return "text.bubble"
        case .evidence: return "doc.badge.plus"
        case .regulation: return "book.closed"
        }
    }
}

struct CaptureAnalysis {
    /// 去掉强制前缀后的原文（保留 #标签 / @文件夹），追加到 Daily Note 时使用
    var text: String
    /// 再去掉 #标签 / @文件夹 后的正文，笔记和待办使用
    var body: String
    var tags: [String]
    var folderName: String?
    var todo: ParsedTodo
    /// 用户用前缀明确指定的类型
    var forced: CaptureKind?
    /// 自动判断的类型
    var recommended: CaptureKind

    var kind: CaptureKind { forced ?? recommended }
}

/// 万能输入解析，移植自安卓端 `CaptureParser.kt`：
/// - 前缀强制类型：`待办 …` / `todo …` / `提醒我 …`、`日记 …` / `daily …`、`笔记 …` / `note …`
/// - `#标签`、`@文件夹` 会被抽出（要求前面是行首或空白，避免误伤 C#、邮箱）
/// - 自动判断：待办 = 含「今天及以后的明确时间」或「明天及以后的日期」；笔记 = 带标签 / 文件夹；其余追加到 Daily Note
enum CaptureParser {
    /// 结审已启用并连接时，才识别「线索 / 想法 / 证据 / 法规」前缀（由 AppModel 同步）
    nonisolated(unsafe) static var sjzOn = false
    private static let sep = #"(?:\s*[:：,，]\s*|\s+)"#
    private static let prefixes: [(RX, CaptureKind)] = [
        (RX("^(?:待办|todo|提醒我?)" + sep, multiline: false, ignoreCase: true), .todo),
        (RX("^(?:日记|daily)" + sep, multiline: false, ignoreCase: true), .daily),
        (RX("^(?:笔记|note)" + sep, multiline: false, ignoreCase: true), .note),
        (RX("^(?:线索|clue)" + sep, multiline: false, ignoreCase: true), .clue),
        (RX("^(?:想法|idea)" + sep, multiline: false, ignoreCase: true), .idea),
        (RX("^(?:证据|evidence)" + sep, multiline: false, ignoreCase: true), .evidence),
        (RX("^(?:法规|regulation)" + sep, multiline: false, ignoreCase: true), .regulation),
    ]
    private static let reTag = RX(#"(^|[\s\u3000])#([^\s#@]+)"#, multiline: false)
    private static let reFolder = RX(#"(^|[\s\u3000])@([^\s#@]+)"#, multiline: false)
    private static let reMultiSpace = RX(#"[ \t]{2,}"#, multiline: false)

    static func analyze(_ input: String, now: Date = Date(), sjz: Bool? = nil) -> CaptureAnalysis {
        var text = input.trimmed
        var forced: CaptureKind?
        let sjzOn = sjz ?? Self.sjzOn
        for (re, kind) in prefixes {
            if kind.isSjz && !sjzOn { continue }
            if let m = re.first(in: text), m.range.location == 0 {
                forced = kind
                text = re.replace(in: text, with: "").trimmed
                break
            }
        }

        var tags: [String] = []
        var folderName: String?
        var body = reTag.replace(in: text) { m in
            tags.append(m.group(2))
            return m.group(1)
        }
        body = reFolder.replace(in: body) { m in
            if folderName == nil { folderName = m.group(2) }
            return m.group(1)
        }
        body = reMultiSpace.replace(in: body, with: " ").trimmed

        let todo = TodoParser.parse(body, now: now)
        let today = Day.today()
        var futureCue = false
        if let d = todo.date, d >= today { futureCue = todo.time != nil || d > today }

        let recommended: CaptureKind
        if futureCue { recommended = .todo }
        else if !tags.isEmpty || folderName != nil { recommended = .note }
        else { recommended = .daily }

        var seen = Set<String>()
        return CaptureAnalysis(
            text: text, body: body,
            tags: tags.filter { seen.insert($0).inserted },
            folderName: folderName, todo: todo, forced: forced, recommended: recommended
        )
    }

    private static func normInfer(_ s: String) -> String {
        RX(#"[\s_\-·]+"#, multiline: false).replace(in: s.lowercased(), with: "")
    }

    private static func dropTrailingS(_ s: String) -> String { s.hasSuffix("s") ? String(s.dropLast()) : s }

    /// 智能推断文件夹：正文里出现了某个已有文件夹的名字（取最长匹配，排除 Daily Note 文件夹）
    static func inferFolder(_ body: String, folders: [IdeashellApi.Folder]) -> IdeashellApi.Folder? {
        let lower = body.lowercased()
        var best: IdeashellApi.Folder?
        var bestLen = 0
        for f in folders {
            let n = normInfer(f.name)
            if n.count < 2 || dropTrailingS(n) == "dailynote" { continue }
            if lower.contains(n) && n.count > bestLen {
                best = f
                bestLen = n.count
            }
        }
        return best
    }

    /// 按名称找文件夹：完全相同 → 忽略大小写 / 空格 / 末尾 s → 包含
    static func matchFolder(_ name: String?, folders: [IdeashellApi.Folder]) -> IdeashellApi.Folder? {
        guard let name, !name.trimmed.isEmpty else { return nil }
        let n = dropTrailingS(normInfer(name))
        func norm(_ f: IdeashellApi.Folder) -> String { dropTrailingS(normInfer(f.name)) }
        return folders.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? folders.first { norm($0) == n }
            ?? folders.first { norm($0).contains(n) }
    }
}
