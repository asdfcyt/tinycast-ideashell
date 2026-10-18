package com.carpe.ideashell.core.voice

/**
 * 语音转写的本地清洗（没有开大模型、或大模型失败时用）：只做稳妥的几件事，不改写意思。
 * - 去掉独立成句的语气词（嗯、呃、额、啊）和句首的「那个，」「就是，」「然后，」；
 * - 单句末尾的句号去掉（待办标题带个句号很怪）。
 * 日期 / 时间不在这里处理，交给后面的 TodoParser。
 */
object SpeechCleaner {
    private val RE_FILLER = Regex("(?:^|(?<=[，。,.！？!?、\\s]))(?:嗯+|呃+|额+|唔+|啊+)(?:[，。,.、\\s]+|$)")
    private val RE_LEADING = Regex("^(?:那个|这个|就是|然后|就是说)[，,、]\\s*")
    private val RE_SPACES = Regex("[ \\t]{2,}")

    fun clean(raw: String): String {
        var s = raw.trim()
        s = RE_FILLER.replace(s, "")
        s = RE_LEADING.replace(s, "")
        s = RE_SPACES.replace(s, " ").trim()
        // 只有一句、末尾是句号：去掉
        if (s.endsWith("。") && s.count { it == '。' } == 1) s = s.dropLast(1)
        return s.ifEmpty { raw.trim() }
    }
}
