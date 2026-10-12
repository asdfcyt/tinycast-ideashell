package com.carpe.ideashell.ui.review

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DateRangePicker
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.carpe.ideashell.ui.components.ScreenHeader
import com.carpe.ideashell.ui.components.SearchButton
import com.carpe.ideashell.ui.components.SegmentedTabs
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

/**
 * 回看：时间线 / Daily Note / 往日回顾 / 档案（搜索已独立成底部导航的一个入口）。
 * 四个页签共用一个列表（同一个滚动位置、同一个下拉刷新），数据都在 [ReviewViewModel] 里，切换页签不会丢。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReviewScreen(
    onOpenConnection: () -> Unit,
    onOpenSearch: () -> Unit = {},
    onOpenNote: (String) -> Unit,
    viewModel: ReviewViewModel = viewModel(factory = ReviewViewModel.Factory),
) {
    val connected by viewModel.connected.collectAsStateWithLifecycle()
    val timeline by viewModel.timeline.collectAsStateWithLifecycle()
    val daily by viewModel.daily.collectAsStateWithLifecycle()
    val dailyToday by viewModel.dailyToday.collectAsStateWithLifecycle()
    val memory by viewModel.memory.collectAsStateWithLifecycle()
    val dossier by viewModel.dossier.collectAsStateWithLifecycle()
    val pane = viewModel.pane

    val clipboard = LocalClipboardManager.current
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    var showRangePicker by remember { mutableStateOf(false) }

    LaunchedEffect(pane, connected) { viewModel.ensureLoaded(pane) }

    fun toast(text: String) {
        scope.launch {
            snackbar.currentSnackbarData?.dismiss()
            snackbar.showSnackbar(text)
        }
    }

    val refreshing = when (pane) {
        ReviewPane.TIMELINE -> timeline.loading && timeline.data != null
        ReviewPane.DAILY -> daily.loading && daily.data != null
        ReviewPane.MEMORY -> memory.loading && memory.data != null
        ReviewPane.DOSSIER -> dossier.loading && dossier.data != null
    }

    Scaffold(
        containerColor = Color.Transparent,
        contentWindowInsets = WindowInsets.statusBars,
        snackbarHost = { SnackbarHost(snackbar, Modifier.padding(bottom = LocalBottomBarPadding.current)) },
    ) { padding ->
      Column(Modifier.padding(padding)) {
        ScreenHeader(
            title = "回看",
            subtitle = "笔记、待办与回忆，一屏看完",
            action = { SearchButton(onOpenSearch) },
        )
        SegmentedTabs(
            labels = ReviewPane.entries.map { it.label },
            selected = pane.ordinal,
            onSelect = { viewModel.selectPane(ReviewPane.entries[it]) },
        )
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = { if (connected) viewModel.refresh(pane) },
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
                    when (pane) {
                        ReviewPane.TIMELINE -> timelineItems(
                            state = timeline,
                            preset = viewModel.preset,
                            range = viewModel.range,
                            onPreset = viewModel::selectPreset,
                            onCustom = { showRangePicker = true },
                            onCopyReport = {
                                viewModel.timelineReport()?.let {
                                    clipboard.setText(AnnotatedString(it))
                                    toast("已复制，可直接贴进日报 / 周报")
                                }
                            },
                            onOpenNote = onOpenNote,
                            onRetry = { viewModel.refresh(ReviewPane.TIMELINE) },
                            onDaySummary = { viewModel.writeDaySummary { toast(it) } },
                            summaryBusy = viewModel.summaryBusy,
                        )

                        ReviewPane.DAILY -> dailyItems(
                            state = daily,
                            today = dailyToday,
                            folderName = viewModel.dailyFolder,
                            onOpenNote = onOpenNote,
                            onRetry = viewModel::loadDaily,
                        )

                        ReviewPane.MEMORY -> memoryItems(
                            state = memory,
                            randomNote = viewModel.randomNote,
                            onShuffle = viewModel::shuffle,
                            onOpenNote = onOpenNote,
                            onRetry = viewModel::loadMemory,
                        )

                        ReviewPane.DOSSIER -> dossierItems(
                            text = viewModel.dossierText,
                            onTextChange = { viewModel.dossierText = it },
                            state = dossier,
                            onSearch = { viewModel.openDossier() },
                            onCopyBrief = {
                                dossier.data?.brief?.let {
                                    clipboard.setText(AnnotatedString(it))
                                    toast("档案简报已复制")
                                }
                            },
                            onOpenNote = onOpenNote,
                            onRetry = { viewModel.openDossier() },
                        )
                    }
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

/** 日期选择器返回的是 UTC 零点的毫秒数 */
private fun utcDate(ms: Long): LocalDate = Instant.ofEpochMilli(ms).atZone(ZoneOffset.UTC).toLocalDate()
