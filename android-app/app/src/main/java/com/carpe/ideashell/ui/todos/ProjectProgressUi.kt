package com.carpe.ideashell.ui.todos

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.dida.FocusParser
import com.carpe.ideashell.data.focus.FocusRepository
import com.carpe.ideashell.data.project.DeliveryState
import com.carpe.ideashell.data.project.Project
import com.carpe.ideashell.data.project.ProjectDelivery
import com.carpe.ideashell.data.project.ProjectFocusStats
import com.carpe.ideashell.data.project.ProjectMonthlyFocus
import com.carpe.ideashell.data.project.ProjectPulse
import com.carpe.ideashell.data.project.ProjectStats
import com.carpe.ideashell.data.project.Trend
import com.carpe.ideashell.domain.Dossier
import com.carpe.ideashell.domain.DossierNote
import com.carpe.ideashell.ui.components.DividedRows
import com.carpe.ideashell.ui.components.InputSheet
import com.carpe.ideashell.ui.components.ListGroup
import com.carpe.ideashell.ui.components.PillChip
import com.carpe.ideashell.ui.components.RowDivider
import com.carpe.ideashell.ui.review.NoteRow
import com.carpe.ideashell.ui.theme.Brand
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.roundToInt

// ───────────────────────── 通用：详情抽屉 ─────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun DetailSheet(
    title: String,
    subtitle: String?,
    onDismiss: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
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
            Column(Modifier.padding(horizontal = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, style = MaterialTheme.typography.titleLarge)
                if (subtitle != null) {
                    Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            content()
        }
    }
}

@Composable
private fun SheetHint(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 4.dp),
    )
}

/** 一行「名称 …… 值」，可带一句小字说明 */
@Composable
private fun SheetFactRow(label: String, value: String, note: String? = null) {
    val scheme = MaterialTheme.colorScheme
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
            Text(value, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Bold)
        }
        if (note != null) Text(note, style = MaterialTheme.typography.bodySmall, color = scheme.onSurfaceVariant)
    }
}

/** 分钟的紧凑写法：45 分 / 1.5 小时 */
internal fun compactMin(min: Int): String = when {
    min <= 0 -> "0"
    min < 60 -> "$min 分"
    min % 60 == 0 -> "${min / 60} 小时"
    else -> "${"%.1f".format(min / 60.0)} 小时"
}

// ───────────────────────── 三格数据的详情 ─────────────────────────

internal enum class StatKind { RECENT, DAYS30, MONTHS }

@Composable
internal fun StatDetailSheet(
    kind: StatKind,
    project: Project,
    stats: ProjectStats,
    monthlyFocus: ProjectMonthlyFocus?,
    onOpenNote: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val today = remember { LocalDate.now() }
    when (kind) {
        // 「最近提及」看的是「多久没动了、平时多久动一次」：最近一次 + 节奏 + 往前的几篇
        StatKind.RECENT -> {
            val gap = stats.lastDay?.let { Dossier.daysBetween(it, today) }
            DetailSheet(
                title = "最近提及",
                subtitle = if (gap == null) "还没有提及「${project.keyword}」的笔记" else "最近一次是 ${Dossier.ago(gap)}，累计 ${stats.total} 篇",
                onDismiss = onDismiss,
            ) { RecentBody(project, stats, today, onOpenNote, onDismiss) }
        }

        // 「近 30 天」看的是「这一个月的分布」：每天的柱图 + 数字 + 按周分组的笔记
        StatKind.DAYS30 -> {
            val list = stats.mentions.filter { n -> n.day?.let { Dossier.daysBetween(it, today) < 30 } == true }
            DetailSheet(
                title = "近 30 天",
                subtitle = "共 ${list.size} 篇提及「${project.keyword}」的笔记",
                onDismiss = onDismiss,
            ) { MonthBody(project, list, today, onOpenNote, onDismiss) }
        }

        StatKind.MONTHS -> DetailSheet(
            title = "近 12 个月",
            subtitle = "每个月提及「${project.keyword}」的笔记数和专注时长，点一个月可以展开那个月的笔记",
            onDismiss = onDismiss,
        ) { MonthBreakdown(stats, monthlyFocus, today, onOpenNote, onDismiss) }
    }
}

private fun snippetOf(n: DossierNote): String = (if (n.viaSpeaker && n.mentions == 0) "有其发言　" else "") + n.snippet

/** 一个分组：小标题（带篇数）+ 白色圆角块里的笔记 */
@Composable
private fun ColumnScope.NoteGroup(label: String, list: List<DossierNote>, onOpenNote: (String) -> Unit, onDismiss: () -> Unit) {
    Text(
        "$label · ${list.size} 篇",
        style = MaterialTheme.typography.titleSmall,
        modifier = Modifier.padding(start = 4.dp, top = 4.dp),
    )
    ListGroup {
        DividedRows(list) { n ->
            NoteRow(n.note, onClick = { onDismiss(); onOpenNote(n.note.id) }, snippet = snippetOf(n))
        }
    }
}

@Composable
private fun MiniStat(value: String, label: String, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(18.dp))
            .background(scheme.surfaceContainerLowest)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.ExtraBold, maxLines = 1)
        Text(label, style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant, maxLines = 1)
    }
}

private fun recencyBucket(ago: Int?): String = when {
    ago == null -> "更早"
    ago <= 0 -> "今天"
    ago == 1 -> "昨天"
    ago <= 6 -> "这周"
    ago <= 13 -> "上周"
    ago <= 30 -> "本月内"
    else -> "更早"
}

/** 最近提及：最近一次（高亮）+ 节奏（距上一篇 / 平时多久一次 / 提醒阈值）+ 再往前的几篇（按时间远近分组） */
@Composable
private fun ColumnScope.RecentBody(
    project: Project,
    stats: ProjectStats,
    today: LocalDate,
    onOpenNote: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    val latest = stats.mentions.firstOrNull()
    if (latest == null) {
        SheetHint("还没有笔记写到这个项目。用主卡上的「记一条」写第一条。")
        return
    }
    val gap = latest.day?.let { Dossier.daysBetween(it, today) }

    // 最近一次
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(Brand.Orange.copy(alpha = 0.2f))
            .clickable { onDismiss(); onOpenNote(latest.note.id) }
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            "最近一次 · " + (gap?.let { Dossier.ago(it) } ?: "") + (latest.day?.let { "（${it.monthValue}月${it.dayOfMonth}日）" } ?: ""),
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.Bold,
            color = scheme.onSurfaceVariant,
        )
        Text(
            latest.note.title.ifBlank { "（无标题）" },
            style = MaterialTheme.typography.titleMedium,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        val snip = snippetOf(latest)
        if (snip.isNotBlank()) {
            Text(snip, style = MaterialTheme.typography.bodyMedium, color = scheme.onSurfaceVariant, maxLines = 3, overflow = TextOverflow.Ellipsis)
        }
    }

    // 节奏
    val days = stats.mentions.mapNotNull { it.day }.distinct().sortedDescending()
    val prevGap = if (days.size >= 2) Dossier.daysBetween(days[1], days[0]) else null
    val rhythm = if (days.size >= 2) Dossier.daysBetween(days.last(), days.first()).toDouble() / (days.size - 1) else null
    ListGroup {
        SheetFactRow(
            "距上一篇",
            when {
                prevGap == null -> "只有这一篇"
                prevGap == 0 -> "同一天"
                else -> "$prevGap 天"
            },
            if (prevGap != null && prevGap > 0) "上一篇是 ${days[1].monthValue}月${days[1].dayOfMonth}日" else null,
        )
        RowDivider()
        SheetFactRow(
            "平时节奏",
            when {
                rhythm == null -> "还不够算"
                rhythm < 1.5 -> "几乎每天"
                else -> "约每 ${if (rhythm < 10) "%.1f".format(rhythm) else rhythm.roundToInt().toString()} 天一次"
            },
            "按累计 ${stats.total} 篇、${days.size} 个有动静的日子算",
        )
        RowDivider()
        SheetFactRow(
            "提醒阈值",
            "${project.staleDays} 天",
            when {
                gap == null -> null
                gap == 0 -> "今天已经记过了"
                gap >= project.staleDays -> "已经 $gap 天没动了，超过 ${gap - project.staleDays} 天，该记一条了"
                else -> "再过 ${project.staleDays - gap} 天没动就会提醒"
            },
        )
    }

    // 往前的几篇，按远近分组
    val earlier = stats.mentions.drop(1).take(9)
    if (earlier.isNotEmpty()) {
        earlier.groupBy { n -> recencyBucket(n.day?.let { Dossier.daysBetween(it, today) }) }.forEach { (label, list) ->
            NoteGroup(label, list, onOpenNote, onDismiss)
        }
    }
}

/** 每天提及数的柱图（最早的在左、今天在右），下面标出起止 */
@Composable
private fun DayBars(series: List<Int>, modifier: Modifier = Modifier) {
    val on = Brand.Orange
    val off = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.1f)
    androidx.compose.foundation.Canvas(modifier.fillMaxWidth().height(56.dp)) {
        val n = series.size
        if (n == 0) return@Canvas
        val max = (series.maxOrNull() ?: 0).coerceAtLeast(1)
        val gap = 3.dp.toPx()
        val bw = (size.width - gap * (n - 1)) / n
        series.forEachIndexed { i, v ->
            val h = if (v == 0) 3.dp.toPx() else (size.height * v / max).coerceAtLeast(6.dp.toPx())
            drawRoundRect(
                color = if (v > 0) on else off,
                topLeft = androidx.compose.ui.geometry.Offset(i * (bw + gap), size.height - h),
                size = androidx.compose.ui.geometry.Size(bw, h),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(bw / 2),
            )
        }
    }
}

/** 近 30 天：每天的柱图 + 篇数 / 活跃天数 / 最长空档 + 常一起出现的标签 + 按周分组的笔记 */
@Composable
private fun ColumnScope.MonthBody(
    project: Project,
    list: List<DossierNote>,
    today: LocalDate,
    onOpenNote: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    if (list.isEmpty()) {
        SheetHint("近 30 天没有笔记提及这个项目。")
        return
    }
    val perDay = IntArray(30)
    list.forEach { n -> n.day?.let { d -> perDay[29 - Dossier.daysBetween(d, today).coerceIn(0, 29)]++ } }
    val active = perDay.count { it > 0 }
    var longest = 0
    var quiet = 0
    for (c in perDay) {
        if (c == 0) {
            quiet++
            longest = maxOf(longest, quiet)
        } else {
            quiet = 0
        }
    }
    val busiestIdx = perDay.indices.maxByOrNull { perDay[it] } ?: 0
    val busiest = today.minusDays((29 - busiestIdx).toLong())

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(scheme.surfaceContainerLowest)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        DayBars(perDay.toList())
        Row {
            Text("30 天前", style = MaterialTheme.typography.labelSmall, color = scheme.onSurfaceVariant, modifier = Modifier.weight(1f))
            Text("今天", style = MaterialTheme.typography.labelSmall, color = scheme.onSurfaceVariant)
        }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        MiniStat("${list.size} 篇", "笔记", Modifier.weight(1f))
        MiniStat("$active / 30 天", "有动静的天数", Modifier.weight(1f))
        MiniStat("$longest 天", "最长空档", Modifier.weight(1f))
    }
    SheetHint(
        "最忙的一天是 ${busiest.monthValue}月${busiest.dayOfMonth}日（${perDay[busiestIdx]} 篇）。" +
            tagLine(project, list),
    )

    val weeks = listOf("最近 7 天" to 0..6, "8–14 天前" to 7..13, "15–21 天前" to 14..20, "22–30 天前" to 21..29)
    for ((label, range) in weeks) {
        val part = list.filter { n -> n.day?.let { Dossier.daysBetween(it, today) in range } == true }
        if (part.isNotEmpty()) NoteGroup(label, part, onOpenNote, onDismiss)
    }
}

/** 这些笔记里常和项目一起出现的标签（去掉项目自己的关键词 / 标签） */
private fun tagLine(project: Project, list: List<DossierNote>): String {
    val own = project.terms.map { it.lowercase() }.toSet()
    val top = list.flatMap { it.tags }
        .filter { it.isNotBlank() && it.trim().trimStart('#').lowercase() !in own }
        .groupingBy { it.trim().trimStart('#') }
        .eachCount()
        .entries.sortedByDescending { it.value }
        .take(5)
    return if (top.isEmpty()) "" else "常一起出现：" + top.joinToString("　") { "#${it.key} ${it.value}" }
}

@Composable
private fun ColumnScope.MonthBreakdown(
    stats: ProjectStats,
    monthlyFocus: ProjectMonthlyFocus?,
    today: LocalDate,
    onOpenNote: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    val focusColor = Color(0xFF3E8BFF)
    val (labels, counts) = remember(stats) { Dossier.monthlySeries(stats.mentions.mapNotNull { it.day }, today) }
    val max = (counts.maxOrNull() ?: 0).coerceAtLeast(1)
    val mins = labels.map { monthlyFocus?.minutes?.get(it) ?: 0 }
    val maxMin = (mins.maxOrNull() ?: 0).coerceAtLeast(1)
    var open by remember { mutableStateOf<String?>(null) }
    SheetHint(
        buildString {
            append("12 个月共 ${counts.sum()} 篇")
            append(
                when {
                    monthlyFocus == null -> "，专注时长统计中…"
                    mins.sum() > 0 -> "，专注 ${compactMin(mins.sum())}"
                    else -> "，没有专注记录"
                },
            )
        },
    )
    ListGroup {
        for (i in labels.indices.reversed()) {
            val label = labels[i]
            val n = counts[i]
            val min = mins[i]
            val isOpen = open == label
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(enabled = n > 0) { open = if (isOpen) null else label }
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    label,
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (n > 0) scheme.onSurface else scheme.onSurfaceVariant,
                    modifier = Modifier.width(64.dp),
                )
                // 上面一条：提及的笔记数（橙）；下面一条：当月专注时长（蓝）
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .height(8.dp)
                            .clip(CircleShape)
                            .background(scheme.onSurface.copy(alpha = 0.08f)),
                    ) {
                        Box(
                            Modifier
                                .fillMaxWidth(n.toFloat() / max)
                                .fillMaxHeight()
                                .clip(CircleShape)
                                .background(Brand.Orange),
                        )
                    }
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .height(8.dp)
                            .clip(CircleShape)
                            .background(scheme.onSurface.copy(alpha = 0.08f)),
                    ) {
                        Box(
                            Modifier
                                .fillMaxWidth(min.toFloat() / maxMin)
                                .fillMaxHeight()
                                .clip(CircleShape)
                                .background(focusColor),
                        )
                    }
                }
                Column(Modifier.width(76.dp), horizontalAlignment = Alignment.End) {
                    Text(
                        "$n 篇",
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = if (n > 0) FontWeight.Bold else FontWeight.Normal,
                        color = if (n > 0) scheme.onSurface else scheme.onSurfaceVariant,
                    )
                    Text(
                        if (monthlyFocus == null) "…" else if (min > 0) compactMin(min) else "—",
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = if (min > 0) FontWeight.Bold else FontWeight.Normal,
                        color = if (min > 0) focusColor else scheme.onSurfaceVariant,
                    )
                }
            }
            if (isOpen) {
                val notes = stats.mentions.filter { m -> m.day?.let { "%04d-%02d".format(it.year, it.monthValue) } == label }
                RowDivider()
                DividedRows(notes) { m ->
                    NoteRow(
                        m.note,
                        onClick = { onDismiss(); onOpenNote(m.note.id) },
                        snippet = (if (m.viaSpeaker && m.mentions == 0) "有其发言　" else "") + m.snippet,
                    )
                }
            }
            if (i > 0) RowDivider()
        }
    }
}

// ───────────────────────── 进展怎么算 ─────────────────────────

/** 主卡环里的进度：有成果用「交付进度」，没有就退回任务完成率；第二个值是环里的小字 */
internal data class ProgressView(val progress: Float?, val caption: String?, val basis: String)

internal fun progressViewOf(delivery: ProjectDelivery?, done: Int, total: Int): ProgressView {
    val p = delivery?.progress
    return when {
        delivery != null && p != null ->
            ProgressView(p, "${delivery.delivered}/${delivery.counted}", "交付进度：${delivery.counted} 个成果，每个等权")
        total > 0 -> ProgressView(done.toFloat() / total, "$done/$total", "任务完成率：还没有任务笔记，暂按近期任务算")
        else -> ProgressView(null, null, "还没有成果，也没有相关任务")
    }
}

@Composable
internal fun ProgressSheet(
    project: Project,
    view: ProgressView,
    delivery: ProjectDelivery?,
    trend: Trend?,
    windows: Pair<Int, Int>?,
    gap: Int?,
    focus: ProjectFocusStats?,
    onDismiss: () -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    DetailSheet(
        title = "进展 · ${project.keyword}",
        subtitle = (view.progress?.let { "${(it * 100).roundToInt()}%　" } ?: "") + view.basis,
        onDismiss = onDismiss,
    ) {
        if (delivery != null && delivery.items.isNotEmpty()) {
            Text("成果", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(start = 4.dp))
            ListGroup {
                delivery.items.forEachIndexed { i, item ->
                    if (i > 0) RowDivider()
                    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                item.title,
                                style = MaterialTheme.typography.bodyLarge,
                                fontWeight = FontWeight.Medium,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f),
                            )
                            Text(
                                when (item.state) {
                                    DeliveryState.DONE -> "100%"
                                    DeliveryState.ACTIVE -> "${(item.score * 100).roundToInt()}%"
                                    DeliveryState.UNKNOWN -> "—"
                                },
                                style = MaterialTheme.typography.bodyLarge,
                                fontWeight = FontWeight.Bold,
                            )
                        }
                        Text(
                            when (item.state) {
                                DeliveryState.DONE -> "已交付"
                                DeliveryState.ACTIVE ->
                                    if (item.stepsTotal > 0) "进行中 · 行动步骤 ${item.stepsDone}/${item.stepsTotal}" else "进行中 · 笔记里还没有行动步骤"
                                DeliveryState.UNKNOWN -> "状态未知（读不到对应的滴答任务），不计入"
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = scheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }

        Text("其他指标", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(start = 4.dp))
        ListGroup {
            if (delivery != null && delivery.counted > 0) {
                SheetFactRow(
                    "在制品",
                    "${delivery.active} 个进行中",
                    if (delivery.active > ProjectPulse.WIP_LIMIT) "偏多：同时推进太多会拖慢交付，先收尾一两个再开新的" else "同时进行的成果数，3 个以内比较从容",
                )
                RowDivider()
            }
            SheetFactRow(
                "势头",
                if (trend == null) "统计中…" else "${trend.arrow} ${trend.label}",
                windows?.let { "最近 7 天有 ${it.first} 天有动静，前 7 天 ${it.second} 天（写了笔记或专注过都算）" },
            )
            RowDivider()
            SheetFactRow("上次提及", if (gap == null) "暂无" else Dossier.ago(gap))
            RowDivider()
            SheetFactRow(
                "专注投入",
                if (focus == null) "统计中…" else "近 7 天 ${compactMin(focus.weekMin)}",
                focus?.let { "近 30 天 ${compactMin(it.monthMin)}" },
            )
        }

        SheetHint(
            "怎么算：以「成果」（一个任务笔记 = 一个要交付的成果）为单位，每个成果等权。" +
                "已交付记 100%，进行中按笔记里「行动步骤」的勾选比例记分；交付进度 = 各成果得分之和 ÷ 成果数。" +
                "用成果而不是任务数，是因为任务可以随手拆、随手删，会让百分比忽高忽低。" +
                "全部来自任务状态、笔记里的 - [x]、提及的笔记和专注记录，没有任何估算。",
        )
    }
}

// ───────────────────────── 专注：卡片 · 明细 · 发起 ─────────────────────────

/** 项目页上的专注统计卡：今天 / 近 7 天 / 近 30 天 / 近 90 天 + 近 14 天小柱图；点开看明细 */
@Composable
internal fun FocusCard(stats: ProjectFocusStats?, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(scheme.surfaceContainerLowest)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("专注", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
            Text(
                if (stats == null) "统计中…" else "明细 ›",
                style = MaterialTheme.typography.labelMedium,
                color = scheme.onSurfaceVariant,
            )
        }
        Row(verticalAlignment = Alignment.Bottom) {
            Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                FocusNumber("今天", stats?.todayMin)
                FocusNumber("近 7 天", stats?.weekMin)
                FocusNumber("近 30 天", stats?.monthMin)
                FocusNumber("近 ${stats?.windowDays ?: 90} 天", stats?.totalMin)
            }
        }
        val daily = stats?.daily14.orEmpty()
        if (daily.any { it > 0 }) {
            MonthBars(daily, 140.dp, 18.dp)
        } else if (stats != null) {
            Text(
                "还没有专注记录。点上面的「专注一次」开始。",
                style = MaterialTheme.typography.bodySmall,
                color = scheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun FocusNumber(label: String, min: Int?) {
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Text(
            if (min == null) "…" else compactMin(min),
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.ExtraBold,
            maxLines = 1,
        )
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
    }
}

@Composable
internal fun FocusDetailSheet(project: Project, stats: ProjectFocusStats, onDismiss: () -> Unit) {
    val zone = remember { ZoneId.systemDefault() }
    DetailSheet(
        title = "专注 · ${project.keyword}",
        subtitle = "近 ${stats.windowDays} 天共 ${FocusParser.formatMinutes(stats.totalMin)}，${stats.count} 次",
        onDismiss = onDismiss,
    ) {
        if (stats.byTask.isNotEmpty()) {
            Text("按任务", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(start = 4.dp))
            ListGroup {
                stats.byTask.take(8).forEachIndexed { i, (title, min) ->
                    if (i > 0) RowDivider()
                    val pct = if (stats.totalMin > 0) (min * 100f / stats.totalMin).roundToInt() else 0
                    SheetFactRow(title, FocusParser.formatMinutes(min), "占 $pct%")
                }
            }
        }
        if (stats.sessions.isNotEmpty()) {
            Text("最近几次", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(start = 4.dp))
            ListGroup {
                stats.sessions.forEachIndexed { i, s ->
                    if (i > 0) RowDivider()
                    val at = Instant.ofEpochMilli(s.startMs).atZone(zone)
                    SheetFactRow(
                        "${at.monthValue}月${at.dayOfMonth}日 %02d:%02d".format(at.hour, at.minute),
                        FocusParser.formatMinutes(s.minutes),
                        s.title,
                    )
                }
            }
        }
        SheetHint("统计范围：滴答里近 ${stats.windowDays} 天属于本项目任务的专注（任务标题含项目关键词 / 标签，或有任务笔记），加上从项目页发起的专注。")
    }
}

/** 「专注一次」：选时长、选要专注的任务（也可以不选，直接为项目专注），开始后到专注页倒计时 */
@Composable
internal fun FocusStartSheet(
    project: Project,
    tasks: List<DidaTask>,
    defaultMinutes: Int,
    onStart: (task: DidaTask?, minutes: Int) -> Unit,
    onDismiss: () -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    var minutes by remember { mutableIntStateOf(defaultMinutes) }
    var picked by remember { mutableStateOf<DidaTask?>(null) }
    InputSheet(
        title = "专注一次 · ${project.keyword}",
        hint = "专注中，通知栏的「记录」会写进项目主页的「里程碑与进展」。",
        confirmLabel = "开始专注 $minutes 分钟",
        onDismiss = onDismiss,
        onConfirm = { onStart(picked, minutes) },
    ) {
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val choices = (FocusRepository.CHOICES + defaultMinutes).distinct().sorted()
            choices.forEach { m ->
                PillChip("$m 分", selected = minutes == m, onClick = { minutes = m })
            }
        }
        ListGroup {
            TaskChoiceRow("不关联任务", "为整个项目专注", picked == null) { picked = null }
            tasks.take(8).forEach { t ->
                RowDivider()
                TaskChoiceRow(TodoMeta.cleanTitle(t.title).ifBlank { t.title }, "滴答任务", picked?.id == t.id) { picked = t }
            }
        }
        if (tasks.isEmpty()) {
            Text(
                "这个项目近期没有未完成的任务；也可以直接为项目专注。",
                style = MaterialTheme.typography.bodySmall,
                color = scheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 4.dp),
            )
        }
    }
}

@Composable
private fun TaskChoiceRow(title: String, sub: String, selected: Boolean, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(sub, style = MaterialTheme.typography.bodySmall, color = scheme.onSurfaceVariant)
        }
        if (selected) Icon(Icons.Filled.Check, contentDescription = "已选", tint = Brand.Orange)
    }
}
