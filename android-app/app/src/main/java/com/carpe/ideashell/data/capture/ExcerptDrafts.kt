package com.carpe.ideashell.data.capture

/**
 * 摘录抽屉里没提交就关掉的内容（仅内存）：误触关闭后，[MAX_AGE_MS] 内再点胶囊、或对同一段文字再摘录，想法还在。
 * 保存成功或有了新的划线摘录，就丢掉。
 */
object ExcerptDrafts {
    const val MAX_AGE_MS = 10 * 60_000L

    data class Draft(
        val pkg: String,
        val appName: String,
        val docTitle: String?,
        val quote: String,
        val source: String,
        val tags: String,
        val thought: String,
        val append: Boolean,
        val at: Long = System.currentTimeMillis(),
    )

    @Volatile
    private var current: Draft? = null

    fun put(draft: Draft) {
        current = draft
    }

    fun clear() {
        current = null
    }

    /** 还没过期的草稿；过期的顺手丢掉 */
    fun alive(now: Long = System.currentTimeMillis()): Draft? {
        val d = current ?: return null
        if (now - d.at > MAX_AGE_MS) {
            current = null
            return null
        }
        return d
    }
}
