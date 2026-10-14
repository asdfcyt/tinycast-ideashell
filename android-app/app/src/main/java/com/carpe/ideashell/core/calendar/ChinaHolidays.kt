package com.carpe.ideashell.core.calendar

import java.time.LocalDate

/**
 * 中国大陆法定节假日与调休。数据全部来自联网同步（HolidayRepository 从 holiday-cn 开源数据集拉取并缓存在本机，
 * 国务院一公布就能更新），代码里不内置任何年表。没拉到数据的年份只显示农历 / 节日，不显示「休 / 班」。
 */
object ChinaHolidays {
    enum class Kind { OFF, WORK }

    /** [name] 是假期名（春节、国庆节…）；调休上班的那天是它所属假期的名字 */
    data class Entry(val kind: Kind, val name: String)

    @Volatile private var entries: Map<LocalDate, Entry> = emptyMap()
    @Volatile private var years: Set<Int> = emptySet()

    /** 装入同步到的数据：[entries] 是这些年里所有的休息 / 调休日，[years] 是确实有安排的年份 */
    fun install(entries: Map<LocalDate, Entry>, years: Set<Int>) {
        this.entries = entries
        this.years = years
    }

    /** 这一天是法定休息日 / 调休上班日；普通日子（或还没同步到数据）返回 null */
    fun of(date: LocalDate): Entry? = entries[date]

    /** 有没有这一年的安排 */
    fun hasYear(year: Int): Boolean = year in years
}
