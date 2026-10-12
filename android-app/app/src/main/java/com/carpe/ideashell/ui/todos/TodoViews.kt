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
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import com.carpe.ideashell.core.parse.Quadrant
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
    if (TodoMeta.isMarkedImportant(task.title)) add("重要")
    if (TodoMeta.isMarkedUrgent(task.title)) add("紧急")
    if (workspace.taskNotes.containsKey(taskKeyOf(task.id))) add("任务笔记")
}

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
        quadrant = if (task.done) null else TodoMeta.quadrantOf(task.title, task.date, today),
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

// ───────────────────────── 四象限（合并进任务列表） ─────────────────────────

@Composable
internal fun quadrantColor(q: Quadrant): Color = when (q) {
    Quadrant.Q1 -> MaterialTheme.colorScheme.error
    Quadrant.Q2 -> MaterialTheme.colorScheme.primary
    Quadrant.Q3 -> MaterialTheme.colorScheme.tertiary
    Quadrant.Q4 -> MaterialTheme.colorScheme.outline
}

/** 象限色点：任务行与筛选条共用，让「颜色 → 象限」只需要学一次 */
@Composable
internal fun QuadrantDot(q: Quadrant, modifier: Modifier = Modifier) {
    Box(modifier.size(8.dp).clip(CircleShape).background(quadrantColor(q)))
}

/**
 * 象限筛选条：全部 / 四个象限，每个带当前数量。
 * 重要 / 紧急由任务标题里的 `!重要` `!紧急` 标记决定，日期在明天及以前自动算紧急；点开任务可以标记。
 */
@Composable
internal fun QuadrantFilterBar(
    counts: Map<Quadrant, Int>,
    total: Int,
    selected: Quadrant?,
    onSelect: (Quadrant?) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.horizontalScroll(rememberScrollState()).padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        PillChip("全部 $total", selected == null, onClick = { onSelect(null) })
        Quadrant.entries.forEach { q ->
            PillChip(
                text = "${q.title} ${counts[q] ?: 0}",
                selected = selected == q,
                onClick = { onSelect(if (selected == q) null else q) },
                leading = { QuadrantDot(q) },
            )
        }
    }
}

// ───────────────────────── 无日期任务的「定日期」 ─────────────────────────

@Composable
internal fun QuickDateMenu(today: LocalDate, onPick: (LocalDate) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        TextButton(onClick = { open = true }) { Text("定日期") }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            listOf(
                "今天" to today,
                "明天" to today.plusDays(1),
                "周末" to today.with(TemporalAdjusters.nextOrSame(DayOfWeek.SATURDAY)),
                "下周一" to today.with(TemporalAdjusters.next(DayOfWeek.MONDAY)),
            ).forEach { (label, date) ->
                DropdownMenuItem(text = { Text(label) }, onClick = { open = false; onPick(date) })
            }
        }
    }
}
