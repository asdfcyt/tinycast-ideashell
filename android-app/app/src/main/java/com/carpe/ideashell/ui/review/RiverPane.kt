package com.carpe.ideashell.ui.review

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.Icon
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import com.carpe.ideashell.R
import com.carpe.ideashell.data.revisit.RevisitRepository
import com.carpe.ideashell.system.openIdeaShellNote
import com.carpe.ideashell.ui.components.AppMenu
import com.carpe.ideashell.ui.components.ConfirmDialog
import com.carpe.ideashell.ui.components.AppMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.carpe.ideashell.core.parse.TimeRanges
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.ideashell.DailyEntry
import com.carpe.ideashell.data.ideashell.NoteInfo
import com.carpe.ideashell.domain.DayBucket
import com.carpe.ideashell.domain.TimelineData
import com.carpe.ideashell.ui.components.NoticeLine
import com.carpe.ideashell.ui.theme.Brand
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/*
 * 回顾的「河」（节点时刻表）：没有卡片外壳，正文直接落在底色上。每天一个大号日期头，
 * 下面是这一天的每一件事，按时间戳从晚到早排开：时间靠左、竖线居中、正文在右，每条记录自己是线上的一个节点。
 * Daily Note 里的每一条（`- **时间** 文字`）拆成独立的一行；Daily Note 那篇笔记本身不再重复出现。
 * 节点区分类型：日记 = 橙色实心圆，笔记 = 深色圆角方块，待办 = 空心环（完成后是灰色实心圆）。
 * 默认只展开今天、昨天，更早的收起成一行日期头，点日期头展开 / 收起。
 * 待办可以交互：点节点直接勾选完成（再点恢复），点文字打开任务详情。
 */

/** 一天里的一行；[clock] 是 HH:mm，没有时间的待办是空字符串，排在最后 */
private sealed interface RiverRow {
    val clock: String

    class Daily(val entry: DailyEntry, val noteId: String?) : RiverRow {
        override val clock: String get() = entry.time
    }

    class Note(val note: NoteInfo) : RiverRow {
        override val clock: String get() = note.localClock.orEmpty()
    }

    class Todo(val task: DidaTask, override val clock: String, val overdue: Boolean) : RiverRow
}

/** 没做完、计划时刻已经过了：过去的日子里没做完的，或今天里时间已过的（全天的待办要到第二天才算） */
private fun isOverdue(t: DidaTask, day: LocalDate, now: java.time.LocalDateTime = java.time.LocalDateTime.now()): Boolean {
    if (t.done) return false
    val today = now.toLocalDate()
    if (day.isBefore(today)) return true
    if (day != today) return false
    val time = t.time ?: return false
    return runCatching { java.time.LocalTime.parse(time).isBefore(now.toLocalTime()) }.getOrDefault(false)
}

/** 待办的时间：做完的用完成时刻，没做完的用计划时刻 */
private fun todoClock(t: DidaTask): String {
    val doneAt = t.completedAt
    if (t.done && doneAt != null) {
        val z = Instant.ofEpochMilli(doneAt).atZone(ZoneId.systemDefault())
        return "%02d:%02d".format(z.hour, z.minute)
    }
    return t.time.orEmpty()
}

private fun rowsOf(day: DayBucket): List<RiverRow> = buildList {
    day.daily.forEach { add(RiverRow.Daily(it, day.dailyNoteId)) }
    day.notes.forEach { add(RiverRow.Note(it)) }
    day.todos.forEach { add(RiverRow.Todo(it, todoClock(it), isOverdue(it, day.date))) }
}.sortedWith(
    // 全天（没有具体时间）的待办排在当天最上面，其余按时间从晚到早
    compareBy<RiverRow> { it.clock.isNotEmpty() }.thenByDescending { it.clock },
)

/**
 * 时间河里「加入重温」的接线：[keys] 是已在重温的条目；长按笔记 / 日记一条，弹出菜单加入或移出。
 * [inRevisit] 是长按那一刻它是否已经加入。
 */
class RevisitActions(
    val keys: Set<String>,
    val onNote: (note: NoteInfo, inRevisit: Boolean) -> Unit,
    val onDaily: (entry: DailyEntry, noteId: String?, date: LocalDate, inRevisit: Boolean) -> Unit,
    /** 删除一条日记（长按菜单 →「删除」→ 确认） */
    val onDeleteDaily: (entry: DailyEntry, date: LocalDate) -> Unit,
)

fun LazyListScope.riverItems(
    state: Async<TimelineData>,
    onOpenNote: (String) -> Unit,
    onOpenTodo: (DidaTask) -> Unit,
    onToggleTodo: (DidaTask) -> Unit,
    isDayOpen: (LocalDate) -> Boolean,
    onToggleDay: (LocalDate) -> Unit,
    onRetry: () -> Unit,
    revisit: RevisitActions,
) {
    val data = state.data
    when {
        data == null && state.error != null -> item(key = "rv-error") {
            InfoCard("没能加载回顾", state.error.orEmpty(), "重试", onRetry)
        }

        data == null -> item(key = "rv-loading") { LoadingBlock() }

        else -> {
            state.error?.let { err -> item(key = "rv-stale") { NoticeLine(err) } }
            if (data.truncated) {
                item(key = "rv-truncated") { NoticeLine("某个小时内的笔记太多，没有取全；缩小时间范围可以看到更完整的结果。") }
            }
            data.todoNote?.let { note -> item(key = "rv-todo-note") { NoticeLine(note) } }

            if (data.isEmpty) {
                item(key = "rv-empty") { InfoCard("这段时间没有记录", "换个范围看看，或者回到「记录」页写下第一条。") }
            } else {
                val today = LocalDate.now()
                data.days.forEach { day ->
                    item(key = "rv-day-${day.date}") {
                        DaySection(day, today, isDayOpen(day.date), { onToggleDay(day.date) }, onOpenNote, onOpenTodo, onToggleTodo, revisit, Modifier.animateItem())
                    }
                }
            }
        }
    }
}

/** 节点的类型 */
private enum class Kind { DAILY, NOTE, TODO, TODO_DONE, TODO_OVERDUE }

@Composable
private fun DaySection(
    day: DayBucket,
    today: LocalDate,
    open: Boolean,
    onToggle: () -> Unit,
    onOpenNote: (String) -> Unit,
    onOpenTodo: (DidaTask) -> Unit,
    onToggleTodo: (DidaTask) -> Unit,
    revisit: RevisitActions,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    val isToday = day.date == today
    val rows = remember(day) { rowsOf(day) }
    // 不是本月的日子带上月份，免得只看到一个「6」不知道是哪个月
    val weekday = TimeRanges.weekdayName(day.date).let { w ->
        if (day.date.year != today.year || day.date.month != today.month) "${day.date.monthValue}月 $w" else w
    }
    val counts = listOfNotNull(
        day.daily.size.takeIf { it > 0 }?.let { "$it 日记" },
        day.notes.size.takeIf { it > 0 }?.let { "$it 笔记" },
        day.todos.size.takeIf { it > 0 }?.let { "${day.todos.count { t -> t.done }}/$it 待办" },
    ).joinToString(" · ")

    Column(modifier.fillMaxWidth().padding(bottom = 6.dp).animateContentSize()) {
        Row(
            modifier = Modifier.fillMaxWidth().height(40.dp).clickable(onClick = onToggle),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                day.date.dayOfMonth.toString(),
                fontSize = 28.sp,
                lineHeight = 34.sp,
                fontWeight = FontWeight.Black,
            )
            Spacer(Modifier.width(8.dp))
            Text(weekday, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.ExtraBold)
            if (isToday) {
                Spacer(Modifier.width(8.dp))
                Box(
                    Modifier.clip(CircleShape).background(Brand.Orange).padding(horizontal = 8.dp, vertical = 2.dp),
                ) {
                    Text("今天", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, color = Brand.Brown)
                }
            }
            Box(Modifier.weight(1f))
            Text(counts, style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant, maxLines = 1)
            Icon(
                if (open) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                contentDescription = if (open) "收起" else "展开",
                tint = scheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 4.dp).size(20.dp),
            )
        }
        if (open) {
            rows.forEachIndexed { i, row ->
                val first = i == 0
                val last = i == rows.lastIndex
                when (row) {
                    is RiverRow.Daily -> DailyLine(row, day.date, first, last, onOpenNote, revisit)
                    is RiverRow.Note -> NoteLine(row.note, first, last, onOpenNote, revisit)
                    is RiverRow.Todo -> TodoLine(row.task, row.clock, row.overdue, first, last, onOpenTodo, onToggleTodo)
                }
            }
        }
    }
}

/**
 * 一行 = 时间（右对齐）+ 竖线上的节点 + 正文。竖线在每一行里各画一段，行与行之间连成一条；
 * 节点周围留出 3dp 的空隙，所以空心环里不会透出线。
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TimelineRow(
    clock: String,
    kind: Kind,
    first: Boolean,
    last: Boolean,
    onClick: (() -> Unit)?,
    onNodeClick: (() -> Unit)? = null,
    /** 长按整行（笔记 / 日记：弹出「加入重温」菜单） */
    onLongClick: (() -> Unit)? = null,
    /** 没有具体时间的待办：时间位置显示「全天」标签 */
    allDay: Boolean = false,
    content: @Composable ColumnScope.() -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    val overdueColor = scheme.error
    val line = scheme.onSurface.copy(alpha = 0.14f)
    val ink = scheme.onSurface
    val muted = scheme.onSurfaceVariant
    val haptic = LocalHapticFeedback.current
    Box(Modifier.fillMaxWidth()) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(
                when {
                    onClick != null && onLongClick != null -> Modifier.combinedClickable(
                        onClick = onClick,
                        onLongClick = {
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            onLongClick()
                        },
                    )
                    onClick != null -> Modifier.clickable(onClick = onClick)
                    else -> Modifier
                },
            )
            .drawBehind {
                val x = RAIL_X.dp.toPx()
                val nodeY = NODE_Y.dp.toPx()
                val gap = 9.dp.toPx()
                val sw = 2.dp.toPx()
                if (!first) drawLine(line, Offset(x, 0f), Offset(x, nodeY - gap), sw)
                if (!last) drawLine(line, Offset(x, nodeY + gap), Offset(x, size.height), sw)
                // 一眼分清：待办 = 方块（空心 = 没做，实心 = 做完），笔记 = 三角，日记 = 圆
                when (kind) {
                    Kind.DAILY -> drawCircle(Brand.Orange, 6.dp.toPx(), Offset(x, nodeY))
                    Kind.NOTE -> {
                        // 和方块一样大（外沿约 11dp），实心；圆角靠描边的圆形拐角
                        val r = 4.8.dp.toPx()
                        val tri = Path().apply {
                            moveTo(x, nodeY - r)
                            lineTo(x + r, nodeY + r * 0.8f)
                            lineTo(x - r, nodeY + r * 0.8f)
                            close()
                        }
                        drawPath(tri, ink, style = androidx.compose.ui.graphics.drawscope.Fill)
                        drawPath(tri, ink, style = Stroke(1.5.dp.toPx(), join = StrokeJoin.Round))
                    }
                    Kind.TODO, Kind.TODO_OVERDUE -> drawRoundRect(
                        if (kind == Kind.TODO_OVERDUE) overdueColor else ink,
                        topLeft = Offset(x - 4.75.dp.toPx(), nodeY - 4.75.dp.toPx()),
                        size = Size(9.5.dp.toPx(), 9.5.dp.toPx()),
                        cornerRadius = CornerRadius(2.dp.toPx()),
                        style = Stroke(2.5.dp.toPx()),
                    )
                    Kind.TODO_DONE -> drawRoundRect(
                        muted,
                        topLeft = Offset(x - 5.5.dp.toPx(), nodeY - 5.5.dp.toPx()),
                        size = Size(11.dp.toPx(), 11.dp.toPx()),
                        cornerRadius = CornerRadius(2.5.dp.toPx()),
                    )
                }
            }
            .padding(vertical = 8.dp),
    ) {
        // 竖线靠左，和日期「13」里的「1」对齐；时间放在节点右边、正文左边
        Spacer(Modifier.width(CLOCK_X.dp))
        if (allDay) {
            Box(Modifier.width(CLOCK_W.dp).padding(top = 3.dp)) {
                Text(
                    "全天",
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Black,
                    color = if (kind == Kind.TODO_OVERDUE) overdueColor else scheme.primary,
                    maxLines = 1,
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .background((if (kind == Kind.TODO_OVERDUE) overdueColor else scheme.primary).copy(alpha = 0.12f))
                        .padding(horizontal = 5.dp, vertical = 1.dp),
                )
            }
        } else {
            Text(
                clock,
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.Black,
                color = if (kind == Kind.TODO_OVERDUE) overdueColor else scheme.primary,
                textAlign = TextAlign.Start,
                maxLines = 1,
                modifier = Modifier.width(CLOCK_W.dp).padding(top = 3.dp),
            )
        }
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f), content = content)
    }
    // 节点本身只有 12dp，点按区域放大到 24 × 36dp（再往右就是时间了）
    if (onNodeClick != null) {
        Box(
            Modifier
                .offset(x = 0.dp, y = (NODE_Y - 18).dp)
                .size(width = CLOCK_X.dp - 2.dp, height = 36.dp)
                .clip(CircleShape)
                .clickable(onClick = onNodeClick),
        )
    }
    }
}

/**
 * 竖线在 9dp（日期头「13」里「1」的中线）；节点 12dp 宽，往右留出空隙后是时间（36dp 宽，从 26dp 起），再是正文；
 * 节点中心距行顶 19dp，对齐第一行文字的中线
 */
private const val CLOCK_X = 26
private const val CLOCK_W = 36
private const val RAIL_X = 9
private const val NODE_Y = 19

/** 日记一句：没有标题，整句就是内容；点一下打开那一天的 Daily Note 全文，长按可以加入重温 */
@Composable
private fun DailyLine(
    row: RiverRow.Daily,
    date: LocalDate,
    first: Boolean,
    last: Boolean,
    onOpenNote: (String) -> Unit,
    revisit: RevisitActions,
) {
    val inRevisit = RevisitRepository.snippetKey(row.noteId, row.entry.text) in revisit.keys
    var menu by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    TimelineRow(
        clock = row.entry.time,
        kind = Kind.DAILY,
        first = first,
        last = last,
        onClick = row.noteId?.let { id -> { onOpenNote(id) } },
        onLongClick = { menu = true },
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Text(
                row.entry.text,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.SemiBold,
                textDecoration = if (row.entry.struck) androidx.compose.ui.text.style.TextDecoration.LineThrough else null,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            if (inRevisit) RevisitMark()
        }
        RevisitMenu(menu, inRevisit, onDismiss = { menu = false }, onDelete = { confirmDelete = true }) {
            revisit.onDaily(row.entry, row.noteId, date, inRevisit)
        }
        if (confirmDelete) {
            ConfirmDialog(
                title = "删除这条日记？",
                text = "将从 $date 的 Daily Note 里删掉：\n\n${row.entry.text.take(120)}",
                confirmLabel = "删除",
                onDismiss = { confirmDelete = false },
                onConfirm = {
                    confirmDelete = false
                    revisit.onDeleteDaily(row.entry, date)
                },
            )
        }
    }
}

/** 已加入重温的小标记（时间河上一眼能看出哪些会回来） */
@Composable
private fun RevisitMark() {
    Icon(
        painterResource(R.drawable.ic_revisit),
        contentDescription = "已加入重温",
        tint = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 6.dp, top = 4.dp).size(14.dp),
    )
}

@Composable
private fun RevisitMenu(
    expanded: Boolean,
    inRevisit: Boolean,
    onDismiss: () -> Unit,
    /** 菜单里的「删除」类项目：文字、图标和动作；没有就不显示 */
    onDelete: (() -> Unit)? = null,
    deleteText: String = "删除",
    deleteIcon: Int? = null,
    onToggle: () -> Unit,
) {
    AppMenu(expanded = expanded, onDismissRequest = onDismiss) {
        AppMenuItem(
            text = { Text(if (inRevisit) "移出重温" else "加入重温") },
            leadingIcon = { Icon(painterResource(R.drawable.ic_revisit), contentDescription = null) },
            onClick = {
                onDismiss()
                onToggle()
            },
        )
        if (onDelete != null) {
            AppMenuItem(
                text = { Text(deleteText) },
                leadingIcon = {
                    if (deleteIcon != null) Icon(painterResource(deleteIcon), contentDescription = null)
                    else Icon(Icons.Filled.Delete, contentDescription = null)
                },
                onClick = {
                    onDismiss()
                    onDelete()
                },
            )
        }
    }
}

@Composable
private fun NoteLine(note: NoteInfo, first: Boolean, last: Boolean, onOpenNote: (String) -> Unit, revisit: RevisitActions) {
    val scheme = MaterialTheme.colorScheme
    val inRevisit = RevisitRepository.noteKey(note.id) in revisit.keys
    val context = androidx.compose.ui.platform.LocalContext.current
    var menu by remember { mutableStateOf(false) }
    TimelineRow(
        clock = note.localClock.orEmpty(),
        kind = Kind.NOTE,
        first = first,
        last = last,
        onClick = { onOpenNote(note.id) },
        onLongClick = { menu = true },
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Text(
                note.title,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Bold,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            if (inRevisit) RevisitMark()
        }
        if (!note.summary.isNullOrBlank()) {
            Text(
                note.summary,
                style = MaterialTheme.typography.bodySmall,
                color = scheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        // 闪念贝壳的接口不能删除笔记：「删除」跳到闪念贝壳里的这条笔记，在那边删
        RevisitMenu(
            menu, inRevisit,
            onDismiss = { menu = false },
            onDelete = { openIdeaShellNote(context, note.id) },
            deleteText = "在闪念贝壳中删除",
            deleteIcon = R.drawable.ic_open_in_new,
        ) { revisit.onNote(note, inRevisit) }
    }
}

@Composable
private fun TodoLine(
    task: DidaTask,
    clock: String,
    overdue: Boolean,
    first: Boolean,
    last: Boolean,
    onOpenTodo: (DidaTask) -> Unit,
    onToggleTodo: (DidaTask) -> Unit,
) {
    val error = MaterialTheme.colorScheme.error
    TimelineRow(
        clock = clock,
        kind = if (task.done) Kind.TODO_DONE else if (overdue) Kind.TODO_OVERDUE else Kind.TODO,
        first = first,
        last = last,
        onClick = { onOpenTodo(task) },
        onNodeClick = { onToggleTodo(task) },
        allDay = clock.isEmpty(),
    ) {
        Text(
            TodoMeta.cleanTitle(task.title),
            style = MaterialTheme.typography.bodyLarge,
            fontWeight = FontWeight.SemiBold,
            textDecoration = if (task.done) TextDecoration.LineThrough else null,
            color = if (task.done) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        if (overdue) {
            Text("已逾期", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold, color = error)
        }
    }
}
