package com.carpe.ideashell.core.parse

import java.time.DayOfWeek
import java.time.LocalDate

/**
 * 待办的重复规则，对应滴答任务的 `repeatFlag`（RFC 5545 的 RRULE，例如 `RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE`）。
 * 只覆盖滴答日期面板里最常用的几种：每 N 天 / 周（可选星期）/ 月（某一天）/ 年。
 */
data class RepeatRule(
    val freq: Freq,
    val interval: Int = 1,
    /** 每周重复时选中的星期；为空表示跟随任务日期那天的星期 */
    val weekdays: Set<DayOfWeek> = emptySet(),
    /** 每月重复时的几号；为空表示跟随任务日期 */
    val monthDay: Int? = null,
) {
    enum class Freq(val code: String, val unit: String) {
        DAILY("DAILY", "天"),
        WEEKLY("WEEKLY", "周"),
        MONTHLY("MONTHLY", "个月"),
        YEARLY("YEARLY", "年"),
    }

    /** 写给滴答的 repeatFlag */
    fun toRRule(): String = buildString {
        append("RRULE:FREQ=").append(freq.code)
        append(";INTERVAL=").append(interval.coerceAtLeast(1))
        if (freq == Freq.WEEKLY && weekdays.isNotEmpty()) {
            append(";BYDAY=").append(weekdays.sortedBy { it.value }.joinToString(",") { BYDAY_CODES.getValue(it) })
        }
        if (freq == Freq.MONTHLY && monthDay != null) append(";BYMONTHDAY=").append(monthDay)
    }

    /** 给人看的说明：每天 / 每个工作日 / 每周一、周三 / 每月 13 日 / 每 2 周 … */
    fun label(): String {
        val n = interval.coerceAtLeast(1)
        return when (freq) {
            Freq.DAILY -> if (n == 1) "每天" else "每 $n 天"
            Freq.WEEKLY -> {
                val days = weekdays
                when {
                    n == 1 && days == WORKDAYS -> "每个工作日"
                    n == 1 && days.size == 7 -> "每天"
                    else -> {
                        val head = if (n == 1) "每周" else "每 $n 周"
                        if (days.isEmpty()) head else head + days.sortedBy { it.value }.joinToString("、") { WEEKDAY_NAMES.getValue(it) }
                    }
                }
            }
            Freq.MONTHLY -> {
                val head = if (n == 1) "每月" else "每 $n 个月"
                when (monthDay) {
                    null -> head
                    -1 -> "每月最后一天"
                    else -> "$head $monthDay 日"
                }
            }
            Freq.YEARLY -> if (n == 1) "每年" else "每 $n 年"
        }
    }

    /** 把「跟随任务日期」的部分（每周没选星期、每月没指定几号）按 [date] 补全 */
    fun resolved(date: LocalDate): RepeatRule = when {
        freq == Freq.WEEKLY && weekdays.isEmpty() -> copy(weekdays = setOf(date.dayOfWeek))
        freq == Freq.MONTHLY && monthDay == null -> copy(monthDay = date.dayOfMonth)
        else -> this
    }

    companion object {
        val WORKDAYS: Set<DayOfWeek> = setOf(
            DayOfWeek.MONDAY, DayOfWeek.TUESDAY, DayOfWeek.WEDNESDAY, DayOfWeek.THURSDAY, DayOfWeek.FRIDAY,
        )

        private val BYDAY_CODES = mapOf(
            DayOfWeek.MONDAY to "MO", DayOfWeek.TUESDAY to "TU", DayOfWeek.WEDNESDAY to "WE", DayOfWeek.THURSDAY to "TH",
            DayOfWeek.FRIDAY to "FR", DayOfWeek.SATURDAY to "SA", DayOfWeek.SUNDAY to "SU",
        )
        private val DAY_BY_CODE = BYDAY_CODES.entries.associate { it.value to it.key }

        private val WEEKDAY_NAMES = mapOf(
            DayOfWeek.MONDAY to "周一", DayOfWeek.TUESDAY to "周二", DayOfWeek.WEDNESDAY to "周三", DayOfWeek.THURSDAY to "周四",
            DayOfWeek.FRIDAY to "周五", DayOfWeek.SATURDAY to "周六", DayOfWeek.SUNDAY to "周日",
        )

        fun weekdayName(day: DayOfWeek): String = WEEKDAY_NAMES.getValue(day)

        /** 解析滴答返回的 repeatFlag；空、无法识别（含 `ERULE:` 之类的旧格式）返回 null */
        fun parse(flag: String?): RepeatRule? {
            val text = flag?.trim().orEmpty()
            if (!text.startsWith("RRULE:", ignoreCase = true)) return null
            val parts = text.substring("RRULE:".length).split(';')
                .mapNotNull { p -> p.split('=', limit = 2).takeIf { it.size == 2 }?.let { it[0].trim().uppercase() to it[1].trim() } }
                .toMap()
            val freq = Freq.entries.firstOrNull { it.code == parts["FREQ"]?.uppercase() } ?: return null
            val days = parts["BYDAY"]?.split(',')?.mapNotNull { DAY_BY_CODE[it.trim().uppercase()] }?.toSet().orEmpty()
            return RepeatRule(
                freq = freq,
                interval = parts["INTERVAL"]?.toIntOrNull()?.coerceAtLeast(1) ?: 1,
                weekdays = if (freq == Freq.WEEKLY) days else emptySet(),
                monthDay = if (freq == Freq.MONTHLY) parts["BYMONTHDAY"]?.toIntOrNull() else null,
            )
        }
    }
}

/** 日期面板里「重复」的常用选项；具体规则跟着当前选的日期走（每周 = 这天的星期，每月 = 这天的几号） */
enum class RepeatPreset(val label: String) {
    DAILY("每天"),
    WORKDAY("每个工作日"),
    WEEKLY("每周"),
    MONTHLY("每月"),
    YEARLY("每年"),
    ;

    fun rule(date: LocalDate): RepeatRule = when (this) {
        DAILY -> RepeatRule(RepeatRule.Freq.DAILY)
        WORKDAY -> RepeatRule(RepeatRule.Freq.WEEKLY, weekdays = RepeatRule.WORKDAYS)
        WEEKLY -> RepeatRule(RepeatRule.Freq.WEEKLY, weekdays = setOf(date.dayOfWeek))
        MONTHLY -> RepeatRule(RepeatRule.Freq.MONTHLY, monthDay = date.dayOfMonth)
        YEARLY -> RepeatRule(RepeatRule.Freq.YEARLY)
    }

    /** 选项旁边的补充说明：每周 · 周三 / 每月 · 13 日 / 每年 · 10月13日 */
    fun hint(date: LocalDate): String = when (this) {
        DAILY -> ""
        WORKDAY -> "周一至周五"
        WEEKLY -> RepeatRule.weekdayName(date.dayOfWeek)
        MONTHLY -> "${date.dayOfMonth} 日"
        YEARLY -> "${date.monthValue}月${date.dayOfMonth}日"
    }

    companion object {
        /** 已有的规则正好是某个常用选项（在 [date] 这天）就返回它，否则 null（属于自定义） */
        fun of(rule: RepeatRule, date: LocalDate): RepeatPreset? = entries.firstOrNull { it.rule(date) == rule }
    }
}
