package com.carpe.ideashell.domain

import com.carpe.ideashell.data.ideashell.NoteInfo

/** 笔记文本的纯函数处理（规则与桌面 `note-text.ts` / `utils.ts` 一致） */
object NoteText {
    private val RE_MEMO_TITLE = Regex("\\*\\*Memo \\d+:[^*]*\\*\\*")
    private val RE_INLINE_TAG = Regex("#([\\p{L}\\p{N}_-]+)")
    private val RE_ONLY_DIGITS = Regex("^\\d+$")

    /** 取出 memo 正文：丢掉头部元信息、memo 标题行、重复的 `summary:` 行和分隔线 */
    fun memoText(text: String): String {
        val i = text.indexOf("## Memos")
        val memos = if (i >= 0) text.substring(i + "## Memos".length) else text
        return memos.lines()
            .filter { !it.trim().startsWith("summary:", ignoreCase = true) && it.trim() != "---" }
            .joinToString("\n")
            .replace(RE_MEMO_TITLE, " ")
    }

    /** 笔记标签：接口 tags 字段 + 正文里的行内 `#标签` */
    fun extractTags(note: NoteInfo, body: String): List<String> {
        val set = LinkedHashSet<String>(note.tags)
        for (m in RE_INLINE_TAG.findAll(body)) {
            val tag = m.groupValues[1]
            if (!RE_ONLY_DIGITS.matches(tag)) set.add(tag)
        }
        return set.toList()
    }

    /** 单行化并截断，超出补「…」 */
    fun truncate(s: String, max: Int): String {
        val flat = s.replace(Regex("\\s+"), " ").trim()
        return if (flat.length <= max) flat else flat.take(max - 1) + "…"
    }
}
