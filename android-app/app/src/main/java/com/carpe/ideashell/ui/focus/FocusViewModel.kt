package com.carpe.ideashell.ui.focus

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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
import com.carpe.ideashell.data.dida.DidaOverview
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.focus.FocusKind
import com.carpe.ideashell.data.focus.FocusResult
import com.carpe.ideashell.data.project.ProjectStatus
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.time.LocalDate

/** 选择器里的一个项目：关键词 + 它名下（不在「今天」列表里的）未完成任务 */
data class ProjectChoice(val keyword: String, val tasks: List<DidaTask>)

class FocusViewModel(private val container: AppContainer) : ViewModel() {
    private val focus = container.focus

    val session = focus.session
    val summary = focus.summary
    val pending = focus.pending
    val connected: StateFlow<Boolean> = container.credentials.didaConnected

    /** 每日专注目标（分钟），在「设置」里改 */
    val goalMin: StateFlow<Int> = container.settings.state.map { it.focusGoalMin }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), container.settings.current.focusGoalMin)

    /** 可以绑定的任务：逾期 + 今天 + 没有日期的（滴答本地缓存里的），已排好顺序 */
    val tasks: StateFlow<List<DidaTask>> = container.todos.state
        .map { data -> data.overview?.let(::candidates).orEmpty() }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), container.todos.state.value.overview?.let(::candidates).orEmpty())

    /**
     * 可以关联的项目：每个关注中（没搁置）的项目，连同它名下还没完成的任务（不论哪天，已在上面「今天」列表里的不重复出现）。
     * 没有任务的项目也在，可以直接为项目专注。
     */
    val projects: StateFlow<List<ProjectChoice>> =
        combine(container.todos.state, container.projects.workspace) { state, workspace ->
            val ov = state.overview
            val shown = ov?.let(::candidates).orEmpty().map { it.id }.toSet()
            val open = ov?.let { it.overdue + it.upcoming + it.undated }.orEmpty()
            workspace.projects.filter { it.status != ProjectStatus.PAUSED }.map { p ->
                ProjectChoice(
                    keyword = p.keyword,
                    tasks = open.filter { t -> t.id !in shown && p.matches(t.title, t.tags) }.sortedBy { it.date ?: "9999" },
                )
            }
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    /** 任务属于哪个项目（关注中的）；不属于任何项目为 null */
    fun projectOf(t: DidaTask): String? =
        container.projects.projects.firstOrNull { it.status != ProjectStatus.PAUSED && it.matches(t.title, t.tags) }?.keyword

    /** 开始前选的时长（分钟）、绑定的任务；开始后它们就存进 [session]，这里只管下一次 */
    /** 番茄走完后接下来该休息什么（短休息 / 每 4 个番茄一次长休息）；null = 现在是专注 */
    val pendingBreak = focus.pendingBreak

    /** 这一轮已完成的番茄数（满 4 个就是长休息） */
    val cycle = focus.cycle

    var minutes by mutableIntStateOf((focus.pendingBreak.value ?: FocusKind.FOCUS).let { focus.lastMinutes(it) })
    var task by mutableStateOf<DidaTask?>(null)

    /** 关联的项目关键词：选了属于某个项目的任务会自动带上；也可以只选项目、不选任务 */
    var project by mutableStateOf<String?>(null)

    /** 正在新建任务（选择器里的「添加」按钮据此显示「添加中」） */
    var adding by mutableStateOf(false)
        private set

    private val _messages = Channel<String>(Channel.BUFFERED)
    val messages: Flow<String> = _messages.receiveAsFlow()

    init {
        container.todos.refresh()
        reload()
        // 专注 ↔ 休息切换时，圆盘的时长换成这一种上次选的
        viewModelScope.launch { focus.pendingBreak.collect { k -> minutes = focus.lastMinutes(k ?: FocusKind.FOCUS) } }
    }

    /** 进入页面 / 回到前台：对账（到点没记的补记、没传成功的补传）并读回滴答里的专注 */
    fun reload() {
        viewModelScope.launch {
            focus.settle()
            focus.refresh()
        }
    }

    /** 不休息了，直接回到专注 */
    fun skipBreak() = focus.skipBreak()

    var refreshing by mutableStateOf(false)
        private set

    /** 下拉强制刷新：对账、读回滴答里的专注、重新拉待办，并刷新通知 / 小部件 */
    fun forceRefresh() {
        if (refreshing) return
        refreshing = true
        viewModelScope.launch {
            try {
                kotlinx.coroutines.coroutineScope {
                    launch { container.todos.refreshNow() }
                    launch {
                        focus.settle()
                        focus.refresh()
                    }
                }
                container.surfaces.updateAll()
                container.widgets.updateFocus()
            } finally {
                refreshing = false
            }
        }
    }

    fun start() {
        val t = task
        if (!focus.start(t?.id, t?.projectId, titleOf(t, project), minutes, focus.pendingBreak.value ?: FocusKind.FOCUS, project)) {
            _messages.trySend("已经有一个专注在进行")
        }
    }

    /** 选择器里选了「任务 / 项目」：还没开始就记下来，已经在专注就直接关联到这次专注（休息时不关联） */
    fun choose(t: DidaTask?, projectKeyword: String?) {
        val p = projectKeyword ?: t?.let(::projectOf)
        if (session.value != null) {
            focus.attach(t?.id, t?.projectId, titleOf(t, p), p)
        } else {
            task = t
            project = p
        }
    }

    private fun titleOf(t: DidaTask?, p: String?): String =
        t?.title?.takeIf { it.isNotBlank() } ?: p?.let { "项目「$it」" }.orEmpty()

    fun pauseOrResume() {
        val s = session.value ?: return
        if (s.paused) focus.resume() else focus.pause()
    }

    /** 结束并记录；放在进程级作用域里，离开页面也会把写入滴答的请求跑完 */
    fun finish() {
        container.appScope.launch {
            when (val r = focus.finish()) {
                is FocusResult.Recorded ->
                    _messages.trySend(if (r.synced) "已记入滴答 · ${r.minutes} 分钟" else "已保存 · ${r.minutes} 分钟，联网后自动同步到滴答")
                FocusResult.TooShort -> _messages.trySend("不足 1 分钟，没有记录")
                FocusResult.None -> Unit
            }
        }
    }

    fun discard() = focus.discard()

    /** 在滴答里新建一个今天的待办并选中它；成功后回调 [onAdded]（用来关掉选择器） */
    fun addTask(title: String, onAdded: () -> Unit) {
        val t = title.trim()
        if (t.isEmpty() || adding) return
        if (!connected.value) {
            _messages.trySend("先连接滴答清单，才能新建任务")
            return
        }
        adding = true
        viewModelScope.launch {
            try {
                val created = focus.addTask(t)
                container.todos.refreshNow()
                val found = created ?: container.todos.state.value.overview?.let(::candidates).orEmpty().firstOrNull { it.title == t }
                if (found != null) {
                    choose(found, null)
                    onAdded()
                } else {
                    _messages.trySend("任务已创建，但没能自动选中，请在列表里选")
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _messages.trySend("新建任务失败，请检查网络和滴答连接")
            } finally {
                adding = false
            }
        }
    }

    fun syncNow() {
        viewModelScope.launch {
            focus.settle()
            focus.refresh()
            if (focus.pending.value.isNotEmpty()) _messages.trySend("同步失败，请检查网络和滴答连接")
        }
    }

    private fun candidates(ov: DidaOverview): List<DidaTask> {
        val today = LocalDate.now().toString()
        val order = compareBy<DidaTask>({ it.date ?: "9999" }, { it.time ?: "99:99" }, { -it.priority })
        return (ov.overdue + ov.upcoming.filter { it.date == today }).sortedWith(order) + ov.undated
    }

    object Factory {
        val instance: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = this[APPLICATION_KEY] as IdeashellApp
                FocusViewModel(app.container)
            }
        }
    }
}
