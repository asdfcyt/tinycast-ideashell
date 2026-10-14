package com.carpe.ideashell.ui.todos

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
import com.carpe.ideashell.core.notes.NoteSections
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.dida.Habit
import com.carpe.ideashell.data.dida.TodoData
import com.carpe.ideashell.data.project.Project
import com.carpe.ideashell.data.project.ProjectDelivery
import com.carpe.ideashell.data.project.ProjectFocusStats
import com.carpe.ideashell.data.project.ProjectMonthlyFocus
import com.carpe.ideashell.data.project.ProjectStats
import com.carpe.ideashell.data.project.ProjectStatus
import com.carpe.ideashell.data.project.Workspace
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch

/** 过去某一天的任务（时间轴往前翻看）：[tasks] 为 null 表示还没读到 */
data class PastDay(val tasks: List<DidaTask>? = null, val loading: Boolean = false, val error: String? = null)

sealed interface TodoEvent {
    data class Message(val text: String) : TodoEvent

    /** 刚完成了一个任务，界面显示「撤销」 */
    data class Completed(val task: DidaTask) : TodoEvent
}

/**
 * 待办页的视图：任务 / 项目 / 习惯。
 * 「任务」是原来的列表 + 收集箱合并后的一个视图：按日期分组，行首的圆圈颜色表示优先级，
 * 没有日期的任务在末尾的「无日期」分组里，行尾「定日期」一键排期。
 */
enum class TodoView(val label: String) {
    LIST("任务"),
    CALENDAR("日历"),
    PROJECTS("项目"),
    HABITS("习惯"),
}

/** 往项目主页笔记的某个小节写内容的方式 */
enum class HomeEditMode {
    /** 整节替换（目标、交付成果） */
    REPLACE,

    /** 追加一条列表项（资料与链接） */
    LINK,

    /** 追加一行带时间的记录（里程碑与进展） */
    MILESTONE,

    /** 追加一段带时间的文字（复盘与经验） */
    REVIEW,
}

data class HabitUi(
    val loading: Boolean = false,
    val habits: List<Habit> = emptyList(),
    val error: String? = null,
    val loaded: Boolean = false,
)

class TodoViewModel(private val container: AppContainer) : ViewModel() {
    val data: StateFlow<TodoData> = container.todos.state
    val connected: StateFlow<Boolean> = container.credentials.didaConnected
    val workspace: StateFlow<Workspace> = container.projects.workspace
    val stats: StateFlow<Map<String, ProjectStats>> = container.projects.stats
    val delivery: StateFlow<Map<String, ProjectDelivery>> = container.projects.delivery
    val focusStats: StateFlow<Map<String, ProjectFocusStats>> = container.projects.focusStats
    val monthlyFocus: StateFlow<Map<String, ProjectMonthlyFocus>> = container.projects.monthlyFocus

    /** 正在进行的专注（项目页的「专注一次」据此显示「专注中」） */
    val focusSession: StateFlow<com.carpe.ideashell.data.focus.FocusRun?> = container.focus.session
    val lastFocusMinutes: Int get() = container.focus.lastMinutes

    var showDone by mutableStateOf(false)
    var showAllUndated by mutableStateOf(false)

    /** 任务视图选中的那一天；null 表示今天 */
    var day by mutableStateOf<java.time.LocalDate?>(null)

    /** 过去几天的任务缓存：读过的日子再点回来直接显示，需要时 [loadPast] 强制刷新 */
    val past = mutableStateMapOf<java.time.LocalDate, PastDay>()

    fun loadPast(day: java.time.LocalDate, force: Boolean = false) {
        val cur = past[day]
        if (!force && (cur?.loading == true || cur?.tasks != null)) return
        past[day] = PastDay(cur?.tasks, loading = true)
        viewModelScope.launch {
            runCatching { container.todos.dayTasks(day) }
                .onSuccess { past[day] = PastDay(it) }
                .onFailure { past[day] = PastDay(cur?.tasks, error = it.message ?: "网络异常") }
        }
    }

    /** 过去那天里的任务：没完成就完成它，完成了就撤销；操作完重读这一天 */
    fun togglePast(task: DidaTask, day: java.time.LocalDate) {
        viewModelScope.launch {
            val r = if (task.done) container.todos.undoComplete(task) else container.todos.complete(task)
            r.onFailure { fail(if (task.done) "撤销失败" else "完成失败", it) }
            if (task.done) r.onSuccess { container.appScope.launch { runCatching { container.projects.afterUndo(task) } } }
            loadPast(day, force = true)
        }
    }

    // ───────────── 日历视图 ─────────────

    /** 日历视图正在看的月份（留在 ViewModel 里：打开任务、切走再回来仍在这个月） */
    var calMonth by mutableStateOf(java.time.YearMonth.now())

    /** 日历读到的任务（含概览之外更远的日期、已完成的），完成 / 改期时会同步更新 */
    val ranged: StateFlow<Map<String, DidaTask>> = container.todos.ranged

    var calLoading by mutableStateOf(false)
        private set

    private val calLoadedAt = HashMap<java.time.YearMonth, Long>()

    /** 日历格子覆盖的日期范围：从本月 1 号所在那周的周一，到本月最后一天所在那周的周日 */
    fun gridRange(month: java.time.YearMonth): Pair<java.time.LocalDate, java.time.LocalDate> {
        val first = month.atDay(1).with(java.time.temporal.TemporalAdjusters.previousOrSame(java.time.DayOfWeek.MONDAY))
        val last = month.atEndOfMonth().with(java.time.temporal.TemporalAdjusters.nextOrSame(java.time.DayOfWeek.SUNDAY))
        return first to last
    }

    /**
     * 读这个月（含首尾补出来的几天）的任务。
     * - 缓存里已经有这段日期的数据（这次运行读过的，或上次存在本地的）就先画出来，后台静默更新，不转圈；
     * - [minAge] 内读过的不重复读；[force] 忽略；
     * - 读完后顺带把前后两个月也预读好，左右划切月时基本是现成的。
     */
    fun loadCalendar(month: java.time.YearMonth, force: Boolean = false, minAge: Long = 60_000L, prefetchNeighbors: Boolean = true) {
        if (!connected.value) return
        viewModelScope.launch {
            fetchMonth(month, force, minAge, silent = false)
            if (prefetchNeighbors) {
                // 先下个月（更常看），再上个月；错开一点，别和手上正在读的请求抢
                for (m in listOf(month.plusMonths(1), month.minusMonths(1))) {
                    kotlinx.coroutines.delay(300)
                    fetchMonth(m, force = false, minAge = 5 * 60_000L, silent = true)
                }
            }
        }
    }

    /** 进入待办页后在后台把当前月预热好，之后下拉进日历直接有数据 */
    fun warmCalendar() = loadCalendar(calMonth, minAge = 5 * 60_000L, prefetchNeighbors = false)

    private suspend fun fetchMonth(month: java.time.YearMonth, force: Boolean, minAge: Long, silent: Boolean) {
        val now = System.currentTimeMillis()
        if (!force && now - (calLoadedAt[month] ?: 0L) < minAge) return
        calLoadedAt[month] = now
        val (from, to) = gridRange(month)
        val lo = from.toString()
        val hi = to.toString()
        val hasData = ranged.value.values.any { (it.date ?: "") in lo..hi }
        val spinner = !silent && !hasData
        if (spinner) calLoading = true
        container.todos.loadRange(from, to).onFailure {
            calLoadedAt.remove(month)
            // 预读失败不打扰；有缓存可看时也只在手动看这个月时提示
            if (!silent) message(if (hasData) "日历没能更新：${it.message ?: "网络异常"}" else "日历没能读到这个月的任务：${it.message ?: "网络异常"}")
        }
        if (spinner) calLoading = false
    }

    /** 日历里点开不在概览里的任务（更远日期的）时，从日历缓存里找 */
    fun rangedTask(id: String): DidaTask? = ranged.value.values.firstOrNull { it.id == id && !it.done }
        ?: ranged.value.values.firstOrNull { it.id == id }

    /** 把无日期任务拖到某一天：改成那天的全天任务 */
    fun scheduleByDrag(task: DidaTask, date: java.time.LocalDate) {
        viewModelScope.launch {
            container.todos.reschedule(task, date.toString(), null)
                .onSuccess { message("已安排到 ${date.monthValue}月${date.dayOfMonth}日") }
                .onFailure { fail("安排失败", it) }
        }
    }

    fun notice(text: String) = message(text)

    /** 当前视图（留在 ViewModel 里：打开笔记再回来仍在原处） */
    var view by mutableStateOf(TodoView.LIST)

    /** 正在查看的项目主页（项目关键词） */
    var openProject by mutableStateOf<String?>(null)

    /** 项目列表页：false 看进行中，true 看搁置 */
    var showPausedProjects by mutableStateOf(false)

    /** 从搜索页点进来要打开详情的任务 id；待办页消费后清空 */
    var pendingTask by mutableStateOf<String?>(null)

    private val _events = Channel<TodoEvent>(Channel.BUFFERED)
    val events: Flow<TodoEvent> = _events.receiveAsFlow()

    private var discovered = false

    init {
        // 以滴答任务内容里的「任务笔记：链接」为准，认回在其他设备上建的任务笔记
        viewModelScope.launch {
            data.collect { d ->
                val ov = d.overview ?: return@collect
                try {
                    container.projects.restoreTaskNotes(ov.overdue + ov.upcoming + ov.undated)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                }
            }
        }
    }

    fun refresh(force: Boolean = false) = container.todos.refresh(force)

    private fun message(text: String) {
        _events.trySend(TodoEvent.Message(text))
    }

    private fun fail(what: String, e: Throwable) = message("$what：${e.message ?: "网络异常"}")

    // ───────────── 任务操作 ─────────────

    fun complete(task: DidaTask) {
        viewModelScope.launch {
            container.todos.complete(task)
                .onSuccess {
                    _events.trySend(TodoEvent.Completed(task))
                    // 属于项目的任务完成后，自动在项目主页「里程碑与进展」记一行（进程级作用域，界面离开也要跑完）
                    container.appScope.launch { runCatching { container.projects.afterComplete(task, "") } }
                }
                .onFailure { fail("完成失败", it) }
        }
    }

    /** 完成并写复盘：有任务笔记就写进它的「复盘」，没有则单独存一条带 #复盘 标签的笔记 */
    fun completeWithReview(task: DidaTask, review: String) {
        viewModelScope.launch {
            container.todos.complete(task)
                .onSuccess {
                    val text = try {
                        container.projects.afterComplete(task, review)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        "已完成，但复盘没有保存：${e.message ?: "网络异常"}"
                    }
                    message(text)
                }
                .onFailure { fail("完成失败", it) }
        }
    }

    fun undoComplete(task: DidaTask) {
        viewModelScope.launch {
            container.todos.undoComplete(task)
                .onSuccess { container.appScope.launch { runCatching { container.projects.afterUndo(task) } } }
                .onFailure { fail("撤销失败", it) }
        }
    }

    fun reschedule(task: DidaTask, date: String, time: String?) {
        viewModelScope.launch {
            container.todos.reschedule(task, date, time).onFailure { fail("改期失败", it) }
        }
    }

    /** 把一批任务（通常是全部逾期）改到某一天，时间清空；失败的会单独提示 */
    fun rescheduleAll(tasks: List<DidaTask>, date: String) {
        viewModelScope.launch {
            var failed = 0
            tasks.forEach { t -> container.todos.reschedule(t, date, null).onFailure { failed++ } }
            message(if (failed == 0) "已把 ${tasks.size} 项改到今天" else "有 $failed 项没有改成功")
        }
    }

    fun setPriority(task: DidaTask, priority: Int) {
        viewModelScope.launch {
            container.todos.setPriority(task, priority).onFailure { fail("修改优先级失败", it) }
        }
    }

    /** 切换 `!重要` / `!紧急` 标记（直接写在待办标题里） */

    fun rename(task: DidaTask, title: String) {
        val clean = title.trim()
        if (clean.isEmpty() || clean == task.title) return
        viewModelScope.launch {
            container.todos.setTitle(task, clean).onFailure { fail("修改标题失败", it) }
        }
    }

    /** 归入项目：给任务加上项目关键词标签 */
    fun assignProject(task: DidaTask, keyword: String) {
        if (task.tags.any { it.equals(keyword, ignoreCase = true) }) return
        viewModelScope.launch {
            container.todos.setTags(task, task.tags + keyword)
                .onSuccess { message("已归入「$keyword」") }
                .onFailure { fail("归入项目失败", it) }
        }
    }

    fun delete(task: DidaTask) {
        viewModelScope.launch {
            container.todos.delete(task)
                .onSuccess { message("已删除") }
                .onFailure { fail("删除失败", it) }
        }
    }

    // ───────────── 任务笔记 ─────────────

    fun createTaskNote(task: DidaTask, deliverable: String, purpose: String, steps: String) {
        viewModelScope.launch {
            try {
                container.projects.createTaskNote(task, deliverable, purpose, steps)
                message("已创建任务笔记")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                fail("创建任务笔记失败", e)
            }
        }
    }

    fun addProgress(task: DidaTask?, noteId: String, text: String) {
        viewModelScope.launch {
            try {
                val synced = container.projects.addProgress(noteId, text, task)
                message(if (synced) "已记入任务笔记，并同步到滴答评论" else "已记入任务笔记")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                fail("保存失败", e)
            }
        }
    }

    // ───────────── 项目 ─────────────

    fun addProject(keyword: String, tags: List<String>): Boolean {
        val ok = container.projects.add(keyword, tags)
        message(if (ok) "已添加项目「${keyword.trim()}」" else "项目已存在或名称为空")
        if (ok) loadStats()
        return ok
    }

    fun removeProject(keyword: String) {
        container.projects.remove(keyword)
        if (openProject == keyword) openProject = null
        message("已移除项目「$keyword」（不会删除任何笔记）")
    }

    fun setStale(keyword: String, days: Int) = container.projects.setStaleDays(keyword, days)
    fun setStatus(keyword: String, status: ProjectStatus) = container.projects.setStatus(keyword, status)
    fun setNext(keyword: String, next: String) {
        container.projects.setNext(keyword, next)
        message("已更新「$keyword」的下一步")
    }

    fun setTags(keyword: String, tags: List<String>) {
        container.projects.setTags(keyword, tags)
        loadStats(force = true)
    }

    /** 逐个统计项目的提及情况（每个要检索多次，串行进行；6 小时内算过的不重复算） */
    fun loadStats(force: Boolean = false) {
        viewModelScope.launch {
            // 以笔记为准：先把闪念贝壳里已有的项目主页（比如桌面端建的）认回来，一次就够
            if (!discovered) {
                discovered = true
                try {
                    val n = container.projects.discoverProjects()
                    if (n > 0) message("从笔记里找到 $n 个项目")
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    discovered = false
                }
            }
            for (p in container.projects.projects) {
                val old = container.projects.stats.value[p.keyword]
                if (!force && old != null && System.currentTimeMillis() - old.at < STATS_TTL_MS) continue
                try {
                    container.projects.refreshStats(p)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    // 单个项目统计失败不影响其它
                }
            }
            // 成果交付进度（项目卡片上的环用它）：只读，不归档；任务列表还没读到时先不算
            val ov = container.todos.state.value.overview
            if (ov != null || !connected.value) {
                for (p in container.projects.projects) {
                    if (p.status == ProjectStatus.PAUSED || container.projects.taskNotesOf(p).isEmpty()) continue
                    val open = ov?.let { o -> (o.overdue + o.upcoming + o.undated).filter { p.matches(it.title, it.tags) }.map { it.id }.toSet() }.orEmpty()
                    val done = ov?.done.orEmpty().filter { p.matches(it.title, it.tags) }.map { it.id }.toSet()
                    try {
                        container.projects.refreshDelivery(p, open, done, archive = false)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Exception) {
                    }
                }
            }
        }
    }

    fun refreshStats(p: Project) {
        viewModelScope.launch {
            try {
                container.projects.refreshStats(p)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                fail("统计失败", e)
            }
        }
    }

    /** 统计项目的成果交付与专注（打开项目页时调用；统计不出来就保留上一次的结果，不打扰） */
    fun loadProjectProgress(p: Project, openIds: Set<String>, doneIds: Set<String>) {
        viewModelScope.launch {
            try {
                container.projects.refreshDelivery(p, openIds, doneIds)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
        }
        viewModelScope.launch {
            try {
                container.projects.refreshFocus(p, openIds + doneIds)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
        }
    }

    /** 统计项目近 12 个月每月的专注时长（打开「近 12 个月」抽屉时调用；统计不出来就保持原样） */
    fun loadMonthlyFocus(p: Project, taskIds: Set<String>) {
        viewModelScope.launch {
            try {
                container.projects.refreshMonthlyFocus(p, taskIds)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
        }
    }

    /**
     * 从项目页开始一次专注：[task] 可以不选（直接为项目专注）。已经有专注在进行时返回 false。
     * 记录的内容会写进项目主页的「里程碑与进展」。
     */
    fun startProjectFocus(p: Project, task: DidaTask?, minutes: Int): Boolean {
        val ok = container.focus.start(
            taskId = task?.id,
            projectId = task?.projectId,
            title = task?.title.orEmpty().ifBlank { "项目「${p.keyword}」" },
            minutes = minutes,
            project = p.keyword,
        )
        if (!ok) message("已经有一个专注在进行，先到专注页结束它")
        return ok
    }

    /** 项目「记一条」：保存为带项目标签的笔记；同名习惯自动打卡 */
    fun logToProject(p: Project, text: String) {
        viewModelScope.launch {
            try {
                val r = container.projects.log(p, text)
                message(if (r.habit != null) "已保存到「${p.keyword}」，并给习惯「${r.habit}」打卡" else "已保存到「${p.keyword}」")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                fail("保存失败", e)
            }
        }
    }

    // ───────────── 项目主页页面 ─────────────

    var homeText by mutableStateOf<String?>(null)
    val noteTexts = mutableStateMapOf<String, String>()
    var pageBusy by mutableStateOf(false)

    /** 读取项目主页笔记与最近的任务笔记正文（读到一条显示一条） */
    fun loadProjectPage(p: Project) {
        homeText = null
        noteTexts.clear()
        viewModelScope.launch {
            container.projects.resolveHome(p.keyword)?.let { id ->
                homeText = readNote(id)
            }
            container.projects.taskNotesOf(p).take(10).forEach { e ->
                launch { noteTexts[e.ref.noteId] = readNote(e.ref.noteId) }
            }
        }
    }

    private suspend fun readNote(id: String): String = try {
        container.notes.note(id, force = true).content.trim()
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        ""
    }

    /**
     * 往项目主页笔记的某个小节写内容：先改本机显示的正文（立刻看到），再同步到闪念贝壳里的那篇笔记；同步失败就还原并提示。
     * 笔记本身仍是一篇完整的笔记，这里只是把每个 `## 小节` 拆成不同的组件来读写。
     */
    fun saveHome(p: Project, section: String, mode: HomeEditMode, input: String) {
        val text = input.trim()
        if (text.isEmpty() && mode != HomeEditMode.REPLACE) return
        val fn: (String) -> String = { old ->
            val kept = old.lines().filterNot { NoteSections.isPlaceholderLine(it) }.joinToString("\n").trim()
            val gap = if (kept.isNotEmpty()) "\n" else ""
            when (mode) {
                HomeEditMode.REPLACE -> text
                HomeEditMode.LINK -> kept + gap + NoteSections.bullets(text)
                HomeEditMode.MILESTONE -> kept + gap + "- ${NoteSections.minuteStamp()} ${text.replace(Regex("\\s*\\n\\s*"), " ")}"
                HomeEditMode.REVIEW -> kept + (if (kept.isNotEmpty()) "\n\n" else "") + "${NoteSections.minuteStamp()}：$text"
            }
        }
        val before = homeText
        if (before != null) homeText = NoteSections.editSection(before, section, fn)
        viewModelScope.launch {
            try {
                container.projects.editHomeSection(p.keyword, section, fn)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                homeText = before
                fail("保存失败", e)
            }
        }
    }

    fun createHome(p: Project) {
        viewModelScope.launch {
            pageBusy = true
            try {
                container.projects.createHome(p)
                message("已创建项目主页笔记")
                loadProjectPage(p)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                fail("创建失败", e)
            } finally {
                pageBusy = false
            }
        }
    }

    fun refreshHome(p: Project) {
        viewModelScope.launch {
            pageBusy = true
            try {
                container.projects.refreshSummary(p)
                message("已更新项目主页的自动汇总")
                loadProjectPage(p)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                fail("更新失败", e)
            } finally {
                pageBusy = false
            }
        }
    }

    // ───────────── 习惯 ─────────────

    var habitUi by mutableStateOf(HabitUi())

    fun loadHabits(force: Boolean = false) {
        if (habitUi.loading) return
        habitUi = habitUi.copy(loading = true, error = null)
        viewModelScope.launch {
            habitUi = try {
                HabitUi(habits = container.habits.today(force), loaded = true)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                habitUi.copy(loading = false, error = e.message ?: "加载失败", loaded = true)
            }
        }
    }

    fun checkin(h: Habit) {
        // 乐观更新
        habitUi = habitUi.copy(habits = habitUi.habits.map { if (it.id == h.id) it.copy(doneToday = true) else it })
        viewModelScope.launch {
            try {
                container.habits.checkin(h)
                message("已打卡：${h.name}")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                habitUi = habitUi.copy(habits = habitUi.habits.map { if (it.id == h.id) it.copy(doneToday = false) else it })
                fail("打卡失败", e)
            }
        }
    }

    companion object {
        private const val STATS_TTL_MS = 6 * 3_600_000L

        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = this[APPLICATION_KEY] as IdeashellApp
                TodoViewModel(app.container)
            }
        }
    }
}
