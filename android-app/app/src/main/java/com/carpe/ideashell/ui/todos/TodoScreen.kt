package com.carpe.ideashell.ui.todos

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
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
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
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.data.dida.DidaOverview
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.project.TaskNoteEntry
import com.carpe.ideashell.data.project.firstMatching
import com.carpe.ideashell.data.project.taskKeyOf
import com.carpe.ideashell.ui.capture.QuickCaptureActivity
import com.carpe.ideashell.ui.components.DividedRows
import com.carpe.ideashell.ui.components.EmptyNote
import com.carpe.ideashell.ui.components.GroupLabel
import com.carpe.ideashell.ui.components.ListGroup
import com.carpe.ideashell.ui.components.NoticeLine
import com.carpe.ideashell.ui.components.RowDivider
import com.carpe.ideashell.ui.components.ScreenHeader
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.LocalDate

internal enum class Tone { OVERDUE, TODAY, NORMAL, MUTED }

/** 列表视图里的一组任务（逾期 / 某一天 / 收集箱 / 最近完成） */
private class TodoGroup(
    val key: String,
    val title: String,
    val count: Int,
    val tone: Tone,
    val tasks: List<DidaTask>,
    val done: Boolean = false,
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

    if (overview.undated.isNotEmpty()) {
        val shown = if (showAllUndated) overview.undated else overview.undated.take(UNDATED_PREVIEW)
        out += TodoGroup(
            key = "g:undated",
            title = "无日期 · 收集箱",
            count = overview.undated.size,
            tone = Tone.MUTED,
            tasks = shown,
            moreLabel = if (overview.undated.size > UNDATED_PREVIEW) {
                if (showAllUndated) "收起" else "还有 ${overview.undated.size - UNDATED_PREVIEW} 项，展开"
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

/** 标题下方那一行：只写有的事实，不堆砌 */
private fun summaryOf(overview: DidaOverview, today: LocalDate): String {
    val todayStr = today.toString()
    val parts = buildList {
        if (overview.overdue.isNotEmpty()) add("逾期 ${overview.overdue.size}")
        val t = overview.upcoming.count { it.date == todayStr }
        if (t > 0) add("今天 $t")
        val f = overview.upcoming.count { it.date != todayStr }
        if (f > 0) add("未来 7 天 $f")
    }
    return if (parts.isEmpty()) "${today.label()} · 没有待办" else parts.joinToString(" · ")
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TodoScreen(
    onOpenConnection: () -> Unit,
    onOpenNote: (String) -> Unit = {},
    onOpenDossier: (String) -> Unit = {},
    viewModel: TodoViewModel = viewModel(factory = TodoViewModel.Factory),
) {
    val data by viewModel.data.collectAsStateWithLifecycle()
    val connected by viewModel.connected.collectAsStateWithLifecycle()
    val workspace by viewModel.workspace.collectAsStateWithLifecycle()
    val stats by viewModel.stats.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val snackbar = remember { SnackbarHostState() }
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    var addingProject by remember { mutableStateOf(false) }
    val overview = data.overview
    val view = viewModel.view

    LifecycleResumeEffect(connected) {
        if (connected) viewModel.refresh()
        onPauseOrDispose { }
    }

    // 进入「项目 / 习惯」视图时再加载对应数据
    LaunchedEffect(view, connected) {
        if (view == TodoView.PROJECTS) viewModel.loadStats()
        if (view == TodoView.HABITS && connected && !viewModel.habitUi.loaded) viewModel.loadHabits()
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
                    val result = snackbar.showSnackbar(
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

    val ctx = remember(overview, today, workspace) {
        overview?.let {
            TodoCtx(
                overview = it,
                today = today,
                workspace = workspace,
                onToggle = { t -> if (t.done) viewModel.undoComplete(t) else viewModel.complete(t) },
                onOpen = { t -> selectedId = t.id },
                onReschedule = { t, date, time -> viewModel.reschedule(t, date, time) },
            )
        }
    }

    val openKey = viewModel.openProject
    val openedProject = openKey?.let { k -> workspace.projects.firstOrNull { it.keyword == k } }
    BackHandler(enabled = openKey != null) { viewModel.openProject = null }
    if (openKey != null && openedProject == null) {
        LaunchedEffect(openKey) { viewModel.openProject = null }
    }

    Scaffold(
        containerColor = Color.Transparent,
        contentWindowInsets = WindowInsets.statusBars,
        snackbarHost = { SnackbarHost(snackbar, Modifier.padding(bottom = LocalBottomBarPadding.current)) },
    ) { padding ->
        if (openedProject != null) {
            Box(Modifier.padding(padding)) {
                ProjectPage(
                    project = openedProject,
                    viewModel = viewModel,
                    stats = stats[openedProject.keyword],
                    ctx = ctx,
                    homeId = workspace.homes[openedProject.keyword],
                    taskNotes = remember(workspace, openedProject) {
                        val terms = openedProject.terms.map { it.lowercase() }
                        workspace.taskNotes.entries
                            .filter { (_, r) -> r.project != null && r.project.lowercase() in terms }
                            .map { TaskNoteEntry(it.key, it.value) }
                            .sortedByDescending { it.ref.createdAt }
                    },
                    onBack = { viewModel.openProject = null },
                    onOpenNote = onOpenNote,
                    onOpenDossier = onOpenDossier,
                    onProgress = { task, noteId, text -> viewModel.addProgress(task, noteId, text) },
                )
            }
        } else Column(Modifier.padding(padding)) {
            ScreenHeader(
                title = "待办",
                subtitle = if (overview != null && view == TodoView.LIST) summaryOf(overview, today) else today.label(),
                action = {
                    FilledTonalIconButton(
                        onClick = {
                            context.startActivity(
                                Intent(context, QuickCaptureActivity::class.java).apply {
                                    action = QuickCaptureActivity.ACTION_QUICK_CAPTURE
                                    putExtra(QuickCaptureActivity.EXTRA_KIND, "TODO")
                                },
                            )
                        },
                    ) { Icon(Icons.Filled.Add, contentDescription = "新建待办") }
                },
            )
            ViewTabs(view) { viewModel.view = it }

            PullToRefreshBox(
                isRefreshing = (data.loading && overview != null) || (view == TodoView.HABITS && viewModel.habitUi.loading && viewModel.habitUi.habits.isNotEmpty()),
                onRefresh = {
                    viewModel.refresh(force = true)
                    if (view == TodoView.HABITS) viewModel.loadHabits(force = true)
                    if (view == TodoView.PROJECTS) viewModel.loadStats(force = true)
                },
                modifier = Modifier.weight(1f),
            ) {
                LazyColumn(
                    contentPadding = PaddingValues(
                        start = 16.dp, end = 16.dp, top = 4.dp,
                        bottom = LocalBottomBarPadding.current + 8.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    when {
                        view == TodoView.PROJECTS -> projectsSection(
                            projects = workspace.projects,
                            stats = stats,
                            ctx = ctx,
                            today = today,
                            onAdd = { addingProject = true },
                            onOpen = { viewModel.openProject = it },
                        )

                        !connected -> item(key = "connect") {
                            EmptyNote(
                                title = "先连接滴答清单",
                                text = "待办来自滴答清单。填入滴答 API 口令后，这里会显示逾期、今天和未来 7 天的任务，点一下就能完成。",
                                action = { Button(onClick = onOpenConnection) { Text("去连接") } },
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
                                    action = { OutlinedButton(onClick = { viewModel.refresh(force = true) }) { Text("重试") } },
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
                            when (view) {
                                TodoView.QUADRANT -> quadrantSection(ctx)
                                TodoView.INBOX -> inboxSection(ctx)
                                else -> {
                                    if (overview.overdue.isEmpty() && overview.upcoming.isEmpty() && overview.undated.isEmpty()) {
                                        item(key = "empty") {
                                            EmptyNote("都做完了", "逾期、今天和未来 7 天都没有待办。下拉可以刷新。")
                                        }
                                    }
                                    groups.forEach { g ->
                                        item(key = g.key) {
                                            TodoGroupBlock(
                                                group = g,
                                                modifier = Modifier.animateItem(),
                                                row = { t ->
                                                    TaskRow(
                                                        task = t,
                                                        tone = g.tone,
                                                        done = g.done,
                                                        project = listNameOf(overview, t.projectId),
                                                        today = today,
                                                        badges = badgesOf(t, workspace),
                                                        onToggle = { if (g.done) viewModel.undoComplete(t) else viewModel.complete(t) },
                                                        onOpen = { selectedId = t.id },
                                                    )
                                                },
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
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

    val selected = selectedId?.let { id ->
        overview?.let { o -> o.findOpen(id) ?: o.done.firstOrNull { it.id == id } }
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
                onToggleMark = { viewModel.toggleMark(selected, it) },
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
        Tone.TODAY -> MaterialTheme.colorScheme.primary
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Column(modifier) {
        GroupLabel(
            text = group.title,
            color = color,
            count = group.count,
            modifier = if (group.onToggle != null) Modifier.clickable { group.onToggle.invoke() } else Modifier,
            trailing = {
                if (group.onToggle != null) {
                    Icon(
                        if (group.expanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                        contentDescription = if (group.expanded) "收起" else "展开",
                        tint = color,
                        modifier = Modifier.padding(end = 8.dp),
                    )
                }
            },
        )
        if (group.tasks.isNotEmpty()) {
            ListGroup(Modifier.padding(top = 2.dp)) {
                DividedRows(group.tasks, inset = 56.dp) { t -> row(t) }
                if (group.moreLabel != null && group.onMore != null) {
                    RowDivider(56.dp)
                    TextButton(onClick = group.onMore, modifier = Modifier.fillMaxWidth()) { Text(group.moreLabel) }
                }
            }
        }
    }
}

// ───────────────────────── 任务行 ─────────────────────────

/**
 * 任务行：圆圈 + 标题 + 一行弱化的说明（时间 / 标记 / 清单 / 标签）。没有自己的卡片，由 [ListGroup] 统一包裹。
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
    /** 行尾的额外操作（例如收集箱里的「定日期」菜单） */
    trailing: (@Composable () -> Unit)? = null,
) {
    val scope = rememberCoroutineScope()
    var checked by remember(task.id) { mutableStateOf(false) }
    val showDone = done || checked
    val scheme = MaterialTheme.colorScheme

    val whenText = when {
        task.date == null -> null
        tone == Tone.OVERDUE -> LocalDate.parse(task.date).let { "${it.monthValue}月${it.dayOfMonth}日" } + (task.time?.let { " $it" } ?: "")
        else -> task.time ?: "全天"
    }
    val support = buildAnnotatedString {
        var first = true
        fun sep() {
            if (!first) append("  ·  ")
            first = false
        }
        if (whenText != null) {
            sep()
            withStyle(SpanStyle(color = if (tone == Tone.OVERDUE) scheme.error else scheme.primary)) { append(whenText) }
        }
        badges.forEach { b ->
            sep()
            withStyle(SpanStyle(color = if (b == "重要") scheme.error else if (b == "紧急") scheme.tertiary else scheme.secondary)) { append(b) }
        }
        if (project.isNotEmpty()) {
            sep()
            append(project)
        }
        task.tags.take(2).forEach { t ->
            sep()
            append("#$t")
        }
    }

    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onOpen)
            .padding(start = 4.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CheckCircle(task.priority, showDone) {
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
        Column(Modifier.weight(1f).padding(vertical = 10.dp, horizontal = 4.dp)) {
            Text(
                TodoMeta.cleanTitle(task.title),
                style = MaterialTheme.typography.bodyLarge,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                textDecoration = if (showDone) TextDecoration.LineThrough else null,
                color = if (showDone) scheme.onSurface.copy(alpha = 0.5f) else scheme.onSurface,
            )
            if (support.isNotEmpty()) {
                Text(
                    support,
                    style = MaterialTheme.typography.labelMedium,
                    color = scheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        trailing?.invoke()
    }
}

private fun priorityColor(priority: Int, fallback: Color): Color = when {
    priority >= 5 -> Color(0xFFE5484D)
    priority >= 3 -> Color(0xFFF5A524)
    priority >= 1 -> Color(0xFF3E8BFF)
    else -> fallback
}

@Composable
private fun CheckCircle(priority: Int, done: Boolean, onClick: () -> Unit) {
    val ring = priorityColor(priority, MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f))
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
