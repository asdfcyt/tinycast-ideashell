package com.carpe.ideashell.core.parse

import java.time.LocalDate
import java.time.temporal.ChronoUnit

/** 时间范围：[start, endExclusive)，按本地日期计 */
data class TimeRange(
    val label: String,
    val start: LocalDate,
    val endExclusive: LocalDate,
    /** 超过最大跨度被截断 */
    val clamped: Boolean = false,
) {
    /** 范围内最后一天（含） */
    val last: LocalDate get() = endExclusive.minusDays(1)

    val days: Int get() = ChronoUnit.DAYS.between(start, endExclusive).toInt()
}

/**
 * 时间范围解析，规则与桌面插件 `time-range.ts` 一致：
 * 留空 = 最近 7 天；今天 / 昨天 / 前天；本周 / 上周；本月 / 上月；
 * 最近 N 天 / 周 / 月；周三 / 上周三；10月3日；2026-10-01；10月1日到10月7日。
 */
object TimeRanges {
    const val MAX_DAYS = 62

    private val WEEKDAY_NAMES = listOf("周日", "周一", "周二", "周三", "周四", "周五", "周六")
    private val WEEKDAY_INDEX = mapOf('一' to 0, '二' to 1, '三' to 2, '四' to 3, '五' to 4, '六' to 5, '日' to 6, '天' to 6) // 周一 = 0

    private val RE_DATE = Regex("(\\d{4})[-/.](\\d{1,2})[-/.](\\d{1,2})|(\\d{1,2})月(\\d{1,2})[日号]?")
    private val RE_RECENT = Regex("^(?:最近|近|过去)([\\d一二两三四五六七八九十]+)(天|日|周|个月|月)$")
    private val RE_WEEKDAY = Regex("^(上|这|本)?(?:周|星期|礼拜)([一二三四五六日天])$")

    fun weekdayName(d: LocalDate): String = WEEKDAY_NAMES[d.dayOfWeek.value % 7]

    fun dayLabel(d: LocalDate): String = "$d ${weekdayName(d)}"

    fun single(d: LocalDate) = TimeRange(dayLabel(d), d, d.plusDays(1))

    fun span(label: String, start: LocalDate, endExclusive: LocalDate) = TimeRange(label, start, endExclusive)

    fun lastDays(n: Int, today: LocalDate = LocalDate.now()) =
        span("最近 $n 天", today.minusDays((n - 1).toLong()), today.plusDays(1))

    /** 用日期选择器选出的起止日（含）构造范围；超长自动截断 */
    fun custom(from: LocalDate, toInclusive: LocalDate): TimeRange {
        val (a, b) = if (from <= toInclusive) from to toInclusive else toInclusive to from
        val label = if (a == b) dayLabel(a) else "$a ~ $b"
        return clampTo(span(label, a, b.plusDays(1)))
    }

    private fun mondayOf(d: LocalDate): LocalDate = d.minusDays((d.dayOfWeek.value - 1).toLong())

    private fun cnToNumber(s: String): Int {
        s.toIntOrNull()?.let { return it }
        val digit = mapOf('一' to 1, '二' to 2, '两' to 2, '三' to 3, '四' to 4, '五' to 5, '六' to 6, '七' to 7, '八' to 8, '九' to 9)
        if (s == "十") return 10
        if (s.startsWith("十")) return 10 + (digit[s.getOrNull(1)] ?: 0)
        if (s.contains("十")) {
            val (a, b) = s.split("十", limit = 2)
            return (digit[a.firstOrNull()] ?: 0) * 10 + (digit[b.firstOrNull()] ?: 0)
        }
        return digit[s.firstOrNull()] ?: 0
    }

    /** 文本里出现的所有明确日期；M月D日 若晚于今天则取去年 */
    private fun findDates(text: String, today: LocalDate): List<LocalDate> =
        RE_DATE.findAll(text).mapNotNull { m ->
            val g = m.groupValues
            runCatching {
                if (g[1].isNotEmpty()) {
                    LocalDate.of(g[1].toInt(), g[2].toInt(), g[3].toInt())
                } else {
                    val d = LocalDate.of(today.year, g[4].toInt(), g[5].toInt())
                    if (d.isAfter(today)) d.minusYears(1) else d
                }
            }.getOrNull()
        }.toList()

    fun parse(input: String, today: LocalDate = LocalDate.now()): TimeRange? {
        val t = input.replace(Regex("\\s+"), "")
        val r: TimeRange? = when {
            t.isEmpty() -> lastDays(7, today)
            t == "今天" || t == "今日" -> single(today)
            t == "昨天" || t == "昨日" -> single(today.minusDays(1))
            t == "前天" -> single(today.minusDays(2))
            t in setOf("本周", "这周", "这一周", "本星期", "这星期") -> {
                val monday = mondayOf(today)
                span("本周", monday, monday.plusDays(7))
            }
            t in setOf("上周", "上一周", "上星期", "上个星期", "上礼拜") -> {
                val monday = mondayOf(today).minusDays(7)
                span("上周", monday, monday.plusDays(7))
            }
            t in setOf("本月", "这个月", "当月") -> {
                val first = today.withDayOfMonth(1)
                span("本月", first, first.plusMonths(1))
            }
            t in setOf("上月", "上个月") -> {
                val first = today.withDayOfMonth(1)
                span("上月", first.minusMonths(1), first)
            }
            else -> parseComplex(t, today)
        }
        return r?.let(::clampTo)
    }

    private fun parseComplex(t: String, today: LocalDate): TimeRange? {
        RE_RECENT.matchEntire(t)?.let { m ->
            val n = cnToNumber(m.groupValues[1])
            if (n <= 0) return null
            val days = when (m.groupValues[2]) {
                "天", "日" -> n
                "周" -> n * 7
                else -> n * 30
            }
            return lastDays(days, today)
        }
        RE_WEEKDAY.matchEntire(t)?.let { m ->
            val monday = mondayOf(today).minusDays(if (m.groupValues[1] == "上") 7 else 0)
            val index = WEEKDAY_INDEX[m.groupValues[2].first()] ?: return null
            return single(monday.plusDays(index.toLong()))
        }
        val dates = findDates(t, today)
        return when {
            dates.size == 1 -> single(dates[0])
            dates.size >= 2 -> {
                val (a, b) = listOf(dates[0], dates[1]).sorted()
                span("$a ~ $b", a, b.plusDays(1))
            }
            else -> null
        }
    }

    /** 超长范围截断，避免一次拉取过多 */
    private fun clampTo(r: TimeRange): TimeRange =
        if (r.days > MAX_DAYS) r.copy(start = r.endExclusive.minusDays(MAX_DAYS.toLong()), clamped = true) else r
}
