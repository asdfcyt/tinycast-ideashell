package com.carpe.ideashell.ui.review

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.core.parse.TimeRange
import com.carpe.ideashell.core.parse.TimeRanges
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.ideashell.NoteInfo
import com.carpe.ideashell.domain.DayBucket
import com.carpe.ideashell.domain.TimelineData
import com.carpe.ideashell.ui.components.DividedRows
import com.carpe.ideashell.ui.components.GroupLabel
import com.carpe.ideashell.ui.components.ListGroup
import com.carpe.ideashell.ui.components.NoticeLine

/**
 * 时间线：顶部一行「范围 ▾ + 更多」，下面一行统计文字；每天一组（标题 + 一张容器，里面是笔记和待办行）。
 * 范围选择、今日小结、复制日报都收进菜单，不再是一排按钮。
 */
fun LazyListScope.timelineItems(
    state: Async<TimelineData>,
    preset: RangePreset?,
    range: TimeRange,
    onPreset: (RangePreset) -> Unit,
    onCustom: () -> Unit,
    onCopyReport: () -> Unit,
    onOpenNote: (String) -> Unit,
    onRetry: () -> Unit,
    onDaySummary: () -> Unit = {},
    summaryBusy: Boolean = false,
) {
    val data = state.data

    item(key = "tl-range") {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                RangeMenu(preset, range, onPreset, onCustom)
                Box(Modifier.weight(1f))
                MoreMenu(
                    canCopy = data != null && !data.isEmpty,
                    summaryBusy = summaryBusy,
                    onDaySummary = onDaySummary,
                    onCopyReport = onCopyReport,
                )
            }
            val line = buildString {
                append(range.label)
                if (range.clamped) append("（范围过长，只取最近 ${TimeRanges.MAX_DAYS} 天）")
                if (data != null) {
                    append(" · ${data.noteCount} 篇笔记")
                    if (data.todoTotal > 0) append(" · 待办完成 ${data.todoDone}/${data.todoTotal}")
                }
            }
            Text(
                line,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 12.dp, bottom = 2.dp),
            )
        }
    }

    when {
        data == null && state.error != null -> item(key = "tl-error") {
            InfoCard("没能加载时间线", state.error.orEmpty(), "重试", onRetry)
        }

        data == null -> item(key = "tl-loading") { LoadingBlock() }

        else -> {
            state.error?.let { err -> item(key = "tl-stale") { NoticeLine(err) } }
            if (data.truncated) {
                item(key = "tl-truncated") { NoticeLine("某个小时内的笔记太多，没有取全；缩小时间范围可以看到更完整的结果。") }
            }
            data.todoNote?.let { note -> item(key = "tl-todo-note") { NoticeLine(note) } }

            if (data.isEmpty) {
                item(key = "tl-empty") { InfoCard("这段时间没有记录", "换个范围看看，或者回到「记录」页写下第一条。") }
            } else {
                data.days.forEach { day ->
                    item(key = "tl-day-${day.date}") { DaySection(day, onOpenNote, Modifier.animateItem()) }
                }
            }
        }
    }
}

@Composable
private fun RangeMenu(preset: RangePreset?, range: TimeRange, onPreset: (RangePreset) -> Unit, onCustom: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        TextButton(onClick = { open = true }) {
            Text(preset?.label ?: "自定义", style = MaterialTheme.typography.titleMedium)
            Icon(Icons.Filled.ArrowDropDown, contentDescription = null)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            RangePreset.entries.forEach { p ->
                DropdownMenuItem(text = { Text(p.label) }, onClick = { open = false; onPreset(p) })
            }
            DropdownMenuItem(
                text = { Text(if (preset == null) "自定义（${range.label}）" else "自定义…") },
                onClick = { open = false; onCustom() },
            )
        }
    }
}

@Composable
private fun MoreMenu(canCopy: Boolean, summaryBusy: Boolean, onDaySummary: () -> Unit, onCopyReport: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) { Icon(Icons.Filled.MoreVert, contentDescription = "更多") }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
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

@Composable
private fun DaySection(day: DayBucket, onOpenNote: (String) -> Unit, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    val entries: List<Any> = day.notes + day.todos
    Column(modifier) {
        GroupLabel(
            text = day.title,
            trailing = {
                val counts = listOfNotNull(
                    day.notes.size.takeIf { it > 0 }?.let { "$it 笔记" },
                    day.todos.size.takeIf { it > 0 }?.let { "${day.todos.count { t -> t.done }}/$it 待办" },
                ).joinToString(" · ")
                Text(counts, style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant, modifier = Modifier.padding(end = 8.dp))
            },
        )
        ListGroup(Modifier.padding(top = 2.dp)) {
            DividedRows(entries, inset = 68.dp) { e ->
                when (e) {
                    is NoteInfo -> TimelineNoteRow(e, onOpenNote)
                    is DidaTask -> TimelineTodoRow(e)
                    else -> Unit
                }
            }
        }
    }
}

@Composable
private fun TimelineNoteRow(note: NoteInfo, onOpenNote: (String) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onOpenNote(note.id) }
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Text(
            note.localClock.orEmpty(),
            style = MaterialTheme.typography.labelMedium,
            color = scheme.primary,
            modifier = Modifier.width(52.dp).padding(top = 3.dp),
        )
        Column(Modifier.weight(1f)) {
            Text(note.title, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (!note.summary.isNullOrBlank()) {
                Text(
                    note.summary,
                    style = MaterialTheme.typography.bodySmall,
                    color = scheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun TimelineTodoRow(task: DidaTask) {
    val scheme = MaterialTheme.colorScheme
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            if (task.done) "✓" else "○",
            style = MaterialTheme.typography.labelLarge,
            color = if (task.done) scheme.primary else scheme.onSurfaceVariant,
            modifier = Modifier.width(52.dp),
        )
        Text(
            task.title,
            style = MaterialTheme.typography.bodyMedium,
            textDecoration = if (task.done) TextDecoration.LineThrough else null,
            color = if (task.done) scheme.onSurface.copy(alpha = 0.55f) else scheme.onSurface,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (task.time != null) {
            Text(task.time, style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant, modifier = Modifier.padding(start = 8.dp))
        }
    }
}
