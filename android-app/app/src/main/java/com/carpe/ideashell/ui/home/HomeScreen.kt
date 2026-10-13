package com.carpe.ideashell.ui.home

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
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
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import com.carpe.ideashell.ui.components.AppMenu
import com.carpe.ideashell.ui.components.AppMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
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
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.carpe.ideashell.R
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.db.CaptureEntity
import com.carpe.ideashell.data.db.CaptureStatus
import com.carpe.ideashell.data.focus.FocusRun
import com.carpe.ideashell.data.ideashell.NoteInfo
import com.carpe.ideashell.ui.components.RowPill
import com.carpe.ideashell.ui.components.SearchButton
import com.carpe.ideashell.ui.components.GroupCard
import com.carpe.ideashell.ui.components.kindIcon
import com.carpe.ideashell.ui.components.relativeTime
import com.carpe.ideashell.ui.glass.GlassBadge
import com.carpe.ideashell.ui.glass.GlassSurface
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import com.carpe.ideashell.ui.glass.isDarkSurface
import com.carpe.ideashell.ui.theme.Brand
import kotlinx.coroutines.delay
import java.time.LocalDate
import java.time.LocalTime
import java.time.format.TextStyle
import java.util.Locale

/**
 * 「今天」页（设计系统「环」· 漫步）。信息很少，每一块只说一件事：
 * - 仪表卡：三层细环（专注 / 待办 / 项目进展）+ 近半年的记录热力图（Daily Note 每天的条数）；
 * - 随机漫步：从 5 年笔记里随机翻出一条旧的，「换一条」再翻（参考 flomo）；
 * - 每日回顾：往年今日 / 1 周前 / 1 个月前……当天写过的笔记，横向滑动；
 * - 下一件：只留最近要做的一件待办，其余去「待办」页。
 * 输入统一由右下角的「+」完成（见 MainActivity），这里不再放输入框。
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    onOpenSearch: () -> Unit,
    onOpenConnection: () -> Unit,
    onOpenTodos: () -> Unit,
    onOpenFocus: () -> Unit,
    onOpenNote: (String) -> Unit,
    viewModel: HomeViewModel = viewModel(factory = HomeViewModel.Factory.instance),
) {
    val connected by viewModel.connected.collectAsStateWithLifecycle()
    val focusRunning by viewModel.focusRunning.collectAsStateWithLifecycle()
    val focusSession by viewModel.focusSession.collectAsStateWithLifecycle()
    val recent by viewModel.recent.collectAsStateWithLifecycle()
    val overview by viewModel.overview.collectAsStateWithLifecycle()
    val focus by viewModel.focus.collectAsStateWithLifecycle()
    val focusGoal by viewModel.focusGoalMin.collectAsStateWithLifecycle()
    val projectProgress by viewModel.projectProgress.collectAsStateWithLifecycle()
    val memory by viewModel.memory.collectAsStateWithLifecycle()
    val heat by viewModel.heat.collectAsStateWithLifecycle()
    val walkNote = viewModel.walkNote
    var recentOpen by rememberSaveable { mutableStateOf(false) }
    val snackbar = remember { SnackbarHostState() }
    val today = remember { LocalDate.now() }

    // 回到「今天」页：专注是今天最新的；回顾数据在仓库里有缓存，不会重复拉
    LifecycleResumeEffect(Unit) {
        viewModel.refreshFocus()
        viewModel.refreshMemory()
        viewModel.refreshHeat()
        onPauseOrDispose { }
    }

    LaunchedEffect(Unit) {
        viewModel.events.collect { event ->
            when (event) {
                is HomeEvent.Message -> snackbar.showSnackbar(event.text)
                is HomeEvent.Saved -> {
                    val result = snackbar.showSnackbar(
                        message = "已保存 · ${event.receipt.detail}",
                        actionLabel = "撤销",
                        withDismissAction = false,
                    )
                    if (result == SnackbarResult.ActionPerformed) viewModel.undo(event.receipt.id)
                }
            }
        }
    }

    // 有待同步 / 同步中的记录时，每秒刷新一次，让「N 秒后同步」倒计时走起来
    val hasUnsent = recent.any { it.status == CaptureStatus.PENDING.name || it.status == CaptureStatus.SENDING.name }
    val now by produceState(System.currentTimeMillis(), hasUnsent) {
        while (hasUnsent) {
            value = System.currentTimeMillis()
            delay(1_000)
        }
        value = System.currentTimeMillis()
    }

    val failedCount = recent.count { it.status == CaptureStatus.FAILED.name }
    val hasDone = recent.any { it.status == CaptureStatus.DONE.name }
    val todayStr = today.toString()
    val overdueTasks = overview?.overdue.orEmpty()
    val todayTasks = overview?.upcoming?.filter { it.date == todayStr }.orEmpty()
    // 圆环里的「待办 x/y」：x 是今天已完成的；y = 今天还没做的 + 没有日期还没做的 + x（逾期、以后的不算在 y 里）
    val undatedTasks = overview?.undated.orEmpty()
    val zone = remember { java.time.ZoneId.systemDefault() }
    val todoDone = overview?.done.orEmpty().count { t ->
        t.completedAt?.let { java.time.Instant.ofEpochMilli(it).atZone(zone).toLocalDate() == today } ?: (t.date == todayStr)
    }
    val todoTotal = todayTasks.size + undatedTasks.size + todoDone
    val remaining = overdueTasks.size + todayTasks.size
    // 下一件：今天有时间的按时间、没时间的排后面；今天没有就看逾期里最早的
    val nextToday = todayTasks.sortedBy { it.time ?: "99:99" }.firstOrNull()
    val nextTask = nextToday ?: overdueTasks.firstOrNull()
    val reviews = remember(memory) {
        memory?.sameDay.orEmpty()
            .flatMap { g -> g.notes.map { ReviewItem(g.label.removeSuffix("的今天"), g.date, it) } }
            .take(REVIEW_LIMIT)
    }
    // 还在撤销窗口内的最新一条：显示在最上面，和「记一条」的反馈放在同一个位置
    val fresh = recent.firstOrNull { it.status == CaptureStatus.PENDING.name && it.readyAt > now }

    Scaffold(
        containerColor = Color.Transparent,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        snackbarHost = { SnackbarHost(snackbar, Modifier.padding(bottom = LocalBottomBarPadding.current)) },
    ) { padding ->
        // 下拉强制刷新：待办、专注、往日回顾、热力图都重新读，不看缓存
        PullToRefreshBox(
            isRefreshing = viewModel.refreshing,
            onRefresh = viewModel::forceRefresh,
            modifier = Modifier.padding(padding),
        ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = LocalBottomBarPadding.current),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item(key = "header") {
                Header(today = today, loaded = overview != null, remaining = remaining, onOpenSearch = onOpenSearch)
            }

            if (fresh != null) {
                item(key = "fresh") {
                    FreshStrip(
                        item = fresh,
                        remainingSec = ((fresh.readyAt - now + 999) / 1000).coerceAtLeast(0),
                        onUndo = { viewModel.undo(fresh.id) },
                        modifier = Modifier.padding(horizontal = 16.dp),
                    )
                }
            }

            // 正在专注：顶部一条状态，显示剩余时长；专注结束后这一条消失，页面恢复原样
            focusSession?.let { run ->
                item(key = "focusing") {
                    FocusingStrip(
                        run = run,
                        onOpen = onOpenFocus,
                        onPauseOrResume = viewModel::pauseOrResumeFocus,
                        onDue = viewModel::settleFocus,
                        modifier = Modifier.padding(horizontal = 16.dp),
                    )
                }
            }

            if (!connected) {
                item(key = "connect") { ConnectCard(onOpenConnection, Modifier.padding(horizontal = 16.dp)) }
            }

            if (failedCount > 0) {
                item(key = "failed") { FailedBanner(failedCount, Modifier.padding(horizontal = 16.dp)) }
            }

            item(key = "dashboard") {
                Dashboard(
                    today = today,
                    loaded = overview != null,
                    remaining = remaining,
                    todoDone = todoDone,
                    todoTotal = todoTotal,
                    focusMin = focus?.todayMin,
                    focusGoal = focusGoal,
                    focusRunning = focusRunning,
                    onOpenFocus = onOpenFocus,
                    projectProgress = projectProgress,
                    heat = heat,
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
            }

            if (overview != null && nextTask != null) {
                item(key = "next") {
                    NextRow(
                        task = nextTask,
                        isOverdue = nextToday == null,
                        remaining = todayTasks.size,
                        overdueCount = overdueTasks.size,
                        onComplete = viewModel::completeTask,
                        onOpen = onOpenTodos,
                        modifier = Modifier.padding(horizontal = 16.dp),
                    )
                }
            }

            if (reviews.isNotEmpty()) {
                item(key = "reviews") {
                    ReviewRow(reviews, onOpenNote = onOpenNote)
                }
            }

            if (walkNote != null) {
                item(key = "walk") {
                    WalkCard(
                        note = walkNote,
                        canShuffle = (memory?.pool?.size ?: 0) > 1,
                        onShuffle = viewModel::shuffleWalk,
                        onOpen = { onOpenNote(walkNote.id) },
                        modifier = Modifier.padding(horizontal = 16.dp),
                    )
                }
            }

            if (recent.isEmpty()) {
                if (overview == null) item(key = "empty") { EmptyHint(Modifier.padding(horizontal = 16.dp)) }
            } else {
                item(key = "recent") {
                    GroupCard(
                        title = "最近记录",
                        count = recent.size,
                        modifier = Modifier.padding(horizontal = 16.dp),
                        expanded = recentOpen,
                        onToggle = { recentOpen = !recentOpen },
                        trailing = if (hasDone) {
                            { RecentMenu(onClearDone = viewModel::clearDone) }
                        } else null,
                        content = {
                            recent.forEach { item ->
                                RecentRow(
                                    item = item,
                                    now = now,
                                    onUndo = { viewModel.undo(item.id) },
                                    onRetry = { viewModel.retry(item.id) },
                                )
                            }
                        },
                    )
                }
            }
        }
        }
    }
}

// ───────────────────────── 顶部 ─────────────────────────

@Composable
private fun Header(today: LocalDate, loaded: Boolean, remaining: Int, onOpenSearch: () -> Unit) {
    val hour = remember { LocalTime.now().hour }
    val greeting = when {
        hour < 6 -> "夜深了"
        hour < 11 -> "早上好"
        hour < 14 -> "中午好"
        hour < 18 -> "下午好"
        else -> "晚上好"
    }
    val sub = when {
        !loaded -> greeting
        remaining == 0 -> "$greeting · 今天清空了"
        else -> "$greeting · 还剩 $remaining 件"
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .height(56.dp)
            .padding(start = 20.dp, end = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                "${today.monthValue}月${today.dayOfMonth}日 ${today.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.CHINA)}",
                style = MaterialTheme.typography.headlineSmall,
            )
            Text(
                sub,
                fontSize = 12.sp,
                lineHeight = 16.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        SearchButton(onOpenSearch)
    }
}

// ───────────────────────── 仪表卡：三层细环 + 记录热力图 ─────────────────────────

private const val REVIEW_LIMIT = 8

private fun formatFocus(min: Int): String = when {
    min < 60 -> "${min}m"
    min % 60 == 0 -> "${min / 60}h"
    else -> "${min / 60}h${min % 60}m"
}

@Composable
private fun Dashboard(
    today: LocalDate,
    loaded: Boolean,
    remaining: Int,
    todoDone: Int,
    todoTotal: Int,
    focusMin: Int?,
    focusGoal: Int,
    focusRunning: Boolean,
    onOpenFocus: () -> Unit,
    projectProgress: Float?,
    heat: HeatState?,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    val dark = isDarkSurface()
    // 外 → 内：专注 / 待办 / 项目进展。三种颜色：橙（品牌）、深棕（墨色）、琥珀（金黄）
    val focusColor = Brand.Orange
    val todoColor = scheme.onSurface
    val projectColor = Brand.Amber
    val target = listOf(
        ((focusMin ?: 0).toFloat() / focusGoal.coerceAtLeast(1)).coerceIn(0f, 1f),
        if (todoTotal == 0) 0f else todoDone.toFloat() / todoTotal,
        (projectProgress ?: 0f).coerceIn(0f, 1f),
    ).map { animateFloatAsState(it, tween(700), label = "ring").value }
    val track = scheme.onSurface.copy(alpha = 0.09f)

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(24.dp))
            .background(scheme.surfaceContainerLowest),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClickLabel = "打开专注", onClick = onOpenFocus)
                .padding(start = 18.dp, end = 14.dp, top = 14.dp, bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Box(Modifier.size(84.dp), contentAlignment = Alignment.Center) {
                Canvas(Modifier.size(84.dp)) {
                    val stroke = 7.dp.toPx()
                    val gap = 2.5.dp.toPx()
                    val colors = listOf(focusColor, todoColor, projectColor)
                    target.forEachIndexed { i, p ->
                        val inset = i * (stroke + gap) + stroke / 2
                        val topLeft = Offset(inset, inset)
                        val arcSize = Size(size.width - inset * 2, size.height - inset * 2)
                        drawArc(track, 0f, 360f, false, topLeft, arcSize, style = Stroke(stroke))
                        if (p > 0f) {
                            drawArc(
                                colors[i], -90f, 360f * p, false, topLeft, arcSize,
                                style = Stroke(stroke, cap = StrokeCap.Round),
                            )
                        }
                    }
                }
                Text(
                    if (loaded) remaining.toString() else "–",
                    fontSize = 22.sp,
                    lineHeight = 24.sp,
                    fontWeight = FontWeight.Black,
                )
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Dot(focusColor)
                    Text("专注", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = scheme.onSurfaceVariant)
                    Text(
                        focusMin?.let(::formatFocus) ?: "–",
                        fontSize = 22.sp,
                        lineHeight = 26.sp,
                        fontWeight = FontWeight.Black,
                    )
                    Text(
                        "/ ${formatFocus(focusGoal)}",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = scheme.onSurfaceVariant,
                    )
                }
                Text(
                    buildAnnotatedString {
                        append("待办 ")
                        withStyle(SpanStyle(fontWeight = FontWeight.ExtraBold, color = scheme.onSurface)) {
                            append(if (loaded) "$todoDone/$todoTotal" else "–")
                        }
                        append("  ·  项目进展 ")
                        withStyle(SpanStyle(fontWeight = FontWeight.ExtraBold, color = scheme.onSurface)) {
                            append(projectProgress?.let { "${(it * 100).toInt()}%" } ?: "–")
                        }
                    },
                    fontSize = 12.sp,
                    lineHeight = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = scheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            // 进入专注页：没在专注时是橙色的播放钮，专注中换成「专注中」小标签
            if (focusRunning) {
                Text(
                    "专注中",
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(focusColor.copy(alpha = if (dark) 0.22f else 0.16f))
                        .padding(horizontal = 10.dp, vertical = 5.dp),
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                    color = if (dark) Brand.OrangeMid else Brand.OrangeDeep,
                )
            } else {
                Box(
                    Modifier.size(36.dp).clip(CircleShape).background(focusColor),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Filled.PlayArrow, contentDescription = "开始专注", tint = Brand.Brown, modifier = Modifier.size(22.dp))
                }
            }
        }
        if (heat != null) Heatmap(today, heat, Modifier.padding(start = 18.dp, end = 18.dp, bottom = 14.dp))
    }
}

@Composable
private fun Dot(color: Color) {
    Box(Modifier.size(8.dp).clip(CircleShape).background(color))
}

/** 近半年每天 Daily Note 里记了几条：一列一周（周一在上），颜色越深条数越多；今天之后的格子不画 */
@Composable
private fun Heatmap(today: LocalDate, heat: HeatState, modifier: Modifier = Modifier) {
    val counts = heat.counts
    val scheme = MaterialTheme.colorScheme
    val dark = isDarkSurface()
    val empty = scheme.onSurface.copy(alpha = if (dark) 0.12f else 0.07f)
    // 四档橙色由浅到深（半透明橙 → 实心橙 → 深橙），层次比固定的几个色块更分明
    val levels = listOf(
        Brand.Orange.copy(alpha = 0.28f),
        Brand.Orange.copy(alpha = 0.55f),
        Brand.Orange,
        Brand.OrangeDeep,
    )
    val weekStart = today.minusDays((today.dayOfWeek.value - 1).toLong())
    val first = weekStart.minusWeeks((HEAT_WEEKS - 1).toLong())
    // 档位按这半年「有记录的日子」的条数分布来切（前 25% / 50% / 80%），而不是固定条数：
    // 记得多的人不会满屏深色，记得少的人也看得出深浅
    val cuts = remember(counts, today) {
        val v = (0 until HEAT_WEEKS * 7).map { counts[first.plusDays(it.toLong())] ?: 0 }.filter { it > 0 }.sorted()
        fun at(q: Double) = if (v.isEmpty()) 1 else v[((v.size - 1) * q).toInt()]
        intArrayOf(at(0.25), at(0.5), at(0.8))
    }
    // 每个月第一次出现的那一列，上面标月份；开头那个月只剩一两列时不标，免得挤在一起
    val months = remember(today) {
        val out = ArrayList<Pair<Int, Int>>()
        var prev = -1
        for (w in 0 until HEAT_WEEKS) {
            val m = first.plusWeeks(w.toLong()).month.value
            if (m != prev) out += w to m
            prev = m
        }
        if (out.size > 1 && out[1].first < 3) out.removeAt(0)
        out.toList()
    }
    val total = remember(counts, today) { (0 until HEAT_WEEKS * 7).sumOf { counts[first.plusDays(it.toLong())] ?: 0 } }
    val monthDays = remember(counts, today) {
        (1..today.dayOfMonth).count { (counts[today.withDayOfMonth(it)] ?: 0) > 0 }
    }

    Column(modifier) {
        Row(Modifier.fillMaxWidth().padding(bottom = 8.dp)) {
            Text("Daily Note · 最近 $HEAT_WEEKS 周", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = scheme.onSurfaceVariant, modifier = Modifier.weight(1f))
            Text(
                when {
                    heat.loading && counts.isEmpty() -> "正在读取…"
                    heat.loading -> "本月记了 $monthDays 天 · 共 $total 条…"
                    else -> "本月记了 $monthDays 天 · 共 $total 条"
                },
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                color = scheme.onSurfaceVariant,
            )
        }
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val gap = 3.dp
            val cell = (maxWidth - gap * (HEAT_WEEKS - 1)) / HEAT_WEEKS
            Box(Modifier.fillMaxWidth().height(14.dp)) {
                months.forEach { (w, m) ->
                    Text(
                        "${m}月",
                        fontSize = 10.sp,
                        lineHeight = 12.sp,
                        fontWeight = FontWeight.Bold,
                        color = scheme.onSurfaceVariant,
                        maxLines = 1,
                        softWrap = false,
                        modifier = Modifier.offset(x = (cell + gap) * w),
                    )
                }
            }
            Canvas(Modifier.fillMaxWidth().padding(top = 16.dp).height(cell * 7 + gap * 6)) {
                val c = cell.toPx()
                val g = gap.toPx()
                for (w in 0 until HEAT_WEEKS) for (d in 0 until 7) {
                    val date = first.plusDays((w * 7 + d).toLong())
                    if (date.isAfter(today)) continue
                    val n = counts[date] ?: 0
                    val color = when {
                        n <= 0 -> empty
                        n <= cuts[0] -> levels[0]
                        n <= cuts[1] -> levels[1]
                        n <= cuts[2] -> levels[2]
                        else -> levels[3]
                    }
                    drawRoundRect(
                        color = color,
                        topLeft = Offset(w * (c + g), d * (c + g)),
                        size = Size(c, c),
                        cornerRadius = CornerRadius(c * 0.3f),
                    )
                }
            }
        }
    }
}

// ───────────────────────── 随机漫步 / 每日回顾 ─────────────────────────

private class ReviewItem(val label: String, val date: LocalDate, val note: NoteInfo)

private fun metaLine(date: LocalDate?, tags: List<String>): String =
    listOfNotNull(date?.toString(), tags.firstOrNull()?.let { "#$it" }).joinToString(" · ")

/** 随机漫步：和「每日回顾」一样有分组标题（右侧「换一条」），下面是橙色紧凑卡（高度固定）：日期 · 标签、标题 1 行、摘要 2 行，超出用省略号 */
@Composable
private fun WalkCard(note: NoteInfo, canShuffle: Boolean, onShuffle: () -> Unit, onOpen: () -> Unit, modifier: Modifier = Modifier) {
    val ink = Brand.Brown
    val summary = note.summary?.trim().orEmpty().takeIf { it.isNotEmpty() && it != note.title.trim() }
    val meta = metaLine(note.localDate, note.tags)
    Column(modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 8.dp, end = 0.dp).padding(bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("随机漫步", fontSize = 13.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.weight(1f))
            if (canShuffle) {
                Text(
                    "换一条",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.ExtraBold,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier
                        .clip(CircleShape)
                        .clickable(role = androidx.compose.ui.semantics.Role.Button, onClick = onShuffle)
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                )
            }
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .height(WALK_HEIGHT)
                .clip(RoundedCornerShape(20.dp))
                .background(Brand.Orange)
                .clickable(onClick = onOpen)
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            if (meta.isNotEmpty()) {
                Text(meta, fontSize = 12.sp, fontWeight = FontWeight.ExtraBold, color = ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Text(
                note.title.ifBlank { summary.orEmpty() },
                fontSize = 15.sp,
                lineHeight = 20.sp,
                fontWeight = FontWeight.Bold,
                color = ink,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (summary != null && note.title.isNotBlank()) {
                Text(
                    summary,
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                    fontWeight = FontWeight.Medium,
                    color = ink,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

private val WALK_HEIGHT = 112.dp

/** 往年今日 / 1 周前 / 1 个月前……当天写过的笔记，横向滑动的小卡 */
@Composable
private fun ReviewRow(list: List<ReviewItem>, onOpenNote: (String) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Column {
        Row(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 8.dp), verticalAlignment = Alignment.Bottom) {
            Text("每日回顾", fontSize = 13.sp, fontWeight = FontWeight.ExtraBold, modifier = Modifier.weight(1f))
        }
        LazyRow(
            contentPadding = PaddingValues(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            items(list, key = { it.note.id }) { r ->
                Column(
                    modifier = Modifier
                        .width(236.dp)
                        .height(112.dp)
                        .clip(RoundedCornerShape(20.dp))
                        .background(scheme.surfaceContainerLowest)
                        .clickable { onOpenNote(r.note.id) }
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        "${r.label} · ${r.date}",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.ExtraBold,
                        color = scheme.primary,
                    )
                    Text(
                        r.note.summary?.takeIf { it.isNotBlank() } ?: r.note.title,
                        fontSize = 13.sp,
                        lineHeight = 20.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

// ───────────────────────── 下一件 ─────────────────────────

/**
 * 只留最近要做的一件待办：今天有时间的按时间、没时间的排后面；今天没有就看逾期里最早的。
 * 左边圆圈直接完成，有逾期时右边写「逾期 N」，点行去「待办」页。
 */
@Composable
private fun NextRow(
    task: DidaTask,
    isOverdue: Boolean,
    remaining: Int,
    overdueCount: Int,
    onComplete: (DidaTask) -> Unit,
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    var checked by remember(task.id) { mutableStateOf(false) }
    val ring = if (task.priority >= 5) Brand.Orange else scheme.onSurface
    val whenText = if (isOverdue) {
        val d = task.date?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
        "逾期" + (d?.let { " ${it.monthValue}月${it.dayOfMonth}日" } ?: "")
    } else {
        task.time.orEmpty()
    }
    RowPill(modifier, onClick = onOpen) {
        Row(
            modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(start = 4.dp, end = 18.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .clickable { if (!checked) { checked = true; onComplete(task) } },
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    modifier = Modifier
                        .size(22.dp)
                        .clip(CircleShape)
                        .background(if (checked) ring else Color.Transparent)
                        .border(2.dp, ring, CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    if (checked) Icon(Icons.Filled.Check, contentDescription = "已完成", tint = scheme.surfaceContainerLowest, modifier = Modifier.size(14.dp))
                }
            }
            Column(Modifier.weight(1f).padding(horizontal = 4.dp, vertical = 8.dp)) {
                Text(
                    buildAnnotatedString {
                        withStyle(SpanStyle(color = scheme.primary, fontWeight = FontWeight.ExtraBold)) {
                            append("下一件")
                            if (whenText.isNotEmpty()) append("  $whenText")
                        }
                        if (remaining > 0) {
                            withStyle(SpanStyle(color = scheme.onSurfaceVariant)) { append("  ·  今天还剩 $remaining 件") }
                        }
                    },
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    task.title,
                    fontSize = 14.sp,
                    lineHeight = 20.sp,
                    fontWeight = FontWeight.Bold,
                    color = scheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (overdueCount > 0) {
                Text(
                    "逾期 $overdueCount",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.ExtraBold,
                    color = scheme.error,
                    maxLines = 1,
                    modifier = Modifier.padding(start = 8.dp),
                )
            }
        }
    }
}

// ───────────────────────── 抽屉里的内容 ─────────────────────────

/** 刚记下、还在 3 秒撤销窗口里的一条 */
@Composable
private fun FreshStrip(item: CaptureEntity, remainingSec: Long, onUndo: () -> Unit, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(48.dp)
            .clip(CircleShape)
            .background(scheme.onSurface.copy(alpha = 0.08f))
            .padding(start = 16.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(painterResource(R.drawable.ic_sparkle), contentDescription = null, tint = scheme.primary, modifier = Modifier.size(18.dp))
        Text(
            item.summary,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Text("$remainingSec 秒", style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant)
        Box(
            modifier = Modifier
                .height(36.dp)
                .clip(CircleShape)
                .background(scheme.inverseSurface)
                .clickable(role = androidx.compose.ui.semantics.Role.Button, onClick = onUndo)
                .padding(horizontal = 16.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text("撤销", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, color = scheme.inverseOnSurface)
        }
    }
}

/** 专注进行中的顶部状态条：圆点 + 任务 + 剩余时间（每秒走），右侧「暂停 / 继续」；整条点开专注页 */
@Composable
private fun FocusingStrip(
    run: FocusRun,
    onOpen: () -> Unit,
    onPauseOrResume: () -> Unit,
    onDue: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    val paused = run.paused
    val now by produceState(System.currentTimeMillis(), run) {
        while (!run.paused) {
            value = System.currentTimeMillis()
            delay(1_000)
        }
        value = System.currentTimeMillis()
    }
    val remain = run.remainingMs(now)
    val due = !paused && run.isDue(now)
    LaunchedEffect(due) { if (due) onDue() }
    val sec = ((remain + 999) / 1000).coerceAtLeast(0)
    val clock = if (sec >= 3600) "%d:%02d:%02d".format(sec / 3600, sec / 60 % 60, sec % 60) else "%02d:%02d".format(sec / 60, sec % 60)
    val what = if (run.kind.isBreak) "放松一下" else run.title.trim().takeIf { it.isNotEmpty() } ?: "自由专注"

    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(52.dp)
            .clip(CircleShape)
            .background(scheme.primary.copy(alpha = 0.14f))
            .clickable(onClickLabel = "打开专注", onClick = onOpen)
            .padding(start = 18.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(if (paused) scheme.onSurfaceVariant else scheme.primary),
        )
        Column(Modifier.weight(1f)) {
            Text(
                if (paused) "${run.kind.label}已暂停" else "${run.kind.label}中",
                style = MaterialTheme.typography.labelMedium,
                color = scheme.onSurfaceVariant,
            )
            Text(
                what,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            "剩 $clock",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.Bold,
            color = scheme.primary,
        )
        Box(
            modifier = Modifier
                .height(36.dp)
                .clip(CircleShape)
                .background(scheme.primary)
                .clickable(role = androidx.compose.ui.semantics.Role.Button, onClick = onPauseOrResume)
                .padding(horizontal = 14.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                if (paused) "继续" else "暂停",
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.Bold,
                color = scheme.onPrimary,
            )
        }
    }
}

/** 「最近记录」标题栏右侧的更多选项 */
@Composable
private fun RecentMenu(onClearDone: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { menu = true }) {
            Icon(Icons.Filled.MoreVert, contentDescription = "更多", tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        AppMenu(expanded = menu, onDismissRequest = { menu = false }) {
            AppMenuItem(text = { Text("清除已完成的记录") }, destructive = true, onClick = { menu = false; onClearDone() })
        }
    }
}

@Composable
private fun ConnectCard(onOpenConnection: () -> Unit, modifier: Modifier = Modifier) {
    GlassSurface(
        modifier = modifier.fillMaxWidth(),
        tint = MaterialTheme.colorScheme.primary,
    ) {
        Row(
            modifier = Modifier.padding(start = 20.dp, end = 12.dp, top = 14.dp, bottom = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("先连接闪念贝壳", style = MaterialTheme.typography.titleMedium)
                Text(
                    "填入 API Key 后，记录会自动同步",
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
            Button(onClick = onOpenConnection) { Text("去连接") }
        }
    }
}

@Composable
private fun FailedBanner(count: Int, modifier: Modifier = Modifier) {
    GlassSurface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        tint = MaterialTheme.colorScheme.error,
        elevated = false,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(Icons.Filled.Warning, contentDescription = null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(20.dp))
            Text(
                "有 $count 条没有同步成功，内容都还在本地，可在下面逐条重试",
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}

@Composable
private fun EmptyHint(modifier: Modifier = Modifier) {
    GlassSurface(modifier = modifier.fillMaxWidth()) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("一个入口，自动分流", style = MaterialTheme.typography.titleSmall)
            HintLine("明天 15:00 开会", "待办（自动建到滴答清单）")
            HintLine("#读书 《穷查理宝典》很有启发", "笔记，带标签")
            HintLine("今天试了新的工作流", "追加到当天的 Daily Note")
            Text(
                "点右下角的 + 开始记录；识别不对，就在输入框下面的「待办 / 日记 / 笔记」里直接指定。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun HintLine(example: String, result: String) {
    Column {
        Text(example, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
        Text("→ $result", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
    }
}

@Composable
private fun RecentRow(
    item: CaptureEntity,
    now: Long,
    onUndo: () -> Unit,
    onRetry: () -> Unit,
) {
    val kind = CaptureKind.valueOf(item.kind)
    val status = item.status
    val remainingSec = ((item.readyAt - now + 999) / 1000).coerceAtLeast(0)
    val inUndoWindow = status == CaptureStatus.PENDING.name && item.readyAt > now

    RowPill {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 14.dp, end = 8.dp, top = 12.dp, bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            GlassBadge(kindIcon(kind))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    item.summary,
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(2.dp))
                val (line, isError) = when {
                    status == CaptureStatus.FAILED.name -> (item.lastError ?: "同步失败") to true
                    inUndoWindow -> "${item.detail} · ${remainingSec} 秒后同步" to false
                    status == CaptureStatus.DONE.name ->
                        "${item.detail} · ${item.resultText ?: "已同步"} · ${relativeTime(item.createdAt, now)}" to false
                    item.attempts > 0 -> "${item.detail} · 等待网络，稍后自动重试" to false
                    else -> "${item.detail} · 正在同步…" to false
                }
                Text(
                    line,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.width(4.dp))
            when {
                inUndoWindow -> TextButton(onClick = onUndo) { Text("撤销") }
                status == CaptureStatus.FAILED.name -> TextButton(onClick = onRetry) { Text("重试") }
                status == CaptureStatus.DONE.name -> Icon(
                    Icons.Filled.Check,
                    contentDescription = "已同步",
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier
                        .padding(end = 8.dp)
                        .size(20.dp),
                )
                else -> CircularProgressIndicator(
                    modifier = Modifier
                        .padding(end = 12.dp)
                        .size(18.dp),
                    strokeWidth = 2.dp,
                )
            }
        }
    }
}
