package com.carpe.ideashell.domain

import com.carpe.ideashell.data.ideashell.NoteInfo
import java.time.LocalDate

/** 往日同期：日历推算，没有任何猜测 */
data class SameDayGroup(
    /** 1 个月前的今天 */
    val label: String,
    val date: LocalDate,
    /** 时间正序 */
    val notes: List<NoteInfo>,
)

data class MemoryData(
    /** 回溯范围内的全部笔记（随机抽取的候选池，已排除 Daily Note） */
    val pool: List<NoteInfo>,
    val sameDay: List<SameDayGroup>,
    val truncated: Boolean,
)

/** 往日回顾的纯规则，与桌面 `memory-lane.ts` 一致 */
object MemoryLane {
    /** 回溯 5 年（笔记总量不大，空区间只需 1 次请求） */
    const val LOOKBACK_YEARS = 5

    private class Offset(val label: String, val shift: (LocalDate) -> LocalDate)

    /** `plusMonths` 在目标月没有该日（如 31 号）时顺延到当月最后一天，正好是我们要的行为 */
    private val OFFSETS: List<Offset> = buildList {
        add(Offset("1 周前的今天") { it.minusDays(7) })
        add(Offset("2 周前的今天") { it.minusDays(14) })
        add(Offset("1 个月前的今天") { it.minusMonths(1) })
        add(Offset("2 个月前的今天") { it.minusMonths(2) })
        add(Offset("3 个月前的今天") { it.minusMonths(3) })
        add(Offset("6 个月前的今天") { it.minusMonths(6) })
        for (i in 1..LOOKBACK_YEARS) add(Offset("$i 年前的今天") { it.minusYears(i.toLong()) })
    }

    private val RE_DATE_TITLE = Regex("^\\d{4}-\\d{2}-\\d{2}")

    fun isDailyNote(note: NoteInfo): Boolean =
        RE_DATE_TITLE.containsMatchIn(note.title) || note.tags.contains("daily-note")

    fun build(notes: List<NoteInfo>, truncated: Boolean, today: LocalDate = LocalDate.now()): MemoryData {
        val byDay = notes.mapNotNull { n -> n.localDate?.let { it to n } }.groupBy({ it.first }, { it.second })

        val seen = HashSet<LocalDate>()
        val sameDay = mutableListOf<SameDayGroup>()
        for (o in OFFSETS) {
            val date = o.shift(today)
            // 两个偏移落在同一天（如月末）时只保留靠前的
            if (!seen.add(date)) continue
            val list = byDay[date]
            if (!list.isNullOrEmpty()) {
                sameDay += SameDayGroup(o.label, date, list.sortedBy { it.createdAt.orEmpty() })
            }
        }
        return MemoryData(pool = notes.filterNot(::isDailyNote), sameDay = sameDay, truncated = truncated)
    }

    /** 从候选池里随机抽一条（避开 [avoid]；避不开时才放宽，保证有结果） */
    fun pickRandom(pool: List<NoteInfo>, avoid: Collection<String> = emptyList()): NoteInfo? {
        val skip = avoid.toSet()
        val fresh = pool.filterNot { it.id in skip }
        return (fresh.ifEmpty { pool }).randomOrNull()
    }

    /** 往日同期里出现过的笔记 id（随机一条不与之重复） */
    fun sameDayIds(data: MemoryData): List<String> = data.sameDay.flatMap { g -> g.notes.map { it.id } }
}
