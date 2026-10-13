package com.carpe.ideashell.ui.todos

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import com.carpe.ideashell.ui.components.AppMenu
import com.carpe.ideashell.ui.components.AppMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import kotlinx.coroutines.launch
import kotlin.math.roundToInt
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.vectorResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.carpe.ideashell.R
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.ui.components.CircleIconButton
import com.carpe.ideashell.ui.components.ListGroup
import com.carpe.ideashell.ui.theme.Brand
import androidx.compose.foundation.lazy.items
import java.time.LocalDate
import java.time.LocalTime
import java.time.YearMonth

/*
 * 待办页「任务」视图的骨架（设计方向「轴」）：
 * 顶部 7 天日期带 → 逾期横幅 → 当天的时间轴（左边时间、中间一条线、右边胶囊，「现在」是一条橙线）。
 * 视图（任务 / 项目 / 习惯）和象限筛选收进标题栏右上角的菜单。
 */

/** 日期带一屏显示 7 格；往前能翻 [PAST_DAYS] 天（一年），往后一周（滴答概览只覆盖未来 7 天） */
internal const val PAST_DAYS = 365
private const val FUTURE_DAYS = 6
private const val VISIBLE_CELLS = 7

// ───────────────────────── 日期带 ─────────────────────────

/**
 * 横向滑动的日期带：默认从今天起 7 天，向右滑可以回顾过去（每个过去的日子点进去读那天完成 / 到期的任务）。
 * 每天一格，小圆点表示当天任务数（最多 3 个，过去的日子不显示）。选中的一格反白。
 */
@Composable
internal fun WeekStrip(
    today: LocalDate,
    selected: LocalDate,
    counts: Map<String, Int>,
    onSelect: (LocalDate) -> Unit,
    modifier: Modifier = Modifier,
) {
    val total = PAST_DAYS + FUTURE_DAYS + 1
    val start = if (selected < today) (PAST_DAYS - java.time.temporal.ChronoUnit.DAYS.between(selected, today).toInt()).coerceIn(0, PAST_DAYS) else PAST_DAYS
    val state = androidx.compose.foundation.lazy.rememberLazyListState(initialFirstVisibleItemIndex = start)
    androidx.compose.foundation.layout.BoxWithConstraints(modifier.fillMaxWidth()) {
        val gap = 6.dp
        val cell = (maxWidth - gap * (VISIBLE_CELLS - 1)) / VISIBLE_CELLS
        androidx.compose.foundation.lazy.LazyRow(
            state = state,
            horizontalArrangement = Arrangement.spacedBy(gap),
        ) {
            items(total, key = { it }) { i ->
                val day = today.minusDays((PAST_DAYS - i).toLong())
                DayCell(
                    day = day,
                    isToday = day == today,
                    selected = day == selected,
                    count = if (day < today) 0 else counts[day.toString()] ?: 0,
                    past = day < today,
                    onClick = { onSelect(day) },
                    modifier = Modifier.width(cell),
                )
            }
        }
    }
}

@Composable
private fun DayCell(
    day: LocalDate,
    isToday: Boolean,
    selected: Boolean,
    count: Int,
    past: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    val fg = if (selected) scheme.inverseOnSurface else if (past) scheme.onSurface.copy(alpha = 0.6f) else scheme.onSurface
    val sub = if (selected) scheme.inverseOnSurface.copy(alpha = 0.8f) else scheme.onSurfaceVariant
    Column(
        modifier = modifier
            .height(62.dp)
            .clip(RoundedCornerShape(22.dp))
            .background(if (selected) scheme.inverseSurface else scheme.surfaceContainerLowest)
            .clickable(onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            when {
                isToday -> "今"
                day.dayOfMonth == 1 -> "${day.monthValue}月"
                else -> "一二三四五六日"[day.dayOfWeek.value - 1].toString()
            },
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.Bold,
            color = sub,
        )
        Text(day.dayOfMonth.toString(), fontSize = 16.sp, lineHeight = 20.sp, fontWeight = FontWeight.Black, color = fg)
        Row(Modifier.padding(top = 3.dp).height(5.dp), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            repeat(count.coerceAtMost(3)) {
                Box(Modifier.size(5.dp).clip(CircleShape).background(Brand.Orange))
            }
        }
    }
}

// ───────────────────────── 日期带 + 当月日历 ─────────────────────────

/**
 * 日期带 + 下拉展开的当月日历：在日期带上往下拖，日历跟着手指一点点长出来（日期带渐隐、日历渐显），松手后吸附到展开或收起；
 * 点下面的小横条也能切换。展开后选日期不会收回，只有往上拖或点小横条才收起。
 * 日历里可以翻月（最早一年前，最晚到概览覆盖的未来一周）。
 */
@Composable
internal fun CalendarStrip(
    today: LocalDate,
    selected: LocalDate,
    counts: Map<String, Int>,
    onSelect: (LocalDate) -> Unit,
    modifier: Modifier = Modifier,
) {
    // 展开与否要跟着页面保存：列表滑出屏幕再回来、旋转屏幕后都保持
    var expanded by rememberSaveable { mutableStateOf(false) }
    val progress = remember { Animatable(if (expanded) 1f else 0f) }
    var month by remember { mutableStateOf(YearMonth.from(selected)) }
    val current by rememberUpdatedState(selected)
    val scope = rememberCoroutineScope()
    // 日历完全展开比日期带多出来的高度（px），拖动时用它把手指位移换算成进度
    val range = remember { floatArrayOf(1f) }
    val showWeek by remember { derivedStateOf { progress.value < 0.999f } }

    fun settle(open: Boolean) {
        if (open && progress.value < 0.01f) month = YearMonth.from(current)
        expanded = open
        scope.launch { progress.animateTo(if (open) 1f else 0f, tween(220)) }
    }

    val drag = rememberDraggableState { dy ->
        scope.launch { progress.snapTo((progress.value + dy / range[0]).coerceIn(0f, 1f)) }
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .draggable(
                state = drag,
                orientation = Orientation.Vertical,
                onDragStarted = {
                    progress.stop()
                    if (progress.value < 0.01f) month = YearMonth.from(current)
                },
                onDragStopped = { velocity ->
                    settle(if (kotlin.math.abs(velocity) > 700f) velocity > 0 else progress.value > 0.5f)
                },
            ),
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .clipToBounds()
                .layout { measurable, constraints ->
                    val placeable = measurable.measure(constraints.copy(minHeight = 0, maxHeight = Constraints.Infinity))
                    val weekH = 62.dp.roundToPx()
                    val extra = (placeable.height - weekH).coerceAtLeast(0)
                    range[0] = extra.coerceAtLeast(1).toFloat()
                    layout(placeable.width, (weekH + extra * progress.value).roundToInt()) { placeable.place(0, 0) }
                },
        ) {
            // 日历一直排好版（透明度随进度变），这样拖动一开始就能量出它的高度；日期带盖在它上面，展开后拿掉
            Box(
                Modifier
                    .layout { measurable, constraints ->
                        val placeable = measurable.measure(constraints)
                        // 收起时只量不摆：不画、也接不到点击，避免和上面的日期带抢触摸
                        layout(placeable.width, placeable.height) { if (progress.value > 0.02f) placeable.place(0, 0) }
                    }
                    .graphicsLayer { alpha = progress.value },
            ) {
                MonthCalendar(
                    month = month,
                    today = today,
                    selected = selected,
                    counts = counts,
                    onMonth = { month = it },
                    onSelect = onSelect,
                )
            }
            if (showWeek) {
                Box(Modifier.align(Alignment.TopStart).graphicsLayer { alpha = 1f - progress.value }) {
                    WeekStrip(today = today, selected = selected, counts = counts, onSelect = onSelect)
                }
            }
        }
        Box(
            modifier = Modifier.fillMaxWidth().height(22.dp).clickable { settle(!expanded) },
            contentAlignment = Alignment.Center,
        ) {
            Box(
                Modifier
                    .width(36.dp)
                    .height(4.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.outline.copy(alpha = 0.5f)),
            )
        }
    }
}

@Composable
private fun MonthCalendar(
    month: YearMonth,
    today: LocalDate,
    selected: LocalDate,
    counts: Map<String, Int>,
    onMonth: (YearMonth) -> Unit,
    onSelect: (LocalDate) -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    val first = today.minusDays(PAST_DAYS.toLong())
    val last = today.plusDays(6)
    val canPrev = month > YearMonth.from(first)
    val canNext = month < YearMonth.from(last)
    ListGroup {
        Column(Modifier.padding(horizontal = 8.dp, vertical = 10.dp)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("${month.year}年${month.monthValue}月", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                if (month != YearMonth.from(today)) {
                    Text(
                        "回到今天",
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.Bold,
                        color = scheme.primary,
                        modifier = Modifier
                            .clip(CircleShape)
                            .clickable { onMonth(YearMonth.from(today)) }
                            .padding(horizontal = 10.dp, vertical = 6.dp),
                    )
                }
                MonthArrow("‹", canPrev) { onMonth(month.minusMonths(1)) }
                MonthArrow("›", canNext) { onMonth(month.plusMonths(1)) }
            }
            Row(Modifier.fillMaxWidth().padding(top = 4.dp)) {
                "一二三四五六日".forEach { c ->
                    Text(
                        c.toString(),
                        style = MaterialTheme.typography.labelMedium,
                        color = scheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.weight(1f).padding(vertical = 4.dp),
                    )
                }
            }
            val offset = month.atDay(1).dayOfWeek.value - 1
            val weeks = (offset + month.lengthOfMonth() + 6) / 7
            repeat(weeks) { w ->
                Row(Modifier.fillMaxWidth()) {
                    repeat(7) { d ->
                        val n = w * 7 + d - offset + 1
                        if (n < 1 || n > month.lengthOfMonth()) {
                            Spacer(Modifier.weight(1f).height(46.dp))
                        } else {
                            val day = month.atDay(n)
                            MonthDay(
                                day = day,
                                isToday = day == today,
                                selected = day == selected,
                                enabled = day >= first && day <= last,
                                past = day < today,
                                count = if (day < today) 0 else counts[day.toString()] ?: 0,
                                onClick = { onSelect(day) },
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MonthArrow(text: String, enabled: Boolean, onClick: () -> Unit) {
    Text(
        text,
        fontSize = 22.sp,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = if (enabled) 1f else 0.25f),
        textAlign = TextAlign.Center,
        modifier = Modifier
            .size(40.dp)
            .clip(CircleShape)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(top = 4.dp),
    )
}

@Composable
private fun MonthDay(
    day: LocalDate,
    isToday: Boolean,
    selected: Boolean,
    enabled: Boolean,
    past: Boolean,
    count: Int,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    val fg = when {
        selected -> scheme.inverseOnSurface
        !enabled -> scheme.onSurface.copy(alpha = 0.28f)
        past -> scheme.onSurface.copy(alpha = 0.65f)
        else -> scheme.onSurface
    }
    Box(modifier.height(46.dp), contentAlignment = Alignment.Center) {
        Column(
            modifier = Modifier
                .size(40.dp)
                .clip(CircleShape)
                .then(if (selected) Modifier.background(scheme.inverseSurface) else Modifier)
                .then(if (isToday && !selected) Modifier.border(1.5.dp, Brand.Orange, CircleShape) else Modifier)
                .clickable(enabled = enabled, onClick = onClick),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text(day.dayOfMonth.toString(), fontSize = 15.sp, lineHeight = 18.sp, fontWeight = if (isToday || selected) FontWeight.Black else FontWeight.Bold, color = fg)
            Box(
                Modifier
                    .padding(top = 1.dp)
                    .size(4.dp)
                    .clip(CircleShape)
                    .background(if (count > 0 && enabled) Brand.Orange else androidx.compose.ui.graphics.Color.Transparent),
            )
        }
    }
}

// ───────────────────────── 逾期横幅 ─────────────────────────

/** 逾期折成一条深棕横幅：点横幅展开 / 收起逾期任务，右侧按钮把它们全部改到今天 */
@Composable
internal fun OverdueBanner(
    count: Int,
    earliest: LocalDate?,
    expanded: Boolean,
    onToggle: () -> Unit,
    onReschedule: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(54.dp)
            .clip(CircleShape)
            .background(scheme.inverseSurface)
            .clickable(onClick = onToggle)
            .padding(start = 20.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(count.toString(), fontSize = 18.sp, fontWeight = FontWeight.Black, color = scheme.inverseOnSurface)
        Text(
            buildString {
                append("项逾期")
                if (earliest != null) append("，最早是 ${earliest.monthValue}月${earliest.dayOfMonth}日")
            },
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.Bold,
            color = scheme.inverseOnSurface,
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )
        Box(
            modifier = Modifier
                .height(38.dp)
                .clip(CircleShape)
                .background(Brand.Orange)
                .clickable(onClick = onReschedule)
                .padding(horizontal = 16.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text("改到今天", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.ExtraBold, color = Brand.Brown)
        }
    }
}

// ───────────────────────── 时间轴 ─────────────────────────

private val LabelWidth = 44.dp
private val NodeSize = 12.dp
private val LabelGap = 8.dp
private val NodeGap = 10.dp

/** 时间线上的竖线：画在整行（含下方 8dp 间隔）的背后，所以相邻两行的线是连着的 */
@Composable
private fun Modifier.timelineRail(): Modifier {
    val color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.14f)
    return drawBehind {
        val x = (LabelWidth + LabelGap + NodeSize / 2).toPx()
        drawLine(color, Offset(x, 0f), Offset(x, size.height), strokeWidth = 2.dp.toPx())
    }
}

/**
 * 一天的时间轴：先是有具体时间的任务（按时间），当天还会在「现在」的位置画一条橙线，最后是「全天」的任务。
 * 每个任务是一条胶囊，时间由左边的时间列表示，所以胶囊里不再重复写时间。
 */
@Composable
internal fun DayTimeline(
    tasks: List<DidaTask>,
    isToday: Boolean,
    row: @Composable (DidaTask) -> Unit,
) {
    val timed = tasks.filter { it.time != null }.sortedBy { it.time }
    val allDay = tasks.filter { it.time == null }.sortedByDescending { it.priority }
    val nowText = LocalTime.now().let { "%02d:%02d".format(it.hour, it.minute) }
    val nowIndex = if (isToday) timed.indexOfFirst { (it.time ?: "") >= nowText }.let { if (it < 0) timed.size else it } else -1

    Column {
        timed.forEachIndexed { i, t ->
            if (i == nowIndex) NowRow(nowText)
            TimelineRow(label = t.time.orEmpty(), hot = t.priority > 0) { row(t) }
        }
        if (nowIndex == timed.size && isToday) NowRow(nowText)
        allDay.forEach { t -> TimelineRow(label = "全天", hot = t.priority > 0) { row(t) } }
    }
}

@Composable
private fun TimelineRow(label: String, hot: Boolean, content: @Composable () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Row(
        modifier = Modifier.fillMaxWidth().timelineRail().padding(bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            label,
            modifier = Modifier.width(LabelWidth),
            textAlign = TextAlign.End,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.ExtraBold,
            color = scheme.onSurfaceVariant,
            maxLines = 1,
        )
        Spacer(Modifier.width(LabelGap))
        Box(
            Modifier
                .size(NodeSize)
                .clip(CircleShape)
                .background(scheme.background)
                .border(2.5.dp, if (hot) Brand.Orange else scheme.onSurface, CircleShape),
        )
        Spacer(Modifier.width(NodeGap))
        Box(Modifier.weight(1f)) { content() }
    }
}

/** 「现在」：橙色实心点（带一圈淡光）+ 一条横穿的橙线 */
@Composable
private fun NowRow(text: String) {
    Column(Modifier.fillMaxWidth().timelineRail()) {
        Row(Modifier.fillMaxWidth().height(26.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                text,
                modifier = Modifier.width(LabelWidth),
                textAlign = TextAlign.End,
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.Black,
                color = MaterialTheme.colorScheme.primary,
                maxLines = 1,
            )
            Spacer(Modifier.width(LabelGap))
            Box(
                Modifier
                    .size(NodeSize)
                    .drawBehind {
                        drawCircle(Brand.Orange.copy(alpha = 0.22f), radius = size.minDimension / 2 + 4.dp.toPx())
                    }
                    .clip(CircleShape)
                    .background(Brand.Orange),
            )
            Spacer(Modifier.width(NodeGap))
            Box(Modifier.weight(1f).height(2.dp).clip(CircleShape).background(Brand.Orange))
        }
        Spacer(Modifier.height(8.dp))
    }
}

// ───────────────────────── 标题栏的视图 / 筛选菜单 ─────────────────────────

/**
 * 标题栏右上角的菜单：切换「任务 / 项目 / 习惯」。
 */
@Composable
internal fun ViewMenuButton(
    view: TodoView,
    onSelectView: (TodoView) -> Unit,
    modifier: Modifier = Modifier,
) {
    var open by remember { mutableStateOf(false) }
    val icon: ImageVector = ImageVector.vectorResource(R.drawable.ic_filter)
    Box(modifier) {
        CircleIconButton(icon, "视图与筛选", onClick = { open = true })
        AppMenu(expanded = open, onDismissRequest = { open = false }) {
            TodoView.entries.forEach { v ->
                AppMenuItem(
                    text = { Text(v.label) },
                    selected = v == view,
                    onClick = {
                        open = false
                        onSelectView(v)
                    },
                )
            }
        }
    }
}
