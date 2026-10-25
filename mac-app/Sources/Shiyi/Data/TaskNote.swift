import Foundation

/// 任务笔记（移植自安卓端 `NoteSections.taskNoteBody` / `ProjectService.createTaskNote`）
enum TaskNoteBuilder {
    /// 每行一条：去掉列表符号 / 序号 / 复选框；box 时写成 `- [ ] xxx`
    static func bullets(_ text: String, box: Bool) -> String {
        let prefix = RX(#"^\s*(?:[-*•·]\s+|\d+[.、)]\s*)?(?:\[[ xX]\]\s*)?"#, multiline: false)
        return text.split(whereSeparator: \.isNewline)
            .map { prefix.replace(in: String($0), with: "").trimmed }
            .filter { !$0.isEmpty }
            .map { box ? "- [ ] \($0)" : "- \($0)" }
            .joined(separator: "\n")
    }

    static func body(taskTitle: String, deliverable: String, purpose: String, steps: String, taskLink: String?) -> String {
        let purposeText = purpose.trimmed.isEmpty ? "（为什么要做这件事？）" : purpose.trimmed
        let stepText = bullets(steps, box: true)
        return [
            "## 任务\n" + (taskLink.map { "[\(taskTitle)](\($0))" } ?? taskTitle),
            "## 交付成果\n" + deliverable,
            "## 行动目的\n" + purposeText,
            "## 行动步骤\n" + (stepText.isEmpty ? "- [ ] （第一步做什么？）" : stepText),
            "## 进展记录\n",
            "## 复盘\n",
        ].joined(separator: "\n\n")
    }

    /// 笔记标题：任务名，最多 30 字
    static func title(_ cleanTitle: String) -> String {
        let flat = RX(#"\s+"#, multiline: false).replace(in: cleanTitle, with: " ").trimmed
        return flat.count <= 30 ? flat : String(flat.prefix(29)) + "…"
    }

    /// 从 `note_create` 的返回里取笔记 id
    static func noteId(from created: String) -> String? {
        if let m = RX(#""note_id"\s*:\s*"([^"]+)""#, multiline: false).first(in: created) { return m.group(1) }
        if let m = RX(#"note_id[:\s]+([0-9a-f]{16,})"#, multiline: false, ignoreCase: true).first(in: created) { return m.group(1) }
        if let m = RX(#"([a-f0-9]{32})"#, multiline: false, ignoreCase: true).first(in: created) { return m.group(1) }
        return nil
    }

    /// 滴答任务备注里的「任务笔记：<链接>」→ 笔记 id（安卓端换机后也是这样找回对应关系的）
    static func linkedNoteId(in content: String) -> String? {
        guard content.contains("任务笔记") else { return nil }
        return linkRE.first(in: content)?.group(1)
    }

    private static let linkRE = RX(#"任务笔记[：:]\s*https?://[^\s/]+/boards/([a-f0-9]+)"#, multiline: false, ignoreCase: true)
}
