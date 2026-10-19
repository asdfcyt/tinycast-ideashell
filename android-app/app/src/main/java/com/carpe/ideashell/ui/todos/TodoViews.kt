package com.carpe.ideashell.ui.todos

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import com.carpe.ideashell.ui.components.AppMenu
import com.carpe.ideashell.ui.components.AppMenuItem
import com.carpe.ideashell.ui.components.PillChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.data.dida.DidaOverview
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.project.Workspace
import com.carpe.ideashell.data.project.taskKeyOf
import com.carpe.ideashell.ui.components.SegmentedTabs
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.temporal.TemporalAdjusters

/** 项目页等非列表视图共用的上下文 */
internal class TodoCtx(
    val overview: DidaOverview,
    val today: LocalDate,
    val workspace: Workspace,
    val onToggle: (DidaTask) -> Unit,
    val onOpen: (DidaTask) -> Unit,
    val onReschedule: (DidaTask, String, String?) -> Unit,
    /** 日历视图读到的任务缓存（更远日期的未完成 / 已完成任务）：项目主页的相关任务也要用 */
    val ranged: Map<String, DidaTask> = emptyMap(),
)

internal fun toneOf(task: DidaTask, today: LocalDate): Tone {
    val d = task.date ?: return Tone.MUTED
    val t = today.toString()
    return when {
        d < t -> Tone.OVERDUE
        d == t -> Tone.TODAY
        else -> Tone.NORMAL
    }
}

internal fun badgesOf(task: DidaTask, workspace: Workspace): List<String> = buildList {
    if (task.isSystemTodo) add("系统待办") else if (task.isCalendar) add("日历")
    if (workspace.taskNotes.containsKey(taskKeyOf(task.id))) add("任务笔记")
}

/** 任务的时间文字：日历事件显示成「09:00–10:30」，滴答任务就是「09:00」；全天为 null */
internal fun timeTextOf(task: DidaTask): String? =
    task.time?.let { t -> task.endTime?.let { "$t–$it" } ?: t }

internal fun listNameOf(overview: DidaOverview, projectId: String): String =
    overview.projects[projectId] ?: if (projectId.startsWith("inbox", ignoreCase = true)) "收集箱" else ""

@Composable
internal fun TodoCtx.TaskItem(task: DidaTask, modifier: Modifier = Modifier, trailing: (@Composable () -> Unit)? = null) {
    TaskRow(
        task = task,
        tone = toneOf(task, today),
        done = task.done,
        project = listNameOf(overview, task.projectId),
        today = today,
        badges = badgesOf(task, workspace),
        onToggle = { onToggle(task) },
        onOpen = { onOpen(task) },
        modifier = modifier,
        trailing = trailing,
        pill = false,
    )
}

// ───────────────────────── 视图切换 ─────────────────────────

/** 视图切换：任务 / 项目 / 习惯 */
@Composable
internal fun ViewTabs(current: TodoView, onSelect: (TodoView) -> Unit) {
    SegmentedTabs(
        labels = TodoView.entries.map { it.label },
        selected = current.ordinal,
        onSelect = { onSelect(TodoView.entries[it]) },
    )
}

// ───────────────────────── 无日期任务的「定日期」 ─────────────────────────

@Composable
internal fun QuickDateMenu(today: LocalDate, onPick: (LocalDate) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        TextButton(onClick = { open = true }) { Text("定日期") }
        AppMenu(expanded = open, onDismissRequest = { open = false }) {
            listOf(
                "今天" to today,
                "明天" to today.plusDays(1),
                "周末" to today.with(TemporalAdjusters.nextOrSame(DayOfWeek.SATURDAY)),
                "下周一" to today.with(TemporalAdjusters.next(DayOfWeek.MONDAY)),
            ).forEach { (label, date) ->
                AppMenuItem(text = { Text(label) }, onClick = { open = false; onPick(date) })
            }
        }
    }
}
