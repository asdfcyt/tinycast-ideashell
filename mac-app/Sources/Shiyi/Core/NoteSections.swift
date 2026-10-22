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
}
