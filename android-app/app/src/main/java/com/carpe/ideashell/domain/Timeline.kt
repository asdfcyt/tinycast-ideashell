package com.carpe.ideashell.domain

import com.carpe.ideashell.core.parse.TimeRange
import com.carpe.ideashell.core.parse.TimeRanges
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.ideashell.NoteInfo
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

data class DayBucket(
    val date: LocalDate,
    /** 2026-10-08 周四 */
    val title: String,
    /** 新的在前 */
    val notes: List<NoteInfo>,
    val todos: List<DidaTask>,
)

data class TimelineData(
    val range: TimeRange,
    /** 新的一天在前 */
    val days: List<DayBucket>,
    val noteCount: Int,
    val todoDone: Int,
    val todoTotal: Int,
    /** 某个 1 小时内的笔记多到取不全 */
    val truncated: Boolean,
    /** 待办没有拉到（没连接滴答，或请求失败）；此时统计里不含待办 */
    val todoNote: String? = null,
) {
    val isEmpty: Boolean get() = days.isEmpty()
}

object Timeline {
    /**
     * 把笔记与待办按天分组（新的在前）。
     * 待办归属哪一天：未完成按计划日期；已完成按完成时间（今天做完的事算在今天），没有完成时间再用计划日期。
     * 无日期的待办不属于任何一天；区间外的丢弃。
     */
    fun build(
        range: TimeRange,
        notes: List<NoteInfo>,
        tasks: List<DidaTask>,
        truncated: Boolean,
        todoNote: String? = null,
        zone: ZoneId = ZoneId.systemDefault(),
    ): TimelineData {
        val todoDays = tasks.mapNotNull { t ->
            val day = taskDay(t, zone) ?: return@mapNotNull null
            if (day.isBefore(range.start) || !day.isBefore(range.endExclusive)) null else day to t
        }
        val noteDays = notes.mapNotNull { n -> n.localDate?.let { it to n } }

        val dates = (noteDays.map { it.first } + todoDays.map { it.first }).toSortedSet(compareByDescending<LocalDate> { it })
        val days = dates.map { date ->
            DayBucket(
                date = date,
                title = TimeRanges.dayLabel(date),
                notes = noteDays.filter { it.first == date }.map { it.second }
                    .sortedByDescending { it.createdAt.orEmpty() },
                todos = todoDays.filter { it.first == date }.map { it.second }
                    .sortedWith(compareBy<DidaTask>({ it.done }, { it.time ?: "99:99" })),
            )
        }
        val todos = todoDays.map { it.second }
        return TimelineData(
            range = range,
            days = days,
            noteCount = noteDays.size,
            todoDone = todos.count { it.done },
            todoTotal = todos.size,
            truncated = truncated,
            todoNote = todoNote,
        )
    }

    private fun taskDay(t: DidaTask, zone: ZoneId): LocalDate? {
        if (t.done) {
            t.completedAt?.let { return Instant.ofEpochMilli(it).atZone(zone).toLocalDate() }
        }
        return t.date?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
    }

    /** 生成可直接贴进日报 / 周报的 Markdown */
    fun report(data: TimelineData): String {
        val lines = mutableListOf(
            "# ${data.range.label} 回顾",
            "",
            "> ${data.noteCount} 条笔记 · 待办完成 ${data.todoDone}/${data.todoTotal}",
        )
        for (day in data.days) {
            lines += listOf("", "## ${day.title}")
            if (day.notes.isNotEmpty()) {
                lines += listOf("", "**笔记**", "")
                // 同一天内按时间正序更符合阅读习惯
                day.notes.reversed().forEach { n ->
                    val time = n.localClock?.let { "$it " }.orEmpty()
                    val summary = n.summary?.let { " — ${NoteText.truncate(it, 80)}" }.orEmpty()
                    lines += "- $time**${n.title}**$summary"
                }
            }
            if (day.todos.isNotEmpty()) {
                lines += listOf("", "**待办**", "")
                day.todos.forEach { t ->
                    lines += "- [${if (t.done) "x" else " "}] ${t.title}${t.time?.let { "（$it）" }.orEmpty()}"
                }
            }
        }
        return lines.joinToString("\n")
    }
}
