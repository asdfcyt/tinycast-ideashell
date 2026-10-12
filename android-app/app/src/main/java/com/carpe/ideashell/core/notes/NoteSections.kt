package com.carpe.ideashell.core.notes

import java.time.LocalDateTime

/**
 * 任务笔记 / 项目主页的正文排版与按小节读写（纯函数，规则与桌面 `task-notes.ts` 一致）。
 * 两者都只是普通的闪念贝壳笔记，用 `## 小节标题` 划分区域。
 */
object NoteSections {
    private val HEADING = Regex("^##\\s+(.*)$")
    private val TAG_LINE = Regex("^(?:#[^\\s#]+\\s*)+$")
    private val STEP_LINE = Regex("^\\s*[-*]\\s+\\[([ xX])]\\s+(.*)$")
    private val BULLET_PREFIX = Regex("^[\\s\\-*•\\d.、)]+")

    /** 本地 "YYYY-MM-DD HH:mm" */
    fun minuteStamp(now: LocalDateTime = LocalDateTime.now()): String =
        "%s %02d:%02d".format(now.toLocalDate(), now.hour, now.minute)

    private fun headingOf(line: String): String? = HEADING.find(line)?.groupValues?.get(1)?.trim()

    /** 把多行文字整理成列表；[box] 为 true 时是待勾选清单 */
    fun bullets(text: String, box: Boolean = false): String =
        text.lines()
            .map { it.replace(BULLET_PREFIX, "").trim() }
            .filter { it.isNotEmpty() }
            .joinToString("\n") { if (box) "- [ ] $it" else "- $it" }

    /**
     * 修改 `## 标题` 小节：[fn] 收到现有正文，返回新正文；
     * 小节不存在则追加到末尾（标签行之前）。
     */
    fun editSection(content: String, title: String, fn: (String) -> String): String {
        val lines = content.lines()
        val start = lines.indexOfFirst { headingOf(it) == title }
        if (start < 0) {
            var end = lines.size
            while (end > 0 && (lines[end - 1].isBlank() || TAG_LINE.matches(lines[end - 1].trim()))) end--
            return (lines.take(end) + listOf("", "## $title", fn("").trim()) + lines.drop(end)).joinToString("\n")
        }
        var end = lines.indices.firstOrNull { it > start && HEADING.containsMatchIn(lines[it]) } ?: -1
        if (end < 0) {
            end = lines.size
            while (end > start + 1 && (lines[end - 1].isBlank() || TAG_LINE.matches(lines[end - 1].trim()))) end--
        }
        val body = lines.subList(start + 1, end).joinToString("\n").trim()
        val next = fn(body).trim()
        return (lines.take(start + 1) + listOf(next, "") + lines.drop(end)).joinToString("\n")
    }

    /** 读 `## 标题` 小节的正文（去掉首尾空白）；小节不存在返回 null。规则与 [editSection] 一致 */
    fun sectionBody(content: String, title: String): String? {
        val lines = content.lines()
        val start = lines.indexOfFirst { headingOf(it) == title }
        if (start < 0) return null
        var end = lines.indices.firstOrNull { it > start && HEADING.containsMatchIn(lines[it]) } ?: -1
        if (end < 0) {
            end = lines.size
            while (end > start + 1 && (lines[end - 1].isBlank() || TAG_LINE.matches(lines[end - 1].trim()))) end--
        }
        return lines.subList(start + 1, end).joinToString("\n").trim()
    }

    /** 模板里的占位行：整行（可带列表符号）是一句用全角括号包起来的提示，例如「（这个项目最终要达成什么？）」 */
    fun isPlaceholderLine(line: String): Boolean {
        val t = line.trim().removePrefix("-").removePrefix("*").trim()
        return t.startsWith("（") && t.endsWith("）")
    }

    /** 统计「行动步骤」小节里的 `- [x]` / `- [ ]`；没有步骤返回 null（模板里的占位步骤不算） */
    fun stepProgress(content: String): Pair<Int, Int>? {
        val lines = content.lines()
        val start = lines.indexOfFirst { headingOf(it) == "行动步骤" }
        if (start < 0) return null
        var done = 0
        var total = 0
        var i = start + 1
        while (i < lines.size && !HEADING.containsMatchIn(lines[i])) {
            val m = STEP_LINE.find(lines[i])
            if (m != null && !m.groupValues[2].trim().startsWith("（")) {
                total++
                if (m.groupValues[1] != " ") done++
            }
            i++
        }
        return if (total > 0) done to total else null
    }

    // ── 任务笔记 ──

    data class TaskNoteInput(
        val taskTitle: String,
        val deliverable: String,
        val purpose: String,
        val steps: String,
        val project: String? = null,
        val taskLink: String? = null,
    )

    fun taskNoteBody(i: TaskNoteInput): String = listOf(
        "## 任务\n${if (i.taskLink != null) "[${i.taskTitle}](${i.taskLink})" else i.taskTitle}",
        "## 交付成果\n${i.deliverable}",
        "## 行动目的\n${i.purpose.trim().ifEmpty { "（为什么要做这件事？）" }}",
        "## 行动步骤\n${bullets(i.steps, box = true).ifEmpty { "- [ ] （第一步做什么？）" }}",
        "## 进展记录\n",
        "## 复盘\n",
    ).joinToString("\n\n")

    // ── 项目主页笔记 ──

    fun projectHomeBody(keyword: String, tags: List<String>, links: String, now: LocalDateTime = LocalDateTime.now()): String = listOf(
        "## 目标\n（这个项目最终要达成什么？）",
        "## 交付成果\n（要交付的成果，而不是要做的事情。例如「完成一篇可发表的论文初稿」）",
        "## 任务笔记（自动汇总）\n${links.ifEmpty { "（还没有任务笔记）" }}",
        "## 项目状态（自动汇总）\n（在项目主页点「更新汇总」：下一步、成果进度、近 7 天专注）",
        "## 资料与链接\n- （把资料、链接贴在这里）",
        "## 里程碑与进展\n- ${minuteStamp(now)} 建立项目主页",
        "## 复盘与经验\n",
        "项目关键词：${(listOf(keyword) + tags).joinToString("、")}",
    ).joinToString("\n\n")

    /** 里程碑文字：有任务笔记就写交付成果并带链接，否则写任务标题 */
    fun milestoneText(title: String, deliverable: String?, noteLink: String?): String =
        if (deliverable != null) "完成：$deliverable${if (noteLink != null) "（[任务笔记]($noteLink)）" else ""}" else "完成：$title"
}
