package com.carpe.ideashell.ui.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.data.db.CaptureEntity
import com.carpe.ideashell.data.db.CaptureStatus
import com.carpe.ideashell.ui.components.CircleIconButton
import com.carpe.ideashell.ui.components.DividedRows
import com.carpe.ideashell.ui.components.GroupCard
import com.carpe.ideashell.ui.components.kindColors
import com.carpe.ideashell.ui.components.kindIcon
import com.carpe.ideashell.ui.components.relativeTime
import com.carpe.ideashell.ui.glass.GlassBadge
import com.carpe.ideashell.ui.glass.GlassSurface
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import com.carpe.ideashell.ui.todos.TaskRow
import com.carpe.ideashell.ui.todos.Tone
import com.carpe.ideashell.ui.todos.listNameOf
import kotlinx.coroutines.delay
import java.time.LocalDate
import java.time.format.TextStyle
import java.util.Locale

/**
 * 「今天」页（对标滴答清单的「今天」）：顶部标题 + 圆形菜单按钮，下面是白色分组卡片——今天的待办、最近记录。
 * 输入统一由右下角的「+」完成（见 MainActivity），这里不再放输入框。
 */
@Composable
fun HomeScreen(
    onOpenConnection: () -> Unit,
    onOpenTodos: () -> Unit,
    viewModel: HomeViewModel = viewModel(factory = HomeViewModel.Factory.instance),
) {
    val connected by viewModel.connected.collectAsStateWithLifecycle()
    val recent by viewModel.recent.collectAsStateWithLifecycle()
    val overview by viewModel.overview.collectAsStateWithLifecycle()
    val templates by viewModel.templates.collectAsStateWithLifecycle()
    var showTemplates by remember { mutableStateOf(false) }
    var recentOpen by rememberSaveable { mutableStateOf(true) }
    val snackbar = remember { SnackbarHostState() }
    val today = remember { LocalDate.now() }

    LaunchedEffect(Unit) {
        viewModel.events.collect { event ->
            when (event) {
                is HomeEvent.Message -> snackbar.showSnackbar(event.text)
                is HomeEvent.Saved -> {
                    val result = snackbar.showSnackbar(
                        message = "已保存 · ${event.receipt.detail}",
                        actionLabel = "撤销",
                        withDismissAction = false,
                    )
                    if (result == SnackbarResult.ActionPerformed) viewModel.undo(event.receipt.id)
                }
            }
        }
    }

    // 有待同步 / 同步中的记录时，每秒刷新一次，让「N 秒后同步」倒计时走起来
    val hasUnsent = recent.any { it.status == CaptureStatus.PENDING.name || it.status == CaptureStatus.SENDING.name }
    val now by produceState(System.currentTimeMillis(), hasUnsent) {
        while (hasUnsent) {
            value = System.currentTimeMillis()
            delay(1_000)
        }
        value = System.currentTimeMillis()
    }

    val failedCount = recent.count { it.status == CaptureStatus.FAILED.name }
    val hasDone = recent.any { it.status == CaptureStatus.DONE.name }
    val todayStr = today.toString()
    val dueTasks = overview?.let { o -> o.overdue + o.upcoming.filter { it.date == todayStr } }.orEmpty()

    Scaffold(
        containerColor = Color.Transparent,
        contentWindowInsets = WindowInsets.statusBars,
        snackbarHost = { SnackbarHost(snackbar, Modifier.padding(bottom = LocalBottomBarPadding.current)) },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.padding(padding),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = LocalBottomBarPadding.current),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item(key = "header") {
                Header(
                    today = today,
                    hasDone = hasDone,
                    onTemplates = { showTemplates = true },
                    onClearDone = viewModel::clearDone,
                )
            }

            if (!connected) {
                item(key = "connect") { ConnectCard(onOpenConnection) }
            }

            if (failedCount > 0) {
                item(key = "failed") { FailedBanner(failedCount) }
            }

            if (overview != null) {
                item(key = "today") {
                    val o = overview
                    GroupCard(
                        title = "今天的待办",
                        count = dueTasks.size,
                        content = {
                            if (dueTasks.isEmpty()) {
                                Text(
                                    "今天没有要做的事，点右下角 + 记一条",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 16.dp),
                                )
                            } else {
                                DividedRows(dueTasks, inset = 56.dp) { t ->
                                    TaskRow(
                                        task = t,
                                        tone = if (t.date != null && t.date < todayStr) Tone.OVERDUE else Tone.TODAY,
                                        done = false,
                                        project = if (o != null) listNameOf(o, t.projectId) else "",
                                        today = today,
                                        badges = emptyList(),
                                        onToggle = { viewModel.completeTask(t) },
                                        onOpen = onOpenTodos,
                                    )
                                }
                                Spacer(Modifier.height(4.dp))
                            }
                        },
                    )
                }
            }

            if (recent.isEmpty()) {
                if (overview == null) item(key = "empty") { EmptyHint() }
            } else {
                item(key = "recent") {
                    GroupCard(
                        title = "最近记录",
                        count = recent.size,
                        expanded = recentOpen,
                        onToggle = { recentOpen = !recentOpen },
                        content = {
                            DividedRows(recent, inset = 58.dp) { item ->
                                RecentRow(
                                    item = item,
                                    now = now,
                                    onUndo = { viewModel.undo(item.id) },
                                    onRetry = { viewModel.retry(item.id) },
                                )
                            }
                            Spacer(Modifier.height(4.dp))
                        },
                    )
                }
            }
        }
    }

    if (showTemplates) {
        TemplateSheet(
            templates = templates,
            onDismiss = { showTemplates = false },
            onSubmit = viewModel::submitTemplate,
            onSave = viewModel::saveTemplate,
            onDelete = viewModel::deleteTemplate,
        )
    }
}

@Composable
private fun Header(today: LocalDate, hasDone: Boolean, onTemplates: () -> Unit, onClearDone: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 4.dp, top = 8.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text("今天", style = MaterialTheme.typography.headlineSmall)
            Text(
                "${today.monthValue}月${today.dayOfMonth}日 ${today.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.CHINA)}",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        androidx.compose.foundation.layout.Box {
            CircleIconButton(Icons.Filled.MoreVert, "更多", onClick = { menu = true })
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("用模板记录") }, onClick = { menu = false; onTemplates() })
                if (hasDone) DropdownMenuItem(text = { Text("清除已完成的记录") }, onClick = { menu = false; onClearDone() })
            }
        }
    }
}

@Composable
private fun ConnectCard(onOpenConnection: () -> Unit) {
    GlassSurface(
        modifier = Modifier.fillMaxWidth(),
        tint = MaterialTheme.colorScheme.primary,
    ) {
        Row(
            modifier = Modifier.padding(start = 20.dp, end = 12.dp, top = 14.dp, bottom = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("先连接闪念贝壳", style = MaterialTheme.typography.titleMedium)
                Text(
                    "填入 API Key 后，记录会自动同步",
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
            Button(onClick = onOpenConnection) { Text("去连接") }
        }
    }
}

@Composable
private fun FailedBanner(count: Int) {
    GlassSurface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        tint = MaterialTheme.colorScheme.error,
        elevated = false,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(Icons.Filled.Warning, contentDescription = null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(20.dp))
            Text(
                "有 $count 条没有同步成功，内容都还在本地，可在下面逐条重试",
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}

@Composable
private fun EmptyHint() {
    GlassSurface(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("一个入口，自动分流", style = MaterialTheme.typography.titleSmall)
            HintLine("明天 15:00 开会", "待办（自动建到滴答清单）")
            HintLine("#读书 《穷查理宝典》很有启发", "笔记，带标签")
            HintLine("今天试了新的工作流", "追加到当天的 Daily Note")
            Text(
                "点右下角的 + 开始记录；识别不对，就在输入框下面的「待办 / 日记 / 笔记」里直接指定。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun HintLine(example: String, result: String) {
    Column {
        Text(example, style = MaterialTheme.typography.bodyMedium)
        Text("→ $result", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
    }
}

@Composable
private fun RecentRow(
    item: CaptureEntity,
    now: Long,
    onUndo: () -> Unit,
    onRetry: () -> Unit,
) {
    val kind = CaptureKind.valueOf(item.kind)
    val colors = kindColors(kind)
    val status = item.status
    val remainingSec = ((item.readyAt - now + 999) / 1000).coerceAtLeast(0)
    val inUndoWindow = status == CaptureStatus.PENDING.name && item.readyAt > now

    run {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 14.dp, end = 8.dp, top = 12.dp, bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            GlassBadge(kindIcon(kind), tint = colors.onContainer)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    item.summary,
                    style = MaterialTheme.typography.bodyLarge,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(2.dp))
                val (line, isError) = when {
                    status == CaptureStatus.FAILED.name -> (item.lastError ?: "同步失败") to true
                    inUndoWindow -> "${item.detail} · ${remainingSec} 秒后同步" to false
                    status == CaptureStatus.DONE.name ->
                        "${item.detail} · ${item.resultText ?: "已同步"} · ${relativeTime(item.createdAt, now)}" to false
                    item.attempts > 0 -> "${item.detail} · 等待网络，稍后自动重试" to false
                    else -> "${item.detail} · 正在同步…" to false
                }
                Text(
                    line,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.width(4.dp))
            when {
                inUndoWindow -> TextButton(onClick = onUndo) { Text("撤销") }
                status == CaptureStatus.FAILED.name -> TextButton(onClick = onRetry) { Text("重试") }
                status == CaptureStatus.DONE.name -> Icon(
                    Icons.Filled.Check,
                    contentDescription = "已同步",
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier
                        .padding(end = 8.dp)
                        .size(20.dp),
                )
                else -> CircularProgressIndicator(
                    modifier = Modifier
                        .padding(end = 12.dp)
                        .size(18.dp),
                    strokeWidth = 2.dp,
                )
            }
        }
    }
}
