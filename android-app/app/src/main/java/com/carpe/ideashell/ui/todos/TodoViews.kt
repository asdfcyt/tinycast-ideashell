package com.carpe.ideashell.ui.todos

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.core.parse.Quadrant
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.data.dida.DidaOverview
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.project.Workspace
import com.carpe.ideashell.data.project.taskKeyOf
import com.carpe.ideashell.ui.components.DividedRows
import com.carpe.ideashell.ui.components.EmptyNote
import com.carpe.ideashell.ui.components.GroupLabel
import com.carpe.ideashell.ui.components.ListGroup
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.temporal.TemporalAdjusters

/** 非列表视图（四象限 / 收集箱 / 项目）共用的上下文 */
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
        onToggle = { onToggle(task) },
        onOpen = { onOpen(task) },
        modifier = modifier,
        trailing = trailing,
    )
}

// ───────────────────────── 视图切换 ─────────────────────────

/** 视图切换：一排文字页签（M3 Tabs），不再是一排圆角按钮 */
@Composable
internal fun ViewTabs(current: TodoView, onSelect: (TodoView) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    ScrollableTabRow(
        selectedTabIndex = current.ordinal,
        containerColor = Color.Transparent,
        contentColor = scheme.primary,
        edgePadding = 12.dp,
        divider = {},
    ) {
        TodoView.entries.forEach { v ->
            Tab(
                selected = current == v,
                onClick = { onSelect(v) },
                selectedContentColor = scheme.primary,
                unselectedContentColor = scheme.onSurfaceVariant,
                text = { Text(v.label, style = MaterialTheme.typography.titleSmall) },
            )
        }
    }
}

// ───────────────────────── 四象限 ─────────────────────────

private const val Q4_PREVIEW = 8

@Composable
private fun quadrantColor(q: Quadrant): Color = when (q) {
    Quadrant.Q1 -> MaterialTheme.colorScheme.error
    Quadrant.Q2 -> MaterialTheme.colorScheme.primary
    Quadrant.Q3 -> MaterialTheme.colorScheme.tertiary
    Quadrant.Q4 -> MaterialTheme.colorScheme.onSurfaceVariant
}

private val quadrantOrder = compareBy<DidaTask>({ it.date ?: "9999-99-99" }, { it.time ?: "" }, { -it.priority })

/** 四象限：重要 / 紧急由任务标题里的 `!重要` `!紧急` 标记决定，日期在明天及以前自动算紧急 */
internal fun LazyListScope.quadrantSection(ctx: TodoCtx) {
    val open = ctx.overview.overdue + ctx.overview.upcoming + ctx.overview.undated
    val groups = open.groupBy { TodoMeta.quadrantOf(it.title, it.date, ctx.today) }

    item(key = "q-hint") {
        Text(
            "点开任务可标记「重要」「紧急」；今天、明天到期或已逾期的任务自动算紧急。",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
        )
    }
    Quadrant.entries.forEach { q ->
        val tasks = groups[q].orEmpty().sortedWith(quadrantOrder)
        item(key = "q:${q.name}") {
            Column(Modifier.animateItem()) {
                GroupLabel(q.title, color = quadrantColor(q), count = tasks.size)
                if (tasks.isEmpty()) {
                    Text(
                        "这里没有任务",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 8.dp, top = 2.dp, bottom = 6.dp),
                    )
                } else {
                    val shown = if (q == Quadrant.Q4) tasks.take(Q4_PREVIEW) else tasks
                    ListGroup(Modifier.padding(top = 2.dp)) {
                        DividedRows(shown, inset = 56.dp) { t -> ctx.TaskItem(t) }
                    }
                    if (shown.size < tasks.size) {
                        Text(
                            "还有 ${tasks.size - shown.size} 项，在「列表」里查看",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(start = 8.dp, top = 4.dp),
                        )
                    }
                }
            }
        }
    }
}

// ───────────────────────── 整理收集箱 ─────────────────────────

/** 整理收集箱：没有日期的任务，行尾「定日期」一键排期；点开可归入项目 / 写交付成果 / 完成 / 删除 */
internal fun LazyListScope.inboxSection(ctx: TodoCtx) {
    val tasks = ctx.overview.undated
    if (tasks.isEmpty()) {
        item(key = "inbox-empty") { EmptyNote("收集箱已清空", "没有需要整理的无日期任务。") }
        return
    }
    item(key = "inbox") {
        Column(Modifier.animateItem()) {
            GroupLabel("没有日期的任务", count = tasks.size)
            ListGroup(Modifier.padding(top = 2.dp)) {
                DividedRows(tasks, inset = 56.dp) { t ->
                    ctx.TaskItem(t, trailing = { QuickDateMenu(ctx.today) { date -> ctx.onReschedule(t, date.toString(), null) } })
                }
            }
        }
    }
}

@Composable
private fun QuickDateMenu(today: LocalDate, onPick: (LocalDate) -> Unit) {
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
