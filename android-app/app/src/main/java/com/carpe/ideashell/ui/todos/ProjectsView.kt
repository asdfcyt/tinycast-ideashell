package com.carpe.ideashell.ui.todos

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.core.template.Templates
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.project.Project
import com.carpe.ideashell.data.project.ProjectStats
import com.carpe.ideashell.data.project.ProjectStatus
import com.carpe.ideashell.data.project.TaskNoteEntry
import com.carpe.ideashell.domain.Dossier
import com.carpe.ideashell.ui.components.CircleIconButton
import com.carpe.ideashell.ui.components.ConfirmDialog
import com.carpe.ideashell.ui.components.EmptyNote
import com.carpe.ideashell.ui.components.FormDialog
import com.carpe.ideashell.ui.components.FormField
import com.carpe.ideashell.ui.components.GroupLabel
import com.carpe.ideashell.ui.components.DividedRows
import com.carpe.ideashell.ui.components.ListGroup
import com.carpe.ideashell.ui.components.PillChip
import com.carpe.ideashell.ui.components.RowPill
import com.carpe.ideashell.ui.components.TextPromptDialog
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import com.carpe.ideashell.ui.glass.isDarkSurface
import com.carpe.ideashell.ui.review.NoteRow
import com.carpe.ideashell.ui.theme.Brand
import java.time.LocalDate
import kotlin.math.roundToInt

private val STALE_CHOICES = listOf(3, 7, 14, 30, 60)

private fun relatedOpen(p: Project, ctx: TodoCtx?): List<DidaTask> {
    val o = ctx?.overview ?: return emptyList()
    return (o.overdue + o.upcoming + o.undated).filter { p.matches(it.title, it.tags) }
}

private fun relatedDone(p: Project, ctx: TodoCtx?): List<DidaTask> =
    ctx?.overview?.done.orEmpty().filter { p.matches(it.title, it.tags) }

// ───────────────────────── 项目的一句话概况 ─────────────────────────

/** 一个项目在列表 / 卡片 / 主页上要用到的几个数：完成度（最近完成 ÷ 最近完成 + 未完成）、距上次提及的天数、是否该记一条了 */
internal class ProjectBrief(
    val project: Project,
    val stats: ProjectStats?,
    val open: Int,
    val done: Int,
    val gap: Int?,
    val stale: Boolean,
) {
    val progress: Float? get() = if (open + done == 0) null else done.toFloat() / (open + done)

    /** 环里写的字：有任务写百分比，没有就写项目名的第一个字 */
    fun ringText(percentSign: Boolean): String =
        progress?.let { "${(it * 100).roundToInt()}" + if (percentSign) "%" else "" } ?: project.keyword.take(1)
}

/** 该记一条了的排最前，其次按状态、名字 */
internal fun briefsOf(
    projects: List<Project>,
    stats: Map<String, ProjectStats>,
    ctx: TodoCtx?,
    today: LocalDate,
): List<ProjectBrief> = projects.map { p ->
    val s = stats[p.keyword]
    val gap = s?.lastDay?.let { Dossier.daysBetween(it, today) }
    ProjectBrief(
        project = p,
        stats = s,
        open = relatedOpen(p, ctx).size,
        done = relatedDone(p, ctx).size,
        gap = gap,
        stale = p.status != ProjectStatus.PAUSED && gap != null && gap >= p.staleDays,
    )
}.sortedWith(
    compareByDescending<ProjectBrief> { it.stale }
        .thenBy { it.project.status.ordinal }
        .thenBy { it.project.keyword.lowercase() },
)

// ───────────────────────── 小部件：环、柱图、提醒标 ─────────────────────────

@Composable
internal fun ProgressRing(
    progress: Float?,
    size: Dp,
    stroke: Dp,
    modifier: Modifier = Modifier,
    arc: Color = Brand.Orange,
    track: Color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.1f),
    content: @Composable BoxScope.() -> Unit,
) {
    Box(modifier.size(size), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val w = stroke.toPx()
            val d = this.size.minDimension - w
            val topLeft = Offset(w / 2, w / 2)
            val box = Size(d, d)
            drawArc(track, 0f, 360f, false, topLeft, box, style = Stroke(w))
            if (progress != null && progress > 0f) {
                drawArc(arc, -90f, 360f * progress.coerceAtMost(1f), false, topLeft, box, style = Stroke(w, cap = StrokeCap.Round))
            }
        }
        content()
    }
}

/** 近 12 个月每月提及数的小柱图 */
@Composable
private fun MonthBars(series: List<Int>, width: Dp, height: Dp, modifier: Modifier = Modifier) {
    val on = Brand.Orange
    val off = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f)
    Canvas(modifier.size(width, height)) {
        val n = series.size
        if (n == 0) return@Canvas
        val max = (series.maxOrNull() ?: 0).coerceAtLeast(1)
        val gap = 2.dp.toPx()
        val bw = (size.width - gap * (n - 1)) / n
        series.forEachIndexed { i, v ->
            val h = if (v == 0) 2.dp.toPx() else (size.height * v / max).coerceAtLeast(4.dp.toPx())
            drawRoundRect(
                color = if (v > 0) on else off,
                topLeft = Offset(i * (bw + gap), size.height - h),
                size = Size(bw, h),
                cornerRadius = CornerRadius(bw / 2),
            )
        }
    }
}

@Composable
private fun StaleChip() {
    val dark = isDarkSurface()
    Box(
        Modifier
            .clip(CircleShape)
            .background(Brand.Orange.copy(alpha = if (dark) 0.22f else 0.2f))
            .padding(horizontal = 9.dp, vertical = 3.dp),
    ) {
        Text(
            "该记一条了",
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.Bold,
            color = if (dark) Brand.OrangeMid else Brand.OrangeDeep,
            maxLines = 1,
        )
    }
}

private fun factsOf(b: ProjectBrief): String = buildList {
    when {
        b.stats == null -> add("统计中…")
        b.stats.lastDay == null -> add("还没有提及记录")
        else -> {
            add("最近 ${Dossier.ago(b.gap ?: 0)}")
            add("近 30 天 ${b.stats.count30} 条")
        }
    }
    if (b.open > 0) add(0, "待办 ${b.open}")
}.joinToString(" · ")

// ───────────────────────── 待办页里的项目横滑条 ─────────────────────────

/** 待办页时间轴下方的项目卡片：该记一条了的在最前，「全部」进完整列表 */
@Composable
internal fun ProjectStrip(
    briefs: List<ProjectBrief>,
    onOpen: (String) -> Unit,
    onAll: () -> Unit,
) {
    val shown = briefs.filter { it.project.status != ProjectStatus.PAUSED }
    if (shown.isEmpty()) return
    Column {
        Row(
            modifier = Modifier.fillMaxWidth().heightIn(min = 40.dp).padding(start = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("项目", style = MaterialTheme.typography.titleSmall)
            Text("  ${shown.size}", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Box(Modifier.weight(1f))
            TextButton(onClick = onAll) { Text("全部 ›") }
        }
        LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            items(shown, key = { it.project.keyword }) { b -> MiniProjectCard(b) { onOpen(b.project.keyword) } }
        }
    }
}

@Composable
private fun MiniProjectCard(b: ProjectBrief, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Column(
        modifier = Modifier
            .width(176.dp)
            .height(112.dp)
            .clip(RoundedCornerShape(22.dp))
            .background(scheme.surfaceContainerLowest)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ProgressRing(b.progress, 30.dp, 4.dp) {
                Text(b.ringText(false), fontSize = 10.sp, fontWeight = FontWeight.ExtraBold, color = scheme.onSurface)
            }
            Text(b.project.keyword, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text(
            b.project.next.ifBlank { "还没写下一步" },
            style = MaterialTheme.typography.bodySmall,
            color = scheme.onSurfaceVariant,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 8.dp),
        )
        Spacer(Modifier.weight(1f))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                when {
                    b.stats == null -> "统计中…"
                    b.stats.lastDay == null -> "还没有记录"
                    else -> Dossier.ago(b.gap ?: 0)
                },
                style = MaterialTheme.typography.labelMedium,
                color = scheme.onSurfaceVariant,
                maxLines = 1,
            )
            Box(Modifier.weight(1f))
            if (b.stale) StaleChip()
        }
    }
}

// ───────────────────────── 项目列表（完整页） ─────────────────────────

internal fun LazyListScope.projectsSection(
    briefs: List<ProjectBrief>,
    showPaused: Boolean,
    onShowPaused: (Boolean) -> Unit,
    onAdd: () -> Unit,
    onOpen: (String) -> Unit,
) {
    if (briefs.isEmpty()) {
        item(key = "p-empty") {
            EmptyNote(
                title = "还没有项目",
                text = "项目是用关键词（和标签）钉住的一件事：笔记里出现关键词、或带这些标签，都算一次提及；" +
                    "待办标题含关键词、或带该标签，就归入这个项目。久不提及会提醒你「该记一条了」。",
                action = { Button(onClick = onAdd) { Text("新增项目") } },
            )
        }
        return
    }
    val active = briefs.filter { it.project.status != ProjectStatus.PAUSED }
    val paused = briefs.filter { it.project.status == ProjectStatus.PAUSED }
    item(key = "p-filter") {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            PillChip("进行中  ${active.size}", selected = !showPaused, onClick = { onShowPaused(false) })
            if (paused.isNotEmpty() || showPaused) {
                PillChip("搁置  ${paused.size}", selected = showPaused, onClick = { onShowPaused(true) })
            }
        }
    }
    val list = if (showPaused) paused else active
    if (list.isEmpty()) {
        item(key = "p-none") {
            EmptyNote(title = if (showPaused) "没有搁置的项目" else "没有进行中的项目", text = "")
        }
    }
    items(list, key = { "p-${it.project.keyword}" }) { b ->
        ProjectCard(b, Modifier.animateItem()) { onOpen(b.project.keyword) }
    }
}

@Composable
private fun ProjectCard(b: ProjectBrief, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val p = b.project
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(24.dp))
            .background(scheme.surfaceContainerLowest)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            ProgressRing(b.progress, 46.dp, 5.dp) {
                Text(b.ringText(true), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.ExtraBold, color = scheme.onSurface)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(p.keyword, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    if (p.status != ProjectStatus.ACTIVE) {
                        Text(p.status.label, style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant)
                    }
                    if (b.stale) StaleChip()
                }
                Text(
                    if (p.next.isBlank()) "还没写下一步" else "下一步 · ${p.next}",
                    style = MaterialTheme.typography.bodyMedium,
                    color = scheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        HorizontalDivider(Modifier.padding(top = 12.dp, bottom = 10.dp), thickness = 0.5.dp, color = scheme.outline.copy(alpha = 0.35f))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                factsOf(b),
                style = MaterialTheme.typography.labelMedium,
                color = scheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            val series = b.stats?.series.orEmpty()
            if (series.any { it > 0 }) {
                Spacer(Modifier.width(12.dp))
                MonthBars(series, 56.dp, 18.dp)
            }
        }
    }
}

@Composable
internal fun AddProjectDialog(onDismiss: () -> Unit, onConfirm: (keyword: String, tags: List<String>) -> Unit) {
    FormDialog(
        title = "新增项目",
        hint = "关键词 + 标签一起定义这个项目：笔记里出现关键词、或带这些标签，都算一次提及；待办标题含它们也归入该项目。",
        fields = listOf(
            FormField("关键词", required = true, placeholder = "例如 篆刻、论文、某位朋友的名字"),
            FormField("额外标签", placeholder = "可选，空格分隔，如 书法 练字"),
        ),
        confirmLabel = "添加",
        onDismiss = onDismiss,
        onConfirm = { v -> onConfirm(v[0], Templates.splitTags(v[1])) },
    )
}

// ───────────────────────── 项目主页 ─────────────────────────

// ───────────────────────── 项目主页 ─────────────────────────

private enum class PageDialog { NEXT, LOG, TAGS, REMOVE }

@Composable
private fun ProjectTaskRow(t: DidaTask, ctx: TodoCtx, done: Boolean) {
    TaskRow(
        task = t,
        tone = if (done) Tone.NORMAL else toneOf(t, ctx.today),
        done = done,
        project = listNameOf(ctx.overview, t.projectId),
        today = ctx.today,
        badges = badgesOf(t, ctx.workspace),
        onToggle = { ctx.onToggle(t) },
        onOpen = { ctx.onOpen(t) },
    )
}

@Composable
private fun HeroButton(text: String, filled: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .height(36.dp)
            .clip(CircleShape)
            .background(if (filled) Brand.Brown else Color.White.copy(alpha = 0.38f))
            .clickable(onClick = onClick)
            .padding(horizontal = 18.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text,
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.Bold,
            color = if (filled) Brand.Cream else Brand.Brown,
        )
    }
}

@Composable
private fun StatTile(value: String, label: String, modifier: Modifier = Modifier, extra: (@Composable () -> Unit)? = null) {
    val scheme = MaterialTheme.colorScheme
    Column(
        modifier = modifier
            .height(60.dp)
            .clip(RoundedCornerShape(18.dp))
            .background(scheme.surfaceContainerLowest)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.SpaceBetween,
    ) {
        if (extra != null) extra() else Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.ExtraBold, maxLines = 1)
        Text(label, style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant, maxLines = 1)
    }
}

/**
 * 项目主页（防弹笔记法的「项目主控台」）：
 * 首屏是一张橙色主卡——完成度环、下一步、「记一条」；其下是三格数据、相关任务（可直接勾选）、要交付的成果、项目主页笔记。
 * 状态在标题旁的小菜单里改，提醒天数、标签、简报、移除都收进右上角「⋯」。
 */
@Composable
internal fun ProjectPage(
    project: Project,
    viewModel: TodoViewModel,
    stats: ProjectStats?,
    ctx: TodoCtx?,
    homeId: String?,
    taskNotes: List<TaskNoteEntry>,
    onBack: () -> Unit,
    onOpenNote: (String) -> Unit,
    onProgress: (task: DidaTask?, noteId: String, text: String) -> Unit,
) {
    var dialog by remember { mutableStateOf<PageDialog?>(null) }
    var progressFor by remember { mutableStateOf<TaskNoteEntry?>(null) }
    var homeEdit by remember { mutableStateOf<HomeEditTarget?>(null) }
    val clipboard = LocalClipboardManager.current
    val scheme = MaterialTheme.colorScheme
    val today = LocalDate.now()
    val tasks = relatedOpen(project, ctx)
    val doneTasks = relatedDone(project, ctx)
    val gap = stats?.lastDay?.let { Dossier.daysBetween(it, today) }
    val total = tasks.size + doneTasks.size

    LaunchedEffect(project.keyword, homeId, taskNotes.size) { viewModel.loadProjectPage(project) }
    LaunchedEffect(project.keyword) { if (stats == null) viewModel.refreshStats(project) }

    LazyColumn(
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = LocalBottomBarPadding.current + 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // 顶栏：返回 · 项目名 · 状态 · ⋯
        item(key = "top") {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 4.dp, bottom = 4.dp)) {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回") }
                Text(
                    project.keyword,
                    style = MaterialTheme.typography.headlineSmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false).padding(start = 4.dp),
                )
                Spacer(Modifier.width(10.dp))
                var statusOpen by remember { mutableStateOf(false) }
                Box {
                    Row(
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(scheme.surfaceContainerHigh)
                            .clickable { statusOpen = true }
                            .padding(start = 10.dp, end = 6.dp, top = 4.dp, bottom = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(project.status.label, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold)
                        Icon(Icons.Filled.KeyboardArrowDown, contentDescription = "改状态", modifier = Modifier.size(16.dp))
                    }
                    DropdownMenu(expanded = statusOpen, onDismissRequest = { statusOpen = false }) {
                        ProjectStatus.entries.forEach { st ->
                            DropdownMenuItem(
                                text = { Text(st.label, fontWeight = if (st == project.status) FontWeight.Bold else FontWeight.Normal) },
                                onClick = { statusOpen = false; viewModel.setStatus(project.keyword, st) },
                            )
                        }
                    }
                }
                Box(Modifier.weight(1f))
                var moreOpen by remember { mutableStateOf(false) }
                Box {
                    CircleIconButton(Icons.Filled.MoreVert, "更多", onClick = { moreOpen = true })
                    DropdownMenu(expanded = moreOpen, onDismissRequest = { moreOpen = false }) {
                        DropdownMenuItem(
                            text = { Text("多久没提及就提醒", style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant) },
                            enabled = false,
                            onClick = {},
                        )
                        STALE_CHOICES.forEach { d ->
                            DropdownMenuItem(
                                text = { Text("$d 天", fontWeight = if (d == project.staleDays) FontWeight.Bold else FontWeight.Normal) },
                                leadingIcon = {
                                    if (d == project.staleDays) Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(20.dp))
                                    else Spacer(Modifier.size(20.dp))
                                },
                                onClick = { moreOpen = false; viewModel.setStale(project.keyword, d) },
                            )
                        }
                        HorizontalDivider(Modifier.padding(vertical = 4.dp))
                        DropdownMenuItem(
                            text = { Text("额外标签：" + project.tags.joinToString(" ") { "#$it" }.ifEmpty { "无" }) },
                            onClick = { moreOpen = false; dialog = PageDialog.TAGS },
                        )
                        if (stats != null && stats.brief.isNotBlank()) {
                            DropdownMenuItem(
                                text = { Text("复制简报") },
                                onClick = { moreOpen = false; clipboard.setText(AnnotatedString(stats.brief)) },
                            )
                        }
                        DropdownMenuItem(text = { Text("重新统计") }, onClick = { moreOpen = false; viewModel.refreshStats(project) })
                        HorizontalDivider(Modifier.padding(vertical = 4.dp))
                        DropdownMenuItem(
                            text = { Text("移除项目", color = scheme.error) },
                            onClick = { moreOpen = false; dialog = PageDialog.REMOVE },
                        )
                    }
                }
            }
        }

        // 主卡：完成度 + 下一步 + 记一条（整页唯一的主操作）
        item(key = "hero") {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(26.dp))
                    .background(Brand.Orange)
                    .padding(horizontal = 16.dp, vertical = 14.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    val progress = if (total == 0) null else doneTasks.size.toFloat() / total
                    ProgressRing(progress, 64.dp, 7.dp, arc = Brand.Brown, track = Brand.Brown.copy(alpha = 0.18f)) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(
                                if (progress == null) "—" else "${(progress * 100).roundToInt()}%",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.ExtraBold,
                                color = Brand.Brown,
                            )
                            if (total > 0) Text("${doneTasks.size}/$total", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = Brand.Brown)
                        }
                    }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("下一步", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold, color = Brand.Brown)
                        Text(
                            project.next.ifBlank { "还没写。写成能直接开始的动作，例如「临《洛神赋》第三段，写 5 遍」。" },
                            style = MaterialTheme.typography.bodyLarge,
                            fontWeight = FontWeight.Bold,
                            color = Brand.Brown,
                            maxLines = 3,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    HeroButton("记一条", filled = true) { dialog = PageDialog.LOG }
                    HeroButton(if (project.next.isBlank()) "写下一步" else "修改", filled = false) { dialog = PageDialog.NEXT }
                }
            }
        }

        // 三格数据：最近提及 / 近 30 天 / 近 12 月（完整的提及笔记在下面「提及的笔记」）
        item(key = "stats") {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StatTile(
                    value = when {
                        stats == null -> "…"
                        stats.lastDay == null -> "暂无"
                        else -> Dossier.ago(gap ?: 0)
                    },
                    label = "最近提及",
                    modifier = Modifier.weight(1f),
                )
                StatTile(
                    value = if (stats == null) "…" else "${stats.count30} 条",
                    label = "近 30 天",
                    modifier = Modifier.weight(1f),
                )
                StatTile(
                    value = "",
                    label = "近 12 月",
                    modifier = Modifier.weight(1.3f),
                    extra = {
                        val series = stats?.series.orEmpty()
                        if (series.isNotEmpty()) MonthBars(series, 80.dp, 22.dp) else Text("…", style = MaterialTheme.typography.titleMedium)
                    },
                )
            }
        }

        // 项目主页笔记拆成的组件（上半）：目标、交付成果；笔记还没建时是创建入口
        homeCreateEntry(homeId, viewModel.pageBusy) { viewModel.createHome(project) }
        homeTopSections(homeId, viewModel.homeText) { homeEdit = it }

        // 相关任务：可直接勾选；已完成的折叠
        item(key = "tasks") {
            var showDone by remember { mutableStateOf(false) }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                GroupLabel(
                    "相关任务",
                    count = tasks.size,
                    trailing = {
                        if (doneTasks.isNotEmpty()) {
                            TextButton(onClick = { showDone = !showDone }) {
                                Text(if (showDone) "收起已完成" else "已完成 ${doneTasks.size} 项 ›")
                            }
                        }
                    },
                )
                if (ctx == null || tasks.isEmpty()) {
                    Text(
                        "近期没有相关任务：任务标题或标签含项目关键词即归入。",
                        style = MaterialTheme.typography.bodySmall,
                        color = scheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 8.dp),
                    )
                } else {
                    tasks.forEach { t -> ProjectTaskRow(t, ctx, done = false) }
                }
                if (showDone && ctx != null) doneTasks.forEach { t -> ProjectTaskRow(t, ctx, done = true) }
            }
        }

        // 提及的笔记：原来「档案」里的内容——凡是写到这个项目关键词 / 标签的笔记，按时间倒序
        mentionItems(stats, onOpenNote)

        // 任务笔记（每个成果一条笔记）
        item(key = "notes") {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                GroupLabel("任务笔记", count = taskNotes.size)
                if (taskNotes.isEmpty()) {
                    Text(
                        "一个任务，一条笔记。在待办里点开属于本项目的任务，选「任务笔记」创建。",
                        style = MaterialTheme.typography.bodySmall,
                        color = scheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 8.dp),
                    )
                } else {
                    taskNotes.forEach { e ->
                        RowPill(onClick = { onOpenNote(e.ref.noteId) }) {
                            Row(
                                modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 6.dp, top = 8.dp, bottom = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(e.ref.deliverable, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    val text = viewModel.noteTexts[e.ref.noteId]
                                    Text(
                                        when {
                                            text == null -> "正在读取…"
                                            text.isBlank() -> "（笔记内容为空）"
                                            else -> text.replace(Regex("\\s+"), " ").take(120)
                                        },
                                        style = MaterialTheme.typography.bodySmall,
                                        color = scheme.onSurfaceVariant,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                                TextButton(onClick = { progressFor = e }) { Text("记进展") }
                            }
                        }
                    }
                }
            }
        }

        // 项目主页笔记的后半部分组件：里程碑、资料、复盘、状态
        homeBottomSections(
            project = project,
            homeId = homeId,
            text = viewModel.homeText,
            busy = viewModel.pageBusy,
            onEdit = { homeEdit = it },
            onRefresh = { viewModel.refreshHome(project) },
            onOpenNote = onOpenNote,
        )
    }

    when (dialog) {
        PageDialog.NEXT -> TextPromptDialog(
            title = "下一步 · ${project.keyword}",
            label = "下一步",
            hint = "写成能直接开始的动作。",
            initial = project.next,
            required = false,
            minLines = 2,
            onDismiss = { dialog = null },
            onConfirm = { viewModel.setNext(project.keyword, it); dialog = null },
        )

        PageDialog.LOG -> TextPromptDialog(
            title = "记一条「${project.keyword}」",
            label = "内容",
            hint = "保存为一条带 ${project.terms.joinToString(" ") { "#$it" }} 的独立笔记（不写入 Daily Note）；有同名滴答习惯会自动打卡。",
            minLines = 4,
            onDismiss = { dialog = null },
            onConfirm = { viewModel.logToProject(project, it); dialog = null },
        )

        PageDialog.TAGS -> TextPromptDialog(
            title = "项目标签",
            label = "标签（空格分隔）",
            initial = project.tags.joinToString(" "),
            required = false,
            singleLine = true,
            onDismiss = { dialog = null },
            onConfirm = { viewModel.setTags(project.keyword, Templates.splitTags(it)); dialog = null },
        )

        PageDialog.REMOVE -> ConfirmDialog(
            title = "移除项目「${project.keyword}」？",
            text = "只会移除项目本身；已有的笔记、任务笔记和项目主页笔记都不会被删除。",
            confirmLabel = "移除",
            onDismiss = { dialog = null },
            onConfirm = { dialog = null; viewModel.removeProject(project.keyword) },
        )

        null -> Unit
    }

    homeEdit?.let { t ->
        TextPromptDialog(
            title = t.title,
            label = t.label,
            hint = t.hint,
            initial = t.initial,
            required = t.mode != HomeEditMode.REPLACE,
            minLines = if (t.mode == HomeEditMode.REPLACE) 4 else 3,
            confirmLabel = if (t.mode == HomeEditMode.REPLACE) "保存" else "添加",
            onDismiss = { homeEdit = null },
            onConfirm = { text ->
                homeEdit = null
                viewModel.saveHome(project, t.section, t.mode, text)
            },
        )
    }

    progressFor?.let { e ->
        TextPromptDialog(
            title = "记一条进展",
            label = "进展",
            hint = e.ref.deliverable,
            minLines = 3,
            onDismiss = { progressFor = null },
            onConfirm = { text ->
                progressFor = null
                val task = ctx?.overview?.findOpen(e.taskId)
                onProgress(task, e.ref.noteId, text)
            },
        )
    }
}

/** 项目页「提及的笔记」：一行概况 + 直接提及的笔记（先 5 条，可展开全部）+ 折叠的「可能相关」 */
private fun LazyListScope.mentionItems(stats: ProjectStats?, onOpenNote: (String) -> Unit) {
    if (stats == null || (stats.mentions.isEmpty() && stats.related.isEmpty())) {
        item(key = "mentions") {
            val scheme = MaterialTheme.colorScheme
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                GroupLabel("提及的笔记")
                Text(
                    if (stats == null) "正在统计…" else "还没有笔记写到这个项目。用上面的「记一条」写第一条。",
                    style = MaterialTheme.typography.bodySmall,
                    color = scheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 8.dp),
                )
            }
        }
        return
    }

    item(key = "mentions") {
        val scheme = MaterialTheme.colorScheme
        var showAll by remember(stats.keyword) { mutableStateOf(false) }
        val shown = if (showAll) stats.mentions else stats.mentions.take(MENTION_PREVIEW)
        val overview = buildList {
            stats.firstDay?.let { add("${it} 起") }
            add("累计 ${stats.total} 篇")
            if (stats.topTags.isNotEmpty()) add(stats.topTags.take(3).joinToString(" ") { "#${it.first}" })
        }.joinToString(" · ")
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            GroupLabel("提及的笔记", count = stats.mentions.size)
            Text(
                overview,
                style = MaterialTheme.typography.bodySmall,
                color = scheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 8.dp),
            )
            if (stats.mentions.isNotEmpty()) {
                ListGroup {
                    DividedRows(shown) { n ->
                        NoteRow(
                            n.note,
                            onClick = { onOpenNote(n.note.id) },
                            snippet = (if (n.viaSpeaker && n.mentions == 0) "有其发言　" else "") + n.snippet,
                        )
                    }
                }
                if (stats.mentions.size > MENTION_PREVIEW) {
                    TextButton(onClick = { showAll = !showAll }) {
                        Text(if (showAll) "收起" else "展开全部 ${stats.mentions.size} 篇 ›")
                    }
                }
            }
        }
    }

    if (stats.related.isNotEmpty()) {
        item(key = "mentions-related") {
            var open by remember(stats.keyword) { mutableStateOf(false) }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                GroupLabel(
                    "可能相关 · 语义相近",
                    count = stats.related.size,
                    trailing = { TextButton(onClick = { open = !open }) { Text(if (open) "收起" else "展开 ›") } },
                )
                if (open) {
                    ListGroup {
                        DividedRows(stats.related) { n -> NoteRow(n.note, onClick = { onOpenNote(n.note.id) }) }
                    }
                }
            }
        }
    }
}

private const val MENTION_PREVIEW = 5
