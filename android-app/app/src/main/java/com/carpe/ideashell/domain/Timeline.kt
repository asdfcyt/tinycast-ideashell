package com.carpe.ideashell.domain

import com.carpe.ideashell.core.parse.TimeRange
import com.carpe.ideashell.core.parse.TimeRanges
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.ideashell.DailyDay
import com.carpe.ideashell.data.ideashell.DailyEntry
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
    /** 这一天 Daily Note 里按时间戳拆开的条目（写入顺序）；没有 Daily Note 为空 */
    val daily: List<DailyEntry> = emptyList(),
    /** 这一天 Daily Note 的笔记 id，点日记条目时打开它 */
    val dailyNoteId: String? = null,
)

data class TimelineData(
    val range: TimeRange,
    /** 新的一天在前 */
    val days: List<DayBucket>,
    /** 真正的笔记数（不含 Daily Note 里的条目） */
    val noteCount: Int,
    val todoDone: Int,
    val todoTotal: Int,
    /** 某个 1 小时内的笔记多到取不全 */
    val truncated: Boolean,
    /** 待办没有拉到（没连接滴答，或请求失败）；此时统计里不含待办 */
    val todoNote: String? = null,
    /** Daily Note 的条目总数 */
    val dailyCount: Int = 0,
) {
    val isEmpty: Boolean get() = days.isEmpty()
}

object Timeline {
    /**
     * 把笔记、待办和 Daily Note 条目按天分组（新的在前）。
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
        daily: Map<LocalDate, DailyDay> = emptyMap(),
    ): TimelineData {
        val todoDays = tasks.mapNotNull { t ->
            val day = taskDay(t, zone) ?: return@mapNotNull null
            if (day.isBefore(range.start) || !day.isBefore(range.endExclusive)) null else day to t
        }
        // Daily Note 那篇笔记成功拆成日记行之后，不再作为「笔记」出现（再列一次就重复了）。
        // 没拆成的（读取失败、重试后仍断网，或一条都没识别出来）照旧显示成一条笔记，点进去还能看全文，不会凭空消失
        val dailyIds = daily.values.filter { it.entries.isNotEmpty() }.map { it.noteId }.toSet()
        val noteDays = notes
            .filterNot { it.id in dailyIds }
            .mapNotNull { n -> n.localDate?.let { it to n } }
        val dailyDays = daily.filter { (d, v) ->
            v.entries.isNotEmpty() && !d.isBefore(range.start) && d.isBefore(range.endExclusive)
        }

        val dates = (noteDays.map { it.first } + todoDays.map { it.first } + dailyDays.keys)
            .toSortedSet(compareByDescending<LocalDate> { it })
        val days = dates.map { date ->
            DayBucket(
                date = date,
                title = TimeRanges.dayLabel(date),
                notes = noteDays.filter { it.first == date }.map { it.second }
                    .sortedByDescending { it.createdAt.orEmpty() },
                todos = todoDays.filter { it.first == date }.map { it.second }
                    .sortedWith(compareBy<DidaTask>({ it.done }, { it.time ?: "99:99" })),
                daily = dailyDays[date]?.entries.orEmpty(),
                dailyNoteId = dailyDays[date]?.noteId,
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
            dailyCount = dailyDays.values.sumOf { it.entries.size },
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
        val summary = buildList {
            add("${data.noteCount} 条笔记")
            if (data.dailyCount > 0) add("${data.dailyCount} 条日记")
            add("待办完成 ${data.todoDone}/${data.todoTotal}")
        }.joinToString(" · ")
        val lines = mutableListOf(
            "# ${data.range.label} 回顾",
            "",
            "> $summary",
        )
        for (day in data.days) {
            lines += listOf("", "## ${day.title}")
            if (day.daily.isNotEmpty()) {
                lines += listOf("", "**日记**", "")
                day.daily.forEach { e -> lines += "- ${e.time} ${NoteText.truncate(e.text, 120)}" }
            }
            if (day.notes.isNotEmpty()) {
                lines += listOf("", "**笔记**", "")
                // 同一天内按时间正序更符合阅读习惯
                day.notes.reversed().forEach { n ->
                    val time = n.localClock?.let { "$it " }.orEmpty()
                    val summaryText = n.summary?.let { " — ${NoteText.truncate(it, 80)}" }.orEmpty()
                    lines += "- $time**${n.title}**$summaryText"
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
