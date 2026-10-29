import Foundation

extension String {
    /// 列表里当标题显示：去掉 Markdown 标记（## 标题、> 引用、- 列表 / 清单、**粗体**、`代码`、[链接](…)）
    var mdPlain: String {
        var s = trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "^(#{1,6}[ \\t]+|>+[ \\t]*|[-*+][ \\t]+(\\[[ xX]\\][ \\t]+)?|\\d{1,3}[.、][ \\t]+)", with: "", options: .regularExpression)
        for p in ["\\*\\*(.+?)\\*\\*", "__(.+?)__", "~~(.+?)~~", "`([^`]+)`"] {
            s = s.replacingOccurrences(of: p, with: "$1", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}
