package com.carpe.ideashell.core.revisit

import android.icu.text.BreakIterator
import java.util.Locale
import kotlin.math.roundToInt
import kotlin.random.Random

/**
 * 填空重温：把摘录 / 笔记里的关键词挖空，先回忆再看答案。
 *
 * 挖哪些词，按优先级：
 * 1. 用户在原文里亲手标的 `{{词}}`（只挖这些）；
 * 2. 没有的话，用 `**加粗**` / `==高亮==` 的词（写的时候强调过，就是重点）；
 * 1'. 用户在重温时手动点选 / 拖选保存的空（[build] 的 manual 参数），优先于下面所有规则；
 * 3. 都没有就自动挑：数字 / 日期、英文术语、中文词（用系统自带的 ICU 分词，去掉「我们 / 因为 / 可以」这类虚词），
 *    数量随篇幅走，每次重温（[seed] 不同）挑的位置会换，避免背「空的位置」而不是背内容。
 *
 * 渲染用的是去掉 Markdown 记号后的纯文本 [Plain.text]，空的位置是它里面的区间 [Plain.blanks]。
 */
object Cloze {
    /** 去掉 Markdown 记号后的文字，以及要挖空的区间（互不重叠、按位置排序）；[auto] 表示是自动挑的（可以「换一批」） */
    data class Plain(val text: String, val blanks: List<IntRange>, val auto: Boolean, val manual: Boolean = false) {
        /** 点到 [offset] 附近时命中哪个空（点在字缝上也算），没有返回 -1 */
        fun blankAt(offset: Int): Int {
            blanks.forEachIndexed { i, r -> if (offset in r.first..(r.last + 1)) return i }
            return -1
        }
    }

    private const val MIN_LENGTH = 8
    private const val MAX_BLANKS = 14

    /** 原文里没有任何可挖的词（太短、全是虚词）时返回 null，界面按普通卡片显示 */
    fun build(source: String, seed: Long, manual: List<IntRange>? = null, ratio: IntRange = 10..25): Plain? {
        val flat = flatten(source)
        val text = flat.text.trim('\n')
        if (text.replace(Regex("\\s"), "").length < MIN_LENGTH) return null
        // 用户亲手挖的空优先于一切自动规则
        if (!manual.isNullOrEmpty()) {
            val mine = normalize(manual.filter { it.first >= 0 && it.last < text.length && it.first <= it.last })
            if (mine.isNotEmpty()) return Plain(text, mine, auto = false, manual = true)
        }
        val shift = flat.text.length - flat.text.trimStart('\n').length

        fun shifted(list: List<IntRange>) =
            list.map { (it.first - shift)..(it.last - shift) }.filter { it.first >= 0 && it.last < text.length }

        val explicit = shifted(flat.explicit)
        val isAuto = explicit.isEmpty() && flat.emphasis.isEmpty()
        val chosen = when {
            explicit.isNotEmpty() -> explicit
            flat.emphasis.isNotEmpty() -> shifted(flat.emphasis).filter { it.last - it.first < 24 }.take(MAX_BLANKS)
            else -> auto(text, seed, ratio)
        }
        val blanks = normalize(chosen)
        return if (blanks.isEmpty()) null else Plain(text, blanks, isAuto)
    }

    /** 排序并去掉重叠 */
    private fun normalize(list: List<IntRange>): List<IntRange> = list.sortedBy { it.first }.fold(mutableListOf<IntRange>()) { acc, r ->
        if (acc.isEmpty() || r.first > acc.last().last) acc += r
        acc
    }

    // ───────────────────────── 手动挖空 ─────────────────────────

    /** 渲染用的纯文本（手动挖空的区间就是相对它的位置；文本变了，存的区间就作废） */
    fun flatText(source: String): String = flatten(source).text.trim('\n')

    /** [offset] 所在的词（ICU 分词；落在空白 / 标点上返回 null） */
    fun wordAt(text: String, offset: Int): IntRange? {
        if (text.isEmpty()) return null
        val at = offset.coerceIn(0, text.length - 1)
        val iter = BreakIterator.getWordInstance(Locale.CHINA)
        iter.setText(text)
        val end = iter.following(at)
        if (end == BreakIterator.DONE) return null
        val start = iter.previous()
        if (start == BreakIterator.DONE || start >= end) return null
        if (text.substring(start, end).none { it.isLetterOrDigit() }) return null
        return start until end
    }

    /** 点一个词：已经是空就取消，不是就挖空 */
    fun toggleWord(text: String, blanks: List<IntRange>, offset: Int): List<IntRange> {
        val word = wordAt(text, offset) ?: return blanks
        val hit = blanks.filter { it.first <= word.last && it.last >= word.first }
        return if (hit.isNotEmpty()) blanks - hit.toSet() else normalize(blanks + listOf(word))
    }

    /** 拖选一段：从起点所在词的开头到终点所在词的结尾整段挖空（盖掉其中已有的空） */
    fun addRange(text: String, blanks: List<IntRange>, from: Int, to: Int): List<IntRange> {
        if (text.isEmpty()) return blanks
        val lo = minOf(from, to).coerceIn(0, text.length - 1)
        val hi = maxOf(from, to).coerceIn(0, text.length - 1)
        var start = wordAt(text, lo)?.first ?: lo
        var end = wordAt(text, hi)?.last ?: hi
        while (start < end && text[start].isWhitespace()) start++
        while (end > start && text[end].isWhitespace()) end--
        if (text[start].isWhitespace()) return blanks
        val r = start..end
        return normalize(blanks.filterNot { it.first <= r.last && it.last >= r.first } + listOf(r))
    }

    // ───────────────────────── 去 Markdown 记号 ─────────────────────────

    private class Flat(val text: String, val explicit: List<IntRange>, val emphasis: List<IntRange>)

    private val RE_INLINE = Regex(
        "\\{\\{(.+?)\\}\\}|(\\*\\*|__|==)(.+?)\\2|!\\[[^\\]]*]\\([^)]*\\)|\\[([^\\]]+)]\\([^)]*\\)|`+([^`]+)`+",
    )
    private val RE_HEADING = Regex("^\\s{0,3}#{1,6}\\s+")
    private val RE_BULLET = Regex("^(\\s*)[-*+]\\s+")
    private val RE_TASK = Regex("^\\[([ xX])]\\s+")
    private val RE_QUOTE = Regex("^\\s*>\\s?")

    private fun flatten(source: String): Flat {
        val out = StringBuilder()
        val explicit = mutableListOf<IntRange>()
        val emphasis = mutableListOf<IntRange>()
        var first = true
        for (raw in source.replace("\r\n", "\n").lines()) {
            if (raw.trimStart().startsWith("```")) continue
            if (!first) out.append('\n')
            first = false
            var line = raw.replace(RE_HEADING, "").replace(RE_QUOTE, "")
            line = RE_BULLET.replace(line) { it.groupValues[1] + "• " }
            line = line.replace(RE_TASK) { if (it.groupValues[1] == " ") "☐ " else "☑ " }

            var last = 0
            for (m in RE_INLINE.findAll(line)) {
                out.append(line, last, m.range.first)
                last = m.range.last + 1
                val g = m.groupValues
                when {
                    g[1].isNotEmpty() -> { // {{挖空}}
                        val s = out.length
                        out.append(g[1])
                        explicit += s until out.length
                    }
                    g[3].isNotEmpty() -> { // **加粗** / ==高亮==
                        val s = out.length
                        out.append(g[3])
                        emphasis += s until out.length
                    }
                    g[4].isNotEmpty() -> out.append(g[4]) // 链接只留文字
                    g[5].isNotEmpty() -> out.append(g[5]) // 行内代码留内容
                    // 图片：什么都不留
                }
            }
            out.append(line, last, line.length)
        }
        return Flat(out.toString(), explicit, emphasis)
    }

    // ───────────────────────── 自动挑词 ─────────────────────────

    private class Candidate(val range: IntRange, val score: Double)

    private val STOP_WORDS = setOf(
        "我们", "你们", "他们", "她们", "它们", "自己", "大家", "这个", "那个", "这些", "那些", "这种", "那种", "这样", "那样", "一个", "一些",
        "一种", "一下", "一直", "一起", "一样", "可以", "因为", "所以", "但是", "如果", "已经", "还是", "就是", "不是", "没有", "什么", "怎么",
        "以及", "或者", "而且", "然后", "虽然", "并且", "通过", "对于", "关于", "需要", "可能", "应该", "之后", "之前", "现在", "时候", "比较",
        "非常", "其实", "当然", "同时", "比如", "例如", "不会", "不能", "不要", "不过", "只是", "只有", "还有", "之间", "其中", "如此", "以后",
        "以前", "为了", "由于", "因此", "而是", "成为", "进行", "能够", "开始", "觉得", "知道", "东西", "问题", "时间", "今天", "明天", "昨天",
    )

    private fun auto(text: String, seed: Long, ratio: IntRange): List<IntRange> {
        val rnd = Random(seed)
        val candidates = mutableListOf<Candidate>()
        val iter = BreakIterator.getWordInstance(Locale.CHINA)
        iter.setText(text)
        var start = iter.first()
        var end = iter.next()
        while (end != BreakIterator.DONE) {
            val word = text.substring(start, end)
            score(word)?.let { s -> candidates += Candidate(start until end, s + rnd.nextDouble() * 1.2) }
            start = end
            end = iter.next()
        }
        if (candidates.isEmpty()) return emptyList()

        // 目标：挖掉的字数占正文（不含空白）的比例，在用户设的范围内随机取（每次重温不同）
        val lo = ratio.first.coerceAtLeast(1)
        val hi = ratio.last.coerceAtLeast(lo)
        val percent = lo + rnd.nextDouble() * (hi - lo)
        val target = (text.count { !it.isWhitespace() } * percent / 100.0).roundToInt().coerceAtLeast(2)
        val picked = mutableListOf<IntRange>()
        var covered = 0
        for (c in candidates.sortedByDescending { it.score }) {
            if (covered >= target && picked.isNotEmpty()) break
            // 两个空之间至少隔一个字，免得连成一大块看不出是两个词
            if (picked.none { c.range.first <= it.last + 2 && c.range.last >= it.first - 2 }) {
                picked += c.range
                covered += c.range.last - c.range.first + 1
            }
        }
        return picked
    }

    /** 这个词值不值得挖；不值得返回 null。数字 > 英文术语 > 3–4 字中文词 > 2 字中文词 */
    private fun score(word: String): Double? {
        if (word.isBlank()) return null
        if (word.any { it.isDigit() }) {
            return if (word.all { it.isDigit() || it == '.' || it == ',' || it == '%' || it == ':' }) 3.0 else 2.4
        }
        val ascii = word.all { it.code < 128 && it.isLetter() }
        if (ascii) return if (word.length >= 3) 2.5 else null
        val cjk = word.all { it in '\u4e00'..'\u9fff' }
        if (!cjk || word.length < 2 || word in STOP_WORDS) return null
        return when (word.length) {
            2 -> 1.0
            3 -> 1.6
            4 -> 1.8
            else -> 1.3
        }
    }
}
