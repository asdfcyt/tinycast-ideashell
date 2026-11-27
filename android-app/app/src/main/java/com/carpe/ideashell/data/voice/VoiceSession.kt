package com.carpe.ideashell.data.voice

/**
 * 语音多轮上下文：只在内存里留最近几轮（说了什么 → 做了什么），过几分钟自动作废。
 * 让「再推迟一天」「那个也完成」「哪个最花时间」这类带指代的话能接上上一句。
 */
object VoiceSession {
    class Turn(val at: Long, val raw: String, var result: String)

    private const val MAX_TURNS = 3
    private const val EXPIRE_MS = 5 * 60_000L
    private val turns = ArrayDeque<Turn>()

    @Synchronized
    fun add(raw: String, result: String, now: Long = System.currentTimeMillis()) {
        turns.addLast(Turn(now, raw, result))
        while (turns.size > MAX_TURNS) turns.removeFirst()
    }

    /** 给刚加进去的那一轮补上更详细的结果（回答的内容、搜到的条数）；找不到对应那一轮就不动 */
    @Synchronized
    fun attach(raw: String, result: String) {
        turns.lastOrNull { it.raw == raw }?.result = result.take(300)
    }

    @Synchronized
    fun recent(now: Long = System.currentTimeMillis()): List<Turn> {
        while (turns.isNotEmpty() && now - turns.first().at > EXPIRE_MS) turns.removeFirst()
        return turns.toList()
    }

    @Synchronized
    fun clear() = turns.clear()

    /** 拼进提示词的「最近对话」；没有就是 null */
    fun contextBlock(now: Long = System.currentTimeMillis()): String? = format(recent(now))

    fun format(list: List<Turn>): String? {
        if (list.isEmpty()) return null
        return "最近对话（越靠后越新）：\n" + list.joinToString("\n") { "· 我说：${it.raw.take(80)}\n  结果：${it.result.take(300)}" }
    }
}
