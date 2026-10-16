package com.carpe.ideashell.ui.todos

import androidx.compose.animation.core.tween
import kotlinx.coroutines.launch
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.core.calendar.ChinaHolidays
import com.carpe.ideashell.core.calendar.DayInfo
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.data.dida.DidaOverview
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.project.Workspace
import com.carpe.ideashell.ui.glass.GlassSupported
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import com.carpe.ideashell.ui.theme.Brand
import java.time.Instant
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import kotlin.math.roundToInt

/*
 * 待办页的「日历」视图：整月大格子，每个格子里按任务画色块（颜色按所在清单），一眼看清这个月哪天排满了。
 * 左右滑动或点上方箭头切月；点某一天从下面弹出当天的任务；
 * 底部一条「无日期」托盘：长按任务拖到某一天，就把它安排到那天（全天）。
 */

private const val WEEK_HEAD = "一二三四五六日"
private val CHIP_COLORS = listOf(
    Color(0xFFE8794A), Color(0xFF3FA37C), Color(0xFF5B8DEF), Color(0xFF9B7BE0),
    Color(0xFFE86F9A), Color(0xFF2FAFC0), Color(0xFFD9A52B), Color(0xFF8A9A5B),
)
private val CHIP_HEIGHT = 14.dp
private val CHIP_PITCH = 16.dp
private val DATE_ROW = 30.dp

/** 色块颜色：同一个清单的任务颜色一致 */
internal fun chipColor(task: DidaTask): Color =
    CHIP_COLORS[Math.floorMod(task.projectId.hashCode(), CHIP_COLORS.size)]

private fun dayOf(task: DidaTask, zone: ZoneId): LocalDate? {
    val planned = task.date?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
    // 和滴答一致：已完成的任务仍然画在计划的那天（改期到 17 号、16 号提前点完成，它还在 17 号）；没有计划日期的才按完成那天
    return planned ?: if (task.done) task.completedAt?.let { Instant.ofEpochMilli(it).atZone(zone).toLocalDate() } else null
}

/**
 * 日历上每天的任务：概览里的未完成任务为准，再补上日历自己读到的更远日期的；已完成的仍画在计划那天（没有计划日期的才画在完成那天）。
 * 同一天里：未完成的在前（按时间、优先级），已完成的在后。
 */
internal fun tasksByDay(overview: DidaOverview?, ranged: Map<String, DidaTask>): Map<LocalDate, List<DidaTask>> {
    val zone = ZoneId.systemDefault()
    val open = LinkedHashMap<String, DidaTask>()
    overview?.let { o -> (o.overdue + o.upcoming).forEach { open[it.id] = it } }
    ranged.values.forEach { if (!it.done && it.id !in open) open[it.id] = it }
    val done = overview?.done.orEmpty() + ranged.values.filter { it.done }

    val seen = HashSet<String>()
    val out = HashMap<LocalDate, MutableList<DidaTask>>()
    for (t in open.values + done) {
        val d = dayOf(t, zone) ?: continue
        if (!seen.add("${t.id}|${t.done}|$d")) continue
        out.getOrPut(d) { mutableListOf() } += t
    }
    return out.mapValues { (_, list) ->
        list.sortedWith(compareBy<DidaTask>({ it.done }, { it.time ?: "99:99" }, { -it.priority }))
    }
}

/** 日历里「当天任务面板」的挂载点：面板内容由 CalendarPage 提供，由 TodoScreen 画在整页最上层 */
internal class CalSheetHost {
    var content by mutableStateOf<(@Composable () -> Unit)?>(null)
    var blurred by mutableStateOf(false)

    /** 面板升起的进度 0..1（磨砂强度跟着它走，面板落下时磨砂同步退掉） */
    var progress by mutableFloatStateOf(0f)
}

@Composable
internal fun CalSheetLayer(host: CalSheetHost) {
    host.content?.invoke()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CalendarPage(
    viewModel: TodoViewModel,
    overview: DidaOverview?,
    today: LocalDate,
    workspace: Workspace,
    onOpenTask: (DidaTask) -> Unit,
    onOpenDay: (LocalDate) -> Unit,
    onAddOnDay: (LocalDate) -> Unit,
    onCollapse: () -> Unit,
    sheetHost: CalSheetHost,
    onDragStart: () -> Unit,
    onDragBy: (Float) -> Unit,
    onDragStop: (Float) -> Unit,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    // 往上推收起：进度跟着手指，松手顺势滑完
    val collapseDrag = rememberDraggableState { onDragBy(it) }
    val haptic = LocalHapticFeedback.current
    val ranged by viewModel.ranged.collectAsStateWithLifecycle()
    val month = viewModel.calMonth
    val (gridStart, gridEnd) = remember(month) { viewModel.gridRange(month) }
    LaunchedEffect(month) { viewModel.loadCalendar(month) }

    val byDay = remember(overview, ranged) { tasksByDay(overview, ranged) }
    val undated = overview?.undated.orEmpty()

    // 拖拽：被拖的任务、手指在屏幕上的位置、每个格子的屏幕范围（换月就重新登记）
    var dragging by remember { mutableStateOf<DidaTask?>(null) }
    var dragPos by remember { mutableStateOf(Offset.Zero) }
    val pageOrigin = remember { floatArrayOf(0f, 0f) }
    val bounds = remember(month) { HashMap<LocalDate, Rect>() }
    val hover by remember(month) {
        derivedStateOf {
            if (dragging == null) null else bounds.entries.firstOrNull { it.value.contains(dragPos) }?.key
        }
    }
    val hoverNow by rememberUpdatedState(hover)
    // 点某一天（或「+N」）浮出的当天任务面板：面板里的任务也能长按拖到别的日期
    var sheetDay by remember { mutableStateOf<LocalDate?>(null) }

    fun endDrag(drop: Boolean) {
        val task = dragging
        val target = hoverNow
        dragging = null
        sheetDay = null
        if (!drop || task == null || target == null) return
        when {
            target < today -> viewModel.notice("不能把任务安排到过去")
            // 有日期的任务拖到别的天：保留原来的时间点，只改日期；拖回原来那天什么都不做
            task.date != null -> if (task.date != target.toString()) viewModel.moveByDrag(task, target)
            else -> viewModel.scheduleByDrag(task, target)
        }
    }

    val chipDrag = ChipDrag(
        draggingId = dragging?.id,
        onStart = { task, pos ->
            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
            dragging = task
            dragPos = pos
        },
        onMove = { dragPos += it },
        onEnd = { endDrag(true) },
        onCancel = { endDrag(false) },
        onMore = { sheetDay = it },
    )

    // 点某一天：当天任务面板浮在整页上面（交给外层 TodoScreen 画，这样标题栏和日历能被同一次磨砂盖住，
    // 和底部弹出面板一个效果）；拖起一条时面板透明（不挡住格子，但手势还在它上面继续），松手后收起
    val sheetContent: (@Composable () -> Unit)? = sheetDay?.let { day ->
        {
            DaySheet(
                day = day,
                tasks = byDay[day].orEmpty(),
                today = today,
                overview = overview,
                workspace = workspace,
                canOpenTimeline = day >= today.minusDays(PAST_DAYS.toLong()) && day <= today.plusDays(6),
                hidden = dragging != null,
                drag = chipDrag,
                onDismiss = { sheetDay = null },
                onToggle = { t -> if (t.done) viewModel.undoComplete(t) else viewModel.complete(t) },
                onOpenTask = onOpenTask,
                onAdd = { sheetDay = null; onAddOnDay(day) },
                onTimeline = { sheetDay = null; onOpenDay(day) },
                host = sheetHost,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
    val pageBlurred = GlassSupported && sheetDay != null && dragging == null
    androidx.compose.runtime.SideEffect {
        sheetHost.content = sheetContent
        sheetHost.blurred = pageBlurred
    }
    androidx.compose.runtime.DisposableEffect(Unit) {
        onDispose {
            sheetHost.content = null
            sheetHost.blurred = false
            sheetHost.progress = 0f
        }
    }

    Box(
        modifier = modifier.onGloballyPositioned {
            val p = it.positionInRoot()
            pageOrigin[0] = p.x
            pageOrigin[1] = p.y
        },
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .padding(bottom = LocalBottomBarPadding.current),
        ) {
            // 顶上的小横条：往上拖一小段或点一下，回到任务视图（和任务视图里往下拖进来对应）
            PullHandle(
                onClick = onCollapse,
                modifier = Modifier.draggable(
                    state = collapseDrag,
                    orientation = Orientation.Vertical,
                    onDragStarted = { onDragStart() },
                    onDragStopped = { onDragStop(it) },
                ),
            )
            MonthBar(
                month = month,
                today = today,
                loading = viewModel.calLoading,
                onMonth = { viewModel.calMonth = it },
            )
            // 整月放在一张圆角卡片里：星期条在上，格子在下；左右划切月，往上划退出
            Column(
                Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp)
                    .clip(RoundedCornerShape(28.dp))
                    .background(scheme.surfaceContainerLowest)
                    .padding(horizontal = 6.dp, vertical = 8.dp)
                    .draggable(
                        state = collapseDrag,
                        orientation = Orientation.Vertical,
                        onDragStarted = { onDragStart() },
                        onDragStopped = { onDragStop(it) },
                    )
                    .pointerInput(month) {
                        var total = 0f
                        detectHorizontalDragGestures(
                            onDragStart = { total = 0f },
                            onDragCancel = { total = 0f },
                            onDragEnd = {
                                if (total > 100f) viewModel.calMonth = month.minusMonths(1)
                                else if (total < -100f) viewModel.calMonth = month.plusMonths(1)
                            },
                            onHorizontalDrag = { _, dx -> total += dx },
                        )
                    },
            ) {
                Row(Modifier.fillMaxWidth().padding(bottom = 2.dp)) {
                    WEEK_HEAD.forEachIndexed { i, c ->
                        Text(
                            c.toString(),
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.Bold,
                            color = if (i >= 5) Brand.OrangeDeep.copy(alpha = 0.85f) else scheme.onSurfaceVariant,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.weight(1f).padding(vertical = 4.dp),
                        )
                    }
                }
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    MonthGrid(
                        month = month,
                        gridStart = gridStart,
                        gridEnd = gridEnd,
                        today = today,
                        byDay = byDay,
                        hover = hover?.takeIf { it >= today },
                        bounds = bounds,
                        onDay = { sheetDay = it },
                        chipDrag = chipDrag,
                    )
                }
            }
            if (undated.isNotEmpty()) {
                UndatedTray(
                    tasks = undated,
                    draggingId = dragging?.id,
                    onOpen = onOpenTask,
                    onStart = { task, pos ->
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        dragging = task
                        dragPos = pos
                    },
                    onMove = { dragPos += it },
                    onEnd = { endDrag(true) },
                    onCancel = { endDrag(false) },
                )
            }
        }

        // 被拖着走的任务：浮在手指上方一点，手指下面的那天会高亮
        dragging?.let { task ->
            Box(
                Modifier
                    .offset {
                        IntOffset(
                            (dragPos.x - pageOrigin[0]).roundToInt() - 70.dp.roundToPx(),
                            (dragPos.y - pageOrigin[1]).roundToInt() - 64.dp.roundToPx(),
                        )
                    }
                    .shadow(8.dp, CircleShape)
                    .clip(CircleShape)
                    .background(scheme.surface)
                    .background(chipColor(task).copy(alpha = 0.35f))
                    .height(36.dp)
                    .widthIn(max = 170.dp)
                    .padding(horizontal = 14.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    TodoMeta.cleanTitle(task.title),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

// ───────────────────────── 月份条 ─────────────────────────

/** 左边大大的月份（年份小字跟在后面），右边是翻月的两个圆钮；不在本月时多一个深色的「今天」 */
@Composable
private fun MonthBar(month: YearMonth, today: LocalDate, loading: Boolean, onMonth: (YearMonth) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Row(
        Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp, top = 2.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "${month.monthValue}月",
            fontSize = 26.sp,
            lineHeight = 30.sp,
            fontWeight = FontWeight.Black,
            color = scheme.onSurface,
        )
        Text(
            "${month.year}",
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.Bold,
            color = scheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 8.dp, top = 6.dp),
        )
        if (loading) {
            CircularProgressIndicator(Modifier.padding(start = 10.dp, top = 6.dp).size(14.dp), strokeWidth = 2.dp)
        }
        Box(Modifier.weight(1f))
        if (month != YearMonth.from(today)) {
            Box(
                modifier = Modifier
                    .padding(end = 8.dp)
                    .height(36.dp)
                    .clip(CircleShape)
                    .background(scheme.inverseSurface)
                    .clickable { onMonth(YearMonth.from(today)) }
                    .padding(horizontal = 14.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text("今天", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.ExtraBold, color = scheme.inverseOnSurface)
            }
        }
        NavArrow("‹") { onMonth(month.minusMonths(1)) }
        Box(Modifier.width(8.dp))
        NavArrow("›") { onMonth(month.plusMonths(1)) }
    }
}

@Composable
private fun NavArrow(text: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(36.dp)
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.surfaceContainerLowest)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, fontSize = 22.sp, lineHeight = 22.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(bottom = 3.dp))
    }
}

// ───────────────────────── 月格子 ─────────────────────────

@Composable
private fun MonthGrid(
    month: YearMonth,
    gridStart: LocalDate,
    gridEnd: LocalDate,
    today: LocalDate,
    byDay: Map<LocalDate, List<DidaTask>>,
    hover: LocalDate?,
    bounds: HashMap<LocalDate, Rect>,
    onDay: (LocalDate) -> Unit,
    chipDrag: ChipDrag,
) {
    val weeks = (ChronoUnit.DAYS.between(gridStart, gridEnd).toInt() + 1) / 7
    // 每格能放几个色块只在这里算一次（每个格子各自用 BoxWithConstraints 量高度，一屏 35~42 个，进入时会明显卡）
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val capacity = ((maxHeight / weeks - DATE_ROW) / CHIP_PITCH).toInt().coerceAtLeast(0)
        MonthRows(month, gridStart, weeks, today, byDay, hover, bounds, capacity, onDay, chipDrag)
    }
}

@Composable
private fun MonthRows(
    month: YearMonth,
    gridStart: LocalDate,
    weeks: Int,
    today: LocalDate,
    byDay: Map<LocalDate, List<DidaTask>>,
    hover: LocalDate?,
    bounds: HashMap<LocalDate, Rect>,
    capacity: Int,
    onDay: (LocalDate) -> Unit,
    chipDrag: ChipDrag,
) {
    val line = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.07f)
    Column(Modifier.fillMaxSize()) {
        repeat(weeks) { w ->
            // 只在周与周之间画一条淡淡的横线（两头留白），没有竖线
            Row(
                Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .drawBehind {
                        if (w > 0) drawLine(line, Offset(10.dp.toPx(), 0f), Offset(size.width - 10.dp.toPx(), 0f), 1.dp.toPx())
                    },
            ) {
                repeat(7) { d ->
                    val day = gridStart.plusDays((w * 7 + d).toLong())
                    DayCell(
                        day = day,
                        inMonth = YearMonth.from(day) == month,
                        isToday = day == today,
                        weekend = d >= 5,
                        hovered = hover == day,
                        tasks = byDay[day].orEmpty(),
                        capacity = capacity,
                        chipDrag = chipDrag,
                        onClick = { onDay(day) },
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxHeight()
                            .onGloballyPositioned { bounds[day] = it.boundsInRoot() },
                    )
                }
            }
        }
    }
}

@Composable
private fun DayCell(
    day: LocalDate,
    inMonth: Boolean,
    isToday: Boolean,
    weekend: Boolean,
    hovered: Boolean,
    tasks: List<DidaTask>,
    capacity: Int,
    chipDrag: ChipDrag,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    // 不在本月的日子淡一点：直接调颜色，不用整块半透明（那会给每个格子单独开一层离屏缓冲）
    val fade = if (inMonth) 1f else 0.45f
    val holiday = ChinaHolidays.of(day)
    Box(
        modifier
            .padding(1.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(if (hovered) Brand.Orange.copy(alpha = 0.22f) else Color.Transparent)
            .clickable(onClick = onClick),
    ) {
        val shown = if (tasks.size <= capacity) tasks else tasks.take((capacity - 1).coerceAtLeast(0))
        val hidden = tasks.size - shown.size
        Column(
            Modifier
                .fillMaxSize()
                .padding(top = 4.dp, start = 2.dp, end = 2.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // 今天是深色实心圆（和上面日期带选中的那格同一种墨色），其余只是数字
            Box(
                Modifier
                    .size(24.dp)
                    .clip(CircleShape)
                    .then(if (isToday) Modifier.background(scheme.inverseSurface) else Modifier),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    day.dayOfMonth.toString(),
                    fontSize = 13.sp,
                    lineHeight = 16.sp,
                    fontWeight = if (isToday) FontWeight.Black else FontWeight.Bold,
                    color = when {
                        isToday -> scheme.inverseOnSurface
                        weekend -> scheme.onSurface.copy(alpha = 0.62f * fade)
                        else -> scheme.onSurface.copy(alpha = fade)
                    },
                )
            }
            Box(Modifier.height(2.dp))
            shown.forEach { TaskChip(it, fade, chipDrag) }
            if (hidden > 0) {
                Text(
                    "+$hidden",
                    fontSize = 10.sp,
                    lineHeight = 12.sp,
                    fontWeight = FontWeight.ExtraBold,
                    color = Brand.OrangeDeep.copy(alpha = fade),
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .clickable { chipDrag.onMore(day) }
                        .padding(horizontal = 8.dp, vertical = 2.dp),
                )
            }
        }
        if (holiday != null) {
            val off = holiday.kind == ChinaHolidays.Kind.OFF
            val tone = if (off) Color(0xFF2E9D6B) else Color(0xFFD2553A)
            Text(
                if (off) "休" else "班",
                fontSize = 8.sp,
                lineHeight = 9.sp,
                fontWeight = FontWeight.ExtraBold,
                color = tone.copy(alpha = fade),
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(top = 3.dp, end = 3.dp)
                    .clip(RoundedCornerShape(4.dp))
                    .background(tone.copy(alpha = 0.14f * fade))
                    .padding(horizontal = 3.dp, vertical = 1.dp),
            )
        }
    }
}

/** 月格子里的色块拖拽：长按有日期的任务，拖到别的日子改期（和无日期托盘共用同一套浮层 / 落点） */
internal class ChipDrag(
    val draggingId: String?,
    val onStart: (DidaTask, Offset) -> Unit,
    val onMove: (Offset) -> Unit,
    val onEnd: () -> Unit,
    val onCancel: () -> Unit,
    /** 点格子里的「+N」：展开这一天的全部任务 */
    val onMore: (LocalDate) -> Unit = {},
)

/** 一条任务：方方正正的淡色块（颜色按清单），字不加粗；已完成的更淡、加删除线。未完成的可以长按拖到别的日子 */
@Composable
private fun TaskChip(task: DidaTask, fade: Float, drag: ChipDrag) {
    val scheme = MaterialTheme.colorScheme
    val bg = chipColor(task).copy(alpha = (if (task.done) 0.12f else 0.26f) * fade)
    // 色块自己在屏幕上的位置：长按起点是色块内的坐标，加上它才是屏幕坐标
    val origin = remember { floatArrayOf(0f, 0f) }
    val latest = rememberUpdatedState(drag)
    Text(
        TodoMeta.cleanTitle(task.title),
        fontSize = 8.sp,
        lineHeight = 10.sp,
        maxLines = 1,
        overflow = TextOverflow.Clip,
        fontWeight = FontWeight.Normal,
        color = scheme.onSurface.copy(alpha = (if (task.done) 0.45f else 0.9f) * fade),
        textDecoration = if (task.done) TextDecoration.LineThrough else null,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 1.dp)
            .height(CHIP_HEIGHT - 2.dp)
            .onGloballyPositioned {
                val p = it.positionInRoot()
                origin[0] = p.x
                origin[1] = p.y
            }
            .graphicsLayer { alpha = if (drag.draggingId == task.id) 0.25f else 1f }
            .background(bg)
            .then(
                if (task.done) Modifier else Modifier.pointerInput(task.id, task.date) {
                    detectDragGesturesAfterLongPress(
                        onDragStart = { local -> latest.value.onStart(task, Offset(origin[0] + local.x, origin[1] + local.y)) },
                        onDrag = { change, amount ->
                            change.consume()
                            latest.value.onMove(amount)
                        },
                        onDragEnd = { latest.value.onEnd() },
                        onDragCancel = { latest.value.onCancel() },
                    )
                },
            )
            .padding(horizontal = 3.dp),
    )
}

// ───────────────────────── 无日期托盘（拖拽的起点） ─────────────────────────

@Composable
private fun UndatedTray(
    tasks: List<DidaTask>,
    draggingId: String?,
    onOpen: (DidaTask) -> Unit,
    onStart: (DidaTask, Offset) -> Unit,
    onMove: (Offset) -> Unit,
    onEnd: () -> Unit,
    onCancel: () -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .padding(top = 10.dp)
            .clip(RoundedCornerShape(24.dp))
            .background(scheme.surfaceContainerLowest)
            .padding(top = 12.dp),
    ) {
        Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("无日期", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.ExtraBold)
            Text(
                tasks.size.toString(),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.Bold,
                color = Brand.OrangeDeep,
                modifier = Modifier
                    .padding(start = 8.dp)
                    .clip(CircleShape)
                    .background(Brand.Orange.copy(alpha = 0.18f))
                    .padding(horizontal = 8.dp, vertical = 1.dp),
            )
            Box(Modifier.weight(1f))
            Text("长按拖到日期", style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant)
        }
        LazyRow(
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(tasks, key = { it.id }) { task ->
                UndatedChip(
                    task = task,
                    hidden = task.id == draggingId,
                    onOpen = { onOpen(task) },
                    onStart = { onStart(task, it) },
                    onMove = onMove,
                    onEnd = onEnd,
                    onCancel = onCancel,
                )
            }
        }
    }
}

@Composable
private fun UndatedChip(
    task: DidaTask,
    hidden: Boolean,
    onOpen: () -> Unit,
    onStart: (Offset) -> Unit,
    onMove: (Offset) -> Unit,
    onEnd: () -> Unit,
    onCancel: () -> Unit,
) {
    // 芯片自己在屏幕上的位置：长按起点是芯片内的坐标，加上它才是屏幕坐标
    val origin = remember { floatArrayOf(0f, 0f) }
    Box(
        Modifier
            .widthIn(max = 170.dp)
            .height(36.dp)
            .onGloballyPositioned {
                val p = it.positionInRoot()
                origin[0] = p.x
                origin[1] = p.y
            }
            .graphicsLayer { alpha = if (hidden) 0.25f else 1f }
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.surfaceContainerHigh)
            .clickable(onClick = onOpen)
            .pointerInput(task.id) {
                detectDragGesturesAfterLongPress(
                    onDragStart = { local -> onStart(Offset(origin[0] + local.x, origin[1] + local.y)) },
                    onDrag = { change, amount ->
                        change.consume()
                        onMove(amount)
                    },
                    onDragEnd = onEnd,
                    onDragCancel = onCancel,
                )
            }
            .padding(horizontal = 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(chipColor(task)))
            Text(
                TodoMeta.cleanTitle(task.title),
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(start = 8.dp),
            )
        }
    }
}

// ───────────────────────── 点某一天：当天的任务 ─────────────────────────

/** 不用 ModalBottomSheet（它是另一个窗口，手指拖不到下面的日期格子），而是浮在日历上的一块面板 */
@Composable
private fun DaySheet(
    day: LocalDate,
    tasks: List<DidaTask>,
    today: LocalDate,
    overview: DidaOverview?,
    workspace: Workspace,
    canOpenTimeline: Boolean,
    hidden: Boolean,
    drag: ChipDrag,
    onDismiss: () -> Unit,
    onToggle: (DidaTask) -> Unit,
    onOpenTask: (DidaTask) -> Unit,
    onAdd: () -> Unit,
    onTimeline: () -> Unit,
    host: CalSheetHost,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    val info = remember(day) { DayInfo.of(day) }
    val maxBody = (LocalConfiguration.current.screenHeightDp * 0.5f).dp
    // 和底部抽屉一样：从下面升起来、遮罩渐显；关的时候落回去再真正移除
    val rise = remember { androidx.compose.animation.core.Animatable(0f) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var closing by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        rise.animateTo(1f, tween(320, easing = androidx.compose.animation.core.FastOutSlowInEasing))
    }
    LaunchedEffect(Unit) { androidx.compose.runtime.snapshotFlow { rise.value }.collect { host.progress = it } }
    fun closeThen(then: () -> Unit) {
        if (closing) return
        closing = true
        scope.launch {
            rise.animateTo(0f, tween(220, easing = androidx.compose.animation.core.FastOutLinearInEasing))
            then()
        }
    }
    androidx.activity.compose.BackHandler(onBack = { closeThen(onDismiss) })
    // 面板像系统底部抽屉一样盖住底部导航：打开时收起导航，关掉（或离开）时放回来
    androidx.compose.runtime.DisposableEffect(Unit) {
        com.carpe.ideashell.ui.glass.NavBarOverlay.hidden = true
        onDispose { com.carpe.ideashell.ui.glass.NavBarOverlay.hidden = false }
    }
    Box(
        modifier
            // 拖着走的时候整块透明，露出下面的格子；仍在组合里，所以手势不会中断
            .graphicsLayer { alpha = if (hidden) 0f else 1f }
            .drawBehind { drawRect(Color.Black.copy(alpha = (if (GlassSupported) 0.22f else 0.32f) * rise.value)) }
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = { closeThen(onDismiss) }),
        contentAlignment = Alignment.BottomCenter,
    ) {
        // 和底部弹出面板（GlassSheet）同一个样子：半透明的奶油面、28dp 顶部圆角、顶部拖动条；背后的日历已经磨砂
        Column(
            Modifier
                .fillMaxWidth()
                // 从屏幕底下升起：位移 = (1 - 进度) × 面板自身高度
                .graphicsLayer { translationY = (1f - rise.value) * size.height }
                .clip(RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp))
                .background(scheme.surface.copy(alpha = if (GlassSupported) 0.82f else 1f))
                .navigationBarsPadding()
                // 吃掉面板上的点击，免得穿到下面的遮罩把面板关掉
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = {}),
        ) {
            // 拖动条：和 Material 底部面板的 DragHandle 同尺寸同间距
            Box(
                Modifier
                    .align(Alignment.CenterHorizontally)
                    .padding(vertical = 22.dp)
                    .size(width = 32.dp, height = 4.dp)
                    .clip(CircleShape)
                    .background(scheme.onSurfaceVariant.copy(alpha = 0.4f)),
            )
            Column(
                Modifier
                    .heightIn(max = maxBody)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp)
                    .padding(bottom = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Column(Modifier.padding(horizontal = 4.dp, vertical = 4.dp)) {
                    Text(
                        "${day.monthValue}月${day.dayOfMonth}日 周${WEEK_HEAD[day.dayOfWeek.value - 1]}" +
                            if (day == today) " · 今天" else "",
                        style = MaterialTheme.typography.titleLarge,
                    )
                    Text(
                        info.detail() + if (tasks.isNotEmpty()) " · ${tasks.size} 项" else "",
                        style = MaterialTheme.typography.bodyMedium,
                        color = scheme.onSurfaceVariant,
                    )
                }
                if (tasks.isEmpty()) {
                    Text(
                        "这天没有安排",
                        style = MaterialTheme.typography.bodyMedium,
                        color = scheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 4.dp, vertical = 8.dp),
                    )
                } else {
                    tasks.forEach { t ->
                        DraggableTaskRow(task = t, drag = drag) {
                            TaskRow(
                                task = t,
                                tone = when {
                                    t.done -> Tone.NORMAL
                                    day < today -> Tone.OVERDUE
                                    day == today -> Tone.TODAY
                                    else -> Tone.NORMAL
                                },
                                done = t.done,
                                project = overview?.let { listNameOf(it, t.projectId) }.orEmpty(),
                                today = today,
                                badges = badgesOf(t, workspace),
                                onToggle = { onToggle(t) },
                                onOpen = { onOpenTask(t) },
                                showWhen = true,
                            )
                        }
                    }
                    if (tasks.any { !it.done }) {
                        Text(
                            "长按任务，拖到上面的日期就能改期",
                            style = MaterialTheme.typography.labelMedium,
                            color = scheme.onSurfaceVariant,
                            modifier = Modifier.padding(start = 4.dp, top = 2.dp),
                        )
                    }
                }
            }
            Row(
                Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (canOpenTimeline) {
                    OutlinedButton(onClick = { closeThen(onTimeline) }, modifier = Modifier.weight(1f)) { Text("时间轴查看") }
                }
                if (day >= today) {
                    Button(onClick = { closeThen(onAdd) }, modifier = Modifier.weight(1f)) { Text("添加待办") }
                }
            }
        }
    }
}

/** 给一行任务套上「长按拖走」：没完成的才能拖；拖起时这一行淡出，手指上跟着一颗小胶囊 */
@Composable
private fun DraggableTaskRow(task: DidaTask, drag: ChipDrag, content: @Composable () -> Unit) {
    val origin = remember { floatArrayOf(0f, 0f) }
    val latest = rememberUpdatedState(drag)
    Box(
        Modifier
            .onGloballyPositioned {
                val p = it.positionInRoot()
                origin[0] = p.x
                origin[1] = p.y
            }
            .graphicsLayer { alpha = if (drag.draggingId == task.id) 0.25f else 1f }
            .then(
                if (task.done) Modifier else Modifier.pointerInput(task.id, task.date) {
                    detectDragGesturesAfterLongPress(
                        onDragStart = { local -> latest.value.onStart(task, Offset(origin[0] + local.x, origin[1] + local.y)) },
                        onDrag = { change, amount ->
                            change.consume()
                            latest.value.onMove(amount)
                        },
                        onDragEnd = { latest.value.onEnd() },
                        onDragCancel = { latest.value.onCancel() },
                    )
                },
            ),
    ) { content() }
}
