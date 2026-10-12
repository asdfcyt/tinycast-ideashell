package com.carpe.ideashell.ui.review

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.carpe.ideashell.core.parse.TimeRanges
import com.carpe.ideashell.domain.Insights
import com.carpe.ideashell.domain.ProjectFlow
import com.carpe.ideashell.domain.ProjectSlice
import com.carpe.ideashell.domain.RhythmInsight
import com.carpe.ideashell.domain.StreakInsight
import com.carpe.ideashell.domain.TodoInsight
import com.carpe.ideashell.domain.TopicInsight
import com.carpe.ideashell.ui.glass.GlassSurface
import com.carpe.ideashell.ui.theme.Brand
import kotlin.math.max
import kotlin.math.roundToInt

/*
 * 回看顶部的「发现」：首屏只让一张卡当主角，其余横滑查看，把首屏的大部分留给下面的时间轴。
 * 第一张是环形的时间分配（按项目拆专注时长，没有专注数据时按记录条数）；
 * 后面每张卡讲一件事，一句结论 + 一张图：记录时刻（24 小时柱）、连续记录（七日点）、待办逾期、常提到的话题。
 * 结论里的关键数字用橙色荧光笔标出（文字里用 «» 包起来）；没有数据撑起来的卡直接不出现；只剩一张卡时不做分页。
 */
fun LazyListScope.insightsItem(flow: ProjectFlow, insights: Insights?, onOpenProject: (String) -> Unit) {
    val hasRing = flow.slices.any { flow.weightOf(it) > 0 || it.stale }
    val ins = insights ?: Insights.Empty
    if (!hasRing && ins.isEmpty) return
    item(key = "insights") { InsightsPager(flow, ins, hasRing, onOpenProject) }
}

private const val CARD_HEIGHT = 200

private class Seg(val name: String, val value: Int, val color: Color, val keyword: String?)

/** 3h10 / 40m */
private fun shortMinutes(min: Int): String = when {
    min < 60 -> "${min}m"
    min % 60 == 0 -> "${min / 60}h"
    else -> "${min / 60}h${"%02d".format(min % 60)}"
}

@Composable
private fun InsightsPager(flow: ProjectFlow, insights: Insights, hasRing: Boolean, onOpenProject: (String) -> Unit) {
    val pages = buildList<@Composable () -> Unit> {
        if (hasRing) add { AllocationCard(flow, onOpenProject) }
        insights.rhythm?.let { add { RhythmCard(it) } }
        insights.streak?.let { add { StreakCard(it) } }
        insights.todo?.let { add { TodoCard(it) } }
        insights.topic?.let { add { TopicCard(it) } }
    }
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

/** 一张卡：固定高度，顶上一行小标签，其余由内容自己排 */
@Composable
private fun InsightCard(label: String, content: @Composable ColumnScope.() -> Unit) {
    GlassSurface(Modifier.fillMaxWidth().height(CARD_HEIGHT.dp), shape = RoundedCornerShape(24.dp)) {
        Column(Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 14.dp)) {
            Text(
                label,
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.ExtraBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            content()
        }
    }
}

/** 卡里的一句结论 */
@Composable
private fun Headline(text: AnnotatedString) {
    Text(
        text,
        fontSize = 18.sp,
        lineHeight = 25.sp,
        fontWeight = FontWeight.ExtraBold,
        modifier = Modifier.padding(top = 4.dp),
        maxLines = 3,
        overflow = TextOverflow.Ellipsis,
    )
}

// ───────────────────────── 时间分配 ─────────────────────────

@Composable
private fun AllocationCard(flow: ProjectFlow, onOpenProject: (String) -> Unit) {
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
    val stale = flow.slices.filter { it.stale && flow.weightOf(it) == 0 }.take(2)
    val title = when {
        total == 0 -> "项目动态"
        flow.byFocus -> "时间分配 · 本期共 ${shortMinutes(flow.totalMin)}"
        else -> "项目动态 · 共 $total 条记录"
    }

    InsightCard(title) {
        Row(
            Modifier.fillMaxWidth().weight(1f),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
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
    Box(Modifier.size(104.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(104.dp)) {
            val sw = 11.dp.toPx()
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
            Text(center, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Black, maxLines = 1)
            Text(caption, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
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
            .heightIn(min = 28.dp)
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

// ───────────────────────── 记录时刻 ─────────────────────────

@Composable
private fun RhythmCard(r: RhythmInsight) {
    val scheme = MaterialTheme.colorScheme
    val maxV = (r.hours.maxOrNull() ?: 1).coerceAtLeast(1)
    val ink = scheme.onSurface.copy(alpha = 0.22f)
    InsightCard("记录时刻") {
        Headline(
            marked(if (r.verb == "记录") "最常在 «${r.peakLabel}» 记录" else "你习惯在 «${r.peakLabel}» ${r.verb}"),
        )
        Box(Modifier.weight(1f))
        Row(
            modifier = Modifier.fillMaxWidth().height(52.dp),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            r.hours.forEachIndexed { h, v ->
                Box(
                    Modifier
                        .weight(1f)
                        .fillMaxHeight((v.toFloat() / maxV).coerceAtLeast(0.06f))
                        .clip(RoundedCornerShape(2.dp))
                        .background(if (h in r.peakRange) Brand.Orange else ink),
                )
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 3.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            listOf("0", "6", "12", "18", "24").forEach {
                Text(it, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.ExtraBold, color = scheme.onSurfaceVariant)
            }
        }
    }
}

// ───────────────────────── 连续记录 ─────────────────────────

@Composable
private fun StreakCard(s: StreakInsight) {
    val scheme = MaterialTheme.colorScheme
    InsightCard("连续记录") {
        Headline(
            marked("«${s.activeDays}/${s.spanDays} 天» 有记录" + if (s.streak >= 2) "，连续 ${s.streak} 天" else ""),
        )
        Box(Modifier.weight(1f))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            s.lastWeek.forEachIndexed { i, on ->
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Box(
                        Modifier
                            .size(22.dp)
                            .clip(CircleShape)
                            .then(
                                if (on) Modifier.background(Brand.Orange)
                                else Modifier.border(2.dp, scheme.onSurface.copy(alpha = 0.25f), CircleShape),
                            ),
                    )
                    Text(
                        TimeRanges.weekdayName(s.lastWeekDays[i]).takeLast(1),
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.ExtraBold,
                        color = if (i == s.lastWeek.lastIndex) scheme.primary else scheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

// ───────────────────────── 待办 ─────────────────────────

@Composable
private fun TodoCard(t: TodoInsight) {
    val scheme = MaterialTheme.colorScheme
    val pct = if (t.total == 0) 0 else (100f * t.done / t.total).roundToInt()
    InsightCard("待办") {
        Headline(
            marked(if (t.overdue > 0) "«${t.overdue} 条» 待办已逾期，最久 ${t.maxLateDays} 天" else "待办没有逾期，都在按时推进"),
        )
        Box(Modifier.weight(1f))
        Row(verticalAlignment = Alignment.Bottom) {
            Text("$pct", fontSize = 30.sp, lineHeight = 34.sp, fontWeight = FontWeight.Black)
            Text("%", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.ExtraBold, modifier = Modifier.padding(bottom = 4.dp))
            Box(Modifier.weight(1f))
            Text(
                "${t.done}/${t.total} 完成",
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.Black,
                color = scheme.primary,
                modifier = Modifier.padding(bottom = 4.dp),
            )
        }
        Box(
            Modifier
                .padding(top = 6.dp)
                .fillMaxWidth()
                .height(8.dp)
                .clip(CircleShape)
                .background(scheme.onSurface.copy(alpha = 0.1f)),
        ) {
            Box(
                Modifier
                    .fillMaxWidth(pct / 100f)
                    .fillMaxHeight()
                    .clip(CircleShape)
                    .background(scheme.onSurface),
            )
        }
    }
}

// ───────────────────────── 话题 ─────────────────────────

@Composable
private fun TopicCard(t: TopicInsight) {
    val scheme = MaterialTheme.colorScheme
    InsightCard("话题") {
        Headline(marked("常提到 " + t.tags.joinToString("、") { "«#${it.first}»" }))
        Box(Modifier.weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            t.tags.forEach { (tag, n) ->
                Row(
                    modifier = Modifier
                        .heightIn(min = 30.dp)
                        .clip(CircleShape)
                        .background(scheme.onSurface.copy(alpha = 0.07f))
                        .padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(tag, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.ExtraBold, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                    Text("$n", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Black, color = scheme.primary)
                }
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
