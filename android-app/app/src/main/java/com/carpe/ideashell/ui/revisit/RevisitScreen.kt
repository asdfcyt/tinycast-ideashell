package com.carpe.ideashell.ui.revisit

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.carpe.ideashell.R
import com.carpe.ideashell.core.revisit.Cloze
import com.carpe.ideashell.core.revisit.Fsrs
import com.carpe.ideashell.data.db.RevisitEntity
import com.carpe.ideashell.data.db.RevisitKind
import com.carpe.ideashell.data.revisit.RevisitRepository
import com.carpe.ideashell.data.revisit.RevisitToday
import com.carpe.ideashell.ui.components.AppMenu
import com.carpe.ideashell.ui.components.AppMenuDivider
import com.carpe.ideashell.ui.components.AppMenuItem
import com.carpe.ideashell.ui.components.CircleIconButton
import com.carpe.ideashell.ui.components.MarkdownText
import com.carpe.ideashell.ui.components.TextPromptDialog
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import com.carpe.ideashell.ui.theme.Brand
import java.time.LocalDate
import java.time.temporal.ChronoUnit

/*
 * 重温页：一次只显示一条，像翻一张便签。
 * 顶部是进度（第几条 / 共几条）与「今天跳过」；中间是一张大卡片（出处 + 记下的日期 + 大字号正文）；
 * 底部三个评分：忘了（明天再来）/ 记得（按 FSRS 排）/ 太简单（间隔更长），按钮下面标出下次是什么时候。
 * 长内容先折叠，点「显示完整」再看全文——先回忆，再选择。处理完一条自动进入下一条，全部完成显示「今天的重温完成」。
 */
@Composable
fun RevisitScreen(
    onBack: () -> Unit,
    onOpenNote: (String) -> Unit,
    viewModel: RevisitViewModel = viewModel(factory = RevisitViewModel.Factory),
) {
    val today by viewModel.today.collectAsStateWithLifecycle()
    val cloze by viewModel.cloze.collectAsStateWithLifecycle()
    val current = today.queue.firstOrNull()
    val snackbar = remember { SnackbarHostState() }
    var composing by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }

    LifecycleResumeEffect(Unit) {
        viewModel.refresh()
        onPauseOrDispose { }
    }
    LaunchedEffect(current?.id) { viewModel.busy = false }
    LaunchedEffect(viewModel) {
        viewModel.messages.collect { text ->
            snackbar.currentSnackbarData?.dismiss()
            snackbar.showSnackbar(text)
        }
    }

    Box(Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .padding(horizontal = 16.dp),
        ) {
            TopBar(
                today = today,
                current = current,
                canUndo = viewModel.undoItems.isNotEmpty(),
                cloze = cloze,
                onToggleCloze = viewModel::toggleCloze,
                onBack = onBack,
                onUndo = viewModel::undo,
                onSkip = { current?.let(viewModel::skipToday) },
                onArchive = { current?.let(viewModel::archive) },
                onOpenSource = { current?.noteId?.let(onOpenNote) },
                onPostponeAll = viewModel::postponeAll,
            )
            Segments(done = today.doneToday, total = today.doneToday + today.remaining)

            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(top = 14.dp),
            ) {
                AnimatedContent(
                    targetState = current,
                    contentKey = { it?.id },
                    modifier = Modifier.fillMaxSize(),
                    transitionSpec = {
                        (slideInHorizontally(tween(260)) { it / 5 } + fadeIn(tween(220))) togetherWith
                            (slideOutHorizontally(tween(200)) { -it / 5 } + fadeOut(tween(140)))
                    },
                    label = "revisit-card",
                ) { item ->
                    if (item != null) RevisitCard(item, cloze) else EmptyState(today, onBack)
                }
                if (current != null) {
                    // 卡片右下角的「记一笔」：图标按钮，不占一整行；已有专题笔记时，入口放在左下角
                    Row(
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .fillMaxWidth()
                            .padding(start = 14.dp, end = 14.dp, bottom = 14.dp),
                        verticalAlignment = Alignment.Bottom,
                    ) {
                        current.topicNoteId?.let { topic ->
                            TopicChip(onClick = { onOpenNote(topic) })
                        }
                        Spacer(Modifier.weight(1f))
                        ThoughtFab(busy = viewModel.thoughtBusy, onClick = { composing = true })
                    }
                }
            }

            if (current != null) {
                RatingBar(
                    enabled = !viewModel.busy,
                    daysOf = { viewModel.previewDays(current, it) },
                    onRate = { viewModel.rate(current, it) },
                    modifier = Modifier.padding(top = 12.dp, bottom = LocalBottomBarPadding.current),
                )
            } else {
                Spacer(Modifier.height(LocalBottomBarPadding.current))
            }
        }
        SnackbarHost(
            snackbar,
            Modifier.align(Alignment.BottomCenter).padding(bottom = LocalBottomBarPadding.current),
        )
    }

    if (composing && current != null) {
        TextPromptDialog(
            title = "记一笔",
            label = "想法",
            hint = thoughtHint(current),
            minLines = 4,
            onDismiss = { composing = false; draft = "" },
            onConfirm = { text ->
                composing = false
                draft = ""
                viewModel.addThought(current, text) {
                    draft = text
                    composing = true
                }
            },
            initial = draft,
        )
    }
}

/** 抽屉里的说明：这一笔会记到哪里 */
private fun thoughtHint(item: RevisitEntity): String = when {
    item.topicNoteId != null -> "会追加到之前为这一条建的专题笔记里。"
    item.kind == RevisitKind.SNIPPET.name && item.sourceLabel == RevisitRepository.DAILY_LABEL ->
        "这一句来自 Daily Note：会以它为底新建一篇专题笔记（引用原文），之后的想法都记在那一篇里。"
    else -> "会追加到原笔记的「想法」小节里。"
}

/** 卡片右下角的「记一笔」：橙色圆形图标按钮；保存中显示转圈并暂停点击 */
@Composable
private fun ThoughtFab(busy: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(52.dp)
            .shadow(6.dp, CircleShape, clip = false)
            .clip(CircleShape)
            .background(Brand.Orange)
            .clickable(enabled = !busy, role = Role.Button, onClickLabel = "记一笔", onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        if (busy) {
            CircularProgressIndicator(Modifier.size(22.dp), color = Brand.Brown, strokeWidth = 2.5.dp)
        } else {
            Icon(Icons.Filled.Add, contentDescription = "记一笔", tint = Brand.Brown, modifier = Modifier.size(26.dp))
        }
    }
}

/** 已经有专题笔记时的入口，在卡片左下角 */
@Composable
private fun TopicChip(onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .height(40.dp)
            .clip(CircleShape)
            .background(Brand.Orange.copy(alpha = 0.22f))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text("专题笔记 ›", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, color = Brand.OrangeDeep, maxLines = 1)
    }
}

// ───────────────────────── 顶部 ─────────────────────────

@Composable
private fun TopBar(
    today: RevisitToday,
    current: RevisitEntity?,
    canUndo: Boolean,
    cloze: Boolean,
    onToggleCloze: () -> Unit,
    onBack: () -> Unit,
    onUndo: () -> Unit,
    onSkip: () -> Unit,
    onArchive: () -> Unit,
    onOpenSource: () -> Unit,
    onPostponeAll: () -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    var menu by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(60.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        CircleIconButton(Icons.AutoMirrored.Filled.ArrowBack, "返回", onBack)
        Column(Modifier.weight(1f).padding(start = 4.dp)) {
            Text("重温", style = MaterialTheme.typography.headlineSmall, maxLines = 1)
            val total = today.doneToday + today.remaining
            if (current != null) {
                // 进度写短一点：出现「撤销」按钮时，标题栏也不会挤
                Text(
                    "第 ${today.doneToday + 1} / $total 条",
                    fontSize = 12.sp,
                    lineHeight = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = scheme.onSurfaceVariant,
                    maxLines = 1,
                    softWrap = false,
                )
            }
        }
        if (canUndo) UndoButton(onUndo)
        if (current != null) PillAction("今天跳过", onSkip)
        Box {
            CircleIconButton(Icons.Filled.MoreVert, "更多", { menu = true })
            AppMenu(expanded = menu, onDismissRequest = { menu = false }) {
                if (current != null) {
                    if (current.noteId != null) {
                        AppMenuItem(text = { Text("在笔记中打开") }, onClick = { menu = false; onOpenSource() })
                    }
                    AppMenuItem(
                        text = { Text(if (cloze) "关闭填空模式" else "开启填空模式") },
                        onClick = { menu = false; onToggleCloze() },
                    )
                    AppMenuItem(text = { Text("不再重温") }, destructive = true, onClick = { menu = false; onArchive() })
                    AppMenuDivider()
                }
                AppMenuItem(text = { Text("全部推后 7 天") }, onClick = { menu = false; onPostponeAll() })
            }
        }
    }
}

/** 撤销：只放一个图标，不再占一个文字胶囊的宽度 */
@Composable
private fun UndoButton(onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(40.dp)
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.surfaceContainerLowest)
            .clickable(role = Role.Button, onClickLabel = "撤销", onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(painterResource(R.drawable.ic_undo), contentDescription = "撤销", modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun PillAction(text: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .height(40.dp)
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.surfaceContainerLowest)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, maxLines = 1, softWrap = false)
    }
}

/** 进度：条数不多时分段（一段一条），多了就是一根连续的条 */
@Composable
private fun Segments(done: Int, total: Int) {
    val scheme = MaterialTheme.colorScheme
    val track = scheme.onSurface.copy(alpha = 0.10f)
    if (total <= 0) {
        Spacer(Modifier.height(4.dp))
        return
    }
    if (total > 12) {
        val progress by animateFloatAsState(done.toFloat() / total, tween(400), label = "progress")
        Box(Modifier.fillMaxWidth().height(4.dp).clip(CircleShape).background(track)) {
            Box(Modifier.fillMaxWidth(progress.coerceIn(0f, 1f)).height(4.dp).clip(CircleShape).background(Brand.Orange))
        }
        return
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        repeat(total) { i ->
            val color by animateColorAsState(
                when {
                    i < done -> Brand.Orange
                    i == done -> scheme.onSurface
                    else -> track
                },
                tween(300),
                label = "segment",
            )
            Box(Modifier.weight(1f).height(4.dp).clip(CircleShape).background(color))
        }
    }
}

// ───────────────────────── 卡片 ─────────────────────────

/** 阅读用的字号：比普通详情页略大一点，但不到「大字」的程度，一屏能放下更多 */
@Composable
private fun BigReading(content: @Composable () -> Unit) {
    val t = MaterialTheme.typography
    MaterialTheme(
        colorScheme = MaterialTheme.colorScheme,
        shapes = MaterialTheme.shapes,
        typography = t.copy(
            headlineSmall = t.headlineSmall.copy(fontSize = 19.sp, lineHeight = 27.sp),
            titleLarge = t.titleLarge.copy(fontSize = 18.sp, lineHeight = 26.sp),
            titleMedium = t.titleMedium.copy(fontSize = 16.sp, lineHeight = 24.sp),
            titleSmall = t.titleSmall.copy(fontSize = 15.sp, lineHeight = 22.sp),
            bodyLarge = t.bodyLarge.copy(fontSize = 16.sp, lineHeight = 26.sp),
            bodyMedium = t.bodyMedium.copy(fontSize = 15.sp, lineHeight = 24.sp),
            bodySmall = t.bodySmall.copy(fontSize = 13.sp, lineHeight = 19.sp),
        ),
        content = content,
    )
}

@Composable
private fun RevisitCard(item: RevisitEntity, cloze: Boolean) {
    val scheme = MaterialTheme.colorScheme
    val long = remember(item.id) { item.text.length > 200 || item.text.count { it == '\n' } > 5 }
    var expanded by remember(item.id) { mutableStateOf(!long) }
    val isNote = item.kind == RevisitKind.NOTE.name
    // 整篇笔记且正文和标题一样（短笔记）时不重复显示
    val showBody = !(isNote && item.text.trim() == item.title.trim())

    // 填空：每次重温（reps 不同）、点「换一批」（reroll 加一）自动挑的位置都会换
    var reroll by remember(item.id) { mutableIntStateOf(0) }
    val plain = remember(item.id, item.text, item.reps, reroll, cloze, showBody) {
        if (cloze && showBody) Cloze.build(item.text, item.id * 31L + item.reps * 7919L + reroll) else null
    }
    var revealed by remember(plain) { mutableStateOf(emptySet<Int>()) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .clip(RoundedCornerShape(28.dp))
            .background(scheme.surfaceContainerLowest)
            .verticalScroll(rememberScrollState())
            // 底部多留一块给右下角的「记一笔」，长内容滚到底也不会被它挡住
            .padding(start = 20.dp, end = 20.dp, top = 20.dp, bottom = 84.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            "${item.sourceLabel} · 记于 ${recordedText(item.recordedAt)}",
            style = MaterialTheme.typography.labelLarge,
            color = Brand.OrangeDeep,
            fontWeight = FontWeight.Bold,
        )
        Text(
            historyText(item),
            style = MaterialTheme.typography.labelMedium,
            color = scheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(10.dp))

        BigReading {
            if (isNote) {
                Text(
                    item.title,
                    style = MaterialTheme.typography.headlineSmall,
                    modifier = Modifier.padding(bottom = 8.dp),
                )
            } else if (item.title.isNotBlank()) {
                Text(
                    "摘自「${item.title}」",
                    style = MaterialTheme.typography.bodySmall,
                    color = scheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 6.dp),
                )
            }

            if (showBody) {
                if (plain != null) {
                    ClozeBar(
                        total = plain.blanks.size,
                        shown = revealed.size,
                        auto = plain.auto,
                        onToggleAll = {
                            revealed = if (revealed.size == plain.blanks.size) emptySet() else plain.blanks.indices.toSet()
                        },
                        onReroll = { reroll++ },
                    )
                    ClozeText(
                        plain = plain,
                        revealed = revealed,
                        onToggle = { i -> revealed = if (i in revealed) revealed - i else revealed + i },
                    )
                } else Box(Modifier.animateContentSize()) {
                    if (expanded) {
                        MarkdownText(item.text)
                    } else {
                        Box(Modifier.heightIn(max = COLLAPSED_HEIGHT).clipToBounds()) {
                            MarkdownText(item.text)
                        }
                        Box(
                            Modifier
                                .align(Alignment.BottomCenter)
                                .fillMaxWidth()
                                .height(56.dp)
                                .background(
                                    Brush.verticalGradient(listOf(Color.Transparent, scheme.surfaceContainerLowest)),
                                ),
                        )
                    }
                }
            }
        }

        if (!expanded && plain == null) {
            Box(
                modifier = Modifier
                    .padding(top = 4.dp)
                    .height(40.dp)
                    .clip(CircleShape)
                    .background(scheme.surfaceContainerHigh)
                    .clickable(role = Role.Button) { expanded = true }
                    .padding(horizontal = 18.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text("显示完整", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold)
            }
        }
    }
}

private val COLLAPSED_HEIGHT = 160.dp

private fun recordedText(ms: Long): String {
    val date = RevisitRepository.dateOf(ms)
    val today = LocalDate.now()
    val label = if (date.year == today.year) "${date.monthValue}月${date.dayOfMonth}日"
    else "${date.year}年${date.monthValue}月${date.dayOfMonth}日"
    val days = ChronoUnit.DAYS.between(date, today)
    return when {
        days <= 0 -> "$label（今天）"
        days < 60 -> "$label（$days 天前）"
        else -> label
    }
}

private fun historyText(item: RevisitEntity): String = when {
    item.reps == 0 -> "第一次重温"
    item.lapses > 0 -> "已重温 ${item.reps} 次 · 忘过 ${item.lapses} 次"
    else -> "已重温 ${item.reps} 次"
}

// ───────────────────────── 评分 ─────────────────────────

@Composable
private fun RatingBar(
    enabled: Boolean,
    daysOf: (Fsrs.Rating) -> Int,
    onRate: (Fsrs.Rating) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
        RateButton("忘了", intervalLabel(daysOf(Fsrs.Rating.AGAIN)), primary = false, enabled = enabled, modifier = Modifier.weight(1f)) {
            onRate(Fsrs.Rating.AGAIN)
        }
        RateButton("记得", intervalLabel(daysOf(Fsrs.Rating.GOOD)), primary = true, enabled = enabled, modifier = Modifier.weight(1.4f)) {
            onRate(Fsrs.Rating.GOOD)
        }
        RateButton("太简单", intervalLabel(daysOf(Fsrs.Rating.EASY)), primary = false, enabled = enabled, modifier = Modifier.weight(1f)) {
            onRate(Fsrs.Rating.EASY)
        }
    }
}

@Composable
private fun RateButton(
    label: String,
    hint: String,
    primary: Boolean,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.96f else 1f, tween(90), label = "press")
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(56.dp)
                .graphicsLayer { scaleX = scale; scaleY = scale }
                .clip(CircleShape)
                .background(if (primary) scheme.inverseSurface else scheme.surfaceContainerLowest)
                .clickable(interactionSource = source, indication = null, enabled = enabled, role = Role.Button, onClick = onClick),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                label,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.ExtraBold,
                color = if (primary) scheme.inverseOnSurface else scheme.onSurface,
            )
        }
        Text(hint, style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant, maxLines = 1)
    }
}

/** 1 → 明天；以后按「N 天后 / N 周后 / N 个月后 / N 年后」 */
private fun intervalLabel(days: Int): String = when {
    days <= 1 -> "明天"
    days < 14 -> "$days 天后"
    days < 60 -> "${days / 7} 周后"
    days < 365 -> "${days / 30} 个月后"
    else -> "${days / 365} 年后"
}

// ───────────────────────── 没有要重温的 ─────────────────────────

@Composable
private fun EmptyState(today: RevisitToday, onBack: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val finished = today.doneToday > 0
    val title = when {
        finished -> "今天的重温完成"
        today.total == 0 -> "还没有要重温的内容"
        else -> "今天没有要重温的"
    }
    val text = buildString {
        when {
            finished -> {
                append("今天重温了 ${today.doneToday} 条。")
                val backlog = today.dueTotal
                if (backlog > 0) append("还有 $backlog 条顺延到后面几天，不会一次性全抛出来。")
                else today.nextDue?.let { append("下一条在${nextDueText(it)}。") }
            }

            today.total == 0 ->
                append("在笔记页点右上角的循环图标，或在笔记里选中一段文字加入；给笔记打上 #重温 标签也会自动加入。")

            else -> today.nextDue?.let { append("下一条在${nextDueText(it)}。") } ?: append("之后到期的内容会按时出现。")
        }
    }
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            Modifier
                .size(72.dp)
                .clip(CircleShape)
                .background(if (finished) Brand.Orange else scheme.surfaceContainerHigh),
            contentAlignment = Alignment.Center,
        ) {
            if (finished) {
                Icon(Icons.Filled.Check, contentDescription = null, tint = Brand.Brown, modifier = Modifier.size(38.dp))
            } else {
                Icon(painterResource(R.drawable.ic_revisit), contentDescription = null, tint = scheme.onSurfaceVariant, modifier = Modifier.size(32.dp))
            }
        }
        Spacer(Modifier.height(18.dp))
        Text(title, style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
        if (text.isNotEmpty()) {
            Spacer(Modifier.height(6.dp))
            Text(
                text,
                style = MaterialTheme.typography.bodyMedium,
                color = scheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
        Spacer(Modifier.height(22.dp))
        Box(
            modifier = Modifier
                .height(48.dp)
                .clip(CircleShape)
                .background(scheme.inverseSurface)
                .clickable(role = Role.Button, onClick = onBack)
                .padding(horizontal = 28.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text("返回", style = MaterialTheme.typography.titleSmall, color = scheme.inverseOnSurface, fontWeight = FontWeight.ExtraBold)
        }
    }
}

private fun nextDueText(date: LocalDate): String {
    val days = ChronoUnit.DAYS.between(LocalDate.now(), date)
    return when {
        days <= 1 -> "明天"
        days < 14 -> "$days 天后（${date.monthValue}月${date.dayOfMonth}日）"
        else -> "${date.monthValue}月${date.dayOfMonth}日"
    }
}
