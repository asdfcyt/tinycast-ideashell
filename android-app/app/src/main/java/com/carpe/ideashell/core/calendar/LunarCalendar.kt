package com.carpe.ideashell.core.calendar

import android.icu.util.Calendar
import android.icu.util.ChineseCalendar
import java.time.LocalDate
import java.time.ZoneId
import java.util.concurrent.ConcurrentHashMap

/**
 * 农历、节气、传统节日与公历节日（用系统自带的 ICU 农历，不需要联网）。
 * 法定节假日和调休见 [ChinaHolidays]。
 */
object LunarCalendar {
    /** 农历的一天；[month] 是 1..12，[leap] 表示闰月 */
    data class Lunar(val year: Int, val month: Int, val day: Int, val leap: Boolean)

    private val ZONE: ZoneId = ZoneId.systemDefault()

    /** ChineseCalendar 的「扩展年」= 公历年 + 2637 */
    private const val ERA_OFFSET = 2637

    private val cache = ConcurrentHashMap<LocalDate, Lunar>()

    fun of(date: LocalDate): Lunar = cache.getOrPut(date) {
        val cal = ChineseCalendar()
        cal.timeInMillis = date.atTime(12, 0).atZone(ZONE).toInstant().toEpochMilli()
        Lunar(
            year = cal.get(Calendar.EXTENDED_YEAR) - ERA_OFFSET,
            month = cal.get(Calendar.MONTH) + 1,
            day = cal.get(Calendar.DAY_OF_MONTH),
            leap = cal.get(Calendar.IS_LEAP_MONTH) == 1,
        )
    }

    /** 农历 [year] 年 [month] 月 [day] 日对应的公历日期；日期不存在返回 null。[year] 是农历年的数字（春节所在的那个公历年） */
    fun toSolar(year: Int, month: Int, day: Int, leap: Boolean = false): LocalDate? = try {
        val cal = ChineseCalendar()
        cal.clear()
        cal.set(Calendar.EXTENDED_YEAR, year + ERA_OFFSET)
        cal.set(Calendar.MONTH, month - 1)
        cal.set(Calendar.IS_LEAP_MONTH, if (leap) 1 else 0)
        cal.set(Calendar.DAY_OF_MONTH, day)
        val result = java.time.Instant.ofEpochMilli(cal.timeInMillis).atZone(ZONE).toLocalDate()
        // 三十 / 闰月这些「不存在」的日子 ICU 会自动顺延，对不上就当没有
        val back = of(result)
        if (back.month == month && back.day == day && back.leap == leap) result else null
    } catch (_: Exception) {
        null
    }

    private val MONTH_NAMES = listOf("正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊")
    private val DAY_NAMES = listOf(
        "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
    )

    fun monthName(l: Lunar): String = (if (l.leap) "闰" else "") + MONTH_NAMES[l.month - 1] + "月"

    /** 日历格子里的农历：初一显示月份（正月 / 闰四月），其余显示日（初二 … 三十） */
    fun dayText(l: Lunar): String = if (l.day == 1) monthName(l) else DAY_NAMES[l.day - 1]

    /** 完整农历：九月初九 / 闰六月十五 */
    fun fullText(l: Lunar): String = monthName(l) + DAY_NAMES[l.day - 1]

    /** 传统节日（农历）；除夕按「正月初一的前一天」算，因为腊月有 29 天也有 30 天 */
    fun lunarFestival(date: LocalDate): String? {
        val l = of(date)
        if (!l.leap) {
            when (l.month to l.day) {
                1 to 1 -> return "春节"
                1 to 15 -> return "元宵"
                2 to 2 -> return "龙抬头"
                5 to 5 -> return "端午"
                7 to 7 -> return "七夕"
                7 to 15 -> return "中元"
                8 to 15 -> return "中秋"
                9 to 9 -> return "重阳"
                12 to 8 -> return "腊八"
                12 to 23 -> return "小年"
            }
        }
        if (l.month == 12 && l.day >= 29) {
            val next = of(date.plusDays(1))
            if (next.month == 1 && next.day == 1) return "除夕"
        }
        return null
    }

    /** 公历节日 / 纪念日（只放大家会在意的） */
    fun solarFestival(date: LocalDate): String? = when (date.monthValue to date.dayOfMonth) {
        1 to 1 -> "元旦"
        2 to 14 -> "情人节"
        3 to 8 -> "妇女节"
        3 to 12 -> "植树节"
        5 to 1 -> "劳动节"
        5 to 4 -> "青年节"
        6 to 1 -> "儿童节"
        7 to 1 -> "建党节"
        8 to 1 -> "建军节"
        9 to 10 -> "教师节"
        10 to 1 -> "国庆节"
        12 to 24 -> "平安夜"
        12 to 25 -> "圣诞节"
        else -> movableFestival(date)
    }

    /** 母亲节（5 月第 2 个周日）/ 父亲节（6 月第 3 个周日） */
    private fun movableFestival(date: LocalDate): String? {
        if (date.dayOfWeek != java.time.DayOfWeek.SUNDAY) return null
        val nth = (date.dayOfMonth - 1) / 7 + 1
        return when {
            date.monthValue == 5 && nth == 2 -> "母亲节"
            date.monthValue == 6 && nth == 3 -> "父亲节"
            else -> null
        }
    }

    private val TERMS = listOf(
        "小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨", "立夏", "小满", "芒种", "夏至",
        "小暑", "大暑", "立秋", "处暑", "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至",
    )

    /** 21 世纪的 24 节气「寿星公式」常数：小寒 … 冬至 */
    private val C_21 = doubleArrayOf(
        5.4055, 20.12, 3.87, 18.73, 5.63, 20.646, 4.81, 20.1, 5.52, 21.04, 5.678, 21.37,
        7.108, 22.83, 7.5, 23.13, 7.646, 23.042, 8.318, 23.438, 7.438, 22.36, 7.18, 21.94,
    )

    /** 当天是不是节气（公式算的，极个别年份可能差一天） */
    fun solarTerm(date: LocalDate): String? {
        val y = date.year % 100
        val m = date.monthValue
        // 每个月有两个节气：索引 2(m-1) 和 2(m-1)+1
        for (i in listOf(2 * (m - 1), 2 * (m - 1) + 1)) {
            val d = (y * 0.2422 + C_21[i]).toInt() - (if (m <= 2) (y - 1) / 4 else y / 4)
            if (d == date.dayOfMonth) return TERMS[i]
        }
        return null
    }

    /** 清明节气所在的公历日期（找传统节日「清明」用） */
    fun qingming(year: Int): LocalDate {
        val y = year % 100
        return LocalDate.of(year, 4, (y * 0.2422 + 4.81).toInt() - y / 4)
    }

    /** 「国庆」「春节」「端午」这类说法对应的下一个日期（今天或以后）；认不出返回 null */
    fun nextFestival(name: String, today: LocalDate): LocalDate? {
        solarDay(name)?.let { (m, d) ->
            return listOf(today.year, today.year + 1).mapNotNull { safe(it, m, d) }.firstOrNull { !it.isBefore(today) }
        }
        movable(name)?.let { f ->
            return listOf(today.year, today.year + 1).map(f).firstOrNull { !it.isBefore(today) }
        }
        if (name == "清明") return listOf(today.year, today.year + 1).map(::qingming).firstOrNull { !it.isBefore(today) }
        if (name == "除夕") {
            return listOf(today.year, today.year + 1)
                .mapNotNull { toSolar(it, 1, 1)?.minusDays(1) }
                .firstOrNull { !it.isBefore(today) }
        }
        lunarDay(name)?.let { (m, d) ->
            // 农历年可能和公历年错开（今年的腊八在明年 1 月之前），多试一年
            return listOf(today.year - 1, today.year, today.year + 1)
                .mapNotNull { toSolar(it, m, d) }
                .filter { !it.isBefore(today) }
                .minOrNull()
        }
        return null
    }

    private fun safe(y: Int, m: Int, d: Int): LocalDate? = runCatching { LocalDate.of(y, m, d) }.getOrNull()

    private fun solarDay(name: String): Pair<Int, Int>? = when (name) {
        "元旦" -> 1 to 1
        "情人节" -> 2 to 14
        "妇女节", "三八" -> 3 to 8
        "植树节" -> 3 to 12
        "劳动节", "五一" -> 5 to 1
        "青年节" -> 5 to 4
        "儿童节", "六一" -> 6 to 1
        "建党节" -> 7 to 1
        "建军节" -> 8 to 1
        "教师节" -> 9 to 10
        "国庆" -> 10 to 1
        "平安夜" -> 12 to 24
        "圣诞" -> 12 to 25
        else -> null
    }

    private fun movable(name: String): ((Int) -> LocalDate)? = when (name) {
        "母亲节" -> { y -> nthSunday(y, 5, 2) }
        "父亲节" -> { y -> nthSunday(y, 6, 3) }
        else -> null
    }

    private fun nthSunday(year: Int, month: Int, n: Int): LocalDate {
        val first = LocalDate.of(year, month, 1)
        val firstSunday = first.plusDays(((7 - first.dayOfWeek.value) % 7).toLong())
        return firstSunday.plusWeeks((n - 1).toLong())
    }

    private fun lunarDay(name: String): Pair<Int, Int>? = when (name) {
        "春节" -> 1 to 1
        "元宵" -> 1 to 15
        "龙抬头" -> 2 to 2
        "端午" -> 5 to 5
        "七夕" -> 7 to 7
        "中元" -> 7 to 15
        "中秋" -> 8 to 15
        "重阳" -> 9 to 9
        "腊八" -> 12 to 8
        "小年" -> 12 to 23
        else -> null
    }
}
