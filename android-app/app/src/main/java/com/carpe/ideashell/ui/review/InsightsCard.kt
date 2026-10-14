package com.carpe.ideashell.ui.review

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.carpe.ideashell.core.parse.TimeRanges
import com.carpe.ideashell.domain.FocusInsight
import com.carpe.ideashell.domain.FocusLine
import com.carpe.ideashell.domain.HabitInsight
import com.carpe.ideashell.domain.Insights
import com.carpe.ideashell.domain.ProjectFlow
import com.carpe.ideashell.domain.ProjectSlice
import com.carpe.ideashell.domain.RhythmInsight
import com.carpe.ideashell.domain.StreakInsight
import com.carpe.ideashell.domain.TodoInsight
import com.carpe.ideashell.domain.TopicInsight
import com.carpe.ideashell.data.revisit.RevisitStats
import com.carpe.ideashell.ui.glass.GlassSurface
import com.carpe.ideashell.ui.theme.Brand
import java.util.Locale
import kotlin.math.max
import kotlin.math.roundToInt

/*
 * 回顾顶部的「发现」：首屏只让一张卡当主角，其余横滑查看，把首屏的大部分留给下面的时间轴。
 * 每张卡只有三层：标签 + 右上角标、一行结论、撑满剩余空间的图——图占满，所以不会有大片空白。
 *
 * 卡的顺序（没有数据撑起来的那张直接不出现；只剩一张时不做分页）：
 *   时间分配（环形，按项目拆专注时长）→ 间隔复习（今天进度 + 记忆阶段分布）→ 专注趋势（每日柱 + 日均虚线）
 *   → 专注时间线（每天一行，橙块 = 一次专注；底色带 = 最佳专注时段）→ 记录时刻（24 小时柱）→ 连续记录（每日记录量柱）
 *   → 项目（谁记得最多、谁久没记）→ 习惯（打卡完成率）→ 待办（按时 / 延期 / 未完成）→ 话题（高频标签）。
 * 结论里的关键数字用橙色荧光笔标出（文字里用 «» 包起来）。
 */
fun LazyListScope.insightsItem(
    flow: ProjectFlow,
    insights: Insights?,
    revisit: RevisitStats,
    rangeLabel: String,
    onOpenProject: (String) -> Unit,
) {
    val hasRing = flow.slices.any { flow.weightOf(it) > 0 || it.stale }
    val ins = insights ?: Insights.Empty
    if (!hasRing && ins.isEmpty && revisit.total == 0) return
    item(key = "insights") { InsightsPager(flow, ins, revisit, hasRing, rangeLabel, onOpenProject) }
}

private const val CARD_HEIGHT = 188

private class Seg(val name: String, val value: Int, val color: Color, val keyword: String?)

/** 3h10 / 40m */
private fun shortMinutes(min: Int): String = when {
    min < 60 -> "${min}m"
    min % 60 == 0 -> "${min / 60}h"
    else -> "${min / 60}h${"%02d".format(min % 60)}"
}

/** 日均「2 小时」「45 分钟」 */
private fun averageText(min: Int): String =
    if (min >= 60) String.format(Locale.ROOT, "%.1f", min / 60.0).removeSuffix(".0") + " 小时" else "$min 分钟"

@Composable
private fun InsightsPager(
    flow: ProjectFlow,
    insights: Insights,
    revisit: RevisitStats,
    hasRing: Boolean,
    rangeLabel: String,
    onOpenProject: (String) -> Unit,
) {
    val pages = buildList<@Composable () -> Unit> {
        if (hasRing) add { AllocationCard(flow, rangeLabel, onOpenProject) }
        if (revisit.total > 0) add { RevisitStatsCard(revisit) }
        insights.focus?.let { f ->
            if (f.hasTrend) {
                add { FocusTrendCard(f) }
                // 专注时间线和最佳专注时段合成一张卡：时间线上用色带标出最佳时段
                add { FocusTimelineCard(f) }
            }
        }
        insights.rhythm?.let { add { RhythmCard(it, rangeLabel) } }
        insights.streak?.let { add { StreakCard(it) } }
        projectRows(flow)?.let { add { ProjectsCard(it, rangeLabel, onOpenProject) } }
        insights.habit?.let { add { HabitCard(it) } }
        insights.todo?.let { add { TodoCard(it) } }
        insights.topic?.let { add { TopicCard(it, rangeLabel) } }
    }
    if (pages.isEmpty()) return
    if (pages.size == 1) {
        pages[0]()
        return
    }
    val state = rememberPagerState { pages.size }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        HorizontalPager(
            state = state,
            // 右侧留 40dp 露出下一张卡的边，提示可以横滑
            contentPadding = PaddingValues(end = 40.dp),
            pageSpacing = 10.dp,
            verticalAlignment = Alignment.Top,
        ) { i -> pages[i]() }
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val dim = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.2f)
            repeat(pages.size) { i ->
                val on = i == state.currentPage
                Box(
                    Modifier
                        .padding(horizontal = 3.dp)
                        .height(6.dp)
                        .width(if (on) 18.dp else 6.dp)
                        .clip(CircleShape)
                        .background(if (on) MaterialTheme.colorScheme.onSurface else dim),
                )
            }
        }
    }
}

/** 一张卡：固定高度；顶上标签 + 右上角标，下面一行结论，图占满剩下的全部空间 */
@Composable
private fun InsightCard(
    label: String,
    meta: String?,
    headline: AnnotatedString?,
    content: @Composable () -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    GlassSurface(Modifier.fillMaxWidth().height(CARD_HEIGHT.dp), shape = RoundedCornerShape(22.dp)) {
        Column(Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 12.dp)) {
            Row(
                Modifier.fillMaxWidth().height(20.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    label,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.ExtraBold,
                    color = scheme.onSurface,
                )
                if (!meta.isNullOrBlank()) {
                    Text(
                        meta,
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = scheme.primary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier
                            .widthIn(max = 140.dp)
                            .clip(CircleShape)
                            .background(scheme.onSurface.copy(alpha = 0.06f))
                            .padding(horizontal = 9.dp, vertical = 2.dp),
                    )
                }
            }
            if (headline != null) {
                Text(
                    headline,
                    fontSize = 17.sp,
                    lineHeight = 24.sp,
                    fontWeight = FontWeight.ExtraBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
            Box(Modifier.weight(1f).fillMaxWidth().padding(top = 10.dp)) { content() }
        }
    }
}

// ───────────────────────── 时间分配 ─────────────────────────

@Composable
private fun AllocationCard(flow: ProjectFlow, rangeLabel: String, onOpenProject: (String) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val palette = listOf(scheme.onSurface, Brand.Orange, Brand.OrangeMid)
    val weighted = flow.slices.filter { flow.weightOf(it) > 0 }
    val shown = weighted.take(palette.size)
    val rest = weighted.drop(palette.size).sumOf { flow.weightOf(it) } + if (flow.byFocus) flow.otherMin else 0
    val segs = buildList {
        shown.forEachIndexed { i, s -> add(Seg(s.project.keyword, flow.weightOf(s), palette[i], s.project.keyword)) }
        if (rest > 0) add(Seg("其他", rest, scheme.onSurface.copy(alpha = 0.18f), null))
    }
    val total = segs.sumOf { it.value }
    val stale = flow.slices.filter { it.stale && flow.weightOf(it) == 0 }.take((5 - segs.size).coerceIn(0, 2))
    val top = segs.firstOrNull { it.keyword != null }
    val headline = when {
        total == 0 -> "项目动态"
        flow.byFocus -> "本期专注 «${shortMinutes(flow.totalMin)}»" +
            (top?.let { "，${it.name}占 ${(100f * it.value / total).roundToInt()}%" } ?: "")
        else -> "共 «$total 条» 记录" + (top?.let { "，${it.name}最多" } ?: "")
    }

    InsightCard(if (flow.byFocus) "时间分配" else "项目动态", rangeLabel, marked(headline)) {
        Row(
            Modifier.fillMaxSize(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            if (total > 0) {
                Ring(
                    segs, total,
                    center = if (flow.byFocus) shortMinutes(flow.totalMin) else "$total",
                    caption = if (flow.byFocus) "专注" else "条记录",
                )
            }
            Column(Modifier.weight(1f)) {
                segs.forEach { seg ->
                    LegendRow(
                        dot = { Box(Modifier.size(10.dp).clip(CircleShape).background(seg.color)) },
                        name = seg.name,
                        figure = if (flow.byFocus) shortMinutes(seg.value) else "${seg.value}",
                        percent = "${(100f * seg.value / total).roundToInt()}%",
                        onClick = seg.keyword?.let { k -> { onOpenProject(k) } },
                    )
                }
                stale.forEach { s -> StaleRow(s, onOpenProject) }
            }
        }
    }
}

@Composable
private fun Ring(segs: List<Seg>, total: Int, center: String, caption: String) {
    Box(Modifier.size(88.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(88.dp)) {
            val sw = 10.dp.toPx()
            val arcSize = Size(size.width - sw, size.height - sw)
            var start = -90f
            for (seg in segs) {
                val sweep = 360f * seg.value / total
                val gap = if (segs.size > 1) 4f else 0f
                drawArc(
                    color = seg.color,
                    startAngle = start,
                    sweepAngle = max(sweep - gap, 1f),
                    useCenter = false,
                    topLeft = Offset(sw / 2, sw / 2),
                    size = arcSize,
                    style = Stroke(sw),
                )
                start += sweep
            }
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(center, fontSize = 16.sp, lineHeight = 19.sp, fontWeight = FontWeight.Black, maxLines = 1)
            Text(caption, fontSize = 10.5.sp, lineHeight = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun LegendRow(
    dot: @Composable () -> Unit,
    name: String,
    figure: String,
    percent: String?,
    onClick: (() -> Unit)?,
    figureColor: Color = Color.Unspecified,
) {
    val scheme = MaterialTheme.colorScheme
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 21.dp)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        dot()
        Text(
            name,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.ExtraBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Text(figure, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Black, color = figureColor, maxLines = 1)
        if (percent != null) {
            Text(
                percent,
                style = MaterialTheme.typography.labelSmall,
                color = scheme.onSurfaceVariant,
                modifier = Modifier.width(30.dp),
                textAlign = TextAlign.End,
            )
        }
    }
}

/** 久没提及的项目：橙色空心环 + 「N 天没记」 */
@Composable
private fun StaleRow(s: ProjectSlice, onOpenProject: (String) -> Unit) {
    LegendRow(
        dot = { Box(Modifier.size(10.dp).border(2.5.dp, Brand.Orange, CircleShape)) },
        name = s.project.keyword,
        figure = s.gapDays?.let { "$it 天没记" } ?: "该记一条了",
        percent = null,
        onClick = { onOpenProject(s.project.keyword) },
        figureColor = Brand.OrangeDeep,
    )
}

// ───────────────────────── 间隔复习 ─────────────────────────

/** 间隔复习：今天的进度 + 重温库里的内容处在记忆的哪个阶段（刚加入 / 巩固中 / 已记牢） */
@Composable
private fun RevisitStatsCard(r: RevisitStats) {
    val scheme = MaterialTheme.colorScheme
    val headline = when {
        r.remaining > 0 -> "今天还剩 «${r.remaining} 条»待重温"
        r.doneToday > 0 -> "今天重温了 «${r.doneToday} 条»，完成"
        else -> "今天没有待重温的"
    } + (r.recallRate?.let { "，记得率 $it%" } ?: "")
    val peak = maxOf(r.fresh, r.learning, r.mature, 1)
    InsightCard("间隔复习", "共 ${r.total} 条", marked(headline)) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center) {
            BarRow("刚加入", r.fresh, peak, scheme.onSurface.copy(alpha = 0.28f), trailing = "${r.fresh} 条")
            BarRow("巩固中", r.learning, peak, Brand.Orange, trailing = "${r.learning} 条")
            BarRow("已记牢", r.mature, peak, scheme.onSurface, trailing = "${r.mature} 条")
        }
    }
}

// ───────────────────────── 专注：趋势 / 时间线（含最佳时段） ─────────────────────────

@Composable
private fun FocusTrendCard(f: FocusInsight) {
    val n = f.days.size
    val shortDays = n <= 7
    val weekday = TimeRanges.weekdayName(f.bestDay)
    InsightCard(
        label = "专注趋势",
        meta = "共 ${shortMinutes(f.minutes.sum())}",
        headline = marked("日均专注 «${averageText(f.avgMin)}»，$weekday 最多"),
    ) {
        BarChart(
            values = f.minutes,
            labels = f.days.map { if (shortDays) TimeRanges.weekdayName(it).takeLast(1) else it.dayOfMonth.toString() },
            valueLabels = if (shortDays) f.minutes.map { if (it > 0) shortMinutes(it) else "" } else null,
            lit = f.minutes.map { it >= f.avgMin },
            nowIndex = n - 1,
            average = f.avgMin,
        )
    }
}

/** 专注时间线 + 最佳专注时段：每天一行的时间线，最佳时段用一条橙色底带从上到下标出来 */
@Composable
private fun FocusTimelineCard(f: FocusInsight) {
    val start = f.bestStart
    val period = periodOf(f.hours)
    val headline = when {
        start != null -> "«$start–${start + 2} 点»最容易专注，占 ${f.bestShare}%"
        period == null -> "专注分散在一天里"
        period.second >= 50 -> "«${period.first}»是主战场，占 ${period.second}%"
        else -> "«${period.first}»专注最多，占 ${period.second}%"
    }
    InsightCard("专注时间线", "近 ${f.lines.size} 天", marked(headline)) { FocusTimeline(f.lines, start) }
}

/** 凌晨 / 上午 / 下午 / 晚上里专注最多的一段和它的占比 */
private fun periodOf(hours: List<Int>): Pair<String, Int>? {
    val total = hours.sum()
    if (total <= 0) return null
    val parts = listOf("凌晨" to 0..4, "上午" to 5..11, "下午" to 12..17, "晚上" to 18..23)
    val best = parts.maxByOrNull { (_, r) -> r.sumOf { hours[it] } } ?: return null
    return best.first to (100f * best.second.sumOf { hours[it] } / total).roundToInt()
}

// ───────────────────────── 记录时刻 ─────────────────────────

@Composable
private fun RhythmCard(r: RhythmInsight, rangeLabel: String) {
    val scheme = MaterialTheme.colorScheme
    InsightCard(
        label = "记录时刻",
        meta = rangeLabel,
        headline = marked(if (r.verb == "记录") "最常在 «${r.peakLabel}» 记录" else "习惯在 «${r.peakLabel}» ${r.verb}"),
    ) {
        HourBars(r.hours, r.peakRange, scheme.onSurface.copy(alpha = 0.22f))
    }
}

/** 24 小时的柱，[lit] 里的小时涂橙，底下是每 2 小时一个数字的横轴 */
@Composable
private fun HourBars(values: List<Int>, lit: IntRange, ink: Color) {
    val scheme = MaterialTheme.colorScheme
    val maxV = (values.maxOrNull() ?: 1).coerceAtLeast(1)
    Column(Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.weight(1f).fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            values.forEachIndexed { h, v ->
                Box(
                    Modifier
                        .weight(1f)
                        .fillMaxHeight((v.toFloat() / maxV).coerceIn(0.04f, 1f))
                        .clip(RoundedCornerShape(2.dp))
                        .background(if (h in lit) Brand.Orange else ink),
                )
            }
        }
        // 每根柱底下一个小刻度；每 2 小时在柱子正中标出它是几点（「17」那根柱就在 16 和 18 之间）
        HourAxis(cellCentered = true, modifier = Modifier.padding(top = 2.dp))
    }
}

/**
 * 24 小时的横轴，每 2 小时一个数字。
 * [cellCentered] = true（柱状图）：数字在「这个小时那根柱」的正中，表示 [h:00, h+1:00)；
 * false（时间线）：数字落在 h:00 这条分界线上，和同一位置的竖线对齐，0 在最左、24 在最右。
 */
@Composable
private fun HourAxis(cellCentered: Boolean, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    val ink = scheme.onSurfaceVariant
    val tick = scheme.onSurface.copy(alpha = 0.28f)
    BoxWithConstraints(modifier.fillMaxWidth().height(AXIS_HEIGHT)) {
        val w = maxWidth
        val labelW = 20.dp
        Canvas(Modifier.fillMaxSize()) {
            val ticks = if (cellCentered) 0..23 else 0..24
            for (h in ticks) {
                val x = size.width * (if (cellCentered) h + 0.5f else h.toFloat()) / 24f
                val long = h % 2 == 0
                drawLine(
                    color = tick,
                    start = Offset(x, 0f),
                    end = Offset(x, (if (long) 4.dp else 2.dp).toPx()),
                    strokeWidth = 1.dp.toPx(),
                )
            }
        }
        for (h in 0..(if (cellCentered) 22 else 24) step 2) {
            val x = w * (if (cellCentered) h + 0.5f else h.toFloat()) / 24f
            val natural = x - labelW / 2
            val (left, align) = when {
                natural < 0.dp -> 0.dp to Alignment.TopStart
                natural > w - labelW -> (w - labelW) to Alignment.TopEnd
                else -> natural to Alignment.TopCenter
            }
            Box(Modifier.offset(x = left).width(labelW), contentAlignment = align) {
                Text(
                    h.toString(),
                    fontSize = 10.5.sp,
                    lineHeight = 12.sp,
                    fontWeight = FontWeight.ExtraBold,
                    color = ink,
                    maxLines = 1,
                    softWrap = false,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
    }
}

private val AXIS_HEIGHT = 18.dp

// ───────────────────────── 连续记录 ─────────────────────────

@Composable
private fun StreakCard(s: StreakInsight) {
    val headline = when {
        s.streak >= 2 -> "«连续 ${s.streak} 天»有记录" +
            (s.breakDay?.let { "，${TimeRanges.weekdayName(it)}断了" } ?: "")
        else -> "«${s.activeDays}/${s.spanDays} 天»有记录"
    }
    val shortDays = s.days.size <= 7
    InsightCard("连续记录", "${s.activeDays}/${s.spanDays} 天", marked(headline)) {
        BarChart(
            values = s.counts,
            labels = s.days.map { if (shortDays) TimeRanges.weekdayName(it).takeLast(1) else it.dayOfMonth.toString() },
            valueLabels = if (shortDays) s.counts.map { it.toString() } else null,
            lit = s.counts.map { it > 0 },
            nowIndex = s.days.lastIndex,
            average = null,
        )
    }
}

/**
 * 通用柱状图：每天一根柱，没有值的那天是空心小圆角；[average] 不为空时画一条横贯的日均虚线；
 * [lit] 的柱涂橙色，其余是淡色；[nowIndex] 那一天的标签用主色。
 */
@Composable
private fun BarChart(
    values: List<Int>,
    labels: List<String>,
    valueLabels: List<String>?,
    lit: List<Boolean>,
    nowIndex: Int,
    average: Int?,
) {
    val scheme = MaterialTheme.colorScheme
    val maxV = (values.maxOrNull() ?: 1).coerceAtLeast(1)
    val labelH = 14.dp
    val valueH = if (valueLabels != null) 12.dp else 0.dp
    val gap = 2.dp
    BoxWithConstraints(Modifier.fillMaxSize()) {
        // 最高的柱：总高度减去上面的数值、下面的标签和三处小间距
        val barMax: Dp = (maxHeight - labelH - valueH - gap * 3).coerceAtLeast(10.dp)
        Row(
            Modifier.fillMaxSize(),
            horizontalArrangement = Arrangement.spacedBy(if (values.size > 7) 4.dp else 8.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            values.forEachIndexed { i, v ->
                Column(
                    Modifier.weight(1f).fillMaxHeight(),
                    verticalArrangement = Arrangement.Bottom,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    if (valueLabels != null) {
                        Text(
                            valueLabels[i],
                            fontSize = 10.sp,
                            lineHeight = 12.sp,
                            fontWeight = FontWeight.ExtraBold,
                            color = scheme.onSurfaceVariant,
                            maxLines = 1,
                        )
                    }
                    Spacer(Modifier.height(gap))
                    if (v > 0) {
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .height(barMax * v / maxV)
                                .clip(RoundedCornerShape(5.dp))
                                .background(if (lit[i]) Brand.Orange else scheme.onSurface.copy(alpha = 0.2f)),
                        )
                    } else {
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .height(8.dp)
                                .border(2.dp, scheme.onSurface.copy(alpha = 0.25f), RoundedCornerShape(5.dp)),
                        )
                    }
                    Spacer(Modifier.height(gap))
                    Text(
                        labels[i],
                        fontSize = 10.5.sp,
                        lineHeight = 14.sp,
                        fontWeight = FontWeight.ExtraBold,
                        color = if (i == nowIndex) scheme.primary else scheme.onSurfaceVariant,
                        maxLines = 1,
                    )
                }
            }
        }
        if (average != null && average > 0) {
            val dash = scheme.onSurface.copy(alpha = 0.35f)
            Canvas(Modifier.fillMaxSize()) {
                val y = size.height - (labelH + gap).toPx() - barMax.toPx() * average / maxV
                drawLine(
                    color = dash,
                    start = Offset(0f, y),
                    end = Offset(size.width, y),
                    strokeWidth = 2.dp.toPx(),
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(10f, 8f)),
                )
            }
        }
    }
}

// ───────────────────────── 专注时间线 ─────────────────────────

/** 每天一行：灰色轨道是 0–24 点，橙块是当天的每一次专注；[bestStart] 不为空时，那 2 小时画一条淡橙色底带 */
@Composable
private fun FocusTimeline(lines: List<FocusLine>, bestStart: Int?) {
    val scheme = MaterialTheme.colorScheme
    val track = scheme.onSurface.copy(alpha = 0.07f)
    val grid = scheme.onSurface.copy(alpha = 0.16f)
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f).fillMaxWidth()) {
            if (bestStart != null) {
                val band = Brand.Orange.copy(alpha = 0.2f)
                Canvas(Modifier.fillMaxSize().padding(start = 18.dp)) {
                    val x = size.width * bestStart / 24f
                    drawRoundRect(band, Offset(x, 0f), Size(size.width * 2 / 24f, size.height), CornerRadius(4.dp.toPx()))
                }
            }
            Column(Modifier.fillMaxSize()) {
                lines.forEach { line ->
                    Row(
                        Modifier.weight(1f).fillMaxWidth().padding(vertical = 1.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        // 行高只有 11dp 上下：字去掉上下留白、不换行，并允许超出行高显示，免得被截成半个字
                        Text(
                            TimeRanges.weekdayName(line.date).takeLast(1),
                            style = TextStyle(
                                fontSize = 10.sp,
                                lineHeight = 10.sp,
                                fontWeight = FontWeight.ExtraBold,
                                color = scheme.onSurfaceVariant,
                                platformStyle = PlatformTextStyle(includeFontPadding = false),
                                lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.Both),
                            ),
                            softWrap = false,
                            maxLines = 1,
                            modifier = Modifier.width(18.dp).wrapContentHeight(align = Alignment.CenterVertically, unbounded = true),
                        )
                        Canvas(Modifier.weight(1f).fillMaxHeight()) {
                            val h = size.height.coerceAtMost(10.dp.toPx())
                            val top = (size.height - h) / 2
                            val r = CornerRadius(h / 2)
                            drawRoundRect(track, Offset(0f, top), Size(size.width, h), r)
                            // 每 2 小时一条竖线，和底下的数字对齐：一眼看出一块橙色落在哪两个整点之间
                            for (g in 2..22 step 2) {
                                val gx = size.width * g / 24f
                                drawLine(grid, Offset(gx, top), Offset(gx, top + h), strokeWidth = 1.dp.toPx())
                            }
                            for (b in line.blocks) {
                                val x = size.width * b.start / 24f
                                // 位置按开始时刻精确画；太短的专注至少给 4dp，免得看不见（不再撑成一整个圆点盖住前后的整点）
                                val w = (size.width * (b.endInclusive - b.start) / 24f).coerceAtLeast(4.dp.toPx())
                                drawRoundRect(Brand.Orange, Offset(x.coerceAtMost(size.width - w), top), Size(w, h), CornerRadius(minOf(h / 2, w / 2)))
                            }
                        }
                    }
                }
            }
        }
        HourAxis(cellCentered = false, modifier = Modifier.padding(start = 18.dp, top = 2.dp))
    }
}

// ───────────────────────── 待办 ─────────────────────────

@Composable
private fun TodoCard(t: TodoInsight) {
    val scheme = MaterialTheme.colorScheme
    val pct = if (t.total == 0) 0 else (100f * t.done / t.total).roundToInt()
    val headline = "完成率 «$pct%»" + if (t.overdue > 0) "，${t.overdue} 条已逾期" else "，没有逾期"
    val open = (t.total - t.done).coerceAtLeast(0)
    val peak = maxOf(t.onTime, t.lateDone, open, 1)
    InsightCard("待办", "${t.done}/${t.total}", marked(headline)) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center) {
            BarRow("按时完成", t.onTime, peak, scheme.onSurface)
            BarRow("延期完成", t.lateDone, peak, Brand.Orange)
            BarRow("还没做完", open, peak, scheme.onSurface.copy(alpha = 0.28f))
        }
    }
}

// ───────────────────────── 话题 ─────────────────────────

@Composable
private fun TopicCard(t: TopicInsight, rangeLabel: String) {
    val scheme = MaterialTheme.colorScheme
    val colors = listOf(scheme.onSurface, Brand.Orange, scheme.onSurface.copy(alpha = 0.28f))
    val peak = (t.tags.firstOrNull()?.second ?: 1).coerceAtLeast(1)
    InsightCard("话题", rangeLabel, marked("常提到 " + t.tags.joinToString("、") { "«#${it.first}»" })) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center) {
            t.tags.forEachIndexed { i, (tag, n) -> BarRow("#$tag", n, peak, colors[i % colors.size]) }
        }
    }
}

/** 名字 + 一根按比例的横条 + 右侧数字（或 [trailing] 文字）；[onClick] 不为空时整行可点 */
@Composable
private fun BarRow(
    name: String,
    value: Int,
    peak: Int,
    color: Color,
    trailing: String = "$value",
    trailingColor: Color = Color.Unspecified,
    onClick: (() -> Unit)? = null,
) {
    val scheme = MaterialTheme.colorScheme
    Row(
        Modifier
            .fillMaxWidth()
            .height(28.dp)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            name,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.ExtraBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.width(66.dp),
        )
        Box(
            Modifier
                .weight(1f)
                .height(8.dp)
                .clip(CircleShape)
                .background(scheme.onSurface.copy(alpha = 0.08f)),
        ) {
            Box(
                Modifier
                    .fillMaxWidth((value.toFloat() / peak).coerceIn(0f, 1f))
                    .fillMaxHeight()
                    .clip(CircleShape)
                    .background(color),
            )
        }
        Text(
            trailing,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.Black,
            color = trailingColor,
            maxLines = 1,
            textAlign = TextAlign.End,
            modifier = Modifier.widthIn(min = 28.dp),
        )
    }
}

// ───────────────────────── 项目 ─────────────────────────

/** 项目卡的行：记得最多的几个项目 + 一个久没记的；只有按专注拆时间时才出（否则时间分配卡已经是这个意思） */
private fun projectRows(flow: ProjectFlow): List<ProjectSlice>? {
    if (!flow.byFocus) return null
    val active = flow.slices.filter { it.activity > 0 }.sortedByDescending { it.activity }
    val stale = flow.slices.firstOrNull { it.stale && it.activity == 0 }
    val rows = active.take(if (stale != null) 2 else 3) + listOfNotNull(stale)
    return rows.takeIf { it.isNotEmpty() }
}

@Composable
private fun ProjectsCard(rows: List<ProjectSlice>, rangeLabel: String, onOpenProject: (String) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val colors = listOf(scheme.onSurface, Brand.Orange, scheme.onSurface.copy(alpha = 0.28f))
    val top = rows.firstOrNull { it.activity > 0 }
    val stale = rows.firstOrNull { it.activity == 0 }
    val headline = when {
        top != null -> "«${top.project.keyword}» 记得最多，${top.activity} 条"
        stale != null -> "«${stale.project.keyword}» 已经 ${stale.gapDays ?: "好几"} 天没记"
        else -> "项目动态"
    }
    val peak = (rows.maxOfOrNull { it.activity } ?: 1).coerceAtLeast(1)
    InsightCard("项目动态", rangeLabel, marked(headline)) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center) {
            rows.forEachIndexed { i, s ->
                if (s.activity > 0) {
                    BarRow(
                        name = s.project.keyword,
                        value = s.activity,
                        peak = peak,
                        color = colors[i % colors.size],
                        trailing = "${s.activity} 条",
                        onClick = { onOpenProject(s.project.keyword) },
                    )
                } else {
                    // 久没记的项目：空条 + 橙色「N 天没记」
                    BarRow(
                        name = s.project.keyword,
                        value = 0,
                        peak = peak,
                        color = Brand.Orange,
                        trailing = s.gapDays?.let { "$it 天没记" } ?: "该记一条了",
                        trailingColor = Brand.OrangeDeep,
                        onClick = { onOpenProject(s.project.keyword) },
                    )
                }
            }
        }
    }
}

// ───────────────────────── 习惯 ─────────────────────────

@Composable
private fun HabitCard(h: HabitInsight) {
    val scheme = MaterialTheme.colorScheme
    val colors = listOf(scheme.onSurface, Brand.Orange, scheme.onSurface.copy(alpha = 0.28f))
    val best = h.rows.first()
    val worst = h.rows.last()
    val headline = when {
        h.rows.size == 1 -> "「${best.name}」打卡完成率 «${(best.rate * 100).roundToInt()}%»"
        worst.rate < 0.5f && worst !== best -> "完成率 «${h.rate}%»，「${worst.name}」落下了"
        else -> "完成率 «${h.rate}%»，「${best.name}」最稳"
    }
    // 最多 3 行：最稳的、最落后的，再补一个中间的
    val rows = if (h.rows.size <= 3) h.rows else listOf(h.rows[0], h.rows[1], h.rows.last())
    InsightCard("习惯打卡", "${h.rows.size} 个习惯", marked(headline)) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center) {
            rows.forEachIndexed { i, r ->
                BarRow(
                    name = r.name,
                    value = r.done,
                    peak = r.due.coerceAtLeast(1),
                    color = colors[i % colors.size],
                    trailing = "${r.done}/${r.due}",
                )
            }
        }
    }
}

/** 「«21–23 点»」里被 «» 包住的部分用橙色荧光笔标出来 */
@Composable
private fun marked(text: String): AnnotatedString {
    val hl = Brand.Orange.copy(alpha = 0.38f)
    return remember(text, hl) {
        buildAnnotatedString {
            var inMark = false
            // split 丢掉了分隔符，靠交替来判断是否在标记里
            for (piece in text.split('«', '»')) {
                if (inMark) withStyle(SpanStyle(background = hl)) { append(piece) } else append(piece)
                inMark = !inMark
            }
        }
    }
}
