package com.carpe.ideashell.core.parse

/**
 * 旧版本写在待办文字里的 `!重要`、`!紧急` 标记：不再使用（四象限已去掉，只保留滴答的优先级），
 * 但老任务的标题里可能还带着，显示时用 [cleanTitle] 去掉。
 */
object TodoMeta {
    private val IMPORTANT_RE = Regex("\\s*[!！]重要")
    private val URGENT_RE = Regex("\\s*[!！]紧急")

    /** 去掉标记后的标题；去完为空则原样返回 */
    fun cleanTitle(content: String): String =
        content.replace(IMPORTANT_RE, "").replace(URGENT_RE, "").trim().ifEmpty { content }
}
