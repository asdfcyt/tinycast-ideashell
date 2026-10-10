package com.carpe.ideashell.core.parse

import java.time.LocalDate

enum class Quadrant(val title: String, val hint: String) {
    Q1("重要且紧急", "马上做"),
    Q2("重要不紧急", "计划着做"),
    Q3("紧急但不重要", "尽量交出去 / 快速处理"),
    Q4("不重要不紧急", "有空再说"),
}

/**
 * 待办的「重要 / 紧急」标记直接写在待办文字里（换设备也在）：`!重要`、`!紧急`。
 * 紧急还会按日期自动判断（今天、明天或已逾期）。规则与桌面 `todo-meta.ts` 一致。
 */
object TodoMeta {
    private val IMPORTANT_RE = Regex("\\s*[!！]重要")
    private val URGENT_RE = Regex("\\s*[!！]紧急")

    fun isMarkedImportant(content: String): Boolean = IMPORTANT_RE.containsMatchIn(content)

    fun isMarkedUrgent(content: String): Boolean = URGENT_RE.containsMatchIn(content)

    /** 去掉标记后的标题；去完为空则原样返回 */
    fun cleanTitle(content: String): String =
        content.replace(IMPORTANT_RE, "").replace(URGENT_RE, "").trim().ifEmpty { content }

    /** 已有该标记就去掉，没有就追加到末尾 */
    fun toggleMark(content: String, mark: Mark): String {
        val re = if (mark == Mark.IMPORTANT) IMPORTANT_RE else URGENT_RE
        val has = if (mark == Mark.IMPORTANT) isMarkedImportant(content) else isMarkedUrgent(content)
        return if (has) content.replace(re, "").trim() else "${content.trim()} !${mark.label}"
    }

    enum class Mark(val label: String) { IMPORTANT("重要"), URGENT("紧急") }

    /** 日期（YYYY-MM-DD）在明天及以前视为紧急 */
    fun quadrantOf(content: String, date: String?, today: LocalDate = LocalDate.now()): Quadrant {
        val limit = today.plusDays(1).toString()
        val important = isMarkedImportant(content)
        val urgent = isMarkedUrgent(content) || (date != null && date <= limit)
        return if (important) {
            if (urgent) Quadrant.Q1 else Quadrant.Q2
        } else {
            if (urgent) Quadrant.Q3 else Quadrant.Q4
        }
    }
}
