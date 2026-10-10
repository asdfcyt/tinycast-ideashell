package com.carpe.ideashell.data.notes

import com.carpe.ideashell.core.parse.TimeRange
import com.carpe.ideashell.data.dida.DidaApi
import com.carpe.ideashell.data.dida.DidaOverview
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.ideashell.DailyNoteService
import com.carpe.ideashell.data.ideashell.IdeashellApi
import com.carpe.ideashell.data.ideashell.NoteBrief
import com.carpe.ideashell.data.ideashell.NoteDetail
import com.carpe.ideashell.data.ideashell.NoteInfo
import com.carpe.ideashell.data.ideashell.NotesInRange
import com.carpe.ideashell.data.ideashell.Speaker
import com.carpe.ideashell.domain.Dossier
import com.carpe.ideashell.domain.DossierData
import com.carpe.ideashell.domain.DossierTodo
import com.carpe.ideashell.domain.MemoryData
import com.carpe.ideashell.domain.MemoryLane
import com.carpe.ideashell.domain.Timeline
import com.carpe.ideashell.domain.TimelineData
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import java.time.LocalDate
import java.time.ZoneId

/**
 * 「回看」的数据来源：时间线 / Daily Note / 搜索 / 往日回顾 / 档案 / 笔记全文。
 * 全部是只读查询，没有本地数据库；笔记全文在内存里留一份小缓存，来回翻看不用重复请求。
 */
class NotesRepository(
    private val ideashell: IdeashellApi,
    private val dida: DidaApi,
    private val dailyNotes: DailyNoteService,
    private val hasDida: () -> Boolean,
    /** 滴答本地缓存（档案里的相关待办用，不额外请求） */
    private val todoSnapshot: () -> DidaOverview?,
) {
    private val detailCache = object : LinkedHashMap<String, NoteDetail>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, NoteDetail>?): Boolean = size > DETAIL_CACHE_SIZE
    }

    /** 范围内的笔记 + 待办，按天分组。待办拉不到时只影响待办统计，不影响笔记。 */
    suspend fun timeline(range: TimeRange): TimelineData = coroutineScope {
        val zone = ZoneId.systemDefault()
        val notesJob = async {
            ideashell.notesInRange(
                range.start.atStartOfDay(zone).toInstant(),
                range.endExclusive.atStartOfDay(zone).toInstant(),
            )
        }
        val tasksJob = async {
            if (!hasDida()) {
                emptyList<DidaTask>() to "未连接滴答清单，待办没有计入"
            } else {
                try {
                    dida.tasksInRange(range.start, range.last) to null
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    emptyList<DidaTask>() to "待办加载失败：${e.message ?: "网络异常"}"
                }
            }
        }
        val found: NotesInRange = notesJob.await()
        val (tasks, todoNote) = tasksJob.await()
        Timeline.build(range, found.notes, tasks, found.truncated, todoNote, zone)
    }

    suspend fun dailyNoteList(): List<NoteBrief> = dailyNotes.list()

    suspend fun search(query: String): List<NoteInfo> = ideashell.searchNotes(query.trim(), 20)

    suspend fun memory(today: LocalDate = LocalDate.now()): MemoryData {
        val zone = ZoneId.systemDefault()
        val start = today.minusYears(MemoryLane.LOOKBACK_YEARS.toLong()).atStartOfDay(zone).toInstant()
        val end = today.plusDays(1).atStartOfDay(zone).toInstant()
        val found = ideashell.notesInRange(start, end)
        return MemoryLane.build(found.notes, found.truncated, today)
    }

    suspend fun dossier(query: String, today: LocalDate = LocalDate.now()): DossierData = coroutineScope {
        val q = query.trim()
        val searches = Dossier.searchVariants(q).map { v -> async { softly { ideashell.searchNotes(v, 20) } ?: emptyList() } }
        val openTodos = async { softly { ideashell.todosByKeyword(q, completed = false) } ?: emptyList() }
        val doneTodos = async { softly { ideashell.todosByKeyword(q, completed = true) } ?: emptyList() }
        val allSpeakers = async { softly { ideashell.listSpeakers() } ?: emptyList<Speaker>() }

        val speakers = Dossier.matchSpeakers(q, allSpeakers.await())
        val speakerNotes: List<NoteInfo> = if (speakers.isEmpty()) {
            emptyList()
        } else {
            softly { ideashell.searchBySpeaker(speakers.map { it.id }, 20) } ?: emptyList()
        }

        val todos = (openTodos.await() + doneTodos.await()).map { DossierTodo(it.title, it.date, it.time, it.done) } +
            localDidaTodos(q)

        Dossier.build(
            query = q,
            searchResults = searches.flatMap { it.await() },
            speakerNotes = speakerNotes,
            speakers = speakers,
            todos = todos.distinctBy { "${it.title}|${it.date}|${it.done}" },
            today = today,
        )
    }

    /** 笔记全文；[force] 跳过缓存 */
    suspend fun note(id: String, force: Boolean = false): NoteDetail {
        if (!force) synchronized(detailCache) { detailCache[id] }?.let { return it }
        val detail = ideashell.noteFull(id)
        synchronized(detailCache) { detailCache[id] = detail }
        return detail
    }

    /** 滴答缓存里标题 / 备注含关键词的任务（未完成 + 最近完成） */
    private fun localDidaTodos(q: String): List<DossierTodo> {
        val o = todoSnapshot() ?: return emptyList()
        val lq = q.lowercase()
        return (o.overdue + o.upcoming + o.undated + o.done)
            .filter { it.title.lowercase().contains(lq) || it.content.lowercase().contains(lq) }
            .map { DossierTodo(it.title, it.date, it.time, it.done) }
    }

    /** 档案是「尽力而为」的聚合：单路失败不拖垮整体 */
    private suspend fun <T> softly(block: suspend () -> T): T? = try {
        block()
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    private companion object {
        const val DETAIL_CACHE_SIZE = 24
    }
}
