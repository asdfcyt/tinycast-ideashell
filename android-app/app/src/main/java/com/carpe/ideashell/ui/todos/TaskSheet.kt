package com.carpe.ideashell.ui.todos

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import com.carpe.ideashell.ui.components.AppMenu
import com.carpe.ideashell.ui.components.AppMenuDivider
import com.carpe.ideashell.ui.components.AppMenuItem
import androidx.compose.material3.Switch
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.project.Project
import com.carpe.ideashell.data.project.TaskNoteRef
import com.carpe.ideashell.data.project.didaTaskUrl
import com.carpe.ideashell.system.openInApp
import androidx.compose.ui.text.font.FontWeight
import com.carpe.ideashell.ui.components.ConfirmDialog
import com.carpe.ideashell.ui.components.brandButtonColors
import com.carpe.ideashell.ui.components.FormDialog
import com.carpe.ideashell.ui.components.FormField
import com.carpe.ideashell.ui.components.ListGroup
import com.carpe.ideashell.ui.components.MenuPropertyRow
import com.carpe.ideashell.ui.components.PropertyRow
import com.carpe.ideashell.ui.components.RowDivider
import com.carpe.ideashell.ui.components.TextPromptDialog
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.temporal.TemporalAdjusters

/** 任务详情里能做的所有事（由 [TodoScreen] 接到 ViewModel） */
internal class TaskSheetActions(
    val onComplete: () -> Unit,
    val onCompleteWithReview: (String) -> Unit,
    val onReschedule: (date: String, time: String?) -> Unit,
    val onPriority: (Int) -> Unit,
    val onRename: (String) -> Unit,
    val onAssignProject: (String) -> Unit,
    val onDelete: () -> Unit,
    val onCreateNote: (deliverable: String, purpose: String, steps: String) -> Unit,
    val onOpenNote: (noteId: String) -> Unit,
    val onProgress: (noteId: String, text: String) -> Unit,
)

private enum class SheetDialog { RENAME, REVIEW, NOTE, PROGRESS, DELETE }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TaskSheet(
    task: DidaTask,
    /** 滴答清单名（收集箱 / 某个清单） */
    listName: String,
    today: LocalDate,
    projects: List<Project>,
    currentProject: Project?,
    note: TaskNoteRef?,
    actions: TaskSheetActions,
    onDismiss: () -> Unit,
) {
    var pickDate by remember { mutableStateOf(false) }
    var pickTime by remember { mutableStateOf(false) }
    var dialog by remember { mutableStateOf<SheetDialog?>(null) }
    val context = LocalContext.current
    val baseDate = task.date ?: today.toString()
    val title = TodoMeta.cleanTitle(task.title)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
    ) {
        Column(
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // 标题与说明
            Column(Modifier.padding(horizontal = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, style = MaterialTheme.typography.titleLarge, textDecoration = if (task.done) TextDecoration.LineThrough else null)
                val meta = listOfNotNull(listName.ifEmpty { null }, currentProject?.let { "项目 ${it.keyword}" }) + task.tags.map { "#$it" }
                if (meta.isNotEmpty()) {
                    Text(meta.joinToString(" · "), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (task.content.isNotBlank()) {
                    Text(
                        task.content,
                        style = MaterialTheme.typography.bodyMedium,
                        maxLines = 6,
                        overflow = TextOverflow.Ellipsis,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            // 属性：一行一项，当前值写在右边，点一下才展开选项
            if (!task.done) {
                ListGroup {
                    MenuPropertyRow("日期", dateText(task.date, today), valueColor = MaterialTheme.colorScheme.primary) { close ->
                        val nextMonday = today.with(TemporalAdjusters.next(DayOfWeek.MONDAY))
                        listOf(
                            "今天" to today,
                            "明天" to today.plusDays(1),
                            "后天" to today.plusDays(2),
                            "下周一" to nextMonday,
                        ).forEach { (label, date) ->
                            AppMenuItem(
                                text = { Text(label) },
                                selected = task.date == date.toString(),
                                onClick = { close(); actions.onReschedule(date.toString(), task.time) },
                            )
                        }
                        AppMenuItem(text = { Text("选择日期…") }, onClick = { close(); pickDate = true })
                    }
                    RowDivider()
                    MenuPropertyRow("时间", task.time ?: "全天") { close ->
                        AppMenuItem(
                            text = { Text("全天") },
                            selected = task.time == null,
                            onClick = { close(); if (task.time != null) actions.onReschedule(baseDate, null) },
                        )
                        AppMenuItem(text = { Text("设置时间…") }, onClick = { close(); pickTime = true })
                    }
                    RowDivider()
                    MenuPropertyRow("优先级", priorityName(task.priority)) { close ->
                        listOf("无" to 0, "低" to 1, "中" to 3, "高" to 5).forEach { (label, value) ->
                            AppMenuItem(
                                text = { Text(label) },
                                selected = task.priority == value,
                                onClick = { close(); actions.onPriority(value) },
                            )
                        }
                    }
                    if (projects.isNotEmpty()) {
                        RowDivider()
                        MenuPropertyRow("项目", currentProject?.keyword ?: "未归入") { close ->
                            projects.forEach { p ->
                                AppMenuItem(
                                    text = { Text(p.keyword) },
                                    selected = currentProject?.keyword == p.keyword,
                                    onClick = { close(); if (currentProject?.keyword != p.keyword) actions.onAssignProject(p.keyword) },
                                )
                            }
                        }
                    }
                }
            }

            // 任务笔记
            ListGroup {
                if (note != null) {
                    PropertyRow(
                        label = "任务笔记",
                        value = note.deliverable,
                        onClick = { actions.onOpenNote(note.noteId) },
                        trailing = { TextButton(onClick = { dialog = SheetDialog.PROGRESS }) { Text("记进展") } },
                    )
                } else {
                    PropertyRow(
                        label = "任务笔记",
                        value = "写交付成果",
                        valueColor = MaterialTheme.colorScheme.primary,
                        onClick = { dialog = SheetDialog.NOTE },
                    )
                }
            }

            // 操作：一个主按钮，其余收进文字按钮和「更多」菜单
            Button(
                onClick = actions.onComplete,
                colors = brandButtonColors(),
                modifier = Modifier.fillMaxWidth().height(52.dp),
            ) {
                Text(if (task.done) "恢复为未完成" else "完成", fontWeight = FontWeight.Bold)
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                if (!task.done) {
                    TextButton(onClick = { dialog = SheetDialog.REVIEW }) { Text("完成并复盘") }
                }
                Spacer(Modifier.weight(1f))
                var more by remember { mutableStateOf(false) }
                Box {
                    TextButton(onClick = { more = true }) { Text("更多") }
                    AppMenu(expanded = more, onDismissRequest = { more = false }) {
                        AppMenuItem(text = { Text("改标题") }, onClick = { more = false; dialog = SheetDialog.RENAME })
                        AppMenuItem(
                            text = { Text("用滴答清单打开") },
                            onClick = {
                                more = false
                                openInApp(context, didaTaskUrl(task.projectId, task.id), "滴答清单")
                            },
                        )
                        AppMenuDivider()
                        AppMenuItem(
                            text = { Text("删除") },
                            destructive = true,
                            onClick = { more = false; dialog = SheetDialog.DELETE },
                        )
                    }
                }
            }
        }
    }

    when (dialog) {
        SheetDialog.RENAME -> TextPromptDialog(
            title = "改标题",
            label = "任务标题",
            initial = task.title,
            singleLine = true,
            onDismiss = { dialog = null },
            onConfirm = { actions.onRename(it); dialog = null },
        )

        SheetDialog.REVIEW -> TextPromptDialog(
            title = "完成并复盘",
            label = "复盘",
            hint = if (note != null) "会写进这个任务的任务笔记「复盘」小节；留空则只标记完成。" else "没有任务笔记：会单独存一条带 #复盘 标签的笔记；留空则只标记完成。",
            required = false,
            confirmLabel = "完成",
            minLines = 4,
            onDismiss = { dialog = null },
            onConfirm = {
                dialog = null
                actions.onCompleteWithReview(it)
            },
        )

        SheetDialog.PROGRESS -> TextPromptDialog(
            title = "记一条进展",
            label = "进展",
            hint = "今天做了什么？卡在哪里？下一步是什么？会同步成滴答任务上的一条评论。",
            minLines = 3,
            onDismiss = { dialog = null },
            onConfirm = { text ->
                dialog = null
                note?.let { actions.onProgress(it.noteId, text) }
            },
        )

        SheetDialog.NOTE -> FormDialog(
            title = "创建任务笔记",
            hint = "「完成一篇可发表的论文初稿」是成果；「阅读文献」只是步骤。",
            fields = listOf(
                FormField("交付成果", required = true, placeholder = "这个任务最终要交付什么？（成果，不是动作）"),
                FormField("行动目的", multiline = true, placeholder = "为什么要做？做完能解决什么？"),
                FormField("行动步骤", multiline = true, placeholder = "一行一步，会变成待勾选清单"),
            ),
            confirmLabel = "创建",
            onDismiss = { dialog = null },
            onConfirm = { v ->
                dialog = null
                actions.onCreateNote(v[0], v[1], v[2])
            },
        )

        SheetDialog.DELETE -> ConfirmDialog(
            title = "删除这个任务？",
            text = title,
            confirmLabel = "删除",
            onDismiss = { dialog = null },
            onConfirm = {
                dialog = null
                actions.onDelete()
            },
        )

        null -> Unit
    }

    if (pickDate) {
        val state = rememberDatePickerState(
            initialSelectedDateMillis = LocalDate.parse(baseDate).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(),
        )
        DatePickerDialog(
            onDismissRequest = { pickDate = false },
            confirmButton = {
                TextButton(onClick = {
                    state.selectedDateMillis?.let { ms ->
                        val d = java.time.Instant.ofEpochMilli(ms).atZone(ZoneOffset.UTC).toLocalDate()
                        actions.onReschedule(d.toString(), task.time)
                    }
                    pickDate = false
                }) { Text("确定") }
            },
            dismissButton = { TextButton(onClick = { pickDate = false }) { Text("取消") } },
        ) { DatePicker(state = state) }
    }

    if (pickTime) {
        val initial = task.time?.split(":")
        val state = rememberTimePickerState(
            initialHour = initial?.getOrNull(0)?.toIntOrNull() ?: 9,
            initialMinute = initial?.getOrNull(1)?.toIntOrNull() ?: 0,
            is24Hour = true,
        )
        AlertDialog(
            onDismissRequest = { pickTime = false },
            text = { TimePicker(state = state) },
            confirmButton = {
                TextButton(onClick = {
                    actions.onReschedule(baseDate, "%02d:%02d".format(state.hour, state.minute))
                    pickTime = false
                }) { Text("确定") }
            },
            dismissButton = { TextButton(onClick = { pickTime = false }) { Text("取消") } },
        )
    }
}

private fun priorityName(p: Int): String = when {
    p >= 5 -> "高"
    p >= 3 -> "中"
    p >= 1 -> "低"
    else -> "无"
}

private fun dateText(date: String?, today: LocalDate): String {
    val d = date?.let { runCatching { LocalDate.parse(it) }.getOrNull() } ?: return "无日期"
    return when (d) {
        today -> "今天"
        today.plusDays(1) -> "明天"
        today.minusDays(1) -> "昨天"
        else -> "${d.monthValue}月${d.dayOfMonth}日"
    }
}
