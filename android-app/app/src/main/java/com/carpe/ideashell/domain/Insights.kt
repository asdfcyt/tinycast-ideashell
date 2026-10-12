package com.carpe.ideashell.domain

import com.carpe.ideashell.data.dida.DidaTask
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit

/** 「记录时刻」：一天里哪几个小时记得最多 */
data class RhythmInsight(
    /** 0..23 每小时的记录数（笔记 + 日记 + 完成的待办） */
    val hours: List<Int>,
    /** 连续 3 小时的高峰窗口起点（含）；高峰是 [peakStart]..[peakStart]+2 */
    val peakStart: Int,
) {
    val peakRange: IntRange get() = peakStart..(peakStart + 2)

    /** 「21–23 点」 */
    val peakLabel: String get() = "$peakStart–${peakStart + 2} 点"

    /** 高峰在晚上是「收尾一天」，在早上是「开始一天」，其余只说最常记录 */
    val verb: String
        get() = when {
            peakStart >= 19 -> "收尾一天"
            peakStart <= 10 -> "开始一天"
            else -> "记录"
        }
}

/** 「连续记录」：每天有没有任何记录 */
data class StreakInsight(
    /** 最近 7 天（含 [anchor]），最早的在前；true = 当天有记录 */
    val lastWeek: List<Boolean>,
    /** 最近 7 天对应的日期 */
    val lastWeekDays: List<LocalDate>,
    /** 范围内（到 [anchor] 为止）有记录的天数 / 总天数 */
    val activeDays: Int,
    val spanDays: Int,
    /** 连续有记录的天数；今天还没记时从昨天往回数 */
    val streak: Int,
)

/** 「待办」：完成了多少、逾期多少 */
data class TodoInsight(
    val done: Int,
    val total: Int,
    /** 计划日已过、还没完成的待办数 */
    val overdue: Int,
    /** 最久逾期多少天 */
    val maxLateDays: Int,
)

/** 「话题」：范围内被提得最多的标签 */
data class TopicInsight(val tags: List<Pair<String, Int>>)

/**
 * 回看顶部「发现」里除时间分配以外的几条结论。每条都能由时间线里已有的数据算出来，
 * 没有足够数据支撑的那条为 null，界面上就不显示。
 */
data class Insights(
    val rhythm: RhythmInsight?,
    val streak: StreakInsight?,
    val todo: TodoInsight?,
    val topic: TopicInsight?,
) {
    val isEmpty: Boolean get() = rhythm == null && streak == null && todo == null && topic == null

    companion object {
        val Empty = Insights(null, null, null, null)

        private val TAG = Regex("#([\\p{L}\\p{N}_\\-]+)")

        /** 至少这么多条带时间的记录才谈得上「习惯」 */
        private const val MIN_RHYTHM_EVENTS = 8

        fun build(
            data: TimelineData,
            today: LocalDate = LocalDate.now(),
            zone: ZoneId = ZoneId.systemDefault(),
        ): Insights {
            if (data.isEmpty) return Empty
            return Insights(
                rhythm = rhythm(data, zone),
                streak = streak(data, today),
                todo = todo(data, today),
                topic = topic(data),
            )
        }

        private fun hourOf(clock: String?): Int? {
            val h = clock?.substringBefore(':')?.toIntOrNull() ?: return null
            return h.takeIf { it in 0..23 }
        }

        private fun doneHour(t: DidaTask, zone: ZoneId): Int? {
            val at = t.completedAt ?: return null
            return Instant.ofEpochMilli(at).atZone(zone).hour
        }

        private fun rhythm(data: TimelineData, zone: ZoneId): RhythmInsight? {
            val hours = IntArray(24)
            for (day in data.days) {
                day.notes.forEach { n -> hourOf(n.localClock)?.let { hours[it]++ } }
                day.daily.forEach { e -> hourOf(e.time)?.let { hours[it]++ } }
                day.todos.forEach { t -> if (t.done) doneHour(t, zone)?.let { hours[it]++ } }
            }
            val total = hours.sum()
            if (total < MIN_RHYTHM_EVENTS) return null
            var best = 0
            var bestSum = -1
            for (s in 0..21) {
                val sum = hours[s] + hours[s + 1] + hours[s + 2]
                if (sum > bestSum) {
                    bestSum = sum
                    best = s
                }
            }
            // 高峰要显著：三个小时占了至少三成
            if (bestSum * 10 < total * 3) return null
            return RhythmInsight(hours.toList(), best)
        }

        private fun streak(data: TimelineData, today: LocalDate): StreakInsight? {
            val active = HashSet<LocalDate>()
            for (day in data.days) {
                if (day.notes.isNotEmpty() || day.daily.isNotEmpty() || day.todos.any { it.done }) active += day.date
            }
            if (active.isEmpty()) return null
            val anchor = minOf(today, data.range.last)
            val span = (ChronoUnit.DAYS.between(data.range.start, anchor).toInt() + 1).coerceAtLeast(1)
            val activeDays = active.count { !it.isBefore(data.range.start) && !it.isAfter(anchor) }
            val week = (6 downTo 0).map { anchor.minusDays(it.toLong()) }
            var cursor = if (anchor in active) anchor else anchor.minusDays(1)
            var streak = 0
            while (cursor in active && !cursor.isBefore(data.range.start)) {
                streak++
                cursor = cursor.minusDays(1)
            }
            return StreakInsight(
                lastWeek = week.map { it in active },
                lastWeekDays = week,
                activeDays = activeDays,
                spanDays = span,
                streak = streak,
            )
        }

        private fun todo(data: TimelineData, today: LocalDate): TodoInsight? {
            if (data.todoTotal == 0) return null
            var overdue = 0
            var maxLate = 0
            for (day in data.days) {
                for (t in day.todos) {
                    if (t.done) continue
                    val planned = t.date?.let { runCatching { LocalDate.parse(it) }.getOrNull() } ?: continue
                    val late = ChronoUnit.DAYS.between(planned, today).toInt()
                    if (late >= 1) {
                        overdue++
                        if (late > maxLate) maxLate = late
                    }
                }
            }
            return TodoInsight(data.todoDone, data.todoTotal, overdue, maxLate)
        }

        private fun topic(data: TimelineData): TopicInsight? {
            val count = LinkedHashMap<String, Int>()
            fun add(tag: String) {
                val t = tag.trim().trimStart('#')
                if (t.isNotEmpty()) count.merge(t, 1, Int::plus)
            }
            for (day in data.days) {
                day.notes.forEach { n -> n.tags.forEach(::add) }
                day.daily.forEach { e -> TAG.findAll(e.text).forEach { add(it.groupValues[1]) } }
            }
            if (count.isEmpty()) return null
            val top = count.entries.sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
                .take(3).map { it.key to it.value }
            return TopicInsight(top)
        }
    }
}
