package com.carpe.ideashell.ui.focus

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material3.SnackbarHost
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
import com.carpe.ideashell.ui.components.CircleIconButton
import com.carpe.ideashell.ui.components.ConfirmDialog
import com.carpe.ideashell.ui.components.RowDivider
import com.carpe.ideashell.ui.components.ScreenHeader
import com.carpe.ideashell.ui.glass.GlassSurface
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
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current

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
        snackbarHost = { SnackbarHost(snackbar, Modifier.padding(bottom = LocalBottomBarPadding.current)) },
    ) { padding ->
        Column(Modifier.padding(padding)) {
            ScreenHeader(
                title = "专注",
                subtitle = when {
                    live == null -> summary?.let { "今天已专注 ${compact(it.todayMin)}" }
                    live.paused -> "已暂停 · ${live.title.ifBlank { "自由专注" }}"
                    else -> "专注中 · ${live.title.ifBlank { "自由专注" }}"
                },
                action = { CircleIconButton(Icons.AutoMirrored.Filled.ArrowBack, "返回", onBack) },
            )
            Column(
                modifier = Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                TimerCard(
                    run = live,
                    now = now,
                    minutes = viewModel.minutes,
                    onMinutes = { viewModel.minutes = it },
                )

                TaskRow(
                    run = live,
                    task = viewModel.task,
                    onClick = { pickTask = true },
                )

                if (live == null) {
                    PrimaryButton("开始专注 · ${viewModel.minutes} 分钟") {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            // 没有通知权限，专注期间看不到倒计时、到点也没有提醒；请求一次，不挡着开始
                            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                        }
                        viewModel.start()
                    }
                } else {
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        SecondaryButton(if (live.paused) "继续" else "暂停", Modifier.weight(1f), viewModel::pauseOrResume)
                        PrimaryButton("结束并记录", Modifier.weight(1f), viewModel::finish)
                    }
                    TextButton(
                        onClick = { confirmDiscard = true },
                        modifier = Modifier.align(Alignment.CenterHorizontally),
                    ) {
                        Text("放弃本次（不记录）", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
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
                if (recent.isNotEmpty()) RecentCard(recent)

                Spacer(Modifier.height(LocalBottomBarPadding.current))
            }
        }
    }

    if (pickTask) {
        TaskPicker(
            tasks = tasks,
            selected = viewModel.task?.id,
            adding = viewModel.adding,
            onAdd = { title -> viewModel.addTask(title) { pickTask = false } },
            onSelect = {
                viewModel.task = it
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

@Composable
private fun TimerCard(run: FocusRun?, now: Long, minutes: Int, onMinutes: (Int) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val dark = isDarkSurface()
    val remaining = run?.remainingMs(now)
    // 没开始：整环；进行中：剩余比例，一圈走完正好归零
    val fraction = if (run == null) 1f else (run.remainingMs(now).toFloat() / run.plannedMs).coerceIn(0f, 1f)
    val arc = if (run?.paused == true) Brand.Orange.copy(alpha = 0.5f) else Brand.Orange
    val track = scheme.onSurface.copy(alpha = if (dark) 0.12f else 0.09f)

    GlassSurface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(28.dp)) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            Box(
                Modifier
                    .size(236.dp)
                    .semantics {
                        contentDescription = if (remaining == null) "已选 $minutes 分钟" else "剩余 ${spoken(remaining)}"
                    },
                contentAlignment = Alignment.Center,
            ) {
                Canvas(Modifier.size(236.dp)) {
                    val stroke = 14.dp.toPx()
                    val inset = stroke / 2
                    val topLeft = Offset(inset, inset)
                    val arcSize = Size(size.width - stroke, size.height - stroke)
                    drawArc(track, 0f, 360f, false, topLeft, arcSize, style = Stroke(stroke))
                    if (fraction > 0f) {
                        drawArc(arc, -90f, 360f * fraction, false, topLeft, arcSize, style = Stroke(stroke, cap = StrokeCap.Round))
                    }
                }
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    if (run == null) {
                        Text(minutes.toString(), style = BigNumber.copy(fontSize = 76.sp, lineHeight = 80.sp))
                        Text("分钟", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = scheme.onSurfaceVariant)
                    } else {
                        Text(countdown(remaining ?: 0L), style = BigNumber.copy(fontSize = 54.sp, lineHeight = 60.sp))
                        Text(
                            if (run.paused) "已暂停" else "${clockOf(run.endAtMs)} 结束",
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = scheme.onSurfaceVariant,
                        )
                    }
                }
            }

            if (run == null) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FocusRepository.CHOICES.forEach { m ->
                        DurationChip(m, selected = m == minutes, modifier = Modifier.weight(1f), onClick = { onMinutes(m) })
                    }
                }
            } else {
                Text(
                    "共 ${run.plannedMin} 分钟 · 已专注 ${spoken(run.elapsedMs(now))}",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = scheme.onSurfaceVariant,
                )
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

@Composable
private fun DurationChip(minutes: Int, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Box(
        modifier = modifier
            .height(44.dp)
            .clip(CircleShape)
            .background(if (selected) Brand.Orange else scheme.surfaceContainerHigh)
            .clickable(role = Role.RadioButton, onClickLabel = "$minutes 分钟", onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            minutes.toString(),
            fontSize = 16.sp,
            fontWeight = FontWeight.ExtraBold,
            color = if (selected) Brand.Brown else scheme.onSurface,
        )
    }
}

// ───────────────────────── 专注什么 ─────────────────────────

@Composable
private fun TaskRow(run: FocusRun?, task: DidaTask?, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val locked = run != null
    val title = when {
        locked -> run?.title?.takeIf { it.isNotBlank() }?.let(TodoMeta::cleanTitle) ?: "自由专注（不关联任务）"
        task != null -> TodoMeta.cleanTitle(task.title)
        else -> "自由专注（不关联任务）"
    }
    val bound = if (locked) !run?.taskId.isNullOrBlank() else task != null
    GlassSurface(
        Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(24.dp),
        onClick = if (locked) null else onClick,
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
            }
            if (!locked) Text("更换", fontSize = 13.sp, fontWeight = FontWeight.Bold, color = scheme.primary)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TaskPicker(
    tasks: List<DidaTask>,
    selected: String?,
    adding: Boolean,
    onAdd: (String) -> Unit,
    onSelect: (DidaTask?) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
    ) {
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
                PickerRow("自由专注", "不关联任务", selected == null) { onSelect(null) }
            }
            if (tasks.isEmpty()) {
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
                PickerRow(TodoMeta.cleanTitle(t.title), whenText(t), selected == t.id) { onSelect(t) }
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
            .clip(CircleShape)
            .background(Brand.Orange)
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
            .clip(CircleShape)
            .background(scheme.surfaceContainerHigh)
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
private fun RecentCard(sessions: List<FocusSession>) {
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
                Row(
                    modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 18.dp, vertical = 8.dp),
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
