package com.carpe.ideashell.core.calendar

import java.time.LocalDate

/** 日历格子里一天要显示的东西：下面一行小字（节日 > 节气 > 农历）和右上角的「休 / 班」 */
data class DayInfo(
    /** 格子下面的小字：春节 / 清明 / 初二 / 十月 */
    val label: String,
    /** label 是节日 / 节气（用强调色显示） */
    val highlight: Boolean,
    val holiday: ChinaHolidays.Entry?,
    /** 完整农历，如「九月初九」 */
    val lunarFull: String,
) {
    /** 选中某天时那行说明里用的：「九月初九 重阳 · 休息（国庆节）」 */
    fun detail(): String = buildList {
        add(lunarFull)
        if (highlight) add(label)
        holiday?.let { add(if (it.kind == ChinaHolidays.Kind.OFF) "休息（${it.name}）" else "调休上班（${it.name}）") }
    }.joinToString(" · ")

    companion object {
        /** 农历 / 节日算起来很快（农历有缓存）；休 / 班可能在联网更新后变化，所以这里不缓存整个结果 */
        fun of(date: LocalDate): DayInfo {
            val lunar = LunarCalendar.of(date)
            val holiday = ChinaHolidays.of(date)
            val festival = LunarCalendar.lunarFestival(date) ?: LunarCalendar.solarFestival(date)
            val term = LunarCalendar.solarTerm(date)
            val (label, highlight) = when {
                festival != null -> festival to true
                term != null -> term to true
                else -> LunarCalendar.dayText(lunar) to false
            }
            return DayInfo(label, highlight, holiday, LunarCalendar.fullText(lunar))
        }
    }
}
