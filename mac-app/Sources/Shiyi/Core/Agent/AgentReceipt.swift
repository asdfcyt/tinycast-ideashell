import Foundation

/// Agent 的结构化回执：最后一条消息末尾带一个 ```shiyi 代码块（也认 ```agent-autoloop，已有的 autoloop Skill 直接能用）。
/// - ask：带选项的提问 → 验收卡上的选项按钮（取代靠猜的固定按钮）
/// - notice：要告诉你的结论 → 接在回复后面
/// - later：稍后复查 → 建一条带「调度台」标签的滴答提醒
struct AgentReceipt {
    struct Ask {
        var title: String
        var options: [String]
        var recommend: Int?
    }

    struct Notice {
        var title: String
        var text: String
    }

    struct Later {
        var at: Date
        var about: String
    }

    var asks: [Ask] = []
    var notices: [Notice] = []
    var laters: [Later] = []

    var isEmpty: Bool { asks.isEmpty && notices.isEmpty && laters.isEmpty }
}

enum ReceiptParser {
    struct Result {
        /// 去掉回执代码块后的正文
        var text: String
        var receipt: AgentReceipt?
        /// 有回执代码块但内容不是合法的回执
        var malformed: Bool
    }

    private static let block = RX("```[ \\t]*(shiyi|agent-autoloop)[^\\n]*\\n([\\s\\S]*?)```", multiline: false)

    /// 从 Agent 的最后一条消息里取回执（取最后一个代码块），并把代码块从正文里去掉
    static func extract(_ s: String) -> Result {
        let ns = s as NSString
        let hits = block.re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard let m = hits.last else { return Result(text: s, receipt: nil, malformed: false) }
        let body = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = ns.replacingCharacters(in: m.range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = body.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Result(text: clean, receipt: nil, malformed: true)
        }
        var r = AgentReceipt()
        for o in list(root["ask"]) {
            let title = str(o["title"] ?? o["question"] ?? o["text"])
            let opts = (o["options"] as? [Any] ?? []).compactMap { v -> String? in
                if let s = v as? String { return s.nonEmpty }
                if let d = v as? [String: Any] { return str(d["label"] ?? d["title"] ?? d["text"]).nonEmpty }
                return nil
            }
            guard !title.isEmpty || !opts.isEmpty else { continue }
            let rec = (o["recommend"] as? Int) ?? (o["recommended"] as? Int)
            r.asks.append(.init(title: title, options: Array(opts.prefix(6)), recommend: rec.flatMap { opts.indices.contains($0) ? $0 : nil }))
        }
        for o in list(root["notice"]) {
            let title = str(o["title"]), text = str(o["text"] ?? o["body"])
            if !title.isEmpty || !text.isEmpty { r.notices.append(.init(title: title, text: text)) }
        }
        for o in list(root["later"]) {
            guard let at = date(o["at"]) else { continue }
            r.laters.append(.init(at: at, about: str(o["about"] ?? o["title"] ?? o["text"])))
        }
        // 能解析成 JSON，但一个有用的字段都没有：也算格式不对
        if r.isEmpty { return Result(text: clean, receipt: nil, malformed: true) }
        return Result(text: clean, receipt: r, malformed: false)
    }

    /// 字段既可以是数组也可以是单个对象
    private static func list(_ v: Any?) -> [[String: Any]] {
        if let a = v as? [[String: Any]] { return a }
        if let d = v as? [String: Any] { return [d] }
        return []
    }

    private static func str(_ v: Any?) -> String {
        (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func date(_ v: Any?) -> Date? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// 派活时追加在指令后面的回执约定
    static let promptSuffix = """


    ---
    回执约定：这一轮做完后，如果需要我拍板、有要告诉我的结论、或需要稍后复查，请在最后一条消息的末尾加一个 ```shiyi 代码块（都没有就不要加），内容是 JSON：
    {"ask":[{"title":"要问的问题","options":["选项A","选项B"],"recommend":0}],"notice":[{"title":"标题","text":"内容"}],"later":[{"at":"2026-11-05T09:00:00+08:00","about":"要复查什么"}]}
    字段都可以省略。需要我回答时，提完问题就结束这一轮，不要继续等。
    """

    /// 回执格式不对时，让它只重发最后一段
    static let rewriteRequest = "你上一条消息末尾的 ```shiyi 回执不是合法的 JSON。请只重新发一遍最后那个 ```shiyi 代码块（合法 JSON，字段只能是 ask / notice / later），不要重做其他事。"
}
