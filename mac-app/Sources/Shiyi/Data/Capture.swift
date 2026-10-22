import Foundation

enum CaptureKind: String, CaseIterable, Identifiable {
    case todo = "待办", daily = "Daily Note", note = "笔记"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .todo: return "checkmark.circle"
        case .daily: return "text.append"
        case .note: return "note.text"
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
    private static let sep = #"(?:\s*[:：,，]\s*|\s+)"#
    private static let prefixes: [(RX, CaptureKind)] = [
        (RX("^(?:待办|todo|提醒我?)" + sep, multiline: false, ignoreCase: true), .todo),
        (RX("^(?:日记|daily)" + sep, multiline: false, ignoreCase: true), .daily),
        (RX("^(?:笔记|note)" + sep, multiline: false, ignoreCase: true), .note),
    ]
    private static let reTag = RX(#"(^|[\s\u3000])#([^\s#@]+)"#, multiline: false)
    private static let reFolder = RX(#"(^|[\s\u3000])@([^\s#@]+)"#, multiline: false)
    private static let reMultiSpace = RX(#"[ \t]{2,}"#, multiline: false)

    static func analyze(_ input: String, now: Date = Date()) -> CaptureAnalysis {
        var text = input.trimmed
        var forced: CaptureKind?
        for (re, kind) in prefixes {
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
