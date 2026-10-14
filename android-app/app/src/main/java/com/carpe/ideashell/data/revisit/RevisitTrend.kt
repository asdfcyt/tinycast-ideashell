package com.carpe.ideashell.data.revisit

import com.carpe.ideashell.data.db.RevisitLogEntity
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters

/** 间隔复习折线图可以选的统计范围 */
enum class RevisitRange(val label: String) {
    LAST7("最近 7 天"),
    LAST30("最近 30 天"),
    THIS_WEEK("本周"),
    THIS_MONTH("本月"),
    LAST_MONTH("上月"),
    ;

    /** 范围内的每一天（最早的在前）；本周 / 本月包含还没到的日子，图上留空 */
    fun days(today: LocalDate): List<LocalDate> {
        val first: LocalDate
        val last: LocalDate
        when (this) {
            LAST7 -> { first = today.minusDays(6); last = today }
            LAST30 -> { first = today.minusDays(29); last = today }
            THIS_WEEK -> {
                first = today.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
                last = first.plusDays(6)
            }
            THIS_MONTH -> {
                first = today.withDayOfMonth(1)
                last = today.with(TemporalAdjusters.lastDayOfMonth())
            }
            LAST_MONTH -> {
                val prev = today.minusMonths(1)
                first = prev.withDayOfMonth(1)
                last = prev.with(TemporalAdjusters.lastDayOfMonth())
            }
        }
        return generateSequence(first) { it.plusDays(1) }.takeWhile { !it.isAfter(last) }.toList()
    }
}

/**
 * 一段时间里每天的重温情况：[reviewed] 每天重温了几次，[forgotten] 其中评「忘了」的几次；
 * 还没到的日子是 null（折线在那里断开，不画成 0）。
 */
data class RevisitTrend(
    val range: RevisitRange,
    val days: List<LocalDate>,
    val reviewed: List<Int?>,
    val forgotten: List<Int?>,
) {
    val totalReviewed: Int get() = reviewed.sumOf { it ?: 0 }
    val totalForgotten: Int get() = forgotten.sumOf { it ?: 0 }

    /** 有重温记录的天数 */
    val activeDays: Int get() = reviewed.count { (it ?: 0) > 0 }

    /** 记得率（百分比）；范围内一次都没重温过为 null */
    val recallRate: Int?
        get() = if (totalReviewed == 0) null else (100.0 * (totalReviewed - totalForgotten) / totalReviewed).toInt()

    companion object {
        fun empty(range: RevisitRange, today: LocalDate = LocalDate.now()): RevisitTrend = build(range, today, emptyList())

        fun build(
            range: RevisitRange,
            today: LocalDate,
            logs: List<RevisitLogEntity>,
            zone: ZoneId = ZoneId.systemDefault(),
        ): RevisitTrend {
            val days = range.days(today)
            val all = HashMap<LocalDate, Int>()
            val forgot = HashMap<LocalDate, Int>()
            for (log in logs) {
                val d = Instant.ofEpochMilli(log.reviewedAt).atZone(zone).toLocalDate()
                all.merge(d, 1, Int::plus)
                if (log.rating == FORGOT) forgot.merge(d, 1, Int::plus)
            }
            return RevisitTrend(
                range = range,
                days = days,
                reviewed = days.map { if (it.isAfter(today)) null else all[it] ?: 0 },
                forgotten = days.map { if (it.isAfter(today)) null else forgot[it] ?: 0 },
            )
        }

        /** 评分「忘了」存下来的值（同 Fsrs.Rating.AGAIN.grade） */
        private const val FORGOT = 1
    }
}
