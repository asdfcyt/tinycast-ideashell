package com.carpe.ideashell.domain

import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.dida.FocusSummary
import com.carpe.ideashell.data.dida.HabitStat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import kotlin.math.min
import kotlin.math.roundToInt

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

/** 「连续记录」：最近几天每天记了多少，哪天断了 */
data class StreakInsight(
    /** 最近 [days].size 天（最多 14 天，含 anchor），最早的在前 */
    val days: List<LocalDate>,
    /** 每天的记录数：笔记 + 日记 + 完成的待办；0 = 当天没有记录 */
    val counts: List<Int>,
    /** 范围内（到 anchor 为止）有记录的天数 / 总天数 */
    val activeDays: Int,
    val spanDays: Int,
    /** 连续有记录的天数；今天还没记时从昨天往回数 */
    val streak: Int,
    /** 连续记录的前一天（断掉的那天）；断点不在范围内为 null */
    val breakDay: LocalDate?,
)

/** 一天的专注时间线：每一次专注是 0..24 小时轴上的一段 */
class FocusLine(val date: LocalDate, val blocks: List<ClosedFloatingPointRange<Float>>)

/** 「专注」：趋势、时间线、最佳时段，都由滴答的专注记录算出 */
data class FocusInsight(
    /** 趋势窗口：最近几天（最多 14 天），最早的在前 */
    val days: List<LocalDate>,
    val minutes: List<Int>,
    /** 窗口内日均专注分钟 */
    val avgMin: Int,
    val bestDay: LocalDate,
    /** 时间线：窗口里最近几天（最多 7 天） */
    val lines: List<FocusLine>,
    /** 整个范围里每个小时的专注分钟 */
    val hours: List<Int>,
    /** 最集中的连续 2 小时窗口起点；专注太分散时为 null */
    val bestStart: Int?,
    /** 这 2 小时占全部专注的百分比 */
    val bestShare: Int,
    val sessionCount: Int,
) {
    /** 趋势和时间线至少要有 3 天才谈得上「趋势」 */
    val hasTrend: Boolean get() = days.size >= MIN_TREND_DAYS && minutes.sum() > 0
}

/** 「待办」：完成了多少、逾期多少 */
data class TodoInsight(
    val done: Int,
    val total: Int,
    /** 计划日已过、还没完成的待办数 */
    val overdue: Int,
    /** 最久逾期多少天 */
    val maxLateDays: Int,
    /** 完成的待办里：计划日当天或之前完成 / 过了计划日才完成 */
    val onTime: Int,
    val lateDone: Int,
)

/** 一个习惯在窗口里的完成情况 */
class HabitRow(val name: String, val due: Int, val done: Int) {
    val rate: Float get() = if (due == 0) 0f else done.toFloat() / due
}

/** 「习惯」：窗口内应打卡的天里完成了多少，哪个最稳、哪个掉队 */
data class HabitInsight(
    /** 完成率从高到低；窗口内没有需要打卡的日子的习惯不在里面 */
    val rows: List<HabitRow>,
    /** 整体完成率（百分比） */
    val rate: Int,
)

/** 「话题」：范围内被提得最多的标签 */
data class TopicInsight(val tags: List<Pair<String, Int>>)

private const val MIN_TREND_DAYS = 3

/**
 * 回顾顶部「发现」里除时间分配以外的几条结论。每条都能由已有的数据算出来，
 * 没有足够数据支撑的那条为 null，界面上就不显示。
 */
data class Insights(
    val rhythm: RhythmInsight?,
    val streak: StreakInsight?,
    val focus: FocusInsight?,
    val habit: HabitInsight?,
    val todo: TodoInsight?,
    val topic: TopicInsight?,
) {
    val isEmpty: Boolean
        get() = rhythm == null && streak == null && focus == null && habit == null && todo == null && topic == null

    companion object {
        val Empty = Insights(null, null, null, null, null, null)

        private val TAG = Regex("#([\\p{L}\\p{N}_\\-]+)")

        /** 至少这么多条带时间的记录才谈得上「习惯」 */
        private const val MIN_RHYTHM_EVENTS = 8

        /** 趋势图最多画这么多天 */
        private const val MAX_TREND_DAYS = 14

        /** 时间线最多画这么多天 */
        private const val MAX_LINE_DAYS = 7

        fun build(
            data: TimelineData?,
            focus: FocusSummary? = null,
            habits: List<HabitStat>? = null,
            today: LocalDate = LocalDate.now(),
            zone: ZoneId = ZoneId.systemDefault(),
        ): Insights {
            val habitInsight = habitOf(habits)
            if (data == null || data.isEmpty) return Empty.copy(habit = habitInsight)
            return Insights(
                rhythm = rhythm(data, zone),
                streak = streak(data, today, zone),
                focus = focusOf(data, focus, today, zone),
                habit = habitInsight,
                todo = todo(data, today, zone),
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

        /** 窗口：anchor 往前最多 [MAX_TREND_DAYS] 天，不早于范围起点；最早的在前 */
        private fun windowOf(data: TimelineData, today: LocalDate): List<LocalDate> {
            val anchor = minOf(today, data.range.last)
            val span = (ChronoUnit.DAYS.between(data.range.start, anchor).toInt() + 1).coerceAtLeast(1)
            val n = min(span, MAX_TREND_DAYS)
            return (n - 1 downTo 0).map { anchor.minusDays(it.toLong()) }
        }

        private fun streak(data: TimelineData, today: LocalDate, zone: ZoneId): StreakInsight? {
            val window = windowOf(data, today)
            if (window.size < MIN_TREND_DAYS) return null
            val perDay = HashMap<LocalDate, Int>()
            for (day in data.days) {
                val n = day.notes.size + day.daily.size + day.todos.count { it.done }
                if (n > 0) perDay.merge(day.date, n, Int::plus)
            }
            if (perDay.isEmpty()) return null
            val anchor = window.last()
            val span = (ChronoUnit.DAYS.between(data.range.start, anchor).toInt() + 1).coerceAtLeast(1)
            val activeDays = perDay.keys.count { !it.isBefore(data.range.start) && !it.isAfter(anchor) }
            var cursor = if (anchor in perDay) anchor else anchor.minusDays(1)
            var streak = 0
            while (cursor in perDay && !cursor.isBefore(data.range.start)) {
                streak++
                cursor = cursor.minusDays(1)
            }
            val breakDay = cursor.takeIf { streak > 0 && !it.isBefore(data.range.start) }
            return StreakInsight(
                days = window,
                counts = window.map { perDay[it] ?: 0 },
                activeDays = activeDays,
                spanDays = span,
                streak = streak,
                breakDay = breakDay,
            )
        }

        private fun focusOf(data: TimelineData, summary: FocusSummary?, today: LocalDate, zone: ZoneId): FocusInsight? {
            val sessions = summary?.sessions.orEmpty()
            if (sessions.isEmpty()) return null
            val window = windowOf(data, today)

            val perDay = HashMap<LocalDate, Double>()
            val blocksOf = HashMap<LocalDate, MutableList<ClosedFloatingPointRange<Float>>>()
            val hourMs = LongArray(24)
            var totalMs = 0L
            for (s in sessions) {
                val start = Instant.ofEpochMilli(s.startMs).atZone(zone)
                val minutes = (s.endMs - s.startMs) / 60000.0
                perDay.merge(start.toLocalDate(), minutes, Double::plus)
                val from = start.hour + start.minute / 60f
                blocksOf.getOrPut(start.toLocalDate()) { mutableListOf() } += from..min(from + minutes.toFloat() / 60f, 24f)
                // 按小时切开，跨小时的专注分别记到各自的小时里
                var t = s.startMs
                while (t < s.endMs) {
                    val z = Instant.ofEpochMilli(t).atZone(zone)
                    val next = z.truncatedTo(ChronoUnit.HOURS).plusHours(1).toInstant().toEpochMilli()
                    val seg = min(s.endMs, next) - t
                    hourMs[z.hour] += seg
                    totalMs += seg
                    t += seg
                }
            }
            val minutes = window.map { (perDay[it] ?: 0.0).roundToInt() }
            val hours = hourMs.map { (it / 60000.0).roundToInt() }
            val bestDay = window[minutes.indices.maxByOrNull { minutes[it] } ?: 0]

            var bestStart: Int? = null
            var bestShare = 0
            if (sessions.size >= 3 && totalMs >= 30 * 60000L) {
                var bestMs = -1L
                var at = 0
                for (h in 0..22) {
                    val sum = hourMs[h] + hourMs[h + 1]
                    if (sum > bestMs) {
                        bestMs = sum
                        at = h
                    }
                }
                val share = (100.0 * bestMs / totalMs).roundToInt()
                // 两个小时要占到四分之一以上才算「最佳时段」，否则只是平均分散
                if (share >= 25) {
                    bestStart = at
                    bestShare = share
                }
            }

            return FocusInsight(
                days = window,
                minutes = minutes,
                avgMin = if (window.isEmpty()) 0 else (minutes.sum().toDouble() / window.size).roundToInt(),
                bestDay = bestDay,
                lines = window.takeLast(MAX_LINE_DAYS).map { d -> FocusLine(d, blocksOf[d].orEmpty()) },
                hours = hours,
                bestStart = bestStart,
                bestShare = bestShare,
                sessionCount = sessions.size,
            )
        }

        private fun habitOf(stats: List<HabitStat>?): HabitInsight? {
            val rows = stats.orEmpty().filter { it.due > 0 }
                .map { HabitRow(it.name, it.due, it.done) }
                .sortedWith(compareByDescending<HabitRow> { it.rate }.thenByDescending { it.done }.thenBy { it.name })
            if (rows.isEmpty()) return null
            val due = rows.sumOf { it.due }
            return HabitInsight(rows, (100.0 * rows.sumOf { it.done } / due).roundToInt())
        }

        private fun todo(data: TimelineData, today: LocalDate, zone: ZoneId): TodoInsight? {
            if (data.todoTotal == 0) return null
            var overdue = 0
            var maxLate = 0
            var onTime = 0
            var lateDone = 0
            for (day in data.days) {
                for (t in day.todos) {
                    val planned = t.date?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
                    if (t.done) {
                        val doneOn = t.completedAt?.let { Instant.ofEpochMilli(it).atZone(zone).toLocalDate() }
                        if (planned != null && doneOn != null && doneOn.isAfter(planned)) lateDone++ else onTime++
                        continue
                    }
                    if (planned == null) continue
                    val late = ChronoUnit.DAYS.between(planned, today).toInt()
                    if (late >= 1) {
                        overdue++
                        if (late > maxLate) maxLate = late
                    }
                }
            }
            return TodoInsight(data.todoDone, data.todoTotal, overdue, maxLate, onTime, lateDone)
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
