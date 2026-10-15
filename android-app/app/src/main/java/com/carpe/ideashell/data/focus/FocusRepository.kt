package com.carpe.ideashell.data.focus

import android.content.Context
import com.carpe.ideashell.data.dida.DaySummaryService
import com.carpe.ideashell.data.dida.DidaApi
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.dida.FocusSummary
import com.carpe.ideashell.system.FocusNotifier
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.time.LocalDate

/** 倒计时的种类：专注 / 短休息 / 长休息。休息不记入滴答，也不绑定任务 */
@Serializable
enum class FocusKind(val label: String, val defaultMin: Int) {
    FOCUS("专注", 25),
    SHORT_BREAK("短休息", 5),
    LONG_BREAK("长休息", 15),
    ;

    val isBreak: Boolean get() = this != FOCUS

    /** 圆盘上能选的最大分钟数：专注 120，休息 60 */
    val maxMin: Int get() = if (isBreak) 60 else 120
    val minMin: Int get() = if (isBreak) 1 else 5
}

/**
 * 正在进行的一次专注（倒计时）。起止用挂钟毫秒时间戳存盘，进程被杀、手机重启后也能接着算。
 * 暂停：记下暂停开始的时刻；继续时把这段加进 [pausedTotalMs]，所以「已专注」不含暂停的时间。
 */
@Serializable
data class FocusRun(
    val taskId: String? = null,
    val projectId: String? = null,
    val title: String = "",
    val startMs: Long,
    val plannedMin: Int,
    /** 暂停开始的时刻；null = 进行中 */
    val pausedAtMs: Long? = null,
    val pausedTotalMs: Long = 0L,
    val kind: FocusKind = FocusKind.FOCUS,
    /** 从项目页发起的专注：项目关键词。专注中的「记录」会写进这个项目的「里程碑与进展」 */
    val project: String? = null,
    /** 这一次专注中通过通知「记录」写下的内容（结束时拿来做反馈） */
    val records: List<String> = emptyList(),
) {
    val paused: Boolean get() = pausedAtMs != null
    val plannedMs: Long get() = plannedMin * 60_000L

    /** 已专注多久（不含暂停），最多不超过计划时长 */
    fun elapsedMs(now: Long): Long = ((pausedAtMs ?: now) - startMs - pausedTotalMs).coerceIn(0L, plannedMs)

    fun remainingMs(now: Long): Long = plannedMs - elapsedMs(now)

    /** 倒计时已走完（容许 1 秒误差：闹钟可能比预期早一点点醒） */
    fun isDue(now: Long): Boolean = !paused && remainingMs(now) <= 1_000L

    /** 进行中时，倒计时归零的挂钟时刻（暂停时没有意义） */
    val endAtMs: Long get() = startMs + pausedTotalMs + plannedMs
}

/** 已经结束、但还没成功写进滴答的一条记录（断网 / 接口失败时留在本机，之后自动重试） */
@Serializable
data class PendingFocus(val startMs: Long, val endMs: Long, val taskId: String?, val title: String)

sealed interface FocusResult {
    /** [synced] = false 表示已存在本机，等联网后自动同步到滴答 */
    data class Recorded(val minutes: Int, val synced: Boolean) : FocusResult

    /** 不足 1 分钟，不记录 */
    data object TooShort : FocusResult

    data object None : FocusResult
}

/**
 * 专注：在应用里倒计时，结束后用滴答 MCP 的 `create_focus` 写进滴答（手机 / 电脑 / 网页的滴答里都能看到）；
 * 同时用 `get_focuses_by_time` 把滴答里已有的专注（含在滴答 App 里计的）读回来显示。
 * 滴答 MCP 读不到「正在进行」的计时，所以不能镜像滴答里当前的计时。
 */
class FocusRepository(
    context: Context,
    private val api: DidaApi,
    private val daySummary: DaySummaryService,
    private val hasDida: () -> Boolean,
    val notifier: FocusNotifier,
    /** 从项目页发起的专注记录成功落盘时回调：（项目, 开始, 结束, 任务 id, 标题） */
    private val onProjectFocus: (String, Long, Long, String?, String) -> Unit = { _, _, _, _, _ -> },
    /** 专注结束时给用户的反馈（番茄完成 / 提前结束且有记录） */
    private val onCelebrate: (Celebration) -> Unit = {},
    /** 这段时间内快记的内容（摘要） */
    private val capturedBetween: suspend (Long, Long) -> List<String> = { _, _ -> emptyList() },
) {
    private val prefs = context.applicationContext.getSharedPreferences("focus", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }
    private val lock = Mutex()

    private val _session = MutableStateFlow(loadSession())
    val session: StateFlow<FocusRun?> = _session.asStateFlow()

    private val _pending = MutableStateFlow(loadPending())
    val pending: StateFlow<List<PendingFocus>> = _pending.asStateFlow()

    /** 滴答里近 7 天的专注（读回来的），没连接或还没读到为 null */
    private val _summary = MutableStateFlow<FocusSummary?>(null)
    val summary: StateFlow<FocusSummary?> = _summary.asStateFlow()

    /**
     * 番茄钟的节奏：专注 25 分钟 → 短休息 5 分钟；每完成 [CYCLE_LENGTH] 个番茄 → 长休息 15 分钟，然后重新计数。
     * 只有倒计时**自然走完**的专注才算一个番茄（中途结束的作废）；休息是在番茄走完后才出现的，所以这里记着「接下来该休息什么」。
     */
    private val _pendingBreak = MutableStateFlow(loadPendingBreak())
    val pendingBreak: StateFlow<FocusKind?> = _pendingBreak.asStateFlow()

    /** 当前这一轮已经完成的番茄数（0 until [CYCLE_LENGTH]；跨天自动清零） */
    private val _cycle = MutableStateFlow(loadCycle())
    val cycle: StateFlow<Int> = _cycle.asStateFlow()

    /** 最近一次成功写入滴答的时刻：今天页据此跳过缓存重新读专注 */
    private val _recordedAt = MutableStateFlow(0L)
    val recordedAt: StateFlow<Long> = _recordedAt.asStateFlow()

    /** 上次选的专注时长，下次打开直接用 */
    val lastMinutes: Int
        get() = lastMinutes(FocusKind.FOCUS)

    /** 每种倒计时各记一个上次选的时长（短休息 / 长休息默认 5 / 15 分钟） */
    fun lastMinutes(kind: FocusKind): Int =
        prefs.getInt(keyOf(kind), kind.defaultMin).coerceIn(kind.minMin, kind.maxMin)

    private fun keyOf(kind: FocusKind) = if (kind == FocusKind.FOCUS) KEY_LAST_MIN else "last_minutes_${kind.name}"

    // ───────────── 计时控制 ─────────────

    /** 开始一次专注；已经有一次在进行时返回 false */
    fun start(
        taskId: String?,
        projectId: String?,
        title: String,
        minutes: Int,
        kind: FocusKind = FocusKind.FOCUS,
        project: String? = null,
    ): Boolean {
        if (_session.value != null) return false
        // 没休息就直接开始下一个专注 = 跳过休息；跳过的是长休息，这一轮也就结束了
        if (!kind.isBreak) skipBreak() else clearPendingBreak()
        val m = minutes.coerceIn(kind.minMin, if (kind.isBreak) kind.maxMin else MAX_MINUTES)
        prefs.edit().putInt(keyOf(kind), m).apply()
        val isBreak = kind.isBreak
        setSession(
            FocusRun(
                taskId = if (isBreak) null else taskId,
                projectId = if (isBreak) null else projectId,
                title = if (isBreak) "" else title,
                startMs = System.currentTimeMillis(),
                plannedMin = m,
                kind = kind,
                project = if (isBreak) null else project,
            ),
        )
        return true
    }

    /** 专注进行中补关联任务 / 项目（休息时不关联）；结束时按这里的最终选择记录 */
    fun attach(taskId: String?, projectId: String?, title: String, project: String?) {
        val s = _session.value ?: return
        if (s.kind.isBreak) return
        setSession(s.copy(taskId = taskId, projectId = projectId, title = title, project = project))
    }

    fun pause() {
        val s = _session.value ?: return
        if (s.paused) return
        setSession(s.copy(pausedAtMs = System.currentTimeMillis()))
    }

    fun resume() {
        val s = _session.value ?: return
        val at = s.pausedAtMs ?: return
        setSession(s.copy(pausedAtMs = null, pausedTotalMs = s.pausedTotalMs + (System.currentTimeMillis() - at)))
    }

    /** 放弃：不记录 */
    fun discard() = setSession(null)

    /** 专注中记下一条（通知「记录」保存成功后调用），结束时在反馈里展示 */
    fun addRecord(text: String) {
        val s = _session.value ?: return
        if (s.kind.isBreak || text.isBlank()) return
        setSession(s.copy(records = s.records + text.trim()))
    }

    /**
     * 结束并记录。倒计时走完或「提前结束」都走这里：按实际专注的时长记，不足 1 分钟不记。
     * 先落盘再上传：上传失败时记录留在本机，不会丢。
     */
    suspend fun finish(): FocusResult {
        val outcome: FocusResult = lock.withLock {
            val s = _session.value ?: return@withLock FocusResult.None
            val now = System.currentTimeMillis()
            val elapsed = s.elapsedMs(now)
            val completed = s.isDue(now)
            if (s.kind.isBreak) {
                // 休息不记录；长休息过完这一轮结束。只在自然走完时提醒一下
                clearPendingBreak()
                if (s.kind == FocusKind.LONG_BREAK) saveCycle(0)
                setSession(null)
                if (completed) notifier.showBreakDone(s.kind, s.plannedMin)
                return@withLock FocusResult.None
            }
            // 番茄走完了才算数；先更新「接下来休息什么」，再结束会话（通知 / 小部件跟着会话刷新时就能看到）
            if (completed) onPomodoroCompleted()
            setSession(null)
            if (elapsed < MIN_RECORD_MS) return@withLock FocusResult.TooShort
            val record = PendingFocus(s.startMs, s.startMs + elapsed, s.taskId, s.title)
            s.project?.let { onProjectFocus(it, record.startMs, record.endMs, s.taskId, if (s.taskId.isNullOrBlank()) "" else s.title) }
            _pending.value = _pending.value + record
            savePending()
            flushLocked()
            val minutes = Math.round(elapsed / 60_000.0).toInt().coerceAtLeast(1)
            val synced = record !in _pending.value
            val next = if (completed) _pendingBreak.value else null
            val captured = runCatching { capturedBetween(s.startMs, System.currentTimeMillis()) }.getOrDefault(emptyList())
            val entries = s.records.map { Celebration.Entry("专注记录", it) } + captured.map { Celebration.Entry("快记", it) }
            notifier.showDone(s.title, minutes, completed, synced, next, next?.let { lastMinutes(it) } ?: 0, entries.map { it.text })
            if (completed || entries.isNotEmpty()) {
                val stats = buildList {
                    add("$minutes 分钟")
                    if (completed) add(if (_cycle.value > 0) "本轮第 ${_cycle.value} 个番茄" else "番茄完成")
                    if (entries.isNotEmpty()) add("${entries.size} 条记录")
                }
                onCelebrate(
                    Celebration(
                        kind = Celebration.Kind.POMODORO,
                        title = com.carpe.ideashell.core.parse.TodoMeta.cleanTitle(s.title).ifBlank { s.title },
                        headline = if (completed) "番茄完成" else "专注已记录",
                        message = Cheer.pomodoro(entries.isNotEmpty(), completed),
                        stats = stats,
                        records = entries,
                    ),
                )
            }
            FocusResult.Recorded(minutes, synced)
        }
        if (outcome is FocusResult.Recorded) refresh()
        return outcome
    }

    /**
     * 对账：倒计时到点了就结束并记录（闹钟、打开应用时都会调用），再把之前没传成功的记录补传。
     * 随时可以调用，没有要做的事时几乎没有开销。
     */
    suspend fun settle() {
        val s = _session.value
        if (s != null && s.isDue(System.currentTimeMillis())) {
            finish()
        } else if (_pending.value.isNotEmpty()) {
            val before = _pending.value.size
            lock.withLock { flushLocked() }
            if (_pending.value.size < before) refresh()
        }
    }

    /** 每分钟的心跳：约好下一次（通知圆环与小部件的进度弧靠它前进） */
    fun tick() {
        val s = _session.value ?: return
        notifier.scheduleTick(s)
    }

    /** 一个番茄走完：计数 +1，该短休息还是长休息 */
    private fun onPomodoroCompleted() {
        val n = _cycle.value + 1
        if (n >= CYCLE_LENGTH) {
            saveCycle(CYCLE_LENGTH)
            setPendingBreak(FocusKind.LONG_BREAK)
        } else {
            saveCycle(n)
            setPendingBreak(FocusKind.SHORT_BREAK)
        }
    }

    /** 不休息了：回到专注。跳过的是长休息，这一轮就从头开始 */
    fun skipBreak() {
        if (_pendingBreak.value == FocusKind.LONG_BREAK) saveCycle(0)
        clearPendingBreak()
    }

    private fun clearPendingBreak() = setPendingBreak(null)

    private fun setPendingBreak(k: FocusKind?) {
        _pendingBreak.value = k
        prefs.edit().apply { if (k == null) remove(KEY_BREAK) else putString(KEY_BREAK, k.name) }.apply()
    }

    private fun saveCycle(n: Int) {
        _cycle.value = n
        prefs.edit().putInt(KEY_CYCLE, n).putString(KEY_CYCLE_DAY, LocalDate.now().toString()).apply()
    }

    private fun loadPendingBreak(): FocusKind? = prefs.getString(KEY_BREAK, null)
        ?.let { n -> FocusKind.entries.firstOrNull { it.name == n && it.isBreak } }

    private fun loadCycle(): Int =
        if (prefs.getString(KEY_CYCLE_DAY, null) == LocalDate.now().toString()) prefs.getInt(KEY_CYCLE, 0).coerceIn(0, CYCLE_LENGTH) else 0

    /** 记录内容已写入后刷新常驻通知（顺便把「输入中」的转圈停掉）；[hint] 会临时显示在通知正文里，下一次心跳恢复 */
    fun refreshNotification(hint: String?) {
        notifier.onSessionChanged(_session.value, hint)
    }

    /** 重启后让通知和闹钟与存盘的状态一致（应用启动时调用一次） */
    fun restore() = notifier.onSessionChanged(_session.value)

    // ───────────── 滴答里的专注（读回来） ─────────────

    suspend fun refresh() {
        if (!hasDida()) {
            _summary.value = null
            return
        }
        runCatching { daySummary.focus(LocalDate.now()) }.onSuccess { _summary.value = it }
    }

    /**
     * 在滴答里新建一个今天的待办（专注页「这次专注做什么」里直接加）。没连接滴答返回 null；
     * 接口返回里解析不出新任务时也返回 null，由调用方刷新列表后按标题去找。失败抛异常。
     */
    suspend fun addTask(title: String): DidaTask? {
        val t = title.trim()
        if (t.isEmpty() || !hasDida()) return null
        return api.createTask(t, LocalDate.now().toString(), null)
    }

    // ───────────── 内部 ─────────────

    private fun setSession(run: FocusRun?) {
        _session.value = run
        prefs.edit().apply {
            if (run == null) remove(KEY_SESSION) else putString(KEY_SESSION, json.encodeToString(FocusRun.serializer(), run))
        }.apply()
        notifier.onSessionChanged(run)
    }

    /** 按顺序补传；碰到一条失败就停（多半是断网，别连着失败） */
    private suspend fun flushLocked() {
        if (!hasDida()) return
        var any = false
        for (p in _pending.value) {
            val ok = try {
                api.createFocus(p.startMs, p.endMs, p.taskId)
                true
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                false
            }
            if (!ok) break
            _pending.value = _pending.value - p
            savePending()
            any = true
        }
        if (any) _recordedAt.value = System.currentTimeMillis()
    }

    private fun savePending() {
        prefs.edit().putString(KEY_PENDING, json.encodeToString(ListSerializer(PendingFocus.serializer()), _pending.value)).apply()
    }

    private fun loadSession(): FocusRun? = runCatching {
        prefs.getString(KEY_SESSION, null)?.let { json.decodeFromString(FocusRun.serializer(), it) }
    }.getOrNull()

    private fun loadPending(): List<PendingFocus> = runCatching {
        prefs.getString(KEY_PENDING, null)?.let { json.decodeFromString(ListSerializer(PendingFocus.serializer()), it) }
    }.getOrNull().orEmpty()

    companion object {
        const val MIN_MINUTES = 5

        const val MAX_MINUTES = 180
        const val DEFAULT_MINUTES = 25
        val CHOICES = listOf(15, 25, 45, 60, 90)
        private const val MIN_RECORD_MS = 60_000L
        private const val KEY_SESSION = "session"
        private const val KEY_PENDING = "pending"
        private const val KEY_LAST_MIN = "last_minutes"
        private const val KEY_BREAK = "pending_break"
        private const val KEY_CYCLE = "cycle"
        private const val KEY_CYCLE_DAY = "cycle_day"

        /** 每完成这么多个番茄，安排一次长休息 */
        const val CYCLE_LENGTH = 4
    }
}
