import Foundation

/// 任务笔记 / 项目主页按 `## 小节标题` 读写（移植自安卓端 `NoteSections.kt`）
enum NoteSections {
    private static let heading = RX(#"^##\s+(.*)$"#, multiline: false)
    private static let tagLine = RX(#"^(?:#[^\s#]+\s*)+$"#, multiline: false)

    /// 本地 "yyyy-MM-dd HH:mm"
    static func minuteStamp(_ now: Date = Date()) -> String {
        let c = Day.cal.dateComponents([.hour, .minute], from: now)
        return Day.string(now) + String(format: " %02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private static func headingOf(_ line: String) -> String? {
        heading.first(in: line).map { $0.group(1).trimmed }
    }

    private static func isBlankOrTag(_ line: String) -> Bool {
        let t = line.trimmed
        return t.isEmpty || tagLine.first(in: t) != nil
    }

    /// 修改 `## 标题` 小节：[fn] 收到现有正文，返回新正文；小节不存在则追加到末尾（标签行之前）
    static func editSection(_ content: String, title: String, _ fn: (String) -> String) -> String {
        let lines = content.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { headingOf($0) == title }) else {
            var end = lines.count
            while end > 0, isBlankOrTag(lines[end - 1]) { end -= 1 }
            return (Array(lines[..<end]) + ["", "## \(title)", fn("").trimmed] + Array(lines[end...])).joined(separator: "\n")
        }
        var end = ((start + 1) ..< lines.count).first { heading.first(in: lines[$0]) != nil } ?? -1
        if end < 0 {
            end = lines.count
            while end > start + 1, isBlankOrTag(lines[end - 1]) { end -= 1 }
        }
        let body = lines[(start + 1) ..< end].joined(separator: "\n").trimmed
        let next = fn(body).trimmed
        return (Array(lines[...start]) + [next, ""] + Array(lines[end...])).joined(separator: "\n")
    }

    // MARK: 读小节（项目主页的组件用）

    /// 读 `## 标题` 小节的正文（去掉首尾空白）；小节不存在返回 nil。规则与 `editSection` 一致
    static func sectionBody(_ content: String, title: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { headingOf($0) == title }) else { return nil }
        var end = ((start + 1) ..< lines.count).first { heading.first(in: lines[$0]) != nil } ?? -1
        if end < 0 {
            end = lines.count
            while end > start + 1, isBlankOrTag(lines[end - 1]) { end -= 1 }
        }
        return lines[(start + 1) ..< end].joined(separator: "\n").trimmed
    }

    /// 模板里的占位行：整行（可带列表符号）是一句用全角括号包起来的提示，例如「（这个项目最终要达成什么？）」
    static func isPlaceholderLine(_ line: String) -> Bool {
        var t = line.trimmed
        if t.hasPrefix("-") || t.hasPrefix("*") { t = String(t.dropFirst()).trimmed }
        return t.hasPrefix("（") && t.hasSuffix("）")
    }

    private static let bulletPrefix = RX(#"^[\s\-*•\d.、)]+"#, multiline: false)

    /// 把多行文字整理成列表；`box` 为 true 时是待勾选清单
    static func bullets(_ text: String, box: Bool = false) -> String {
        text.components(separatedBy: "\n")
            .map { bulletPrefix.replace(in: $0, with: "").trimmed }
            .filter { !$0.isEmpty }
            .map { box ? "- [ ] \($0)" : "- \($0)" }
            .joined(separator: "\n")
    }

    private static let stepLine = RX(#"^\s*[-*]\s+\[([ xX])\]\s+(.*)$"#, multiline: false)

    /// 统计「行动步骤」小节里的 `- [x]` / `- [ ]`；没有步骤返回 nil（模板里的占位步骤不算）
    static func stepProgress(_ content: String) -> (done: Int, total: Int)? {
        let lines = content.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { headingOf($0) == "行动步骤" }) else { return nil }
        var done = 0, total = 0
        var i = start + 1
        while i < lines.count, heading.first(in: lines[i]) == nil {
            if let m = stepLine.first(in: lines[i]), !m.group(2).trimmed.hasPrefix("（") {
                total += 1
                if m.group(1) != " " { done += 1 }
            }
            i += 1
        }
        return total > 0 ? (done, total) : nil
    }
}
