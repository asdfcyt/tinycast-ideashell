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
import com.carpe.ideashell.data.mcp.retrying
import com.carpe.ideashell.domain.Dossier
import com.carpe.ideashell.domain.DossierData
import com.carpe.ideashell.domain.DossierTodo
import com.carpe.ideashell.domain.MemoryData
import com.carpe.ideashell.data.backup.BackupService
import com.carpe.ideashell.domain.MemoryLane
import com.carpe.ideashell.domain.Timeline
import com.carpe.ideashell.domain.TimelineData
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.LocalDate
import java.time.ZoneId

/**
 * 「回顾」的数据来源：时间线（含 Daily Note 拆条）/ 搜索 / 往日回顾 / 提及概览 / 笔记全文。
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

    /** 删除某一天 Daily Note 里的一条日记；返回是否真的删掉了 */
    suspend fun deleteDailyEntry(date: java.time.LocalDate, entry: com.carpe.ideashell.data.ideashell.DailyEntry): Boolean =
        dailyNotes.deleteEntry(date, entry)

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
        // Daily Note 按时间戳拆成一条一条放进时间河；读不到不影响笔记和待办
        val dailyJob = async { softly { dailyNotes.daysInRange(range.start, range.last) } ?: emptyMap() }
        val found: NotesInRange = notesJob.await()
        val (tasks, todoNote) = tasksJob.await()
        Timeline.build(range, found.notes.filterNot { BackupService.isBackupNote(it) }, tasks, found.truncated, todoNote, zone, dailyJob.await())
    }


    /** 最近 [days] 天（含今天）的笔记，不含备份笔记；「快速启动」梳理今天时用 */
    suspend fun recentNotes(days: Int): List<NoteInfo> {
        val zone = ZoneId.systemDefault()
        val today = LocalDate.now()
        val found = ideashell.notesInRange(
            today.minusDays((days - 1).toLong()).atStartOfDay(zone).toInstant(),
            today.plusDays(1).atStartOfDay(zone).toInstant(),
        )
        return found.notes.filterNot { BackupService.isBackupNote(it) }
    }

    /** 区间内每天的 Daily Note（笔记 id + 条目） */
    suspend fun dailyDays(from: LocalDate, to: LocalDate): Map<LocalDate, com.carpe.ideashell.data.ideashell.DailyDay> =
        dailyNotes.daysInRange(from, to)

    suspend fun search(query: String): List<NoteInfo> = ideashell.searchNotes(query.trim(), 20)

    private var memoryCache: MemoryData? = null
    private var memoryCacheAt = 0L
    private var memoryCacheDay: LocalDate? = null
    private val memoryLock = Mutex()

    /**
     * 往日回顾（5 年笔记）：拉一次要把区间二分到每段不超过 20 条，请求不少，
     * 所以缓存 [MEMORY_TTL_MS]；[force] 用于用户主动刷新。
     */
    suspend fun memory(today: LocalDate = LocalDate.now(), force: Boolean = false): MemoryData = memoryLock.withLock {
        val cached = memoryCache
        val fresh = cached != null && memoryCacheDay == today &&
            System.currentTimeMillis() - memoryCacheAt < MEMORY_TTL_MS
        if (!force && fresh) return@withLock cached!!
        loadMemory(today).also {
            memoryCache = it
            memoryCacheAt = System.currentTimeMillis()
            memoryCacheDay = today
        }
    }

    /** 缓存里已有的往日回顾（不发请求）；还没加载过为 null */
    fun memoryCached(): MemoryData? = memoryCache

    private suspend fun loadMemory(today: LocalDate): MemoryData {
        val zone = ZoneId.systemDefault()
        val start = today.minusYears(MemoryLane.LOOKBACK_YEARS.toLong()).atStartOfDay(zone).toInstant()
        val end = today.plusDays(1).atStartOfDay(zone).toInstant()
        val found = ideashell.notesInRange(start, end)
        return MemoryLane.build(found.notes.filterNot { BackupService.isBackupNote(it) }, found.truncated, today)
    }

    /**
     * 「今天」页热力图：近 [weeks] 周每天 Daily Note 里有几条记录。
     * 列表 1 次请求拿全部日期；每天的条数要读那天的全文，过去的日子读过一次就存在本机，之后只重读今天。
     * [onProgress] 每读完一批回调一次（已知的天数 → 条数），界面可以边读边画。
     */
    suspend fun dailyHeat(
        today: LocalDate = LocalDate.now(),
        weeks: Int,
        onProgress: (Map<LocalDate, Int>) -> Unit,
    ): Map<LocalDate, Int> {
        val first = today.minusDays((today.dayOfWeek.value - 1).toLong()).minusWeeks((weeks - 1).toLong())
        return dailyNotes.entryCounts(first, today, onProgress)
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
        val detail = retrying { ideashell.noteFull(id) }
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
        const val MEMORY_TTL_MS = 20 * 60 * 1000L
    }
}
