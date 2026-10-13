package com.carpe.ideashell.data.revisit

import com.carpe.ideashell.core.revisit.Fsrs
import com.carpe.ideashell.data.db.RevisitDao
import com.carpe.ideashell.data.db.RevisitEntity
import com.carpe.ideashell.data.db.RevisitKind
import com.carpe.ideashell.data.ideashell.NoteDetail
import com.carpe.ideashell.data.ideashell.NoteInfo
import com.carpe.ideashell.data.ideashell.NoteTime
import com.carpe.ideashell.data.settings.AppSettings
import com.carpe.ideashell.data.settings.SettingsStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId

/** 「今天」要重温的东西：已按「最该复习（最接近遗忘）」排好，并按每日上限截断 */
data class RevisitToday(
    val queue: List<RevisitEntity> = emptyList(),
    /** 今天已经重温过几条 */
    val doneToday: Int = 0,
    val limit: Int = AppSettings.DEFAULT_REVISIT_LIMIT,
    /** 重温库里一共多少条（不含「不再重温」的） */
    val total: Int = 0,
    /** 已经到期的一共多少条（含超出每日上限、顺延到后面几天的） */
    val dueTotal: Int = 0,
    /** 今天没有可重温的时，下一条什么时候出现 */
    val nextDue: LocalDate? = null,
) {
    val remaining: Int get() = queue.size
}

enum class AddResult { ADDED, EXISTS, RESTORED }

/**
 * 笔记 / 日记片段的 FSRS 间隔重温。数据在本机数据库（重温项表），不依赖网络；
 * 只有「加入整篇笔记」时会去读一次笔记全文做快照，读不到就退回摘要。
 */
class RevisitRepository(
    private val dao: RevisitDao,
    private val settings: SettingsStore,
    scope: CoroutineScope,
    /** 读笔记全文（做快照用） */
    private val loadNote: suspend (String) -> NoteDetail,
) {
    private val day = MutableStateFlow(LocalDate.now())

    /** 还在重温的条目 key 集合（时间河 / 笔记页据此显示「已加入」标记） */
    val keys: StateFlow<Set<String>> = dao.observeActive()
        .map { list -> list.map { it.dedupeKey }.toSet() }
        .distinctUntilChanged()
        .stateIn(scope, SharingStarted.Eagerly, emptySet())

    val today: StateFlow<RevisitToday> = combine(
        dao.observeActive(),
        settings.state.map { it.revisitDailyLimit }.distinctUntilChanged(),
        day,
    ) { items, limit, _ -> computeToday(items, limit, System.currentTimeMillis()) }
        .stateIn(scope, SharingStarted.Eagerly, RevisitToday())

    private val addLock = Mutex()

    /** 回到前台 / 跨天后调用：让「今天」的数据按新的日期重算 */
    fun refreshDay() {
        day.value = LocalDate.now()
    }

    // ───────────────────────── 加入 / 移出 ─────────────────────────

    /** 加入整篇笔记（正文做快照）。[detail] 已经读过全文时直接传，省一次请求 */
    suspend fun addNote(info: NoteInfo, detail: NoteDetail? = null): AddResult {
        val key = noteKey(info.id)
        existing(key)?.let { return revive(it) }
        val full = detail ?: try {
            loadNote(info.id)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }
        val text = (full?.content?.takeIf { it.isNotBlank() } ?: info.summary ?: info.title).take(MAX_TEXT)
        val recorded = (full?.createdAt ?: info.createdAt)?.let { NoteTime.parse(it)?.toEpochMilli() }
        return insert(
            key = key,
            kind = RevisitKind.NOTE,
            noteId = info.id,
            title = (full?.title?.ifBlank { null } ?: info.title).ifBlank { "无标题" },
            text = text,
            sourceLabel = "笔记",
            recordedAt = recorded,
        )
    }

    /** 加入一段摘录：笔记里选中的文字，或 Daily Note 里的一条 */
    suspend fun addSnippet(
        noteId: String?,
        noteTitle: String,
        text: String,
        sourceLabel: String,
        recordedAt: Long? = null,
    ): AddResult {
        val body = text.trim()
        if (body.isEmpty()) return AddResult.EXISTS
        val key = snippetKey(noteId, body)
        existing(key)?.let { return revive(it) }
        return insert(
            key = key,
            kind = RevisitKind.SNIPPET,
            noteId = noteId,
            title = noteTitle,
            text = body.take(MAX_TEXT),
            sourceLabel = sourceLabel,
            recordedAt = recordedAt,
        )
    }

    /**
     * 带 `#重温` 标签的笔记自动加入（与桌面端保持一致）。已经加入过、或点过「不再重温」的不会再加。
     * 悄悄进行，不打扰用户；某一条读不到就留给下次。
     */
    suspend fun autoAddTagged(notes: List<NoteInfo>) {
        val tagged = notes.filter { n -> n.tags.any { it.removePrefix("#").equals(TAG, ignoreCase = true) } }
        for (note in tagged) {
            if (existing(noteKey(note.id)) != null) continue
            try {
                addNote(note)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
        }
    }

    /** 笔记全文页打开时用：有 `#重温` 标签就自动加入（已读过全文，不再重复请求） */
    suspend fun autoAddIfTagged(detail: NoteDetail) {
        if (detail.tags.none { it.removePrefix("#").equals(TAG, ignoreCase = true) }) return
        if (existing(noteKey(detail.id)) != null) return
        addNote(NoteInfo(id = detail.id, title = detail.title, summary = detail.summary, tags = detail.tags, createdAt = detail.createdAt), detail)
    }

    /** 「移出重温」：保留一行并标记，所以 `#重温` 标签不会又把它加回来；再次加入时恢复 */
    suspend fun setArchived(key: String, archived: Boolean) {
        val item = dao.byKey(key) ?: return
        if (archived) dao.update(item.copy(archived = true)) else revive(item)
    }

    suspend fun archive(id: Long) {
        dao.get(id)?.let { dao.update(it.copy(archived = true)) }
    }

    /** 撤销「不再重温」 */
    suspend fun restore(id: Long) {
        dao.get(id)?.let { revive(it) }
    }

    // ───────────────────────── 重温 ─────────────────────────

    /** 评分：忘了（明天再来）/ 记得（按 FSRS 排）/ 太简单（间隔更长）。返回评分前的条目，用于撤销 */
    suspend fun rate(id: Long, rating: Fsrs.Rating, now: Long = System.currentTimeMillis()): RevisitEntity? {
        val item = dao.get(id) ?: return null
        val retention = settings.current.revisitRetention / 100.0
        val memory = memoryOf(item)
        val elapsed = elapsedDays(item, now)
        val next = if (memory == null) Fsrs.first(rating) else Fsrs.next(memory, elapsed, rating)
        val days = Fsrs.nextIntervalDays(memory, elapsed, rating, retention)
        dao.update(
            item.copy(
                stability = next.stability,
                difficulty = next.difficulty,
                due = startOfDay(LocalDate.now().plusDays(days.toLong())),
                reps = item.reps + 1,
                lapses = item.lapses + if (rating == Fsrs.Rating.AGAIN && item.reps > 0) 1 else 0,
                lastRating = rating.grade,
                lastReviewAt = now,
                skippedUntil = 0L,
            ),
        )
        return item
    }

    /** 评分按钮下面的「明天 / 3 天后」预览 */
    fun previewDays(item: RevisitEntity, rating: Fsrs.Rating, now: Long = System.currentTimeMillis()): Int =
        Fsrs.nextIntervalDays(
            memoryOf(item),
            elapsedDays(item, now),
            rating,
            settings.current.revisitRetention / 100.0,
        )

    /** 今天跳过：明天再出现，不影响记忆曲线 */
    suspend fun skipToday(id: Long) {
        val item = dao.get(id) ?: return
        dao.update(item.copy(skippedUntil = startOfDay(LocalDate.now().plusDays(1))))
    }

    /** 把撤销前的状态原样写回 */
    suspend fun restoreState(item: RevisitEntity) = dao.update(item)

    /** 一键把现在已到期的全部推后 [days] 天（积压太多时用）；返回受影响的条数和原状态（用于撤销） */
    suspend fun postponeAll(days: Int = 7): List<RevisitEntity> {
        val endToday = startOfDay(LocalDate.now().plusDays(1))
        val newDue = startOfDay(LocalDate.now().plusDays(days.toLong()))
        val due = dao.active().filter { it.due < endToday }
        if (due.isEmpty()) return emptyList()
        dao.updateAll(due.map { it.copy(due = newDue, skippedUntil = 0L) })
        return due
    }

    suspend fun restoreAll(items: List<RevisitEntity>) {
        if (items.isNotEmpty()) dao.updateAll(items)
    }

    /** 当前已到期的条数（含超出每日上限的），用于「全部推后」的提示 */
    suspend fun dueCount(): Int {
        val endToday = startOfDay(LocalDate.now().plusDays(1))
        return dao.active().count { it.due < endToday }
    }

    /** 提醒用：此刻今天还剩几条要重温（与「今天」页同一口径） */
    suspend fun remainingToday(): Int =
        computeToday(dao.active(), settings.current.revisitDailyLimit, System.currentTimeMillis()).remaining

    suspend fun get(id: Long): RevisitEntity? = dao.get(id)

    // ───────────────────────── 内部 ─────────────────────────

    private suspend fun existing(key: String): RevisitEntity? = dao.byKey(key)

    private suspend fun revive(item: RevisitEntity): AddResult {
        if (!item.archived) return AddResult.EXISTS
        val tomorrow = startOfDay(LocalDate.now().plusDays(1))
        dao.update(item.copy(archived = false, due = maxOf(item.due, tomorrow), skippedUntil = 0L))
        return AddResult.RESTORED
    }

    private suspend fun insert(
        key: String,
        kind: RevisitKind,
        noteId: String?,
        title: String,
        text: String,
        sourceLabel: String,
        recordedAt: Long?,
    ): AddResult = addLock.withLock {
        // 加锁后再查一次：同时点两下不会插入两条
        existing(key)?.let { return@withLock revive(it) }
        val now = System.currentTimeMillis()
        dao.insert(
            RevisitEntity(
                dedupeKey = key,
                kind = kind.name,
                noteId = noteId,
                title = title,
                text = text,
                sourceLabel = sourceLabel,
                recordedAt = recordedAt ?: now,
                addedAt = now,
                stability = 0.0,
                difficulty = 0.0,
                // 刚记下的东西明天才第一次出现，不是立刻重温
                due = startOfDay(LocalDate.now().plusDays(1)),
                reps = 0,
                lapses = 0,
                lastRating = 0,
                lastReviewAt = 0L,
                skippedUntil = 0L,
                archived = false,
            ),
        )
        AddResult.ADDED
    }

    companion object {
        const val TAG = "重温"
        private const val MAX_TEXT = 6000
        private const val DAY_MS = 24L * 60 * 60 * 1000

        fun noteKey(noteId: String): String = "n:$noteId"

        fun snippetKey(noteId: String?, text: String): String {
            val norm = text.trim().replace(Regex("\\s+"), " ")
            return "s:${noteId.orEmpty()}:${norm.hashCode().toUInt().toString(16)}${norm.length}"
        }

        private val zone: ZoneId get() = ZoneId.systemDefault()

        fun startOfDay(date: LocalDate): Long = date.atStartOfDay(zone).toInstant().toEpochMilli()

        fun dateOf(ms: Long): LocalDate = Instant.ofEpochMilli(ms).atZone(zone).toLocalDate()

        /** 某天某刻（本地时间）的毫秒数 */
        fun millisOf(dateTime: LocalDateTime): Long = dateTime.atZone(zone).toInstant().toEpochMilli()

        private fun memoryOf(item: RevisitEntity): Fsrs.Memory? =
            if (item.reps == 0) null else Fsrs.Memory(item.stability, item.difficulty)

        private fun elapsedDays(item: RevisitEntity, now: Long): Double {
            val last = if (item.reps == 0) item.addedAt else item.lastReviewAt
            return ((now - last).coerceAtLeast(0L)).toDouble() / DAY_MS
        }

        /** 排序用的「还记得多少」：越低越该先复习。没复习过的按「记得」的初始稳定性估算 */
        private fun retrievabilityOf(item: RevisitEntity, now: Long): Double {
            val stability = if (item.reps == 0) Fsrs.first(Fsrs.Rating.GOOD).stability else item.stability
            return Fsrs.retrievability(elapsedDays(item, now), stability)
        }

        internal fun computeToday(items: List<RevisitEntity>, limit: Int, now: Long): RevisitToday {
            val today = LocalDate.now()
            val startToday = startOfDay(today)
            val endToday = startOfDay(today.plusDays(1))
            val doneToday = items.count { it.lastReviewAt >= startToday }
            val due = items.filter { it.due < endToday && it.lastReviewAt < startToday }
            val room = (limit - doneToday).coerceAtLeast(0)
            val queue = due
                .filter { it.skippedUntil <= now }
                .sortedBy { retrievabilityOf(it, now) }
                .take(room)
            val nextDue = items.filter { it.due >= endToday }.minOfOrNull { it.due }?.let { dateOf(it) }
            return RevisitToday(
                queue = queue,
                doneToday = doneToday,
                limit = limit,
                total = items.size,
                dueTotal = due.size,
                nextDue = nextDue,
            )
        }
    }
}
