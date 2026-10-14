package com.carpe.ideashell.ui.review

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DateRangePicker
import com.carpe.ideashell.ui.components.AppMenu
import com.carpe.ideashell.ui.components.AppMenuDivider
import com.carpe.ideashell.ui.components.AppMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberDateRangePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.carpe.ideashell.data.project.firstMatching
import com.carpe.ideashell.data.project.taskKeyOf
import com.carpe.ideashell.domain.Insights
import com.carpe.ideashell.ui.components.ScreenHeader
import com.carpe.ideashell.ui.components.SearchButton
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import com.carpe.ideashell.ui.todos.TaskSheet
import com.carpe.ideashell.ui.todos.TaskSheetActions
import com.carpe.ideashell.ui.todos.listNameOf
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

/**
 * 回顾：没有页签，只有一条按时间戳排开的河。
 * 顶部是「发现」横滑卡：环形的时间分配（点项目进项目页）、专注趋势 / 时间线 / 最佳时段、记录时刻、连续记录、习惯、待办、话题；

 * 下面每天一个日期头（默认只展开今天、昨天），笔记、完成的待办和 Daily Note 里的每一条日记按时间戳混在一起，每条是竖线上的一个节点。
 * 范围、今日小结、复制日报都收进标题栏的范围菜单。
 * 人物 / 主题的聚合（原来的「档案」）已经分流：成了项目的在项目页，没成项目的在搜索里。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReviewScreen(
    onOpenConnection: () -> Unit,
    onOpenSearch: () -> Unit = {},
    onOpenNote: (String) -> Unit,
    onOpenProject: (String) -> Unit = {},
    viewModel: ReviewViewModel = viewModel(factory = ReviewViewModel.Factory),
) {
    val connected by viewModel.connected.collectAsStateWithLifecycle()
    val timeline by viewModel.timeline.collectAsStateWithLifecycle()
    val flow by viewModel.flow.collectAsStateWithLifecycle()
    val todoData by viewModel.todoData.collectAsStateWithLifecycle()
    val workspace by viewModel.workspace.collectAsStateWithLifecycle()
    // 洞察卡（专注趋势 / 时间线 / 习惯 / 记录时刻……）在 ViewModel 里于后台线程算好，进页面直接用，不在组合时现算
    val insights by viewModel.insights.collectAsStateWithLifecycle()
    val revisitKeys by viewModel.revisitKeys.collectAsStateWithLifecycle()
    val revisitStats by viewModel.revisitStats.collectAsStateWithLifecycle()
    val revisitTrend by viewModel.revisitTrend.collectAsStateWithLifecycle()

    val clipboard = LocalClipboardManager.current
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    var showRangePicker by remember { mutableStateOf(false) }

    LaunchedEffect(connected) { viewModel.ensureLoaded() }
    LaunchedEffect(viewModel) { viewModel.messages.collect { text -> scope.launch { snackbar.currentSnackbarData?.dismiss(); snackbar.showSnackbar(text) } } }

    fun toast(text: String) {
        scope.launch {
            snackbar.currentSnackbarData?.dismiss()
            snackbar.showSnackbar(text)
        }
    }

    Scaffold(
        containerColor = Color.Transparent,
        contentWindowInsets = WindowInsets.statusBars,
        snackbarHost = { SnackbarHost(snackbar, Modifier.padding(bottom = LocalBottomBarPadding.current)) },
    ) { padding ->
        Column(Modifier.padding(padding)) {
            ScreenHeader(
                title = "回顾",
                action = {
                    RangeMenu(
                        label = viewModel.preset?.label ?: "自定义",
                        selected = viewModel.preset,
                        customLabel = viewModel.range.label,
                        canCopy = timeline.data?.isEmpty == false,
                        summaryBusy = viewModel.summaryBusy,
                        onPreset = viewModel::selectPreset,
                        onCustom = { showRangePicker = true },
                        onDaySummary = { viewModel.writeDaySummary { toast(it) } },
                        onCopyReport = {
                            viewModel.timelineReport()?.let {
                                clipboard.setText(AnnotatedString(it))
                                toast("已复制，可直接贴进日报 / 周报")
                            }
                        },
                    )
                    Spacer(Modifier.width(8.dp))
                    SearchButton(onOpenSearch)
                },
            )
            PullToRefreshBox(
                isRefreshing = timeline.loading && timeline.data != null,
                onRefresh = { if (connected) viewModel.refresh() },
                modifier = Modifier.weight(1f),
            ) {
                LazyColumn(
                    state = viewModel.listState,
                    contentPadding = PaddingValues(
                        start = 16.dp, end = 16.dp, top = 4.dp,
                        bottom = LocalBottomBarPadding.current + 8.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    if (!connected) {
                        item(key = "connect") { ConnectIdeashellCard(onOpenConnection) }
                    } else {
                        insightsItem(
                            flow = flow,
                            insights = insights,
                            revisit = RevisitPanel(revisitStats, revisitTrend),
                            rangeLabel = viewModel.preset?.label ?: viewModel.range.label,
                            onOpenProject = onOpenProject,
                        )
                        riverItems(
                            state = timeline,
                            onOpenNote = onOpenNote,
                            onOpenTodo = { viewModel.openTodo(it.id) },
                            onToggleTodo = viewModel::toggleTodo,
                            isDayOpen = { viewModel.isDayOpen(it) },
                            onToggleDay = { viewModel.toggleDay(it) },
                            onRetry = viewModel::refresh,
                            revisit = RevisitActions(
                                keys = revisitKeys,
                                onNote = viewModel::toggleNoteRevisit,
                                onDaily = viewModel::toggleDailyRevisit,
                            ),
                        )
                    }
                }
            }
        }
    }

    // 河里的待办：点文字打开详情，复用「待办」页的同一张任务详情（完成 / 改期 / 优先级 / 归入项目 / 任务笔记……）
    val selected = viewModel.selectedTodo(timeline.data)
    if (selected != null) {
        // 清单名只在待办页打开过 / 同步过才有；没有时回落成「滴答清单」
        val listName = todoData.overview?.let { listNameOf(it, selected.projectId) }?.ifBlank { null } ?: "滴答清单"
        TaskSheet(
            task = selected,
            listName = listName,
            today = remember { LocalDate.now() },
            projects = workspace.projects,
            currentProject = workspace.projects.firstMatching(selected.title, selected.tags),
            note = workspace.taskNotes[taskKeyOf(selected.id)],
            actions = TaskSheetActions(
                onComplete = {
                    viewModel.openTodo(null)
                    viewModel.toggleTodo(selected)
                },
                onCompleteWithReview = { review ->
                    viewModel.openTodo(null)
                    viewModel.completeTodoWithReview(selected, review)
                },
                onReschedule = { date, time -> viewModel.rescheduleTodo(selected, date, time) },
                onPriority = { viewModel.setTodoPriority(selected, it) },
                onRename = { viewModel.renameTodo(selected, it) },
                onAssignProject = { viewModel.assignTodoProject(selected, it) },
                onDelete = {
                    viewModel.openTodo(null)
                    viewModel.deleteTodo(selected)
                },
                onCreateNote = { d, p, st -> viewModel.createTodoNote(selected, d, p, st) },
                onOpenNote = {
                    viewModel.openTodo(null)
                    onOpenNote(it)
                },
                onProgress = { noteId, text -> viewModel.addTodoProgress(selected, noteId, text) },
            ),
            onDismiss = { viewModel.openTodo(null) },
        )
    }

    if (showRangePicker) {
        val pickerState = rememberDateRangePickerState()
        DatePickerDialog(
            onDismissRequest = { showRangePicker = false },
            confirmButton = {
                TextButton(
                    enabled = pickerState.selectedStartDateMillis != null,
                    onClick = {
                        val from = pickerState.selectedStartDateMillis?.let(::utcDate)
                        val to = pickerState.selectedEndDateMillis?.let(::utcDate)
                        if (from != null) viewModel.selectCustom(from, to ?: from)
                        showRangePicker = false
                    },
                ) { Text("确定") }
            },
            dismissButton = { TextButton(onClick = { showRangePicker = false }) { Text("取消") } },
        ) {
            DateRangePicker(
                state = pickerState,
                modifier = Modifier.fillMaxWidth().height(500.dp),
                title = { Text("选择起止日期", modifier = Modifier.padding(start = 24.dp, top = 16.dp)) },
            )
        }
    }
}

/** 标题栏右侧的范围药丸：点开选范围；今日小结、复制日报也在这个菜单里 */
@Composable
private fun RangeMenu(
    label: String,
    selected: RangePreset?,
    customLabel: String,
    canCopy: Boolean,
    summaryBusy: Boolean,
    onPreset: (RangePreset) -> Unit,
    onCustom: () -> Unit,
    onDaySummary: () -> Unit,
    onCopyReport: () -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .height(44.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceContainerLowest)
                .clickable { open = true }
                .padding(start = 16.dp, end = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(label, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, maxLines = 1)
            Icon(Icons.Filled.ArrowDropDown, contentDescription = "选择范围")
        }
        AppMenu(expanded = open, onDismissRequest = { open = false }) {
            RangePreset.entries.forEach { p ->
                AppMenuItem(
                    text = { Text(p.label) },
                    selected = p == selected,
                    onClick = { open = false; onPreset(p) },
                )
            }
            AppMenuItem(
                text = { Text(if (selected == null) "自定义（$customLabel）" else "自定义…") },
                selected = selected == null,
                onClick = { open = false; onCustom() },
            )
            AppMenuDivider()
            // 下面两项是操作，不是「选范围」，用分隔线隔开
            AppMenuItem(
                text = { Text(if (summaryBusy) "正在汇总今天…" else "生成今日小结") },
                enabled = !summaryBusy,
                onClick = { open = false; onDaySummary() },
            )
            AppMenuItem(
                text = { Text("复制为日报 / 周报") },
                enabled = canCopy,
                onClick = { open = false; onCopyReport() },
            )
        }
    }
}

/** 日期选择器返回的是 UTC 零点的毫秒数 */
private fun utcDate(ms: Long): LocalDate = Instant.ofEpochMilli(ms).atZone(ZoneOffset.UTC).toLocalDate()
