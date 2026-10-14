package com.carpe.ideashell.core.parse

import java.time.DayOfWeek
import java.time.LocalDate
import java.time.temporal.TemporalAdjusters

/**
 * 文字里的重复说法 → [RepeatRule]：每天 / 每周一 / 每周一三五 / 每周末 / 每个工作日 /
 * 每月 1 号 / 每月最后一天（月底） / 每年 10 月 1 日 / 每 2 天 / 每隔 3 周 / 每两个月。
 *
 * [anchored] 表示说法里带了具体的星期 / 几号 / 间隔（「每周一」），可以放心当成待办；
 * 单独的「每天」「每周」可能只是日记里的一句习惯（「我每天都跑步」），不会单凭它自动归为待办。
 */
object RepeatParser {
    class Found(
        val rule: RepeatRule,
        /** 命中的原文（从待办内容里去掉） */
        val hit: String,
        val anchored: Boolean,
        /** 说法里自己带了日期（每年 10 月 1 日）时，第一次发生的日期 */
        val fixedFirst: LocalDate? = null,
    )

    private const val N = "(?:[0-9]{1,2}|[零〇一二三四五六七八九十两]{1,3})"
    private const val WEEK = "(?:周|星期|礼拜)"
    private const val DAYCH = "[一二三四五六日天]"

    private val RE_YEARLY_DATE = Regex("每年\\s*($N)月\\s*($N)[日号]?")
    private val RE_MONTH_END = Regex("每(?:个)?月\\s*(?:的)?(?:最后一天|最后一日|月底|月末|底|末)")
    private val RE_MONTH_DAY = Regex("每(?:个)?月\\s*(?:的)?($N)\\s*[日号]")
    private val RE_WORKDAY = Regex("每(?:个)?(?:工作日|周内)")
    private val RE_WEEKEND = Regex("每(?:个)?周末")
    private val RE_WEEKDAYS = Regex("每(?:个)?$WEEK($DAYCH(?:\\s*[、,，和及与]?\\s*(?:$WEEK)?$DAYCH)*)(?![次个遍回篇节课])")
    private val RE_INTERVAL = Regex("每隔\\s*($N)\\s*(天|日|周|个?星期|个?礼拜|个?月|年)|每\\s*($N)\\s*(?:个)?(天|日|周|星期|礼拜|月|年)(?!份)")
    private val RE_DAILY = Regex("每(?:一)?(?:天|日)")
    private val RE_WEEKLY = Regex("每(?:一)?(?:个)?$WEEK(?![一二三四五六日天末次个遍回])")
    private val RE_MONTHLY = Regex("每(?:一)?个?月(?!份)(?![0-9一二三四五六七八九十])")
    private val RE_YEARLY = Regex("每(?:一)?年")

    private val CN = mapOf('零' to 0, '〇' to 0, '一' to 1, '二' to 2, '两' to 2, '三' to 3, '四' to 4, '五' to 5, '六' to 6, '七' to 7, '八' to 8, '九' to 9)

    private val DAY_OF = mapOf(
        '一' to DayOfWeek.MONDAY, '二' to DayOfWeek.TUESDAY, '三' to DayOfWeek.WEDNESDAY, '四' to DayOfWeek.THURSDAY,
        '五' to DayOfWeek.FRIDAY, '六' to DayOfWeek.SATURDAY, '日' to DayOfWeek.SUNDAY, '天' to DayOfWeek.SUNDAY,
    )

    private fun num(s: String): Int? {
        s.toIntOrNull()?.let { return it }
        val ten = s.indexOf('十')
        if (ten < 0) return if (s.length == 1) CN[s[0]] else null
        val tens = if (ten == 0) 1 else CN[s[0]] ?: return null
        val ones = if (ten == s.length - 1) 0 else CN[s[ten + 1]] ?: return null
        return tens * 10 + ones
    }

    fun find(text: String): Found? {
        RE_YEARLY_DATE.find(text)?.let { m ->
            val month = num(m.groupValues[1])
            val day = num(m.groupValues[2])
            if (month != null && day != null && month in 1..12 && day in 1..31) {
                val today = LocalDate.now()
                val first = listOf(today.year, today.year + 1)
                    .mapNotNull { y -> runCatching { LocalDate.of(y, month, day) }.getOrNull() }
                    .firstOrNull { !it.isBefore(today) }
                return Found(RepeatRule(RepeatRule.Freq.YEARLY), m.value, anchored = true, fixedFirst = first)
            }
        }
        RE_MONTH_END.find(text)?.let { m ->
            return Found(RepeatRule(RepeatRule.Freq.MONTHLY, monthDay = -1), m.value, anchored = true)
        }
        RE_MONTH_DAY.find(text)?.let { m ->
            val day = num(m.groupValues[1])
            if (day != null && day in 1..31) {
                return Found(RepeatRule(RepeatRule.Freq.MONTHLY, monthDay = day), m.value, anchored = true)
            }
        }
        RE_WORKDAY.find(text)?.let { m ->
            return Found(RepeatRule(RepeatRule.Freq.WEEKLY, weekdays = RepeatRule.WORKDAYS), m.value, anchored = true)
        }
        RE_WEEKEND.find(text)?.let { m ->
            return Found(
                RepeatRule(RepeatRule.Freq.WEEKLY, weekdays = setOf(DayOfWeek.SATURDAY, DayOfWeek.SUNDAY)),
                m.value, anchored = true,
            )
        }
        RE_WEEKDAYS.find(text)?.let { m ->
            val days = m.groupValues[1].mapNotNull { DAY_OF[it] }.toSet()
            if (days.isNotEmpty()) return Found(RepeatRule(RepeatRule.Freq.WEEKLY, weekdays = days), m.value, anchored = true)
        }
        RE_INTERVAL.find(text)?.let { m ->
            val skip = m.groups[1] != null // 「每隔 3 天」= 中间隔 3 天 = 每 4 天
            val n = num(if (skip) m.groupValues[1] else m.groupValues[3])
            val unit = if (skip) m.groupValues[2] else m.groupValues[4]
            if (n != null && n in 1..99) {
                val freq = when {
                    unit == "天" || unit == "日" -> RepeatRule.Freq.DAILY
                    unit.endsWith("周") || unit.endsWith("星期") || unit.endsWith("礼拜") -> RepeatRule.Freq.WEEKLY
                    unit.endsWith("月") -> RepeatRule.Freq.MONTHLY
                    else -> RepeatRule.Freq.YEARLY
                }
                val interval = if (skip) n + 1 else n
                // 「每 1 天」这种就是最普通的「每天」，不算带了具体信息
                return Found(RepeatRule(freq, interval), m.value, anchored = interval > 1)
            }
        }
        RE_DAILY.find(text)?.let { return Found(RepeatRule(RepeatRule.Freq.DAILY), it.value, anchored = false) }
        RE_WEEKLY.find(text)?.let { return Found(RepeatRule(RepeatRule.Freq.WEEKLY), it.value, anchored = false) }
        RE_MONTHLY.find(text)?.let { return Found(RepeatRule(RepeatRule.Freq.MONTHLY), it.value, anchored = false) }
        RE_YEARLY.find(text)?.let { return Found(RepeatRule(RepeatRule.Freq.YEARLY), it.value, anchored = false) }
        return null
    }

    /** 这条规则从 [from]（含）起第一次发生的日期 */
    fun firstOccurrence(rule: RepeatRule, from: LocalDate): LocalDate = when (rule.freq) {
        RepeatRule.Freq.DAILY, RepeatRule.Freq.YEARLY -> from
        RepeatRule.Freq.WEEKLY ->
            if (rule.weekdays.isEmpty()) from
            else generateSequence(from) { it.plusDays(1) }.take(7).first { it.dayOfWeek in rule.weekdays }
        RepeatRule.Freq.MONTHLY -> {
            val md = rule.monthDay
            if (md == null) from
            else generateSequence(from.withDayOfMonth(1)) { it.plusMonths(1) }
                .take(14)
                .mapNotNull { first ->
                    val day = if (md == -1) first.lengthOfMonth() else md
                    if (day > first.lengthOfMonth()) null else first.withDayOfMonth(day)
                }
                .firstOrNull { !it.isBefore(from) } ?: from
        }
    }
}
