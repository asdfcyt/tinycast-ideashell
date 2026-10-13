package com.carpe.ideashell.ui.home

import androidx.compose.runtime.getValue
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
import com.carpe.ideashell.core.capture.CapturePlanner
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.core.parse.FolderInfo
import com.carpe.ideashell.core.template.Template
import com.carpe.ideashell.core.template.Templates
import com.carpe.ideashell.data.capture.SubmitReceipt
import com.carpe.ideashell.data.db.CaptureEntity
import com.carpe.ideashell.data.dida.DidaOverview
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.dida.FocusSummary
import com.carpe.ideashell.data.focus.FocusRun
import com.carpe.ideashell.data.ideashell.NoteInfo
import com.carpe.ideashell.domain.MemoryData
import com.carpe.ideashell.domain.MemoryLane
import com.carpe.ideashell.data.project.ProjectStatus
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import java.time.LocalDate
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** 热力图数据：每天 Daily Note 的条目数 */
data class HeatState(val counts: Map<LocalDate, Int>, val loading: Boolean)

/** 热力图显示的周数（半年） */
const val HEAT_WEEKS = 26

sealed interface HomeEvent {
    data class Saved(val receipt: SubmitReceipt) : HomeEvent
    data class Message(val text: String) : HomeEvent
}

class HomeViewModel(private val container: AppContainer) : ViewModel() {
    var text by mutableStateOf("")
    var override by mutableStateOf<CaptureKind?>(null)

    val folders: StateFlow<List<FolderInfo>> = container.folders.folders

    /** 今日重温：到期的笔记 / 摘录（已按每日上限截断），今天页顶部的卡片用它 */
    val revisitToday: StateFlow<com.carpe.ideashell.data.revisit.RevisitToday> = container.revisit.today

    fun refreshRevisit() = container.revisit.refreshDay()
    val connected: StateFlow<Boolean> = container.credentials.ideashellConnected

    val recent: StateFlow<List<CaptureEntity>> = container.captures.recent
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private val _events = Channel<HomeEvent>(Channel.BUFFERED)
    val events: Flow<HomeEvent> = _events.receiveAsFlow()

    /** 「今天」页展示的待办（来自滴答的本地缓存，后台刷新） */
    val overview: StateFlow<DidaOverview?> = container.todos.state
        .map { it.overview }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), container.todos.state.value.overview)

    /**
     * 项目（搁置的不算）的进展，与项目页同一口径：每个项目取「交付进度」
     * （以成果 = 任务笔记为单位，已交付记满分，进行中按行动步骤的勾选比例记分），再对各项目求平均；
     * 项目还没有任务笔记时退回相关任务的完成率（完成 ÷ 完成 + 未完成，只在滴答本地缓存里匹配）。
     * 没有项目或没有可算的数据为 null。
     */
    val projectProgress: StateFlow<Float?> =
        combine(container.projects.workspace, overview, container.projects.delivery) { workspace, ov, delivery ->
            if (ov == null) return@combine null
            val open = ov.overdue + ov.upcoming + ov.undated
            val each = workspace.projects.filter { it.status != ProjectStatus.PAUSED }.mapNotNull { p ->
                delivery[p.keyword]?.progress ?: run {
                    val o = open.count { t -> p.matches(t.title, t.tags) }
                    val d = ov.done.count { t -> p.matches(t.title, t.tags) }
                    if (o + d == 0) null else d.toFloat() / (o + d)
                }
            }
            if (each.isEmpty()) null else each.average().toFloat()
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    private var deliveryAt = 0L

    /** 任务列表读到 / 变化后，统计各项目的成果交付情况（只读，不归档；15 秒内不重复算） */
    private suspend fun refreshDelivery(ov: DidaOverview) {
        val now = System.currentTimeMillis()
        if (now - deliveryAt < 15_000L) return
        deliveryAt = now
        val open = ov.overdue + ov.upcoming + ov.undated
        for (p in container.projects.projects) {
            if (p.status == ProjectStatus.PAUSED || container.projects.taskNotesOf(p).isEmpty()) continue
            val openIds = open.filter { p.matches(it.title, it.tags) }.map { it.id }.toSet()
            val doneIds = ov.done.filter { p.matches(it.title, it.tags) }.map { it.id }.toSet()
            try {
                container.projects.refreshDelivery(p, openIds, doneIds, archive = false)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
            }
        }
    }

    /** 每日专注目标（分钟），在「设置」里改 */
    val focusGoalMin: StateFlow<Int> = container.settings.state.map { it.focusGoalMin }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), container.settings.current.focusGoalMin)

    /** 今天的专注（来自滴答，只读）；没连接滴答或还没加载为 null */
    private val _focus = MutableStateFlow<FocusSummary?>(null)
    val focus: StateFlow<FocusSummary?> = _focus.asStateFlow()
    private var focusAt = 0L

    /** 是否正在专注（应用内的倒计时）：今天页的专注行据此显示「专注中」 */
    val focusRunning: StateFlow<Boolean> = container.focus.session.map { it != null }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), container.focus.session.value != null)

    /** 正在进行的专注：今天页顶部的「专注中」条据此显示剩余时间；没有为 null */
    val focusSession: StateFlow<FocusRun?> = container.focus.session
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), container.focus.session.value)

    fun pauseOrResumeFocus() {
        val s = container.focus.session.value ?: return
        if (s.paused) container.focus.resume() else container.focus.pause()
    }

    /** 倒计时走完：马上结束并记录（不等闹钟），记录在进程级作用域里跑，离开页面也不会中断 */
    fun settleFocus() {
        container.appScope.launch { container.focus.settle() }
    }

    /** 记录热力图：近半年每天 Daily Note 的条目数；没连接闪念贝壳为 null，[HeatState.loading] 表示还在读 */
    private val _heat = MutableStateFlow<HeatState?>(null)
    val heat: StateFlow<HeatState?> = _heat.asStateFlow()
    private var heatJob: Job? = null
    private var heatAt = 0L

    /** 往日回顾的数据（5 年笔记，仓库里有 20 分钟缓存）；没连接闪念贝壳或还没加载为 null */
    private val _memory = MutableStateFlow<MemoryData?>(container.notes.memoryCached())
    val memory: StateFlow<MemoryData?> = _memory.asStateFlow()

    /** 「随机漫步」当前这一条 */
    var walkNote by mutableStateOf<NoteInfo?>(null)
        private set

    init {
        container.todos.refresh()
        refreshFocus()
        refreshMemory()
        refreshHeat()
        viewModelScope.launch {
            overview.collect { ov -> if (ov != null) refreshDelivery(ov) }
        }
    }

    /** 回到「今天」页时调用：一分钟内不重复读；读的时候边读边画 */
    fun refreshHeat() {
        if (!container.credentials.ideashellConnected.value) {
            _heat.value = null
            return
        }
        if (heatJob?.isActive == true) return
        val now = System.currentTimeMillis()
        if (now - heatAt < HEAT_TTL_MS && _heat.value?.loading == false) return
        heatJob = viewModelScope.launch {
            _heat.value = HeatState(_heat.value?.counts.orEmpty(), loading = true)
            val result = runCatching {
                container.notes.dailyHeat(LocalDate.now(), HEAT_WEEKS) { partial ->
                    _heat.value = HeatState(partial, loading = true)
                }
            }
            result.onSuccess {
                heatAt = System.currentTimeMillis()
                _heat.value = HeatState(it, loading = false)
            }.onFailure {
                _heat.value = HeatState(_heat.value?.counts.orEmpty(), loading = false)
            }
        }
    }

    /** 回到「今天」页时调用：两分钟内不重复请求 */
    fun refreshFocus() {
        if (container.credentials.didaToken.isNullOrBlank()) {
            _focus.value = null
            return
        }
        val now = System.currentTimeMillis()
        // 刚在专注页记了一条（写进滴答）时，不等缓存过期，马上重读
        val freshRecord = container.focus.recordedAt.value > focusAt
        if (!freshRecord && now - focusAt < FOCUS_TTL_MS && _focus.value != null) return
        focusAt = now
        viewModelScope.launch {
            runCatching { container.daySummary.focus(LocalDate.now()) }
                .onSuccess { _focus.value = it }
                .onFailure { focusAt = 0L }
        }
    }

    /** 仓库有 20 分钟缓存，频繁调用不会重复拉 */
    fun refreshMemory() {
        if (!container.credentials.ideashellConnected.value) {
            _memory.value = null
            walkNote = null
            return
        }
        viewModelScope.launch {
            runCatching { container.notes.memory() }.onSuccess { m ->
                _memory.value = m
                if (walkNote == null || m.pool.none { it.id == walkNote?.id }) {
                    walkNote = MemoryLane.pickRandom(m.pool, MemoryLane.sameDayIds(m))
                }
            }
        }
    }

    /** 换一条随机笔记（避开往年今日里已有的，也避开当前这条） */
    fun shuffleWalk() {
        val m = _memory.value ?: return
        walkNote = MemoryLane.pickRandom(m.pool, MemoryLane.sameDayIds(m) + listOfNotNull(walkNote?.id))
    }

    fun refreshTodos() = container.todos.refresh(force = true)

    /** 下拉刷新中 */
    var refreshing by mutableStateOf(false)
        private set

    /** 下拉强制刷新：绕过各处的缓存，把待办、专注、往日回顾、热力图全部重新读一遍 */
    fun forceRefresh() {
        if (refreshing) return
        refreshing = true
        viewModelScope.launch {
            try {
                focusAt = 0L
                heatAt = 0L
                heatJob?.cancel()
                val jobs = listOf(
                    launch { runCatching { container.todos.refreshNow() } },
                    launch {
                        if (!container.credentials.didaToken.isNullOrBlank()) {
                            runCatching { container.daySummary.focus(LocalDate.now()) }.onSuccess { _focus.value = it }
                        }
                    },
                    launch {
                        if (container.credentials.ideashellConnected.value) {
                            runCatching { container.notes.memory(force = true) }.onSuccess { _memory.value = it }
                        }
                    },
                )
                refreshHeat()
                jobs.forEach { it.join() }
                heatJob?.join()
                container.focus.settle()
                container.surfaces.updateAll()
            } finally {
                refreshing = false
            }
        }
    }

    fun completeTask(task: DidaTask) {
        viewModelScope.launch {
            container.todos.complete(task).onFailure {
                _events.send(HomeEvent.Message("完成失败：${it.message ?: "网络异常"}"))
            }
            container.surfaces.updateAll()
        }
    }

    /** @param readClipboard 输入「剪贴板」时由界面提供剪贴板里的文字 */
    fun submit(readClipboard: () -> String?) {
        val resolved = CapturePlanner.resolveClipboard(text, readClipboard)
        if (resolved == null) {
            _events.trySend(HomeEvent.Message("剪贴板里没有文字"))
            return
        }
        // 剪贴板内容默认存为笔记（与桌面一致）；前缀仍然优先
        val kind = override ?: if (resolved.fromClipboard) CaptureKind.NOTE else null

        viewModelScope.launch {
            val receipt = container.captures.submitText(resolved.input, kind, ORIGIN_APP)
            if (receipt == null) {
                _events.send(HomeEvent.Message("没有可保存的内容"))
                return@launch
            }
            text = ""
            override = null
            _events.send(HomeEvent.Saved(receipt))
        }
    }

    /** 内置模板 + 自定义模板（同名时自定义优先） */
    val templates: StateFlow<List<Template>> = container.workspace.state
        .map { Templates.merge(it.templates) }
        .stateIn(viewModelScope, SharingStarted.Eagerly, Templates.merge(container.workspace.current.templates))

    /** 用模板录入：标题固定「模板名 日期」，正文每个字段一段 `**字段**：值`。返回是否已保存 */
    fun submitTemplate(template: Template, values: Map<String, String>): Boolean {
        val built = Templates.buildNote(template, values)
        if (built.filled == 0) {
            _events.trySend(HomeEvent.Message("请至少填写一项"))
            return false
        }
        viewModelScope.launch {
            val receipt = container.captures.submitNote(
                title = built.title,
                body = built.body,
                tags = template.tags,
                folderName = template.folderName,
                label = "模板「${template.name}」",
                origin = ORIGIN_APP,
            )
            _events.send(HomeEvent.Saved(receipt))
        }
        return true
    }

    fun saveTemplate(template: Template, replacing: String?) {
        container.workspace.update { w ->
            val key = (replacing ?: template.name).lowercase()
            val rest = w.templates.filterNot { it.name.lowercase() == key || it.name.lowercase() == template.name.lowercase() }
            w.copy(templates = rest + template.copy(builtin = false))
        }
        _events.trySend(HomeEvent.Message("已保存模板「${template.name}」"))
    }

    fun deleteTemplate(name: String) {
        container.workspace.update { w -> w.copy(templates = w.templates.filterNot { it.name.equals(name, ignoreCase = true) }) }
        _events.trySend(HomeEvent.Message("已删除模板「$name」"))
    }

    fun undo(id: Long) {
        viewModelScope.launch {
            val ok = container.captures.undo(id)
            _events.send(HomeEvent.Message(if (ok) "已撤销" else "已经开始同步，无法撤销"))
        }
    }

    fun retry(id: Long) {
        viewModelScope.launch { container.captures.retry(id) }
    }

    fun clearDone() {
        viewModelScope.launch { container.captures.clearDone() }
    }

    private companion object {
        const val ORIGIN_APP = "app"
        const val FOCUS_TTL_MS = 2 * 60 * 1000L
        const val HEAT_TTL_MS = 60 * 1000L
    }

    object Factory {
        val instance: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = this[APPLICATION_KEY] as IdeashellApp
                HomeViewModel(app.container)
            }
        }
    }
}
