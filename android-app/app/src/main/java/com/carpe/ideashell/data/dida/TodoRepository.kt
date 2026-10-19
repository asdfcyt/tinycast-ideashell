package com.carpe.ideashell.data.dida

import com.carpe.ideashell.data.mcp.McpAuthException
import com.carpe.ideashell.data.mcp.McpHttpException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import java.io.IOException
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
 * 再提交滴答。提交失败时分两种：
 * - 断网 / 超时 / 服务端暂时出错：保留界面上的改动，把操作记进本机队列（[PendingTodoQueue]），联网后自动提交；
 * - 凭证失效 / 服务端明确拒绝：回滚并把原因抛给界面。
 */
class TodoRepository(
    private val api: DidaApi,
    private val cacheFile: File,
    private val scope: CoroutineScope,
    private val hasCredential: () -> Boolean,
    /** 离线操作队列的存盘文件 */
    pendingFile: File = File(cacheFile.parentFile, "todo_pending.json"),
    /** 有操作进了离线队列：安排一次「有网就提交」的后台任务（进程被杀后也能提交） */
    private val onQueued: () -> Unit = {},
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val _state = MutableStateFlow(TodoData())
    val state: StateFlow<TodoData> = _state.asStateFlow()

    private val refreshLock = Mutex()
    private val stateLock = Mutex()

    // ---- 离线操作队列 ----
    private val pendingStore = PendingTodoStore(pendingFile, json)
    private val queueLock = Mutex()
    private val flushLock = Mutex()
    private val pending = ArrayList(pendingStore.load())

    /** 正在提交的那一条（合并新操作时不能动它，否则「已发出去」的操作会被当成「还没发」抵消掉） */
    private var inFlight: PendingTodoOp? = null

    /** 刚提交成功的操作：刷新结果里可能还是旧数据，一小段时间内继续把它盖上去 */
    private val recentlyFlushed = ArrayList<Pair<PendingTodoOp, Long>>()

    private val _pendingCount = MutableStateFlow(pending.size)

    /** 还没提交到滴答的操作条数（界面提示「N 项修改联网后同步」） */
    val pendingCount: StateFlow<Int> = _pendingCount.asStateFlow()

    private val _syncNotice = MutableStateFlow<String?>(null)

    /** 离线操作提交时被服务端拒绝（任务已被删等）的说明；一会儿自动消失 */
    val syncNotice: StateFlow<String?> = _syncNotice.asStateFlow()

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
                // 先把离线时记下的操作提交了，再读最新的，免得读到的是「还没改」的旧数据
                flushPending()
                val fetched = api.fetchOverview(LocalDate.now())
                val now = System.currentTimeMillis()
                val withoutDone = stateLock.withLock {
                    recentlyDone.entries.removeAll { now - it.value > DONE_GRACE_MS }
                    recentlyDone.keys.fold(fetched) { acc, id -> acc.withoutTask(id) }
                }
                // 仍在队列里的（和刚提交、服务端可能还没反映的）操作，盖在读到的数据上，界面上的改动不会「弹回去」
                val cleaned = applyOps(withoutDone, queuedOps(now))
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
        return submit(PendingTodoOp(PendingKind.COMPLETE, task.id, task.projectId)) { api.complete(task) }.onFailure {
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
        return submit(PendingTodoOp(PendingKind.REOPEN, task.id, task.projectId)) { api.reopen(task) }.onFailure {
            rollback(before)
            _ranged.value = rangedBefore
        }
    }

    suspend fun reschedule(task: DidaTask, date: String, time: String?): Result<Unit> {
        val before = _state.value.overview
        val rangedBefore = _ranged.value
        mutate { o -> insertOpen(o.withoutTask(task.id), task.copy(date = date, time = time)) }
        _ranged.update { it - openKey(task.id) + (openKey(task.id) to task.copy(date = date, time = time, done = false)) }
        return submit(PendingTodoOp(PendingKind.RESCHEDULE, task.id, task.projectId, date = date, time = time)) { api.reschedule(task, date, time) }.onFailure {
            rollback(before)
            _ranged.value = rangedBefore
        }
    }

    suspend fun setPriority(task: DidaTask, priority: Int): Result<Unit> {
        val before = _state.value.overview
        val rangedBefore = _ranged.value
        mutate { o -> replaceOpen(o, task.copy(priority = priority)) }
        patchRanged(task.copy(priority = priority))
        return submit(PendingTodoOp(PendingKind.PRIORITY, task.id, task.projectId, priority = priority)) { api.setPriority(task, priority) }.onFailure {
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
        return submit(PendingTodoOp(PendingKind.TITLE, task.id, task.projectId, text = title)) { api.setTitle(task, title) }.onFailure {
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
        return submit(PendingTodoOp(PendingKind.CONTENT, task.id, task.projectId, text = content)) { api.setContent(task, content) }.onFailure {
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
        return submit(PendingTodoOp(PendingKind.TAGS, task.id, task.projectId, tags = tags)) { api.setTags(task, tags) }.onFailure {
            rollback(before)
            _ranged.value = rangedBefore
        }
    }

    suspend fun delete(task: DidaTask): Result<Unit> {
        val before = _state.value.overview
        val rangedBefore = _ranged.value
        mutate { o -> o.withoutTask(task.id) }
        _ranged.update { it - openKey(task.id) - doneKey(task.id) }
        return submit(PendingTodoOp(PendingKind.DELETE, task.id, task.projectId)) { api.deleteTask(task) }.onFailure {
            rollback(before)
            _ranged.value = rangedBefore
        }
    }

    /** 评论失败不影响主流程 */
    suspend fun comment(task: DidaTask, text: String): Boolean =
        attempt { api.addComment(task.projectId, task.id, text) }.isSuccess

    // ---- 离线操作队列 ----

    /** 断网 / 超时 / 服务端暂时出错：值得稍后重试；凭证失效和服务端明确拒绝不算 */
    private fun isRetryable(e: Throwable): Boolean = when (e) {
        is IOException -> true
        is McpHttpException -> e.httpCode >= 500 || e.httpCode == 429 || e.httpCode == 408
        else -> false
    }

    /**
     * 提交一次操作。前面已经有排着队的操作时，这一条也排在后面（保证先后顺序）并顺手试着提交；
     * 否则直接提交，遇到断网类错误就记进队列、对界面报成功（界面上的改动保留）。
     */
    private suspend fun submit(op: PendingTodoOp, call: suspend () -> Unit): Result<Unit> {
        if (queueLock.withLock { pending.isNotEmpty() }) {
            enqueue(op)
            scope.launch { flushPending() }
            return Result.success(Unit)
        }
        val result = attempt { call() }
        val error = result.exceptionOrNull() ?: return result
        if (!isRetryable(error)) return result
        enqueue(op)
        return Result.success(Unit)
    }

    private suspend fun enqueue(op: PendingTodoOp) {
        queueLock.withLock {
            val head = inFlight?.takeIf { f -> pending.any { it === f } }
            val candidates = pending.filter { it !== head }
            val merged = PendingTodoQueue.merge(candidates, op)
            pending.clear()
            if (head != null) pending.add(head)
            pending.addAll(merged)
            pendingStore.save(pending)
            _pendingCount.value = pending.size
        }
        onQueued()
    }

    private suspend fun send(op: PendingTodoOp) {
        val stub = op.stub()
        when (op.kind) {
            PendingKind.COMPLETE -> api.complete(stub)
            PendingKind.REOPEN -> api.reopen(stub)
            PendingKind.RESCHEDULE -> api.reschedule(stub, op.date ?: LocalDate.now().toString(), op.time)
            PendingKind.PRIORITY -> api.setPriority(stub, op.priority)
            PendingKind.TITLE -> api.setTitle(stub, op.text.orEmpty())
            PendingKind.CONTENT -> api.setContent(stub, op.text.orEmpty())
            PendingKind.TAGS -> api.setTags(stub, op.tags)
            PendingKind.DELETE -> api.deleteTask(stub)
        }
    }

    /**
     * 把队列里的操作按顺序提交给滴答。断网 / 凭证失效时停下，留着下次再来；
     * 被服务端明确拒绝的（任务已被删等）丢掉并提示。返回队列是否已经清空。
     */
    suspend fun flushPending(): Boolean {
        if (!hasCredential()) return queueLock.withLock { pending.isEmpty() }
        if (queueLock.withLock { pending.isEmpty() }) return true
        var dropped = 0
        var lastReason: String? = null
        flushLock.withLock {
            while (true) {
                val op = queueLock.withLock { pending.firstOrNull()?.also { inFlight = it } } ?: break
                val error = attempt { send(op) }.exceptionOrNull()
                val gone = op.kind == PendingKind.DELETE && error is McpHttpException && error.httpCode == 404
                val stop = error != null && !gone && (isRetryable(error) || error is McpAuthException)
                queueLock.withLock {
                    inFlight = null
                    if (!stop) {
                        pending.removeAll { it === op }
                        pendingStore.save(pending)
                        _pendingCount.value = pending.size
                    }
                }
                when {
                    error == null || gone -> synchronized(recentlyFlushed) { recentlyFlushed += op to System.currentTimeMillis() }
                    stop -> break
                    else -> {
                        dropped++
                        lastReason = error.message
                    }
                }
            }
        }
        if (dropped > 0) {
            _syncNotice.value = "有 $dropped 项离线时的修改没能同步到滴答" + (lastReason?.let { "：$it" } ?: "") + "，已按滴答里的最新状态为准"
            scope.launch {
                delay(20_000L)
                _syncNotice.value = null
            }
            scope.launch { doRefresh() }
        }
        return queueLock.withLock { pending.isEmpty() }
    }

    /** 还在队列里的操作 + 刚提交成功、服务端数据可能还没反映的操作（按先后顺序） */
    private suspend fun queuedOps(now: Long): List<PendingTodoOp> {
        val recent = synchronized(recentlyFlushed) {
            recentlyFlushed.removeAll { now - it.second > DONE_GRACE_MS }
            recentlyFlushed.map { it.first }
        }
        return recent + queueLock.withLock { pending.toList() }
    }

    /** 把操作的效果盖到一份读来的概览上 */
    private fun applyOps(base: DidaOverview, ops: List<PendingTodoOp>): DidaOverview {
        if (ops.isEmpty()) return base
        fun open(o: DidaOverview, id: String) = (o.overdue + o.upcoming + o.undated).firstOrNull { it.id == id }
        return ops.fold(base) { o, op ->
            when (op.kind) {
                PendingKind.COMPLETE -> open(o, op.taskId)?.let { t ->
                    o.withoutTask(t.id).copy(done = listOf(t.copy(done = true, completedAt = op.at)) + o.done)
                } ?: o
                PendingKind.REOPEN -> o.done.firstOrNull { it.id == op.taskId }?.let { t ->
                    insertOpen(o.copy(done = o.done.filterNot { it.id == t.id }), t.copy(done = false, completedAt = null))
                } ?: o
                PendingKind.DELETE -> o.withoutTask(op.taskId)
                PendingKind.RESCHEDULE -> open(o, op.taskId)?.let { t ->
                    insertOpen(o.withoutTask(t.id), t.copy(date = op.date, time = op.time))
                } ?: o
                PendingKind.PRIORITY -> open(o, op.taskId)?.let { replaceOpen(o, it.copy(priority = op.priority)) } ?: o
                PendingKind.TITLE -> open(o, op.taskId)?.let { replaceOpen(o, it.copy(title = op.text.orEmpty())) } ?: o
                PendingKind.CONTENT -> open(o, op.taskId)?.let { replaceOpen(o, it.copy(content = op.text.orEmpty())) } ?: o
                PendingKind.TAGS -> open(o, op.taskId)?.let { replaceOpen(o, it.copy(tags = op.tags)) } ?: o
            }
        }
    }

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
