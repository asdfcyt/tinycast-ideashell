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
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import com.carpe.ideashell.domain.Insights
import com.carpe.ideashell.domain.TimelineData
import com.carpe.ideashell.ui.components.ScreenHeader
import com.carpe.ideashell.ui.components.SearchButton
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

/**
 * 回看：没有页签，只有一条按时间戳排开的河。
 * 顶部是「发现」一张卡：环形的时间分配（点项目进项目页）+ 记录时刻、连续记录、待办逾期、话题几条一句话结论；
 * 下面每天一个日期头，笔记、完成的待办和 Daily Note 里的每一条日记按时间戳混在一起，每条是竖线上的一个节点。
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
    // 记录时刻 / 连续记录 / 待办逾期 / 话题：全部由已加载的时间线算出，不额外请求
    val insights = remember(timeline.data) { timeline.data?.let { Insights.build(it) } }

    val clipboard = LocalClipboardManager.current
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    var showRangePicker by remember { mutableStateOf(false) }

    LaunchedEffect(connected) { viewModel.ensureLoaded() }

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
                title = "回看",
                subtitle = subtitleOf(viewModel, timeline.data),
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
                        insightsItem(flow, insights, onOpenProject)
                        riverItems(
                            state = timeline,
                            onOpenNote = onOpenNote,
                            onRetry = viewModel::refresh,
                        )
                    }
                }
            }
        }
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

/** 标题下的一行：范围 + 笔记 / 日记 / 待办的总数（总数只是背景信息，不再占首屏） */
private fun subtitleOf(viewModel: ReviewViewModel, data: TimelineData?): String = buildString {
    append(viewModel.range.label)
    if (data != null) {
        append(" · ${data.noteCount} 篇笔记")
        if (data.dailyCount > 0) append(" · ${data.dailyCount} 条日记")
        if (data.todoTotal > 0) append(" · 待办 ${data.todoDone}/${data.todoTotal}")
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
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            RangePreset.entries.forEach { p ->
                DropdownMenuItem(
                    text = { Text(p.label, fontWeight = if (p == selected) FontWeight.Bold else FontWeight.Normal) },
                    onClick = { open = false; onPreset(p) },
                )
            }
            DropdownMenuItem(
                text = { Text(if (selected == null) "自定义（$customLabel）" else "自定义…") },
                onClick = { open = false; onCustom() },
            )
            HorizontalDivider(Modifier.padding(vertical = 4.dp))
            DropdownMenuItem(
                text = { Text(if (summaryBusy) "正在汇总今天…" else "生成今日小结") },
                enabled = !summaryBusy,
                onClick = { open = false; onDaySummary() },
            )
            DropdownMenuItem(
                text = { Text("复制为日报 / 周报") },
                enabled = canCopy,
                onClick = { open = false; onCopyReport() },
            )
        }
    }
}

/** 日期选择器返回的是 UTC 零点的毫秒数 */
private fun utcDate(ms: Long): LocalDate = Instant.ofEpochMilli(ms).atZone(ZoneOffset.UTC).toLocalDate()
