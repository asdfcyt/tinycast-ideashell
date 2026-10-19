package com.carpe.ideashell.ui.todos

import com.carpe.ideashell.ui.glass.GlassButton
import com.carpe.ideashell.ui.glass.GlassOutlinedButton
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.data.dida.DidaOverview
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.project.ProjectStatus
import com.carpe.ideashell.data.project.TaskNoteEntry
import com.carpe.ideashell.data.project.firstMatching
import com.carpe.ideashell.data.project.taskKeyOf
import com.carpe.ideashell.ui.capture.QuickCaptureActivity
import com.carpe.ideashell.ui.components.AppSnackbarHost
import com.carpe.ideashell.ui.components.showTimed
import com.carpe.ideashell.ui.components.CircleIconButton
import com.carpe.ideashell.ui.components.EmptyNote
import com.carpe.ideashell.ui.components.GroupCard
import com.carpe.ideashell.ui.components.NoticeLine
import com.carpe.ideashell.ui.components.PillChip
import com.carpe.ideashell.ui.components.RowPill
import com.carpe.ideashell.ui.components.ScreenHeader
import com.carpe.ideashell.ui.components.SearchButton
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import com.carpe.ideashell.ui.theme.Brand
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.LocalDate
import kotlin.math.roundToInt

internal enum class Tone { OVERDUE, TODAY, NORMAL, MUTED }

/** 列表视图里的一组任务（逾期 / 某一天 / 收集箱 / 最近完成） */
private class TodoGroup(
    val key: String,
    val title: String,
    val count: Int,
    val tone: Tone,
    val tasks: List<DidaTask>,
    val done: Boolean = false,
    /** 没有日期的一组：行尾带「定日期」快捷菜单 */
    val quickDate: Boolean = false,
    /** 非空表示这一组可以折叠 */
    val onToggle: (() -> Unit)? = null,
    val expanded: Boolean = true,
    val moreLabel: String? = null,
    val onMore: (() -> Unit)? = null,
)

private val WEEK = arrayOf("一", "二", "三", "四", "五", "六", "日")

private fun LocalDate.label(): String = "${monthValue}月${dayOfMonth}日 周${WEEK[dayOfWeek.value - 1]}"

private val taskOrder = compareBy<DidaTask>({ it.date ?: "" }, { it.time ?: "" }, { -it.priority })

private fun buildGroups(
    overview: DidaOverview,
    today: LocalDate,
    showDone: Boolean,
    showAllUndated: Boolean,
    onToggleDone: () -> Unit,
    onToggleUndated: () -> Unit,
): List<TodoGroup> {
    val out = mutableListOf<TodoGroup>()
    val todayStr = today.toString()
    val overdue = overview.overdue.sortedWith(taskOrder)
    if (overdue.isNotEmpty()) out += TodoGroup("g:overdue", "已逾期", overdue.size, Tone.OVERDUE, overdue)

    overview.upcoming.sortedWith(taskOrder).groupBy { it.date!! }.toSortedMap().forEach { (dateStr, tasks) ->
        val d = LocalDate.parse(dateStr)
        val title = when (dateStr) {
            todayStr -> "今天 · ${d.label()}"
            today.plusDays(1).toString() -> "明天 · ${d.label()}"
            else -> d.label()
        }
        out += TodoGroup("g:$dateStr", title, tasks.size, if (dateStr == todayStr) Tone.TODAY else Tone.NORMAL, tasks)
    }

    val undated = overview.undated
    if (undated.isNotEmpty()) {
        val shown = if (showAllUndated) undated else undated.take(UNDATED_PREVIEW)
        out += TodoGroup(
            key = "g:undated",
            title = "无日期",
            count = undated.size,
            tone = Tone.MUTED,
            tasks = shown,
            quickDate = true,
            moreLabel = if (undated.size > UNDATED_PREVIEW) {
                if (showAllUndated) "收起" else "还有 ${undated.size - UNDATED_PREVIEW} 项，展开"
            } else {
                null
            },
            onMore = onToggleUndated,
        )
    }

    if (overview.done.isNotEmpty()) {
        out += TodoGroup(
            key = "g:done",
            title = "最近完成",
            count = overview.done.size,
            tone = Tone.MUTED,
            tasks = if (showDone) overview.done else emptyList(),
            done = true,
            onToggle = onToggleDone,
            expanded = showDone,
        )
    }
    return out
}

private const val UNDATED_PREVIEW = 5

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TodoScreen(
    onOpenConnection: () -> Unit,
    onOpenSearch: () -> Unit = {},
    onOpenNote: (String) -> Unit = {},
    onOpenFocus: () -> Unit = {},
    viewModel: TodoViewModel = viewModel(factory = TodoViewModel.Factory),
) {
    val data by viewModel.data.collectAsStateWithLifecycle()
    val connected by viewModel.connected.collectAsStateWithLifecycle()
    val didaConnected by viewModel.didaOn.collectAsStateWithLifecycle()
    val pendingCount by viewModel.pendingCount.collectAsStateWithLifecycle()
    val syncNotice by viewModel.syncNotice.collectAsStateWithLifecycle()
    val workspace by viewModel.workspace.collectAsStateWithLifecycle()
    val stats by viewModel.stats.collectAsStateWithLifecycle()
    val delivery by viewModel.delivery.collectAsStateWithLifecycle()
    val focusStats by viewModel.focusStats.collectAsStateWithLifecycle()
    // 日历视图里读到的更远日期的任务：点开它们的详情时要用
    val ranged by viewModel.ranged.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val snackbar = remember { SnackbarHostState() }
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    // 最近完成里的任务如果有成果小票，点开先看小票（里面还能进任务详情）
    val tickets = remember { (context.applicationContext as com.carpe.ideashell.IdeashellApp).container.tickets }
    var ticket by remember { mutableStateOf<com.carpe.ideashell.data.focus.Celebration?>(null) }
    var addingProject by remember { mutableStateOf(false) }
    var overdueOpen by rememberSaveable { mutableStateOf(false) }
    val overview = data.overview
    val view = viewModel.view

    LifecycleResumeEffect(connected) {
        if (connected) viewModel.refresh()
        onPauseOrDispose { }
    }

    // 任务页下方的项目卡，以及完整的项目 / 习惯页，要用到这两份数据
    LaunchedEffect(view, connected) {
        if (view == TodoView.PROJECTS || view == TodoView.LIST) viewModel.loadStats()
        if (view == TodoView.HABITS && didaConnected && !viewModel.habitUi.loaded) viewModel.loadHabits()
    }

    // 从搜索页点进来的任务：切到列表并直接打开详情
    LaunchedEffect(viewModel.pendingTask) {
        viewModel.pendingTask?.let {
            viewModel.openProject = null
            viewModel.view = TodoView.LIST
            selectedId = it
            viewModel.pendingTask = null
        }
    }

    LaunchedEffect(Unit) {
        viewModel.events.collect { event ->
            snackbar.currentSnackbarData?.dismiss()
            when (event) {
                is TodoEvent.Message -> launch { snackbar.showSnackbar(event.text) }
                is TodoEvent.Completed -> launch {
                    val result = snackbar.showTimed(
                        message = "已完成「${TodoMeta.cleanTitle(event.task.title).take(14)}」",
                        actionLabel = "撤销",
                    )
                    if (result == SnackbarResult.ActionPerformed) viewModel.undoComplete(event.task)
                }
            }
        }
    }

    val today = remember(overview) { LocalDate.now() }
    val groups = remember(overview, viewModel.showDone, viewModel.showAllUndated) {
        if (overview == null) {
            emptyList()
        } else {
            buildGroups(
                overview, today, viewModel.showDone, viewModel.showAllUndated,
                onToggleDone = { viewModel.showDone = !viewModel.showDone },
                onToggleUndated = { viewModel.showAllUndated = !viewModel.showAllUndated },
            )
        }
    }

    val ctx = remember(overview, today, workspace, ranged) {
        overview?.let {
            TodoCtx(
                overview = it,
                today = today,
                workspace = workspace,
                onToggle = { t -> if (t.done) viewModel.undoComplete(t) else viewModel.complete(t) },
                onOpen = { t -> selectedId = t.id },
                onReschedule = { t, date, time -> viewModel.reschedule(t, date, time) },
                ranged = ranged,
            )
        }
    }

    val briefs = remember(workspace, stats, ctx, today, delivery) { briefsOf(workspace.projects, stats, ctx, today, delivery) }

    // 完整的项目 / 习惯页按返回键，回到任务页
    BackHandler(enabled = view != TodoView.LIST && viewModel.openProject == null) { viewModel.view = TodoView.LIST }

    val openKey = viewModel.openProject
    val openedProject = openKey?.let { k -> workspace.projects.firstOrNull { it.keyword == k } }
    BackHandler(enabled = openKey != null) { viewModel.openProject = null }
    if (openKey != null && openedProject == null) {
        LaunchedEffect(openKey) { viewModel.openProject = null }
    }

    // 任务 ⇄ 日历的展开进度（0 = 任务，1 = 日历）：手势拖动时跟手，菜单 / 返回键 / 点小横条时自动滑过去
    val revealScope = rememberCoroutineScope()
    val wantCalendar = view == TodoView.CALENDAR && connected
    val reveal = remember { CalendarReveal(if (wantCalendar) 1f else 0f, revealScope) }
    reveal.travel = with(LocalDensity.current) { 320.dp.toPx() }
    LaunchedEffect(wantCalendar) { if (!reveal.dragging && reveal.target != wantCalendar) reveal.settle(wantCalendar) }
    // 进待办页稍等一下，在后台把当前月的日历数据预热好
    LaunchedEffect(connected, overview != null) {
        if (connected && overview != null) {
            delay(1_200)
            viewModel.warmCalendar()
        }
    }
    val listVisible by remember { derivedStateOf { reveal.progress < 0.999f } }
    val calVisible by remember { derivedStateOf { reveal.progress > 0.001f } }
    fun finishReveal(open: Boolean) {
        if (open) viewModel.view = TodoView.CALENDAR else if (viewModel.view == TodoView.CALENDAR) viewModel.view = TodoView.LIST
    }

    // 日历里点某一天浮出面板时，标题栏跟着日历一起磨砂（和底部弹出面板一样整页变糊）
    val calSheetHost = remember { CalSheetHost() }
    // 磨砂强度 = 统一强度 × 面板升起进度 × （拖任务改期时淡出）
    val dragFade by animateFloatAsState(if (calSheetHost.blurred) 1f else 0f, label = "pageBlurFade")
    val pageBlur = with(LocalDensity.current) {
        (com.carpe.ideashell.ui.glass.SheetBlurPx * calSheetHost.progress * dragFade).toDp()
    }

    Scaffold(
        containerColor = Color.Transparent,
        contentWindowInsets = WindowInsets.statusBars,
        snackbarHost = { AppSnackbarHost(snackbar, Modifier.padding(bottom = LocalBottomBarPadding.current)) },
    ) { padding ->
        Box(Modifier.fillMaxSize()) {
        if (openedProject != null) {
            Box(Modifier.padding(padding)) {
                ProjectPage(
                    project = openedProject,
                    viewModel = viewModel,
                    stats = stats[openedProject.keyword],
                    delivery = delivery[openedProject.keyword],
                    focusStats = focusStats[openedProject.keyword],
                    ctx = ctx,
                    homeId = workspace.homes[openedProject.keyword],
                    taskNotes = remember(workspace, openedProject) {
                        val terms = openedProject.terms.map { it.lowercase() }
                        workspace.taskNotes.entries
                            .filter { (_, r) -> !r.archived && r.project != null && r.project.lowercase() in terms }
                            .map { TaskNoteEntry(it.key, it.value) }
                            .sortedByDescending { it.ref.createdAt }
                    },
                    onBack = { viewModel.openProject = null },
                    onOpenNote = onOpenNote,
                    onOpenFocus = onOpenFocus,
                    onProgress = { task, noteId, text -> viewModel.addProgress(task, noteId, text) },
                )
            }
        } else Column(
            // 整页（标题栏 + 日历）一起磨砂，面板画在它外面（CalSheetLayer），所以面板自己不会糊
            Modifier
                .then(if (pageBlur > 0.dp) Modifier.blur(pageBlur) else Modifier)
                .padding(padding),
        ) {
            ScreenHeader(
                title = if (view == TodoView.LIST) "待办" else view.label,
                action = {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        // 在看别的日子的时间轴时，一键回到今天
                        val picked = viewModel.day
                        if (view == TodoView.LIST && picked != null && picked != today) {
                            TodayButton(onClick = { viewModel.day = null })
                        }
                        if (view != TodoView.LIST) {
                            CircleIconButton(Icons.AutoMirrored.Filled.ArrowBack, "返回待办", onClick = { viewModel.view = TodoView.LIST })
                        }
                        if (view == TodoView.PROJECTS) {
                            CircleIconButton(
                                Icons.Filled.Add, "新增项目", onClick = { addingProject = true },
                                container = Brand.Orange, content = Brand.Brown,
                            )
                        }
                        SearchButton(onOpenSearch)
                        ViewMenuButton(
                            view = view,
                            onSelectView = { viewModel.view = it },
                        )
                    }
                },
            )

            // 任务 ⇄ 日历：进度跟着手指走（往下拖，日历从标题栏下面落下来；往上推，收回去），松手后顺势滑完
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .clipToBounds(),
            ) {
            if (listVisible) Box(
                Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        val p = reveal.progress
                        alpha = (1f - p * 1.6f).coerceIn(0f, 1f)
                        translationY = p * reveal.travel * 0.18f
                    },
            ) {
            PullToRefreshBox(
                isRefreshing = (data.loading && overview != null) || (view == TodoView.HABITS && viewModel.habitUi.loading && viewModel.habitUi.habits.isNotEmpty()),
                onRefresh = {
                    viewModel.refresh(force = true)
                    if (view == TodoView.HABITS && didaConnected) viewModel.loadHabits(force = true)
                    if (view == TodoView.PROJECTS) viewModel.loadStats(force = true)
                },
                modifier = Modifier.fillMaxSize(),
            ) {
                LazyColumn(
                    contentPadding = PaddingValues(
                        start = 16.dp, end = 16.dp, top = 4.dp,
                        bottom = LocalBottomBarPadding.current + 8.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    when {
                        view == TodoView.PROJECTS -> projectsSection(
                            briefs = briefs,
                            showPaused = viewModel.showPausedProjects,
                            onShowPaused = { viewModel.showPausedProjects = it },
                            onAdd = { addingProject = true },
                            onOpen = { viewModel.openProject = it },
                        )

                        !connected -> item(key = "connect") {
                            EmptyNote(
                                title = "先连接滴答清单",
                                text = "待办来自滴答清单。填入滴答 API 口令后，这里会显示逾期、今天和未来 7 天的任务，点一下就能完成。也可以在「设置 → 日历同步」里把系统日历的事件读进来。",
                                action = { GlassButton(onClick = onOpenConnection) { Text("去连接") } },
                            )
                        }

                        view == TodoView.HABITS && !didaConnected -> item(key = "habit-connect") {
                            EmptyNote(
                                title = "习惯来自滴答清单",
                                text = "连接滴答清单后，这里可以查看并打卡今天的习惯。",
                                action = { GlassButton(onClick = onOpenConnection) { Text("去连接") } },
                            )
                        }

                        view == TodoView.HABITS -> habitsSection(
                            ui = viewModel.habitUi,
                            onRefresh = { viewModel.loadHabits(force = true) },
                            onCheckin = { viewModel.checkin(it) },
                        )

                        overview == null || ctx == null -> item(key = "first-load") {
                            if (data.error != null) {
                                EmptyNote(
                                    title = "没能加载待办",
                                    text = data.error.orEmpty(),
                                    action = { GlassOutlinedButton(onClick = { viewModel.refresh(force = true) }) { Text("重试") } },
                                )
                            } else {
                                Box(Modifier.fillMaxWidth().padding(vertical = 56.dp), contentAlignment = Alignment.Center) {
                                    CircularProgressIndicator()
                                }
                            }
                        }

                        else -> {
                            data.error?.let { err -> item(key = "stale") { NoticeLine(err) } }
                            overview.warning?.let { w -> item(key = "warn") { NoticeLine(w) } }
                            if (pendingCount > 0) {
                                item(key = "pending") { NoticeLine("有 $pendingCount 项修改还没同步到滴答，联网后会自动提交") }
                            }
                            syncNotice?.let { n -> item(key = "sync-notice") { NoticeLine(n) } }
                            val openCount = overview.overdue.size + overview.upcoming.size + overview.undated.size
                            // 日期带可以往前翻 PAST_DAYS 天、往后看一周；过去的日子读滴答里那天完成 / 到期的任务
                            val day = viewModel.day?.takeIf { it >= today.minusDays(PAST_DAYS.toLong()) && it <= today.plusDays(6) } ?: today
                            val isToday = day == today
                            val isPast = day < today
                            val overdue = overview.overdue.sortedWith(taskOrder)
                            val dayTasks = overview.upcoming.filter { it.date == day.toString() }

                            item(key = "week") {
                                CalendarStrip(
                                    today = today,
                                    selected = day,
                                    counts = overview.upcoming.groupingBy { it.date.orEmpty() }.eachCount(),
                                    onSelect = {
                                        viewModel.day = it
                                        if (it < today) viewModel.loadPast(it)
                                    },
                                    // 往下拉 / 点小横条：进入日历视图，项目、最近完成和当天的安排都收起
                                    onExpand = {
                                        viewModel.calMonth = java.time.YearMonth.from(day)
                                        viewModel.view = TodoView.CALENDAR
                                    },
                                    onDragStart = {
                                        viewModel.calMonth = java.time.YearMonth.from(day)
                                        reveal.dragStart()
                                    },
                                    onDragBy = { reveal.dragBy(it) },
                                    onDragStop = { v -> finishReveal(reveal.release(v)) },
                                )
                            }
                            if (isPast) {
                                val state = viewModel.past[day]
                                val list = state?.tasks
                                item(key = "past-$day") {
                                    LaunchedEffect(day) { viewModel.loadPast(day) }
                                    when {
                                        list == null && state?.error != null -> EmptyNote(
                                            title = "没能读到这一天",
                                            text = state.error.orEmpty(),
                                            action = { GlassOutlinedButton(onClick = { viewModel.loadPast(day, force = true) }) { Text("重试") } },
                                        )

                                        list == null -> Box(Modifier.fillMaxWidth().padding(vertical = 40.dp), contentAlignment = Alignment.Center) {
                                            CircularProgressIndicator()
                                        }

                                        list.isEmpty() -> Text(
                                            "这天没有记录",
                                            style = MaterialTheme.typography.bodyMedium,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            modifier = Modifier.padding(start = 8.dp, top = 8.dp, bottom = 8.dp),
                                        )

                                        else -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                            val doneN = list.count { it.done }
                                            Text(
                                                "${day.monthValue}月${day.dayOfMonth}日 · 完成 $doneN" + if (list.size > doneN) " · 未完成 ${list.size - doneN}" else "",
                                                style = MaterialTheme.typography.labelMedium,
                                                fontWeight = FontWeight.Bold,
                                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                modifier = Modifier.padding(start = 8.dp),
                                            )
                                            DayTimeline(tasks = list, isToday = false) { t ->
                                                TaskRow(
                                                    task = t,
                                                    tone = if (t.done) Tone.NORMAL else Tone.OVERDUE,
                                                    done = t.done,
                                                    project = listNameOf(overview, t.projectId),
                                                    today = today,
                                                    badges = badgesOf(t, workspace),
                                                    onToggle = { viewModel.togglePast(t, day) },
                                                    onOpen = { selectedId = t.id },
                                                    showWhen = false,
                                                )
                                            }
                                        }
                                    }
                                }
                            } else if (openCount == 0) {
                                item(key = "empty") {
                                    EmptyNote("都做完了", "逾期、今天和未来 7 天都没有待办。下拉可以刷新，向右滑动上面的日期带可以回顾过去。")
                                }
                            } else {
                                if (overdue.isNotEmpty()) {
                                    item(key = "overdue") {
                                        OverdueBanner(
                                            count = overdue.size,
                                            earliest = overdue.firstOrNull()?.date?.let { runCatching { LocalDate.parse(it) }.getOrNull() },
                                            expanded = overdueOpen,
                                            onToggle = { overdueOpen = !overdueOpen },
                                            onReschedule = { viewModel.rescheduleAll(overdue, today.toString()) },
                                        )
                                    }
                                    if (overdueOpen) {
                                        item(key = "overdue-list") {
                                            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                                overdue.forEach { t ->
                                                    TaskRow(
                                                        task = t,
                                                        tone = Tone.OVERDUE,
                                                        done = false,
                                                        project = listNameOf(overview, t.projectId),
                                                        today = today,
                                                        badges = badgesOf(t, workspace),
                                                        onToggle = { viewModel.complete(t) },
                                                        onOpen = { selectedId = t.id },
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }

                                item(key = "timeline-$day") {
                                    if (dayTasks.isEmpty()) {
                                        Text(
                                            if (isToday) "今天没有安排" else "这天没有安排",
                                            style = MaterialTheme.typography.bodyMedium,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            modifier = Modifier.padding(start = 8.dp, top = 8.dp, bottom = 8.dp),
                                        )
                                    } else {
                                        DayTimeline(tasks = dayTasks, isToday = isToday) { t ->
                                            TaskRow(
                                                task = t,
                                                tone = if (isToday) Tone.TODAY else Tone.NORMAL,
                                                done = false,
                                                project = listNameOf(overview, t.projectId),
                                                today = today,
                                                badges = badgesOf(t, workspace),
                                                onToggle = { viewModel.complete(t) },
                                                onOpen = { selectedId = t.id },
                                                showWhen = false,
                                            )
                                        }
                                    }
                                }
                            }
                            // 项目：排在「无日期」后面（最近完成之前），只在看「今天」时出现
                            var extrasShown = false
                            val emitExtras: LazyListScope.() -> Unit = {
                                if (briefs.any { it.project.status != ProjectStatus.PAUSED }) {
                                    item(key = "project-strip") {
                                        ProjectStrip(
                                            briefs = briefs,
                                            onOpen = { viewModel.openProject = it },
                                            onAll = { viewModel.view = TodoView.PROJECTS },
                                        )
                                    }
                                }
                            }
                            // 无日期 / 最近完成：只在「今天」这一天的下方出现
                            groups.filter { g ->
                                (g.key == "g:undated" || g.key == "g:done") &&
                                    (viewModel.day == null || viewModel.day == today)
                            }.forEach { g ->
                                if (g.key == "g:done" && !extrasShown) {
                                    extrasShown = true
                                    emitExtras()
                                }
                                item(key = g.key) {
                                    TodoGroupBlock(
                                        group = g,
                                        modifier = Modifier.animateItem(),
                                        row = { t ->
                                            val quickDate: (@Composable () -> Unit)? = if (g.quickDate) {
                                                { QuickDateMenu(today) { date -> viewModel.reschedule(t, date.toString(), null) } }
                                            } else {
                                                null
                                            }
                                            TaskRow(
                                                task = t,
                                                tone = g.tone,
                                                done = g.done,
                                                project = listNameOf(overview, t.projectId),
                                                today = today,
                                                badges = badgesOf(t, workspace),
                                                onToggle = { if (g.done) viewModel.undoComplete(t) else viewModel.complete(t) },
                                                onOpen = {
                                                    val tk = if (g.done) tickets.forTask(t.id) else null
                                                    if (tk != null) ticket = tk else selectedId = t.id
                                                },
                                                trailing = quickDate,
                                            )
                                        },
                                    )
                                }
                            }
                            if (isToday && !extrasShown) emitExtras()
                        }
                    }
                }
            }
            }
            if (calVisible) CalendarPage(
                viewModel = viewModel,
                overview = overview,
                today = today,
                workspace = workspace,
                onOpenTask = { t -> selectedId = t.id },
                onOpenDay = { d ->
                    viewModel.day = d
                    if (d < today) viewModel.loadPast(d)
                    viewModel.view = TodoView.LIST
                },
                onAddOnDay = { d -> context.startActivity(QuickCaptureActivity.intent(context, d)) },
                onCollapse = { viewModel.view = TodoView.LIST },
                sheetHost = calSheetHost,
                onDragStart = { reveal.dragStart() },
                onDragBy = { reveal.dragBy(it) },
                onDragStop = { v -> finishReveal(reveal.release(v)) },
                modifier = Modifier
                    .fillMaxSize()
                    .offset { IntOffset(0, (-(1f - reveal.progress) * reveal.travel).roundToInt()) }
                    .graphicsLayer { alpha = (reveal.progress * 1.6f).coerceIn(0f, 1f) },
            )
            }
        }
        CalSheetLayer(calSheetHost)
        }
    }

    if (addingProject) {
        AddProjectDialog(
            onDismiss = { addingProject = false },
            onConfirm = { keyword, tags ->
                addingProject = false
                viewModel.addProject(keyword, tags)
            },
        )
    }

    ticket?.let { tk ->
        com.carpe.ideashell.ui.components.TicketDialog(
            c = tk,
            onDismiss = { ticket = null },
            onDetail = tk.taskId?.let { id -> { selectedId = id } },
        )
    }

    val selected = selectedId?.let { id ->
        overview?.let { o -> o.findOpen(id) ?: o.done.firstOrNull { it.id == id } }
            ?: ranged.values.firstOrNull { it.id == id && !it.done }
            ?: ranged.values.firstOrNull { it.id == id }
    }
    if (selected != null && overview != null) {
        TaskSheet(
            task = selected,
            listName = listNameOf(overview, selected.projectId),
            today = today,
            projects = workspace.projects,
            currentProject = workspace.projects.firstMatching(selected.title, selected.tags),
            note = workspace.taskNotes[taskKeyOf(selected.id)],
            actions = TaskSheetActions(
                onComplete = {
                    selectedId = null
                    if (selected.done) viewModel.undoComplete(selected) else viewModel.complete(selected)
                },
                onCompleteWithReview = { review ->
                    selectedId = null
                    viewModel.completeWithReview(selected, review)
                },
                onReschedule = { date, time -> viewModel.reschedule(selected, date, time) },
                onPriority = { viewModel.setPriority(selected, it) },
                onRename = { viewModel.rename(selected, it) },
                onAssignProject = { viewModel.assignProject(selected, it) },
                onDelete = {
                    selectedId = null
                    viewModel.delete(selected)
                },
                onCreateNote = { d, p, s -> viewModel.createTaskNote(selected, d, p, s) },
                onOpenNote = {
                    selectedId = null
                    onOpenNote(it)
                },
                onProgress = { noteId, text -> viewModel.addProgress(selected, noteId, text) },
            ),
            onDismiss = { selectedId = null },
            onOpenFocus = onOpenFocus,
        )
    } else if (selectedId != null && overview != null) {
        // 任务已不在列表里（例如刚完成），收起详情
        LaunchedEffect(selectedId) { selectedId = null }
    }
}

// ───────────────────────── 分组 ─────────────────────────

@Composable
private fun TodoGroupBlock(
    group: TodoGroup,
    modifier: Modifier = Modifier,
    row: @Composable (DidaTask) -> Unit,
) {
    val color = when (group.tone) {
        Tone.OVERDUE -> MaterialTheme.colorScheme.error
        else -> MaterialTheme.colorScheme.onSurface
    }
    GroupCard(
        title = group.title,
        modifier = modifier,
        count = group.count,
        titleColor = color,
        expanded = group.expanded || group.onToggle == null,
        onToggle = group.onToggle,
        content = if (group.tasks.isNotEmpty()) {
            {
                group.tasks.forEach { t -> row(t) }
                if (group.moreLabel != null && group.onMore != null) {
                    TextButton(onClick = group.onMore, modifier = Modifier.fillMaxWidth()) { Text(group.moreLabel) }
                }
            }
        } else {
            null
        },
    )
}

// ───────────────────────── 任务行 ─────────────────────────

/**
 * 任务行：圆圈 + 标题 + 一行弱化的说明（时间 / 标记 / 清单 / 标签）。
 * [pill] 为 true（默认）时自己是一条胶囊——逾期任务反白成深棕胶囊；为 false 时只是一行，由外层 [ListGroup] 统一包裹。
 */
@Composable
internal fun TaskRow(
    task: DidaTask,
    tone: Tone,
    done: Boolean,
    project: String,
    today: LocalDate,
    badges: List<String>,
    onToggle: () -> Unit,
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
    /** 行尾的额外操作（例如「无日期」分组里的「定日期」菜单） */
    trailing: (@Composable () -> Unit)? = null,
    pill: Boolean = true,
    /** 在说明行里写时间 / 日期；放在时间轴上时时间已经在左边，传 false */
    showWhen: Boolean = true,
) {
    val scope = rememberCoroutineScope()
    var checked by remember(task.id) { mutableStateOf(false) }
    val showDone = done || checked
    val scheme = MaterialTheme.colorScheme
    val dark = pill && tone == Tone.OVERDUE && !showDone
    val titleColor = if (dark) scheme.inverseOnSurface else scheme.onSurface
    val supportColor = if (dark) scheme.inverseOnSurface.copy(alpha = 0.72f) else scheme.onSurfaceVariant
    val hot = if (dark) Brand.Orange else scheme.error

    val whenText = when {
        !showWhen -> null
        task.date == null -> null
        tone == Tone.OVERDUE -> LocalDate.parse(task.date).let { "${it.monthValue}月${it.dayOfMonth}日" } + (timeTextOf(task)?.let { " $it" } ?: "")
        else -> timeTextOf(task) ?: "全天"
    }
    val support = buildAnnotatedString {
        var first = true
        fun sep() {
            if (!first) append("  ·  ")
            first = false
        }
        if (whenText != null) {
            sep()
            withStyle(SpanStyle(color = if (tone == Tone.OVERDUE) hot else scheme.primary)) { append(whenText) }
        }
        badges.forEach { b ->
            sep()
            withStyle(SpanStyle(color = supportColor)) { append(b) }
        }
        if (project.isNotEmpty()) {
            sep()
            append(project)
        }
        task.location?.let { loc ->
            sep()
            append(loc)
        }
        task.tags.take(2).forEach { t ->
            sep()
            append("#$t")
        }
    }

    val content: @Composable () -> Unit = {
        Row(
            modifier = (if (pill) Modifier else modifier.clickable(onClick = onOpen))
                .fillMaxWidth()
                .padding(start = 4.dp, end = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CheckCircle(task.priority, showDone, dark) {
                if (done) {
                    onToggle()
                } else if (!checked) {
                    checked = true
                    scope.launch {
                        delay(360)
                        onToggle()
                    }
                }
            }
            Column(Modifier.weight(1f).padding(vertical = 12.dp, horizontal = 4.dp)) {
                Text(
                    TodoMeta.cleanTitle(task.title),
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = if (showDone) FontWeight.Normal else FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    textDecoration = if (showDone) TextDecoration.LineThrough else null,
                    color = if (showDone) titleColor.copy(alpha = 0.5f) else titleColor,
                )
                if (support.isNotEmpty()) {
                    Text(
                        support,
                        style = MaterialTheme.typography.labelMedium,
                        color = supportColor,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            trailing?.invoke()
        }
    }

    if (pill) RowPill(modifier, dark, onOpen, content) else content()
}

private fun priorityColor(priority: Int, fallback: Color): Color = when {
    priority >= 5 -> Color(0xFFE5484D)
    priority >= 3 -> Color(0xFFF5A524)
    priority >= 1 -> Color(0xFF3E8BFF)
    else -> fallback
}

@Composable
private fun CheckCircle(priority: Int, done: Boolean, dark: Boolean, onClick: () -> Unit) {
    val base = if (dark) MaterialTheme.colorScheme.inverseOnSurface else MaterialTheme.colorScheme.onSurfaceVariant
    val ring = priorityColor(priority, base.copy(alpha = 0.55f))
    val fill by animateFloatAsState(if (done) 1f else 0f, label = "check-fill")
    Box(
        modifier = Modifier
            .size(48.dp)
            .clip(CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(24.dp)
                .clip(CircleShape)
                .background(ring.copy(alpha = fill))
                .border(2.dp, ring, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (fill > 0.05f) {
                Icon(Icons.Filled.Check, contentDescription = "已完成", tint = Color.White, modifier = Modifier.size(16.dp))
            }
        }
    }
}
