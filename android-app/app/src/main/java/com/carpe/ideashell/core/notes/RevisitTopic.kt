package com.carpe.ideashell.core.notes

import com.carpe.ideashell.data.ideashell.DailyFormat

/**
 * 重温页「记一笔」的笔记排版（纯函数）。
 * Daily Note 里的一句话本身不能再往里加东西（它只是流水账里的一条），所以以这一句为底新建一篇「专题」笔记：
 * 开头是引用的原文和出处，下面的「想法」小节里每次重温写下的新想法按时间累积。
 */
object RevisitTopic {
    const val SECTION = "想法"
    const val TAG = "专题"
    private const val TITLE_MAX = 30

    /** 专题笔记的标题：取原文第一行，过长截断 */
    fun title(snippet: String): String {
        val first = snippet.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() }.orEmpty()
            .replace(Regex("\\s+"), " ")
        return when {
            first.isEmpty() -> "专题"
            first.length <= TITLE_MAX -> first
            else -> first.take(TITLE_MAX - 1) + "…"
        }
    }

    /** 新建专题笔记的正文：引用原文 + 出处，再开一个「想法」小节放第一条想法 */
    fun body(source: String, snippet: String, thought: String, stamp: String): String {
        val quote = (listOf("摘自 $source", "") + snippet.trim().lines().map { it.trimEnd() })
            .joinToString("\n") { if (it.isEmpty()) ">" else "> $it" }
        return "$quote\n\n## $SECTION\n${DailyFormat.formatEntry(thought, stamp)}"
    }

    /** 往已有笔记的「想法」小节末尾追加一条（小节不存在就新建在标签行之前） */
    fun appendThought(content: String, thought: String, stamp: String): String =
        NoteSections.editSection(content, SECTION) { old ->
            val entry = DailyFormat.formatEntry(thought, stamp)
            if (old.isBlank()) entry else "$old\n$entry"
        }
}
