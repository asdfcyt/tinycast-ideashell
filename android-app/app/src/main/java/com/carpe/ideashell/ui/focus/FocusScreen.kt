package com.carpe.ideashell.ui.focus

import com.carpe.ideashell.ui.glass.GlassSheet
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import com.carpe.ideashell.data.focus.FocusKind
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.semantics.Role
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.dida.FocusSession
import com.carpe.ideashell.data.focus.FocusRepository
import com.carpe.ideashell.data.focus.FocusRun
import com.carpe.ideashell.ui.components.AppSnackbarHost
import com.carpe.ideashell.ui.components.CircleIconButton
import com.carpe.ideashell.ui.components.ConfirmDialog
import com.carpe.ideashell.ui.components.RowDivider
import com.carpe.ideashell.ui.components.ScreenHeader
import com.carpe.ideashell.ui.glass.GlassSurface
import com.carpe.ideashell.ui.glass.glassButton
import com.carpe.ideashell.ui.glass.glassChip
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import com.carpe.ideashell.ui.glass.isDarkSurface
import com.carpe.ideashell.ui.theme.Brand
import kotlinx.coroutines.delay
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * 专注页（设计系统「环」）：一个环、一件事。
 * - 上半是主角：大圆环倒计时（没开始时是选好的时长），下面选 15 / 25 / 45 / 60 / 90 分钟；
 * - 然后是「专注什么」（可绑定滴答里的一个待办，也可以不绑），和唯一的主按钮；
 * - 下半是滴答里读回来的专注：今天 / 近 7 天 / 最近几次。结束后写进滴答（create_focus），所以手机和电脑的滴答里都看得到。
 * 计时靠系统的倒计时通知 + 闹钟，退出本页、锁屏、杀进程都不影响；到点没打开应用也会自动记录。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FocusScreen(
    onBack: () -> Unit,
    onOpenConnection: () -> Unit,
    viewModel: FocusViewModel = viewModel(factory = FocusViewModel.Factory.instance),
) {
    val run by viewModel.session.collectAsStateWithLifecycle()
    val summary by viewModel.summary.collectAsStateWithLifecycle()
    val pending by viewModel.pending.collectAsStateWithLifecycle()
    val connected by viewModel.connected.collectAsStateWithLifecycle()
    val goal by viewModel.goalMin.collectAsStateWithLifecycle()
    val tasks by viewModel.tasks.collectAsStateWithLifecycle()
    val projects by viewModel.projects.collectAsStateWithLifecycle()
    val pendingBreak by viewModel.pendingBreak.collectAsStateWithLifecycle()
    val cycle by viewModel.cycle.collectAsStateWithLifecycle()
    val idleKind = pendingBreak ?: FocusKind.FOCUS
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current

    // 最近专注里的记录如果有成果小票，点一下就能看
    val tickets = remember { (context.applicationContext as com.carpe.ideashell.IdeashellApp).container.tickets }
    var ticket by remember { mutableStateOf<com.carpe.ideashell.data.focus.Celebration?>(null) }

    var pickTask by remember { mutableStateOf(false) }
    var confirmDiscard by remember { mutableStateOf(false) }
    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }

    LifecycleResumeEffect(Unit) {
        viewModel.reload()
        onPauseOrDispose { }
    }
    LaunchedEffect(Unit) { viewModel.messages.collect { snackbar.showSnackbar(it) } }

    // 倒计时：进行中每 250ms 取一次时间；暂停或没在专注时不走
    val live = run
    val now by produceState(System.currentTimeMillis(), live == null, live?.paused) {
        while (true) {
            value = System.currentTimeMillis()
            if (live == null || live.paused) break
            delay(250)
        }
    }
    // 到点：马上对账记录（应用在后台时由闹钟负责，这里是在前台时的快路径）
    val due = live != null && live.isDue(now)
    LaunchedEffect(due) { if (due) viewModel.reload() }

    Scaffold(
        containerColor = Color.Transparent,
        contentWindowInsets = WindowInsets.statusBars,
        snackbarHost = { AppSnackbarHost(snackbar, Modifier.padding(bottom = LocalBottomBarPadding.current)) },
    ) { padding ->
        Column(Modifier.padding(padding)) {
            ScreenHeader(
                title = "专注",
                subtitle = when {
                    live == null -> summary?.let { "今天已专注 ${compact(it.todayMin)}" }
                    live.kind.isBreak -> if (live.paused) "已暂停 · ${live.kind.label}" else "${live.kind.label}中"
                    live.paused -> "已暂停 · ${live.title.ifBlank { "自由专注" }}"
                    else -> "专注中 · ${live.title.ifBlank { "自由专注" }}"
                },
                action = { CircleIconButton(Icons.AutoMirrored.Filled.ArrowBack, "返回", onBack) },
            )
            PullToRefreshBox(
                isRefreshing = viewModel.refreshing,
                onRefresh = viewModel::forceRefresh,
                modifier = Modifier.weight(1f),
            ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                TimerCard(
                    run = live,
                    now = now,
                    kind = idleKind,
                    cycle = cycle,
                    minutes = viewModel.minutes,
                    onSkipBreak = viewModel::skipBreak,
                    onMinutes = { viewModel.minutes = it },
                    onStart = {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            // 没有通知权限，专注期间看不到倒计时、到点也没有提醒；请求一次，不挡着开始
                            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                        }
                        viewModel.start()
                    },
                )

                // 休息不绑定任务
                if (if (live != null) !live.kind.isBreak else !idleKind.isBreak) {
                    TaskRow(
                        run = live,
                        task = viewModel.task,
                        project = viewModel.project,
                        onClick = { pickTask = true },
                    )
                }

                if (live != null) {
                    val isBreak = live.kind.isBreak
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        SecondaryButton(if (live.paused) "继续" else "暂停", Modifier.weight(1f), viewModel::pauseOrResume)
                        PrimaryButton(if (isBreak) "结束休息" else "结束并记录", Modifier.weight(1f), viewModel::finish)
                    }
                    if (!isBreak) {
                        TextButton(
                            onClick = { confirmDiscard = true },
                            modifier = Modifier.align(Alignment.CenterHorizontally),
                        ) {
                            Text("放弃本次（不记录）", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
                        }
                    }
                }

                if (!connected) {
                    Banner("连接滴答清单后，专注会自动计入滴答；现在开始的专注先存在本机。", "去连接", onOpenConnection)
                }
                if (pending.isNotEmpty()) {
                    Banner("有 ${pending.size} 条专注还没同步到滴答", "立即同步", viewModel::syncNow)
                }

                TodayCard(
                    connected = connected,
                    todayMin = summary?.todayMin,
                    todayPomos = summary?.todayPomos ?: 0,
                    weekMin = summary?.weekMin,
                    goalMin = goal,
                )

                val recent = remember(summary) { summary?.sessions.orEmpty().asReversed().take(RECENT_LIMIT) }
                if (recent.isNotEmpty()) RecentCard(
                    sessions = recent,
                    ticketOf = { s -> tickets.forFocus(s.startMs, s.taskId) },
                    onOpenTicket = { ticket = it },
                )

                Spacer(Modifier.height(LocalBottomBarPadding.current))
            }
            }
        }
    }

    ticket?.let { com.carpe.ideashell.ui.components.TicketDialog(it, onDismiss = { ticket = null }) }

    if (pickTask) {
        TaskPicker(
            tasks = tasks,
            projects = projects,
            selected = if (live != null) live.taskId else viewModel.task?.id,
            selectedProject = if (live != null) live.project else viewModel.project,
            projectOf = viewModel::projectOf,
            adding = viewModel.adding,
            onAdd = { title -> viewModel.addTask(title) { pickTask = false } },
            onSelect = { t, p ->
                viewModel.choose(t, p)
                pickTask = false
            },
            onDismiss = { pickTask = false },
        )
    }
    if (confirmDiscard) {
        ConfirmDialog(
            title = "放弃这次专注？",
            text = "已经专注的时间不会被记录。",
            confirmLabel = "放弃",
            onDismiss = { confirmDiscard = false },
            onConfirm = {
                confirmDiscard = false
                viewModel.discard()
            },
        )
    }
}

// ───────────────────────── 计时环 ─────────────────────────

/**
 * 计时圆盘：
 * - 没开始：一整圈对应「最大时长」（专注 120 分钟、休息 60 分钟），拖动圆环上的把手或直接点圆环就能选时长，
 *   圈里 60 根刻度、四个方位标出数值，圆心是大号分钟数和「开始」按钮；
 * - 进行中：圆环是剩余比例（一圈走完正好归零），圆心是倒计时。
 */
@Composable
internal fun TimerCard(
    run: FocusRun?,
    now: Long,
    kind: FocusKind,
    cycle: Int,
    minutes: Int,
    onSkipBreak: () -> Unit,
    onMinutes: (Int) -> Unit,
    onStart: () -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    val dark = isDarkSurface()
    val remaining = run?.remainingMs(now)
    val shownKind = run?.kind ?: kind
    val maxMin = shownKind.maxMin
    // 没开始：选了多少占多少；进行中：剩余比例，一圈走完正好归零
    val fraction = if (run == null) (minutes.toFloat() / maxMin).coerceIn(0f, 1f) else (run.remainingMs(now).toFloat() / run.plannedMs).coerceIn(0f, 1f)
    val arcColor = when {
        run?.paused == true -> Brand.Orange.copy(alpha = 0.5f)
        shownKind.isBreak -> Color(0xFF4FAE8B)
        else -> Brand.Orange
    }
    val track = scheme.onSurface.copy(alpha = if (dark) 0.12f else 0.09f)
    val tickOn = scheme.onSurface.copy(alpha = 0.55f)
    val tickOff = scheme.onSurface.copy(alpha = if (dark) 0.2f else 0.16f)
    val labelColor = scheme.onSurfaceVariant
    val measurer = rememberTextMeasurer()
    val haptic = LocalHapticFeedback.current
    val currentMinutes by rememberUpdatedState(minutes)
    val currentOnMinutes by rememberUpdatedState(onMinutes)
    val currentKind by rememberUpdatedState(shownKind)

    GlassSurface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(28.dp)) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 18.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            if (run == null) {
                CycleHeader(kind, cycle, onSkipBreak)
            } else {
                Text(
                    run.kind.label,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    color = arcColor,
                )
            }

            Box(
                Modifier
                    .widthIn(max = 300.dp)
                    .fillMaxWidth()
                    .aspectRatio(1f)
                    .semantics {
                        contentDescription = if (remaining == null) "已选 $minutes 分钟，拖动圆环调整" else "剩余 ${spoken(remaining)}"
                    }
                    .then(
                        if (run != null) Modifier else Modifier
                            .pointerInput(Unit) {
                                // 点一下圆环：直接跳到那个时长
                                detectTapGestures { pos ->
                                    val k = currentKind
                                    val m = minutesAt(pos, size.width.toFloat(), size.height.toFloat(), k, null)
                                    if (m != currentMinutes) {
                                        haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                        currentOnMinutes(m)
                                    }
                                }
                            }
                            .pointerInput(Unit) {
                                var lastFraction = 0f
                                detectDragGestures(
                                    onDragStart = { pos ->
                                        lastFraction = currentMinutes.toFloat() / currentKind.maxMin
                                        val k = currentKind
                                        val m = minutesAt(pos, size.width.toFloat(), size.height.toFloat(), k, lastFraction)
                                        if (m != currentMinutes) currentOnMinutes(m)
                                        lastFraction = m.toFloat() / k.maxMin
                                    },
                                    onDrag = { change, _ ->
                                        change.consume()
                                        val k = currentKind
                                        val m = minutesAt(change.position, size.width.toFloat(), size.height.toFloat(), k, lastFraction)
                                        lastFraction = m.toFloat() / k.maxMin
                                        if (m != currentMinutes) {
                                            haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                            currentOnMinutes(m)
                                        }
                                    },
                                )
                            },
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Canvas(Modifier.fillMaxSize()) {
                    val stroke = 26.dp.toPx()
                    val c = center
                    val outerR = size.minDimension / 2 - 2.dp.toPx()
                    val ringR = outerR - stroke / 2
                    val topLeft = Offset(c.x - ringR, c.y - ringR)
                    val arcSize = Size(ringR * 2, ringR * 2)
                    drawCircle(track, ringR, c, style = Stroke(stroke))
                    if (fraction > 0f) {
                        drawArc(arcColor, -90f, 360f * fraction, false, topLeft, arcSize, style = Stroke(stroke, cap = StrokeCap.Round))
                    }

                    // 刻度：每 6° 一根（一圈 60 根），每 5 根一根长的
                    val tickOuter = outerR - stroke - 8.dp.toPx()
                    for (i in 0 until 60) {
                        val long = i % 5 == 0
                        val len = (if (long) 10.dp else 5.dp).toPx()
                        val rad = Math.toRadians(i * 6.0 - 90.0)
                        val dx = cos(rad).toFloat()
                        val dy = sin(rad).toFloat()
                        drawLine(
                            color = if (i / 60f < fraction || (i == 0 && fraction > 0f)) tickOn else tickOff,
                            start = Offset(c.x + dx * tickOuter, c.y + dy * tickOuter),
                            end = Offset(c.x + dx * (tickOuter - len), c.y + dy * (tickOuter - len)),
                            strokeWidth = (if (long) 2.dp else 1.2.dp).toPx(),
                            cap = StrokeCap.Round,
                        )
                    }

                    // 四个方位的数值：上 = 最大值，右 = 1/4，下 = 1/2，左 = 3/4
                    if (run == null) {
                        val labelR = tickOuter - 10.dp.toPx() - 14.dp.toPx()
                        val style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Bold, color = labelColor)
                        listOf(maxMin to 0.0, maxMin / 4 to 90.0, maxMin / 2 to 180.0, maxMin * 3 / 4 to 270.0).forEach { (value, deg) ->
                            val layout = measurer.measure(value.toString(), style)
                            val rad = Math.toRadians(deg - 90.0)
                            drawText(
                                layout,
                                topLeft = Offset(
                                    c.x + cos(rad).toFloat() * labelR - layout.size.width / 2f,
                                    c.y + sin(rad).toFloat() * labelR - layout.size.height / 2f,
                                ),
                            )
                        }
                        // 把手
                        val a = Math.toRadians(360.0 * fraction - 90.0)
                        val hc = Offset(c.x + cos(a).toFloat() * ringR, c.y + sin(a).toFloat() * ringR)
                        drawCircle(Color.Black.copy(alpha = 0.18f), stroke * 0.46f, hc + Offset(0f, 1.5.dp.toPx()))
                        drawCircle(Color.White, stroke * 0.42f, hc)
                        drawCircle(arcColor, stroke * 0.16f, hc)
                    }
                }
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    if (run == null) {
                        Text(minutes.toString(), style = BigNumber.copy(fontSize = 60.sp, lineHeight = 64.sp))
                        Text("分钟", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = scheme.onSurfaceVariant)
                        Spacer(Modifier.height(10.dp))
                        StartPill(onStart)
                    } else {
                        Text(countdown(remaining ?: 0L), style = BigNumber.copy(fontSize = 50.sp, lineHeight = 56.sp))
                        Text(
                            if (run.paused) "已暂停" else "${clockOf(run.endAtMs)} 结束",
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = scheme.onSurfaceVariant,
                        )
                    }
                }
            }

            if (run != null) {
                Text(
                    "共 ${run.plannedMin} 分钟 · 已${if (run.kind.isBreak) "休息" else "专注"} ${spoken(run.elapsedMs(now))}",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = scheme.onSurfaceVariant,
                )
            }
        }
    }
}

/** 点 / 拖的位置 → 分钟数。[lastFraction] 用来防止从 0 点附近一跨就从最大值跳到最小值（拖过头时停在端点） */
private fun minutesAt(pos: Offset, width: Float, height: Float, kind: FocusKind, lastFraction: Float?): Int {
    val dx = pos.x - width / 2f
    val dy = pos.y - height / 2f
    var deg = Math.toDegrees(atan2(dx.toDouble(), -dy.toDouble()))
    if (deg < 0) deg += 360.0
    var f = (deg / 360.0).toFloat()
    if (lastFraction != null) {
        if (lastFraction > 0.75f && f < 0.25f) f = 1f
        else if (lastFraction < 0.25f && f > 0.75f) f = 0f
    }
    return Math.round(f * kind.maxMin).coerceIn(kind.minMin, kind.maxMin)
}

@Composable
private fun StartPill(onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .height(40.dp)
            .clip(CircleShape)
            .background(Brand.Orange)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 22.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text("开始", fontSize = 15.sp, fontWeight = FontWeight.ExtraBold, color = Brand.Brown)
        Icon(Icons.Filled.PlayArrow, contentDescription = null, tint = Brand.Brown, modifier = Modifier.size(18.dp))
    }
}

/**
 * 番茄钟进度：一轮 4 个番茄（实心 = 已完成）。番茄走完后这里变成「休息一下」，并给一个「跳过休息」。
 * 休息只会在番茄走完后出现，平时只有专注。
 */
@Composable
private fun CycleHeader(kind: FocusKind, cycle: Int, onSkipBreak: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val total = FocusRepository.CYCLE_LENGTH
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (kind.isBreak) {
            Text(
                if (kind == FocusKind.LONG_BREAK) "完成 $total 个番茄 · 长休息" else "第 $cycle 个番茄完成 · 短休息",
                fontSize = 14.sp,
                fontWeight = FontWeight.ExtraBold,
                color = Color(0xFF4FAE8B),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(7.dp), verticalAlignment = Alignment.CenterVertically) {
            for (i in 0 until total) {
                Box(
                    Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(if (i < cycle) (if (kind.isBreak) Color(0xFF4FAE8B) else Brand.Orange) else scheme.onSurface.copy(alpha = 0.12f)),
                )
            }
            if (!kind.isBreak) {
                Text(
                    if (cycle == 0) "  开始第 1 个番茄" else "  第 ${cycle + 1} 个番茄",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = scheme.onSurfaceVariant,
                )
            }
        }
        if (kind.isBreak) {
            TextButton(onClick = onSkipBreak) {
                Text("跳过休息，直接专注", fontSize = 13.sp, color = scheme.onSurfaceVariant)
            }
        }
    }
}

private val BigNumber = TextStyle(
    fontWeight = FontWeight.Black,
    letterSpacing = 0.sp,
    // 等宽数字：倒计时每秒变化，字宽不跳
    fontFeatureSettings = "tnum",
)

// ───────────────────────── 专注什么 ─────────────────────────

@Composable
internal fun TaskRow(run: FocusRun?, task: DidaTask?, project: String?, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    // 专注进行中也可以补选 / 更换关联的任务和项目
    val shownProject = if (run != null) run.project else project
    val title = when {
        run != null -> run.title.takeIf { it.isNotBlank() }?.let(TodoMeta::cleanTitle) ?: "自由专注（不关联任务）"
        task != null -> TodoMeta.cleanTitle(task.title)
        project != null -> "项目「$project」"
        else -> "自由专注（不关联任务）"
    }
    val bound = if (run != null) (!run.taskId.isNullOrBlank() || !run.project.isNullOrBlank()) else (task != null || project != null)
    GlassSurface(
        Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(24.dp),
        onClick = onClick,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().heightIn(min = 64.dp).padding(horizontal = 18.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text("专注什么", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = scheme.onSurfaceVariant)
                Text(
                    title,
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    color = if (bound) scheme.onSurface else scheme.onSurfaceVariant,
                )
                // 任务属于某个项目时，标出来：这次专注会计入项目的专注统计和「里程碑与进展」
                if (shownProject != null && !title.startsWith("项目「")) {
                    Text("项目 · $shownProject", fontSize = 12.sp, color = scheme.primary, maxLines = 1)
                }
            }
            Text(if (bound) "更换" else "选择", fontSize = 13.sp, fontWeight = FontWeight.Bold, color = scheme.primary)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TaskPicker(
    tasks: List<DidaTask>,
    projects: List<ProjectChoice>,
    selected: String?,
    selectedProject: String?,
    projectOf: (DidaTask) -> String?,
    adding: Boolean,
    onAdd: (String) -> Unit,
    onSelect: (DidaTask?, String?) -> Unit,
    onDismiss: () -> Unit,
) {
    // 专注页背后是大号倒计时和卡片，磨砂要比别的抽屉更重一些才不抢眼
    GlassSheet(onDismiss = onDismiss, blurPx = 56) {
        Text(
            "这次专注做什么",
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.padding(start = 24.dp, end = 24.dp, bottom = 8.dp),
        )
        LazyColumn(
            Modifier.padding(horizontal = 12.dp).imePadding(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 24.dp),
        ) {
            item(key = "add") { AddTaskRow(adding, onAdd) }
            item(key = "none") {
                PickerRow("自由专注", "不关联任务", selected == null && selectedProject == null) { onSelect(null, null) }
            }
            if (tasks.isEmpty() && projects.isEmpty()) {
                item(key = "empty") {
                    Text(
                        "滴答里今天没有待办。可以在上面直接新建一个，或先不关联任务直接开始。",
                        fontSize = 13.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp),
                    )
                }
            }
            items(tasks, key = { it.id }) { t ->
                val p = projectOf(t)
                PickerRow(
                    TodoMeta.cleanTitle(t.title),
                    whenText(t) + (p?.let { " · 项目 $it" } ?: ""),
                    selected == t.id,
                ) { onSelect(t, null) }
            }
            // 项目：可以直接为项目专注，也可以挑它名下的任务（任务属于项目，专注会计入项目统计和「里程碑与进展」）
            projects.forEach { pc ->
                item(key = "project-${pc.keyword}") {
                    Text(
                        "项目 · ${pc.keyword}",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(start = 12.dp, end = 12.dp, top = 14.dp, bottom = 2.dp),
                    )
                }
                item(key = "project-self-${pc.keyword}") {
                    PickerRow("为项目「${pc.keyword}」专注", "不选具体任务", selected == null && selectedProject == pc.keyword) {
                        onSelect(null, pc.keyword)
                    }
                }
                items(pc.tasks, key = { "project-${pc.keyword}-${it.id}" }) { t ->
                    PickerRow(TodoMeta.cleanTitle(t.title), whenText(t), selected == t.id) { onSelect(t, pc.keyword) }
                }
            }
        }
    }
}

/** 选择器顶部：现场新建一个今天的滴答任务并选中，回车或点「添加」 */
@Composable
private fun AddTaskRow(adding: Boolean, onAdd: (String) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    var text by remember { mutableStateOf("") }
    val canAdd = text.isNotBlank() && !adding
    val submit = { if (canAdd) onAdd(text.trim()) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp)
            .height(52.dp)
            .clip(CircleShape)
            .background(scheme.onSurface.copy(alpha = 0.06f))
            .padding(start = 18.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        BasicTextField(
            value = text,
            onValueChange = { text = it.replace("\n", "") },
            singleLine = true,
            textStyle = MaterialTheme.typography.bodyLarge.copy(color = scheme.onSurface),
            cursorBrush = SolidColor(scheme.primary),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { submit() }),
            modifier = Modifier.weight(1f),
            decorationBox = { inner ->
                Box(contentAlignment = Alignment.CenterStart) {
                    if (text.isEmpty()) {
                        Text("新建任务并专注…", style = MaterialTheme.typography.bodyLarge, color = scheme.onSurfaceVariant)
                    }
                    inner()
                }
            },
        )
        Box(
            modifier = Modifier
                .height(36.dp)
                .clip(CircleShape)
                .background(if (canAdd) scheme.primary else scheme.onSurface.copy(alpha = 0.12f))
                .clickable(enabled = canAdd, role = Role.Button, onClick = { submit() })
                .padding(horizontal = 16.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                if (adding) "添加中" else "添加",
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.Bold,
                color = if (canAdd) scheme.onPrimary else scheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun PickerRow(title: String, sub: String, selected: Boolean, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .clickable(role = Role.RadioButton, onClick = onClick)
            .heightIn(min = 56.dp)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(sub, fontSize = 12.sp, color = scheme.onSurfaceVariant, maxLines = 1)
        }
        if (selected) Icon(Icons.Filled.Check, contentDescription = "已选", tint = scheme.primary, modifier = Modifier.size(22.dp))
    }
}

private fun whenText(t: DidaTask): String {
    val today = LocalDate.now().toString()
    return when {
        t.date == null -> "无日期"
        t.date < today -> "逾期 · " + t.date.drop(5).replaceFirst('-', '/')
        t.date > today -> t.date.drop(5).replaceFirst('-', '/') + (t.time?.let { " $it" } ?: "")
        else -> "今天" + (t.time?.let { " $it" } ?: "")
    }
}

// ───────────────────────── 按钮与提示 ─────────────────────────

@Composable
private fun PrimaryButton(text: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(56.dp)
            .glassButton(CircleShape, Brand.Orange)
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, fontSize = 16.sp, fontWeight = FontWeight.ExtraBold, color = Brand.Brown, maxLines = 1)
    }
}

@Composable
private fun SecondaryButton(text: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(56.dp)
            .glassChip(CircleShape)
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, fontSize = 16.sp, fontWeight = FontWeight.ExtraBold, color = scheme.onSurface, maxLines = 1)
    }
}

@Composable
private fun Banner(text: String, action: String, onAction: () -> Unit) {
    GlassSurface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp), tint = Brand.Orange) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 6.dp, top = 6.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(text, Modifier.weight(1f), fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.SemiBold)
            TextButton(onClick = onAction) { Text(action, fontWeight = FontWeight.Bold) }
        }
    }
}

// ───────────────────────── 滴答里的专注 ─────────────────────────

@Composable
private fun TodayCard(connected: Boolean, todayMin: Int?, todayPomos: Int, weekMin: Int?, goalMin: Int) {
    val scheme = MaterialTheme.colorScheme
    val progress = ((todayMin ?: 0).toFloat() / goalMin.coerceAtLeast(1)).coerceIn(0f, 1f)
    GlassSurface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(24.dp)) {
        Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("今天", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = scheme.onSurfaceVariant, modifier = Modifier.padding(bottom = 4.dp))
                Text(todayMin?.let(::compact) ?: "–", fontSize = 28.sp, lineHeight = 32.sp, fontWeight = FontWeight.Black)
                Text("/ ${compact(goalMin)}", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = scheme.onSurfaceVariant, modifier = Modifier.padding(bottom = 4.dp))
            }
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(6.dp)
                    .clip(CircleShape)
                    .background(scheme.onSurface.copy(alpha = 0.09f)),
            ) {
                if (progress > 0f) Box(Modifier.fillMaxWidth(progress).height(6.dp).clip(CircleShape).background(Brand.Orange))
            }
            Text(
                when {
                    !connected -> "连接滴答清单后，这里显示滴答里的专注"
                    todayMin == null -> "正在读取滴答里的专注…"
                    else -> "番茄钟 $todayPomos 个 · 近 7 天 ${compact(weekMin ?: 0)}"
                },
                fontSize = 12.sp,
                lineHeight = 17.sp,
                fontWeight = FontWeight.SemiBold,
                color = scheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun RecentCard(
    sessions: List<FocusSession>,
    ticketOf: (FocusSession) -> com.carpe.ideashell.data.focus.Celebration?,
    onOpenTicket: (com.carpe.ideashell.data.focus.Celebration) -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    Text(
        "最近专注",
        style = MaterialTheme.typography.titleSmall,
        modifier = Modifier.padding(start = 8.dp, top = 6.dp),
    )
    GlassSurface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(24.dp)) {
        Column {
            sessions.forEachIndexed { i, s ->
                if (i > 0) RowDivider()
                val tk = ticketOf(s)
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .then(if (tk != null) Modifier.clickable { onOpenTicket(tk) } else Modifier)
                        .heightIn(min = 56.dp)
                        .padding(horizontal = 18.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            s.title?.takeIf { it.isNotBlank() }?.let(TodoMeta::cleanTitle) ?: "自由专注",
                            style = MaterialTheme.typography.titleSmall,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(rangeText(s), fontSize = 12.sp, color = scheme.onSurfaceVariant, maxLines = 1)
                    }
                    Text(
                        compact(Math.round((s.endMs - s.startMs) / 60_000.0).toInt()),
                        fontSize = 15.sp,
                        fontWeight = FontWeight.ExtraBold,
                        textAlign = TextAlign.End,
                    )
                }
            }
        }
    }
}

// ───────────────────────── 格式化 ─────────────────────────

private const val RECENT_LIMIT = 6

private val HHMM = DateTimeFormatter.ofPattern("HH:mm")

private fun clockOf(ms: Long): String = HHMM.format(Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()))

private fun rangeText(s: FocusSession): String {
    val zone = ZoneId.systemDefault()
    val start = Instant.ofEpochMilli(s.startMs).atZone(zone)
    val day = if (start.toLocalDate() == LocalDate.now()) "今天" else "${start.monthValue}月${start.dayOfMonth}日"
    return "$day ${clockOf(s.startMs)}–${clockOf(s.endMs)}"
}

/** 42m / 2h / 1h25m（和「今天」页的专注环同一写法） */
private fun compact(min: Int): String = when {
    min < 60 -> "${min}m"
    min % 60 == 0 -> "${min / 60}h"
    else -> "${min / 60}h${min % 60}m"
}

/** 倒计时：向上取整到秒，开始时正好是 25:00；一小时以上显示 1:30:00 */
private fun countdown(ms: Long): String {
    val total = ((ms + 999) / 1000).coerceAtLeast(0)
    val h = total / 3600
    val m = total % 3600 / 60
    val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
}

/** 读屏 / 说明文字用：「24 分 35 秒」 */
private fun spoken(ms: Long): String {
    val total = ((ms + 999) / 1000).coerceAtLeast(0)
    val m = total / 60
    val s = total % 60
    return if (m == 0L) "$s 秒" else "$m 分 $s 秒"
}
