package com.carpe.ideashell.data.revisit

import com.carpe.ideashell.core.parse.TimeRange
import com.carpe.ideashell.data.db.RevisitLogEntity
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * 一段时间里每天的重温情况：[reviewed] 每天重温了几次，[forgotten] 其中评「忘了」的几次；
 * 还没到的日子是 null（折线在那里断开，不画成 0）。
 */
data class RevisitTrend(
    /** 范围的名字，跟着回顾页顶部选的范围走（如「最近 7 天」「本周」） */
    val label: String,
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
        fun empty(range: TimeRange, today: LocalDate = LocalDate.now()): RevisitTrend = build(range, today, emptyList())

        /** [range] 就是回顾页顶部选的统计范围；范围里还没到的日子留空 */
        fun build(
            range: TimeRange,
            today: LocalDate,
            logs: List<RevisitLogEntity>,
            zone: ZoneId = ZoneId.systemDefault(),
        ): RevisitTrend {
            val days = generateSequence(range.start) { it.plusDays(1) }.takeWhile { it.isBefore(range.endExclusive) }.toList()
            val all = HashMap<LocalDate, Int>()
            val forgot = HashMap<LocalDate, Int>()
            for (log in logs) {
                val d = Instant.ofEpochMilli(log.reviewedAt).atZone(zone).toLocalDate()
                all.merge(d, 1, Int::plus)
                if (log.rating == FORGOT) forgot.merge(d, 1, Int::plus)
            }
            return RevisitTrend(
                label = range.label,
                days = days,
                reviewed = days.map { if (it.isAfter(today)) null else all[it] ?: 0 },
                forgotten = days.map { if (it.isAfter(today)) null else forgot[it] ?: 0 },
            )
        }

        /** 评分「忘了」存下来的值（同 Fsrs.Rating.AGAIN.grade） */
        private const val FORGOT = 1
    }
}
