import Foundation

/// Markdown 表格：粘贴时生成、预览时解析共用（`| a | b |` + `| --- | ---: |`）
enum MarkdownTable {
    enum Align: Int { case left, center, right }

    /// 单元格里的换行变空格，`|` 转义，免得撑破表格
    static func escapeCell(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
            .trimmed
    }

    /// 第一行当表头；列数不齐的补空格
    static func render(rows: [[String]], aligns: [Align] = []) -> String {
        let n = rows.map { $0.count }.max() ?? 0
        guard n > 0, !rows.isEmpty else { return "" }
        func line(_ r: [String]) -> String {
            var cells: [String] = []
            for i in 0 ..< n { cells.append(escapeCell(i < r.count ? r[i] : "")) }
            return "| " + cells.joined(separator: " | ") + " |"
        }
        var seps: [String] = []
        for i in 0 ..< n {
            switch i < aligns.count ? aligns[i] : .left {
            case .left: seps.append("---")
            case .center: seps.append(":---:")
            case .right: seps.append("---:")
            }
        }
        var out = [line(rows[0]), "| " + seps.joined(separator: " | ") + " |"]
        for r in rows.dropFirst() { out.append(line(r)) }
        return out.joined(separator: "\n")
    }

    /// 这一行是不是表格行（以 | 开头）
    static func isRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.count > 1
    }

    /// 切出一行的单元格；`\|` 当成普通的竖线
    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var out: [String] = []
        var cur = ""
        var esc = false
        for ch in t {
            if esc {
                if ch == "|" { cur.append("|") } else { cur.append("\\"); cur.append(ch) }
                esc = false
            } else if ch == "\\" {
                esc = true
            } else if ch == "|" {
                out.append(cur.trimmed)
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        if esc { cur.append("\\") }
        out.append(cur.trimmed)
        return out
    }

    /// 是分隔行（`---` / `:---:` / `---:`）就返回每列的对齐方式，不是返回 nil
    static func aligns(ofSeparator cells: [String]) -> [Align]? {
        guard !cells.isEmpty else { return nil }
        var out: [Align] = []
        for c in cells {
            guard !c.isEmpty, c.contains("-"), c.allSatisfy({ "-: ".contains($0) }) else { return nil }
            let l = c.hasPrefix(":"), r = c.hasSuffix(":")
            out.append(l && r ? .center : (r ? .right : .left))
        }
        return out
    }
}
