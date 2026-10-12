package com.carpe.ideashell.ui.review

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.Companion.APPLICATION_KEY
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.carpe.ideashell.AppContainer
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.core.parse.TimeRange
import com.carpe.ideashell.core.parse.TimeRanges
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.dida.FocusSummary
import com.carpe.ideashell.data.dida.HabitStat
import com.carpe.ideashell.data.dida.TodoData
import com.carpe.ideashell.data.mcp.McpAuthException
import com.carpe.ideashell.data.project.Workspace
import com.carpe.ideashell.domain.Insights
import com.carpe.ideashell.domain.ProjectFlow
import com.carpe.ideashell.domain.Timeline
import com.carpe.ideashell.domain.TimelineData
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate

/** 一块异步数据的状态：加载中仍可显示旧数据（先显示后刷新） */
data class Async<T>(
    val loading: Boolean = false,
    val data: T? = null,
    val error: String? = null,
)

/** 时间河的快捷范围，文字交给 [TimeRanges.parse]，规则与桌面一致 */
enum class RangePreset(val label: String, val text: String) {
    TODAY("今天", "今天"),
    YESTERDAY("昨天", "昨天"),
    LAST7("最近 7 天", ""),
    THIS_WEEK("本周", "本周"),
    LAST_WEEK("上周", "上周"),
    THIS_MONTH("本月", "本月"),
    LAST_MONTH("上月", "上月"),
    ;

    fun range(): TimeRange = TimeRanges.parse(text) ?: TimeRanges.lastDays(7)
}

/**
 * 回顾：一条按时间戳排开的河——笔记、完成的待办、Daily Note 里的每一条日记混在一起，
 * 顶部是这段时间「时间去哪了」（按项目拆分）。数据都在这里，切走页签再回来不会丢。
 */
class ReviewViewModel(private val container: AppContainer) : ViewModel() {
    private val repo = container.notes

    val connected: StateFlow<Boolean> = container.credentials.ideashellConnected
    val workspace: StateFlow<Workspace> = container.projects.workspace

    /** 列表滚动位置放在这里：进笔记全文页再返回，界面会重建，位置仍在 */
    val listState = LazyListState()

    var preset by mutableStateOf<RangePreset?>(RangePreset.LAST7)
        private set
    var range by mutableStateOf(RangePreset.LAST7.range())
        private set

    /** 滴答的清单名（任务详情里显示「属于哪个清单」） */
    val todoData: StateFlow<TodoData> = container.todos.state

    private val _timeline = MutableStateFlow(Async<TimelineData>())
    val timeline: StateFlow<Async<TimelineData>> = _timeline.asStateFlow()
    private var timelineJob: Job? = null

    private val _flow = MutableStateFlow(ProjectFlow.Empty)
    val flow: StateFlow<ProjectFlow> = _flow.asStateFlow()
    private var flowJob: Job? = null

    /** 这段范围里的专注记录（含每一次的起止），专注趋势 / 时间线 / 最佳时段由它算出；没连滴答或读不到为 null */
    private val _focus = MutableStateFlow<FocusSummary?>(null)
    val focus: StateFlow<FocusSummary?> = _focus.asStateFlow()

    /** 窗口内每个习惯的打卡情况；没连滴答 / 没有习惯 / 读不到为 null */
    private val _habits = MutableStateFlow<List<HabitStat>?>(null)
    val habits: StateFlow<List<HabitStat>?> = _habits.asStateFlow()

    /**
     * 洞察卡的数据：时间线 / 专注 / 习惯任何一个变了，就在后台线程重算一次。
     * 以前是在组合里 remember 现算，每次切进回顾页都要在主线程重算，是切页卡顿的来源之一。
     */
    val insights: StateFlow<Insights> = combine(
        _timeline.map { it.data }.distinctUntilChanged(),
        _focus,
        _habits,
    ) { data, focus, habits -> Insights.build(data, focus, habits) }
        .flowOn(Dispatchers.Default)
        .stateIn(viewModelScope, SharingStarted.Eagerly, Insights.Empty)

    /** 每个时间范围上一次读到的结果（仅内存）：切回顾过的范围、再次进页面时先显示它，数据够新就不再请求 */
    private class Snapshot(
        var data: TimelineData? = null,
        var flow: ProjectFlow = ProjectFlow.Empty,
        var focus: FocusSummary? = null,
        var habits: List<HabitStat>? = null,
        var at: Long = 0L,
    )

    private val snapshots = HashMap<String, Snapshot>()

    private fun snapshotOf(r: TimeRange): Snapshot =
        snapshots.getOrPut("${r.start}|${r.endExclusive}") { Snapshot() }

    // ───────────── 哪几天展开 ─────────────

    /** 用户手动展开 / 收起过的日子；没动过的按默认：只有今天、昨天展开，前天及更早的收起 */
    private val dayOpen = mutableStateMapOf<LocalDate, Boolean>()

    fun isDayOpen(date: LocalDate, today: LocalDate = LocalDate.now()): Boolean =
        dayOpen[date] ?: !date.isBefore(today.minusDays(1))

    fun toggleDay(date: LocalDate, today: LocalDate = LocalDate.now()) {
        dayOpen[date] = !isDayOpen(date, today)
    }

    // ───────────── 河里的待办：点开详情、勾选、改期…… ─────────────

    private val _messages = Channel<String>(Channel.BUFFERED)

    /** 操作结果的提示（失败原因、已完成等），界面用 Snackbar 显示 */
    val messages = _messages.receiveAsFlow()

    private fun say(text: String) {
        _messages.trySend(text)
    }

    /** 正在看详情的待办 id；任务在时间线里找不到了（例如刚删除）就自然收起 */
    var selectedTodoId by mutableStateOf<String?>(null)
        private set

    fun openTodo(id: String?) {
        selectedTodoId = id
    }

    fun selectedTodo(data: TimelineData?): DidaTask? {
        val id = selectedTodoId ?: return null
        return data?.days?.firstNotNullOfOrNull { d -> d.todos.firstOrNull { it.id == id } }
    }

    /** 先在界面上改（乐观更新），再请求滴答，最后悄悄重读一遍时间线对齐（失败时也靠它回滚） */
    private fun todoOp(
        task: DidaTask,
        failText: String,
        patch: ((DidaTask) -> DidaTask?)?,
        onOk: suspend () -> Unit = {},
        op: suspend () -> Result<Unit>,
    ) {
        if (patch != null) patchTodo(task.id, patch)
        viewModelScope.launch {
            op().onSuccess { onOk() }.onFailure { say("$failText：${it.message ?: "网络异常"}") }
            loadTimeline(quiet = true)
        }
    }

    private fun patchTodo(id: String, transform: (DidaTask) -> DidaTask?) {
        _timeline.update { st ->
            val d = st.data ?: return@update st
            val days = d.days.map { day ->
                if (day.todos.none { it.id == id }) day
                else day.copy(todos = day.todos.mapNotNull { if (it.id == id) transform(it) else it })
            }
            val todos = days.flatMap { it.todos }
            st.copy(data = d.copy(days = days, todoDone = todos.count { it.done }, todoTotal = todos.size))
        }
    }

    /** 点节点：没做完就完成，做完了就恢复 */
    fun toggleTodo(task: DidaTask) {
        if (task.done) {
            todoOp(task, "撤销失败", { it.copy(done = false, completedAt = null) }) { container.todos.undoComplete(task) }
        } else {
            todoOp(
                task, "完成失败",
                { it.copy(done = true, completedAt = System.currentTimeMillis()) },
                onOk = {
                    say("已完成")
                    // 属于项目的任务完成后，自动在项目主页「里程碑与进展」记一行（进程级作用域，界面离开也要跑完）
                    container.appScope.launch { runCatching { container.projects.afterComplete(task, "") } }
                },
            ) { container.todos.complete(task) }
        }
    }

    fun completeTodoWithReview(task: DidaTask, review: String) {
        todoOp(
            task, "完成失败",
            { it.copy(done = true, completedAt = System.currentTimeMillis()) },
            onOk = {
                say(
                    try {
                        container.projects.afterComplete(task, review)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        "已完成，但复盘没有保存：${e.message ?: "网络异常"}"
                    },
                )
            },
        ) { container.todos.complete(task) }
    }

    fun rescheduleTodo(task: DidaTask, date: String, time: String?) =
        todoOp(task, "改期失败", { it.copy(date = date, time = time) }) { container.todos.reschedule(task, date, time) }

    fun setTodoPriority(task: DidaTask, priority: Int) =
        todoOp(task, "修改优先级失败", { it.copy(priority = priority) }) { container.todos.setPriority(task, priority) }

    fun toggleTodoMark(task: DidaTask, mark: TodoMeta.Mark) = renameTodo(task, TodoMeta.toggleMark(task.title, mark))

    fun renameTodo(task: DidaTask, title: String) {
        val clean = title.trim()
        if (clean.isEmpty() || clean == task.title) return
        todoOp(task, "修改标题失败", { it.copy(title = clean) }) { container.todos.setTitle(task, clean) }
    }

    fun assignTodoProject(task: DidaTask, keyword: String) {
        if (task.tags.any { it.equals(keyword, ignoreCase = true) }) return
        val tags = task.tags + keyword
        todoOp(task, "归入项目失败", { it.copy(tags = tags) }, onOk = { say("已归入「$keyword」") }) {
            container.todos.setTags(task, tags)
        }
    }

    fun deleteTodo(task: DidaTask) =
        todoOp(task, "删除失败", { null }, onOk = { say("已删除") }) { container.todos.delete(task) }

    fun createTodoNote(task: DidaTask, deliverable: String, purpose: String, steps: String) {
        viewModelScope.launch {
            try {
                container.projects.createTaskNote(task, deliverable, purpose, steps)
                say("已创建任务笔记")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                say("创建任务笔记失败：${e.message ?: "网络异常"}")
            }
        }
    }

    fun addTodoProgress(task: DidaTask, noteId: String, text: String) {
        viewModelScope.launch {
            try {
                val synced = container.projects.addProgress(noteId, text, task)
                say(if (synced) "已记入任务笔记，并同步到滴答评论" else "已记入任务笔记")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                say("保存失败：${e.message ?: "网络异常"}")
            }
        }
    }

    /**
     * 进页面时：还没有数据就拉一次；有数据但已经放了一阵（[STALE_MS]）就在后台悄悄刷新，
     * 刷新期间照常显示旧的，不出现空白；否则保持（下拉刷新才强制重读）。
     */
    fun ensureLoaded() {
        if (!connected.value) return
        val st = _timeline.value
        if (st.loading) return
        if (st.data == null) {
            loadTimeline()
        } else if (System.currentTimeMillis() - snapshotOf(range).at > STALE_MS) {
            loadTimeline()
        }
    }

    fun refresh() = loadTimeline()

    fun selectPreset(p: RangePreset) {
        preset = p
        range = p.range()
        loadTimeline(clear = true)
    }

    fun selectCustom(from: LocalDate, toInclusive: LocalDate) {
        preset = null
        range = TimeRanges.custom(from, toInclusive)
        loadTimeline(clear = true)
    }

    /**
     * [clear]：换了范围。看过的范围先把上次的整套结果摆出来，够新（[FRESH_MS]）就不再请求；没看过才清空等加载。
     * [quiet]：待办操作后的对齐重读，不动时间分配和专注（它们不受影响，也不值得再请求一遍）。
     */
    private fun loadTimeline(clear: Boolean = false, quiet: Boolean = false) {
        timelineJob?.cancel()
        if (!quiet) flowJob?.cancel()
        val target = range
        val snap = snapshotOf(target)
        val cached = snap.data
        if (clear) {
            if (cached != null) {
                _timeline.value = Async(data = cached)
                _flow.value = snap.flow
                _focus.value = snap.focus
                _habits.value = snap.habits
                if (System.currentTimeMillis() - snap.at < FRESH_MS) return
                _timeline.update { it.copy(loading = true) }
            } else {
                _timeline.value = Async(loading = true)
                _flow.value = ProjectFlow.Empty
                _focus.value = null
                _habits.value = null
            }
        } else {
            _timeline.update { it.copy(loading = true, error = null) }
        }
        timelineJob = viewModelScope.launch {
            try {
                // 拉取之外的解析 / 拼装也不占主线程
                val data = withContext(Dispatchers.Default) { repo.timeline(target) }
                snap.data = data
                snap.at = System.currentTimeMillis()
                _timeline.value = Async(data = data)
                if (!quiet) loadFlow(data, snap)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _timeline.update { it.copy(loading = false, error = friendly(e)) }
            }
        }
    }

    /**
     * 「时间去哪了」：专注记录按项目拆分。专注读不到（没连接滴答 / 请求失败）就只按记录条数拆，不影响河本身。
     * 项目统计（距上次提及多少天）用已经算好的，没有就不显示「没记」提醒。
     * 专注与习惯并行读；读失败时保留上一次的结果，不把已有的卡片闪没。
     */
    private fun loadFlow(data: TimelineData, snap: Snapshot) {
        flowJob?.cancel()
        suspend fun build(focus: FocusSummary?): ProjectFlow = withContext(Dispatchers.Default) {
            val projects = container.projects.projects
            if (projects.isEmpty()) ProjectFlow.Empty
            else ProjectFlow.build(projects, data, focus, container.projects.stats.value)
        }
        val hasDida = !container.credentials.didaToken.isNullOrBlank()
        flowJob = viewModelScope.launch {
            // 先用现有数据画一版（专注沿用上次的，没有就空），专注读回来再替换
            build(snap.focus).also { _flow.value = it; snap.flow = it }
            if (!hasDida) {
                _focus.value = null
                _habits.value = null
                snap.focus = null
                snap.habits = null
                return@launch
            }
            coroutineScope {
                // 习惯打卡：窗口与洞察卡一致（到今天为止最近最多 14 天）；读不到就保持原样
                launch {
                    val anchor = minOf(LocalDate.now(), data.range.last)
                    val from = maxOf(data.range.start, anchor.minusDays(13))
                    try {
                        container.habits.statsIn(from, anchor).also { _habits.value = it; snap.habits = it }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Exception) {
                    }
                }
                val focus = try {
                    container.daySummary.focusIn(data.range.start, data.range.endExclusive)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    null
                }
                if (focus != null) {
                    snap.focus = focus
                    _focus.value = focus
                    build(focus).also { _flow.value = it; snap.flow = it }
                }
            }
        }
    }

    /** 今日小结：今天完成的任务 + 专注时长，插到今天 Daily Note 的最前面（重复生成会替换，不堆叠） */
    var summaryBusy by mutableStateOf(false)
        private set

    fun writeDaySummary(onDone: (String) -> Unit) {
        if (summaryBusy) return
        summaryBusy = true
        viewModelScope.launch {
            val text = try {
                container.daySummary.hud(container.daySummary.write())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                "生成失败：${friendly(e)}"
            } finally {
                summaryBusy = false
            }
            onDone(text)
        }
    }

    fun timelineReport(): String? = _timeline.value.data?.let { Timeline.report(it) }

    private fun friendly(e: Exception): String =
        if (e is McpAuthException) "闪念贝壳 API Key 无效或已失效，请到「连接与诊断」重新填写" else (e.message ?: "加载失败")

    companion object {
        /** 看过的范围再次进入：这么久之内不重新请求 */
        private const val FRESH_MS = 60_000L

        /** 再次进入页面时，数据超过这么久就在后台悄悄刷新 */
        private const val STALE_MS = 3 * 60_000L

        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = this[APPLICATION_KEY] as IdeashellApp
                ReviewViewModel(app.container)
            }
        }
    }
}
