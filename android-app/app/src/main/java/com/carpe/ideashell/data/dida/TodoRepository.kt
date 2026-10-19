package com.carpe.ideashell.data.dida

import com.carpe.ideashell.data.mcp.McpAuthException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.time.LocalDate

data class TodoData(
    val overview: DidaOverview? = null,
    val loading: Boolean = false,
    /** 最近一次刷新失败的原因；有旧数据时界面仍显示旧数据 */
    val error: String? = null,
    val updatedAt: Long = 0L,
)

@Serializable
private data class TodoCache(val overview: DidaOverview, val updatedAt: Long)

/** 日历视图读到的任务，存成文件：重新打开应用、进日历时先有数据可画 */
@Serializable
private data class RangedCache(val tasks: List<DidaTask>)

/**
 * 待办的数据来源（以滴答为主）：本地缓存秒开 → 后台刷新；完成 / 改期等操作先改本地（乐观更新），
 * 再提交滴答，失败回滚并把原因抛给界面。
 */
class TodoRepository(
    private val api: DidaApi,
    private val cacheFile: File,
    private val scope: CoroutineScope,
    private val hasCredential: () -> Boolean,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val _state = MutableStateFlow(TodoData())
    val state: StateFlow<TodoData> = _state.asStateFlow()

    private val refreshLock = Mutex()
    private val stateLock = Mutex()

    /** 本次运行中刚完成的任务：刷新结果里即使还带着它（服务端延迟）也先不显示 */
    private val recentlyDone = HashMap<String, Long>()

    /**
     * 日历视图读到的任务（含已完成，覆盖概览之外更远的日期）。key = 任务 id + 「|o」（未完成）/「|d」（已完成），
     * 因为重复任务的「已完成的这一次」和「下一次」id 相同。完成 / 改期 / 删除等操作会同步改它，日历不用重读也是对的。
     */
    private val _ranged = MutableStateFlow<Map<String, DidaTask>>(emptyMap())
    val ranged: StateFlow<Map<String, DidaTask>> = _ranged.asStateFlow()

    private fun openKey(id: String) = "$id|o"
    private fun doneKey(id: String) = "$id|d"

    private val rangedFile get() = File(cacheFile.parentFile, "todo_ranged.json")

    private fun keyOf(t: DidaTask) = if (t.done) doneKey(t.id) else openKey(t.id)

    /** 读 [from]..[to] 之间的任务并替换日历缓存里这段日期的旧数据；失败时保留旧数据 */
    suspend fun loadRange(from: LocalDate, to: LocalDate): Result<Unit> = attempt {
        // 一个月最多几百条任务的 JSON：解析放到后台线程，别卡住正在滑动的界面
        val fetched = withContext(Dispatchers.Default) { api.tasksInRange(from, to).filter { it.date != null } }
        val lo = from.toString()
        val hi = to.toString()
        _ranged.update { cur ->
            cur.filterValues { (it.date ?: "") < lo || (it.date ?: "") > hi } +
                fetched.associateBy { if (it.done) doneKey(it.id) else openKey(it.id) }
        }
    }

    @OptIn(FlowPreview::class)
    private fun startRangedPersistence() {
        // 先把上次存的读进来（读到之前已经有新数据的话，新数据优先）
        scope.launch(Dispatchers.IO) {
            val saved = runCatching { json.decodeFromString(RangedCache.serializer(), rangedFile.readText()) }.getOrNull()
            if (saved != null) {
                _ranged.update { cur -> saved.tasks.associateBy { keyOf(it) } + cur }
            }
        }
        // 之后每次变化（读到新月份、完成、改期……）稍等一下再写盘，别每次都写
        scope.launch(Dispatchers.IO) {
            _ranged.drop(1).debounce(1_500).collect { map ->
                val today = LocalDate.now()
                val lo = today.minusDays(200).toString()
                val hi = today.plusDays(400).toString()
                val keep = map.values.filter { (it.date ?: "") in lo..hi }
                runCatching { rangedFile.writeText(json.encodeToString(RangedCache.serializer(), RangedCache(keep))) }
            }
        }
    }

    init {
        startRangedPersistence()
        scope.launch(Dispatchers.IO) {
            val cache = runCatching { json.decodeFromString(TodoCache.serializer(), cacheFile.readText()) }.getOrNull()
            if (cache != null && _state.value.overview == null) {
                _state.update { it.copy(overview = cache.overview, updatedAt = cache.updatedAt) }
            }
        }
    }

    /** 取当前概览；内存里还没有就同步读一次本地缓存（小部件 / 通知在进程刚起来时用） */
    fun peek(): DidaOverview? {
        _state.value.overview?.let { return it }
        val cache = runCatching { json.decodeFromString(TodoCache.serializer(), cacheFile.readText()) }.getOrNull() ?: return null
        _state.update { if (it.overview == null) it.copy(overview = cache.overview, updatedAt = cache.updatedAt) else it }
        return _state.value.overview
    }

    /** 立即刷新并等待结束（后台任务用） */
    suspend fun refreshNow() {
        if (hasCredential()) doRefresh()
    }

    /** 数据超过 [staleMs] 没刷新就刷新；[force] 忽略新鲜度 */
    fun refresh(force: Boolean = false, staleMs: Long = 60_000L) {
        if (!hasCredential()) return
        val st = _state.value
        if (!force && st.overview != null && System.currentTimeMillis() - st.updatedAt < staleMs) return
        scope.launch { doRefresh() }
    }

    private suspend fun doRefresh() {
        if (!refreshLock.tryLock()) return
        try {
            _state.update { it.copy(loading = true) }
            try {
                val fetched = api.fetchOverview(LocalDate.now())
                val now = System.currentTimeMillis()
                val cleaned = stateLock.withLock {
                    recentlyDone.entries.removeAll { now - it.value > DONE_GRACE_MS }
                    recentlyDone.keys.fold(fetched) { acc, id -> acc.withoutTask(id) }
                }
                _state.update { TodoData(overview = cleaned, loading = false, error = null, updatedAt = now) }
                persist(cleaned, now)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val msg = if (e is McpAuthException) "滴答凭证无效或已失效，请到「连接与诊断」重新填写" else (e.message ?: "刷新失败")
                _state.update { it.copy(loading = false, error = msg) }
            }
        } finally {
            refreshLock.unlock()
        }
    }

    /** 完成任务（乐观更新）。失败时回滚并返回失败原因 */
    suspend fun complete(task: DidaTask): Result<Unit> {
        val before = _state.value.overview
        val rangedBefore = _ranged.value
        stateLock.withLock { recentlyDone[task.id] = System.currentTimeMillis() }
        mutate { o ->
            o.withoutTask(task.id).copy(done = listOf(task.copy(done = true, completedAt = System.currentTimeMillis())) + o.done)
        }
        if (task.date != null) {
            _ranged.update { it - openKey(task.id) + (doneKey(task.id) to task.copy(done = true, completedAt = System.currentTimeMillis())) }
        }
        return attempt { api.complete(task) }.onFailure {
            stateLock.withLock { recentlyDone.remove(task.id) }
            rollback(before)
            _ranged.value = rangedBefore
        }
    }

    /**
     * 某一天的任务（回顾过去用）：当天完成的 + 当天到期但没完成的。
     * 完成的任务没有计划时间时，用完成时刻当作它在时间轴上的位置。
     */
    suspend fun dayTasks(day: java.time.LocalDate): List<DidaTask> {
        val zone = java.time.ZoneId.systemDefault()
        val ds = day.toString()
        return api.tasksInRange(day, day).filter { t ->
            if (t.done) {
                t.completedAt?.let { java.time.Instant.ofEpochMilli(it).atZone(zone).toLocalDate() == day } ?: (t.date == ds)
            } else {
                t.date == ds
            }
        }.map { t ->
            val at = t.completedAt
            if (t.done && t.time == null && at != null) {
                val z = java.time.Instant.ofEpochMilli(at).atZone(zone)
                t.copy(time = "%02d:%02d".format(z.hour, z.minute))
            } else {
                t
            }
        }
    }

    /** 撤销刚才的完成 */
    suspend fun undoComplete(task: DidaTask): Result<Unit> {
        val before = _state.value.overview
        val rangedBefore = _ranged.value
        stateLock.withLock { recentlyDone.remove(task.id) }
        mutate { o -> insertOpen(o.copy(done = o.done.filterNot { it.id == task.id }), task.copy(done = false, completedAt = null)) }
        if (task.date != null) {
            _ranged.update { it - doneKey(task.id) + (openKey(task.id) to task.copy(done = false, completedAt = null)) }
        }
        return attempt { api.reopen(task) }.onFailure {
            rollback(before)
            _ranged.value = rangedBefore
        }
    }

    suspend fun reschedule(task: DidaTask, date: String, time: String?): Result<Unit> {
        val before = _state.value.overview
        val rangedBefore = _ranged.value
        mutate { o -> insertOpen(o.withoutTask(task.id), task.copy(date = date, time = time)) }
        _ranged.update { it - openKey(task.id) + (openKey(task.id) to task.copy(date = date, time = time, done = false)) }
        return attempt { api.reschedule(task, date, time) }.onFailure {
            rollback(before)
            _ranged.value = rangedBefore
        }
    }

    suspend fun setPriority(task: DidaTask, priority: Int): Result<Unit> {
        val before = _state.value.overview
        val rangedBefore = _ranged.value
        mutate { o -> replaceOpen(o, task.copy(priority = priority)) }
        patchRanged(task.copy(priority = priority))
        return attempt { api.setPriority(task, priority) }.onFailure {
            rollback(before)
            _ranged.value = rangedBefore
        }
    }

    /** 改标题（`!重要` / `!紧急` 标记就写在标题里） */
    suspend fun setTitle(task: DidaTask, title: String): Result<Unit> {
        val before = _state.value.overview
        val rangedBefore = _ranged.value
        mutate { o -> replaceOpen(o, task.copy(title = title)) }
        patchRanged(task.copy(title = title))
        return attempt { api.setTitle(task, title) }.onFailure {
            rollback(before)
            _ranged.value = rangedBefore
        }
    }

    /** 整体替换备注（语音「补充一下」会把新内容追加到原备注后面再整体写回） */
    suspend fun setContent(task: DidaTask, content: String): Result<Unit> {
        val before = _state.value.overview
        val rangedBefore = _ranged.value
        mutate { o -> replaceOpen(o, task.copy(content = content)) }
        patchRanged(task.copy(content = content))
        return attempt { api.setContent(task, content) }.onFailure {
            rollback(before)
            _ranged.value = rangedBefore
        }
    }

    /** 整体替换标签（「归入项目」就是给任务加项目标签） */
    suspend fun setTags(task: DidaTask, tags: List<String>): Result<Unit> {
        val before = _state.value.overview
        val rangedBefore = _ranged.value
        mutate { o -> replaceOpen(o, task.copy(tags = tags)) }
        patchRanged(task.copy(tags = tags))
        return attempt { api.setTags(task, tags) }.onFailure {
            rollback(before)
            _ranged.value = rangedBefore
        }
    }

    suspend fun delete(task: DidaTask): Result<Unit> {
        val before = _state.value.overview
        val rangedBefore = _ranged.value
        mutate { o -> o.withoutTask(task.id) }
        _ranged.update { it - openKey(task.id) - doneKey(task.id) }
        return attempt { api.deleteTask(task) }.onFailure {
            rollback(before)
            _ranged.value = rangedBefore
        }
    }

    /** 评论失败不影响主流程 */
    suspend fun comment(task: DidaTask, text: String): Boolean =
        attempt { api.addComment(task.projectId, task.id, text) }.isSuccess

    // ---- 本地状态变换 ----

    private suspend fun mutate(transform: (DidaOverview) -> DidaOverview) {
        var snapshot: DidaOverview? = null
        _state.update { st ->
            val o = st.overview ?: return@update st
            val next = transform(o)
            snapshot = next
            st.copy(overview = next)
        }
        snapshot?.let { persist(it, _state.value.updatedAt) }
    }

    private suspend fun rollback(before: DidaOverview?) {
        if (before == null) return
        _state.update { it.copy(overview = before) }
        persist(before, _state.value.updatedAt)
    }

    /** 把任务按日期放进逾期 / 近 7 天 / 无日期；超出 7 天的不在列表里显示 */
    private fun insertOpen(o: DidaOverview, task: DidaTask): DidaOverview {
        val today = LocalDate.now().toString()
        val limit = LocalDate.now().plusDays(7).toString()
        val d = task.date
        return when {
            d == null -> o.copy(undated = listOf(task) + o.undated)
            d < today -> o.copy(overdue = o.overdue + task)
            d <= limit -> o.copy(upcoming = o.upcoming + task)
            else -> o
        }
    }

    /** 日历缓存里同一个任务（未完成的那份）换成新内容 */
    private fun patchRanged(task: DidaTask) {
        _ranged.update { cur -> cur.mapValues { (_, v) -> if (v.id == task.id && !v.done) task else v } }
    }

    private fun replaceOpen(o: DidaOverview, task: DidaTask): DidaOverview {
        fun swap(list: List<DidaTask>) = list.map { if (it.id == task.id) task else it }
        return o.copy(overdue = swap(o.overdue), upcoming = swap(o.upcoming), undated = swap(o.undated))
    }

    private suspend fun persist(overview: DidaOverview, updatedAt: Long) = withContext(Dispatchers.IO) {
        runCatching { cacheFile.writeText(json.encodeToString(TodoCache.serializer(), TodoCache(overview, updatedAt))) }
    }

    private inline fun <T> attempt(block: () -> T): Result<T> = try {
        Result.success(block())
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        Result.failure(e)
    }

    private companion object {
        const val DONE_GRACE_MS = 2 * 60_000L
    }
}
