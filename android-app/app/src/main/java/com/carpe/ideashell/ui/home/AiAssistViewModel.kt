package com.carpe.ideashell.ui.home

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.runtime.mutableStateMapOf
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.Companion.APPLICATION_KEY
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.carpe.ideashell.AppContainer
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.focus.FocusKind
import com.carpe.ideashell.data.llm.AiAssistant
import com.carpe.ideashell.data.llm.AiDayPlan
import com.carpe.ideashell.data.llm.DraftItem
import com.carpe.ideashell.data.llm.PlanContext
import com.carpe.ideashell.data.llm.QuickStartInput
import com.carpe.ideashell.data.llm.QuickStartPlan
import com.carpe.ideashell.data.llm.QuickStartPlanner
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import java.time.LocalDate

sealed interface QuickStartUi {
    data object Idle : QuickStartUi
    data object Loading : QuickStartUi
    class Error(val text: String) : QuickStartUi
    class Ready(val plan: QuickStartPlan) : QuickStartUi
}

sealed interface PlanUi {
    data object Idle : PlanUi

    /** 第一步：倒出脑子里的事 */
    data object Input : PlanUi
    class Loading(val text: String) : PlanUi

    /** 第一步的结果：拆好的小任务 + 每个要多久，可以调 */
    class Breakdown(val note: String) : PlanUi

    /** 第二步的结果：排好的计划 */
    class Result(val plan: AiDayPlan) : PlanUi
    class Failed(val text: String) : PlanUi
}

/**
 * 「今天」页的两个 AI 功能（从 Mac 端迁移）：
 * - AI 规划（重新规划），两步：① 把脑子里没记下的事拆成小任务并估好时长；② 根据今天已有的任务把它们排进日程。勾选确认后才写进滴答；
 * - 快速启动：AI 梳理今天要做的事、值得留意的事，并给一个 10~25 分钟的小目标，点一下就开始专注。
 */
class AiAssistViewModel(private val container: AppContainer) : ViewModel() {
    private val _messages = Channel<String>(Channel.BUFFERED)
    val messages: Flow<String> = _messages.receiveAsFlow()

    val llmConfigured: Boolean get() = container.llm.configured

    // ───────────────────────── 快速启动 ─────────────────────────

    var quickStart by mutableStateOf<QuickStartUi>(QuickStartUi.Idle)
        private set

    /** 「先放一放」里已经延期的：key → 结果文字 */
    val postponed: SnapshotStateMap<String, String> = mutableStateMapOf()

    private var quickCache: QuickStartPlan? = null

    /** 打开快速启动：30 分钟内、同一天有结果就直接用，否则重新梳理 */
    fun openQuickStart() {
        val c = quickCache
        if (c != null && System.currentTimeMillis() - c.madeAt < CACHE_MS && sameDay(c.madeAt)) {
            quickStart = QuickStartUi.Ready(c)
            return
        }
        loadQuickStart()
    }

    fun loadQuickStart() {
        if (quickStart is QuickStartUi.Loading) return
        quickStart = QuickStartUi.Loading
        postponed.clear()
        viewModelScope.launch {
            try {
                val today = LocalDate.now()
                val input = coroutineScope {
                    val connected = container.credentials.ideashellConnected.value
                    val notes = async { if (connected) runCatching { container.notes.recentNotes(2) }.getOrDefault(emptyList()) else emptyList() }
                    val daily = async {
                        if (connected) runCatching { container.notes.dailyDays(today.minusDays(2), today) }.getOrDefault(emptyMap()) else emptyMap()
                    }
                    QuickStartInput(
                        overview = container.todos.state.value.overview,
                        recentNotes = notes.await(),
                        dailyDays = daily.await(),
                        projects = container.projects.projects,
                        focusMinutesToday = container.focus.summary.value?.todayMin ?: 0,
                        focusGoalMinutes = container.settings.current.focusGoalMin,
                    )
                }
                val plan = QuickStartPlanner.plan(container.llm, input)
                quickCache = plan
                quickStart = QuickStartUi.Ready(plan)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                quickStart = QuickStartUi.Error(e.message ?: "梳理失败，请重试")
            }
        }
    }

    /** 开始专注；已经有一个在进行时返回 false */
    fun startFocus(task: DidaTask?, minutes: Int): Boolean {
        val title = task?.title?.takeIf { it.isNotBlank() }.orEmpty()
        val ok = container.focus.start(task?.id, task?.projectId, title, minutes, FocusKind.FOCUS, null)
        if (!ok) _messages.trySend("已经有一个专注在进行")
        return ok
    }

    /** 「先放一放」里的延期：改到某一天，保留原来的时间点 */
    fun postpone(key: String, task: DidaTask, date: LocalDate, label: String) {
        viewModelScope.launch {
            container.todos.reschedule(task, date.toString(), task.time)
                .onSuccess { postponed[key] = "已延期到$label" }
                .onFailure { _messages.send("延期失败：${it.message ?: "网络异常"}") }
        }
    }

    private fun sameDay(ms: Long): Boolean =
        java.time.Instant.ofEpochMilli(ms).atZone(java.time.ZoneId.systemDefault()).toLocalDate() == LocalDate.now()

    // ───────────────────────── AI 规划（两步） ─────────────────────────
    // ① 倒出脑子里的事 → AI 拆成小任务、估好每个要多久（可以调）
    // ② 根据今天已有的任务，把它们排进空档（同时顾到逾期 / 未排期的待办）
    // 每一项都能取消勾选，点「应用」才写进滴答。

    var planUi by mutableStateOf<PlanUi>(PlanUi.Idle)
        private set

    /** 「脑子里还有什么想做的事」 */
    var goals by mutableStateOf("")

    /** 第一步拆出来的小任务（时长可调），以及勾选要排的 */
    var draft by mutableStateOf<List<DraftItem>>(emptyList())
        private set
    var checkedDraft by mutableStateOf<Set<String>>(emptySet())
        private set

    var checkedMoves by mutableStateOf<Set<String>>(emptySet())
        private set
    var checkedNew by mutableStateOf<Set<String>>(emptySet())
        private set
    var applying by mutableStateOf(false)
        private set

    /** 现在在第几步：0 还没开始 / 没配置，1 拆解，2 排期 */
    val planStep: Int
        get() = when (planUi) {
            PlanUi.Idle -> 0
            PlanUi.Input, is PlanUi.Breakdown -> 1
            is PlanUi.Result -> 2
            is PlanUi.Loading, is PlanUi.Failed -> failedStep
        }

    private var breakNote = ""
    private var planJob: Job? = null
    private var planGen = 0

    /** 出错时是哪一步：1 拆解、2 排期；重试从这一步再来 */
    private var failedStep = 0

    /** 这一轮规划是什么时候开始的；同一天、4 小时内再打开，接着上次的进度（输入的、拆好的、排好没应用的都在） */
    private var planStartedAt = 0L

    private fun planRecent(): Boolean =
        System.currentTimeMillis() - planStartedAt < PLAN_KEEP_MS &&
            java.time.Instant.ofEpochMilli(planStartedAt).atZone(java.time.ZoneId.systemDefault()).toLocalDate() == LocalDate.now()

    private fun planFresh(): Boolean = planUi !is PlanUi.Idle && planUi !is PlanUi.Failed && planRecent()

    /**
     * 打开面板：上一轮还在（正在分析 / 输入没写完 / 拆好没排 / 排好没应用）就接着看；
     * 没有、过期了或上次出错了，才重新开始：没配置大模型只提示去配置，配置了就回到第一步的输入页。
     */
    fun openPlan() {
        if (planFresh()) return
        // 上次是分析出错了：已经写的内容 / 拆好的任务不丢，回到出错前的那一页
        if (planUi is PlanUi.Failed && failedStep != 0 && planRecent() && container.llm.configured) {
            planUi = if (draft.isNotEmpty()) PlanUi.Breakdown(breakNote) else PlanUi.Input
            return
        }
        restartPlan()
    }

    /** 丢掉上一轮，重新开始（顶部「重新开始」） */
    fun restartPlan() {
        planJob?.cancel()
        planGen++
        goals = ""
        draft = emptyList()
        checkedDraft = emptySet()
        checkedMoves = emptySet()
        checkedNew = emptySet()
        breakNote = ""
        failedStep = 0
        applying = false
        planStartedAt = System.currentTimeMillis()
        planUi = if (container.llm.configured) PlanUi.Input else PlanUi.Failed(NOT_CONFIGURED)
    }

    /** 读最新的待办（往后半个月：既看得到时间占用，也不拖慢速度）并汇总成上下文 */
    private suspend fun loadContext(): PlanContext {
        val today = LocalDate.now()
        runCatching { container.todos.loadRange(today, today.plusDays(14)) }
        val ov = container.todos.state.value.overview
        return AiAssistant.context(
            overview = ov,
            extra = container.todos.ranged.value.values.filter { !it.done },
            projects = container.projects.projects,
            recentTitles = emptyList(),
            projectName = { ov?.projects?.get(it) },
        )
    }

    /** 第一步：把倒出来的事拆成小任务、估好时长 */
    fun decompose() {
        val text = goals.trim()
        if (text.isEmpty()) return
        val gen = ++planGen
        planJob?.cancel()
        failedStep = 1
        planUi = PlanUi.Loading("AI 正在识别你写的事：哪些是已有待办、哪些是新事，并估算时长…")
        planJob = viewModelScope.launch {
            try {
                val ctx = loadContext()
                if (gen != planGen) return@launch
                val (note, items) = AiAssistant.decompose(
                    llm = container.llm,
                    ctx = ctx,
                    text = text,
                    projectKeys = container.projects.projects.map { it.keyword }.toSet(),
                )
                if (gen != planGen) return@launch
                draft = items
                checkedDraft = items.map { it.key }.toSet()
                breakNote = note
                planUi = PlanUi.Breakdown(note)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (gen == planGen) planUi = PlanUi.Failed(e.message ?: "出错了，请重试")
            }
        }
    }

    /** 没有新的事要加，只想把现有待办（逾期 / 没排期的）重新排一遍：跳过第一步 */
    fun skipToSchedule() {
        draft = emptyList()
        checkedDraft = emptySet()
        schedule()
    }

    fun toggleDraft(key: String) {
        checkedDraft = if (key in checkedDraft) checkedDraft - key else checkedDraft + key
    }

    /** 调某个任务的预计时长（5 分钟起，最长 3 小时） */
    fun adjustMinutes(key: String, delta: Int) {
        draft = draft.map { if (it.key == key && it.taskId == null) it.copy(minutes = (it.minutes + delta).coerceIn(5, 180)) else it }
    }

    /** 第二步：根据今天已有的任务排期 */
    fun schedule() {
        val items = draft.filter { it.key in checkedDraft }
        val gen = ++planGen
        planJob?.cancel()
        failedStep = 2
        planUi = PlanUi.Loading("AI 正在根据已有的日程排期…（会避开已占用的时段，遵守你说的时间限制）")
        planJob = viewModelScope.launch {
            try {
                val ctx = loadContext()
                if (gen != planGen) return@launch
                val plan = AiAssistant.schedule(container.llm, ctx, items)
                if (gen != planGen) return@launch
                checkedMoves = plan.moves.map { it.id }.toSet()
                checkedNew = plan.newTasks.map { it.key }.toSet()
                planUi = PlanUi.Result(plan)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (gen == planGen) planUi = PlanUi.Failed(e.message ?: "出错了，请重试")
            }
        }
    }

    /** 排期页「调整任务」：回到拆解页（没有拆解过就回输入页） */
    fun backToBreakdown() {
        planUi = if (draft.isNotEmpty()) PlanUi.Breakdown(breakNote) else PlanUi.Input
    }

    /** 拆解页「重新输入」：回到输入页，已经写的内容还在 */
    fun backToInput() {
        planUi = PlanUi.Input
    }

    fun retryPlan() {
        when {
            !container.llm.configured -> planUi = PlanUi.Failed(NOT_CONFIGURED)
            failedStep == 2 -> schedule()
            failedStep == 1 -> decompose()
            else -> restartPlan()
        }
    }

    fun toggleMove(id: String) {
        checkedMoves = if (id in checkedMoves) checkedMoves - id else checkedMoves + id
    }

    fun toggleNew(key: String) {
        checkedNew = if (key in checkedNew) checkedNew - key else checkedNew + key
    }

    /** 把勾选的改期 + 新任务写进滴答 */
    fun applyPlan(onDone: () -> Unit) {
        val plan = (planUi as? PlanUi.Result)?.plan ?: return
        if (applying) return
        val moves = plan.moves.filter { it.id in checkedMoves }
        val news = plan.newTasks.filter { it.key in checkedNew }
        if (moves.isEmpty() && news.isEmpty()) return
        applying = true
        viewModelScope.launch {
            var moved = 0
            var movedFailed = 0
            for (m in moves) {
                container.todos.reschedule(m.task, m.date, m.time).onSuccess { moved++ }.onFailure { movedFailed++ }
            }
            var created = 0
            var createdFailed = 0
            for (n in news) {
                val notes = buildList {
                    add("预计 ${n.minutes} 分钟")
                    n.parent?.let { add("来自：$it") }
                    if (n.reason.isNotBlank()) add(n.reason)
                }
                container.todos.createTask(
                    title = n.title,
                    date = n.date,
                    time = n.time,
                    priority = n.priority,
                    content = "AI 规划：" + notes.joinToString(" · "),
                    tags = listOfNotNull(n.project),
                ).onSuccess { created++ }.onFailure { createdFailed++ }
            }
            container.surfaces.updateAll()
            val parts = buildList {
                if (moved > 0) add("改期 $moved 件")
                if (created > 0) add("新建 $created 个任务")
                if (movedFailed + createdFailed > 0) add("${movedFailed + createdFailed} 项没成功")
            }
            _messages.send("已应用 AI 规划：" + parts.joinToString("，").ifEmpty { "没有改动" })
            applying = false
            // 计划已经写进滴答：这一轮到此为止，下次打开重新看
            planUi = PlanUi.Idle
            onDone()
        }
    }

    private companion object {
        const val PLAN_KEEP_MS = 4 * 60 * 60 * 1000L
        const val NOT_CONFIGURED = "还没配置大模型：到「设置 → 账号与连接」填好接口地址、模型名和 Key，再回来试。"
        const val CACHE_MS = 30 * 60 * 1000L
    }

    object Factory {
        val instance: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = this[APPLICATION_KEY] as IdeashellApp
                AiAssistViewModel(app.container)
            }
        }
    }
}
