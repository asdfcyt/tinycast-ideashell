package com.carpe.ideashell.ui.review

import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalTextToolbar
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.data.ideashell.DailyEntry
import com.carpe.ideashell.data.ideashell.DailyFormat
import com.carpe.ideashell.data.ideashell.NoteInfo
import com.carpe.ideashell.data.ideashell.NoteTime
import com.carpe.ideashell.data.revisit.RevisitRepository
import com.carpe.ideashell.ui.theme.Brand
import kotlinx.coroutines.launch
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.res.painterResource
import com.carpe.ideashell.R
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.core.parse.TimeRanges
import com.carpe.ideashell.data.ideashell.NoteDetail
import com.carpe.ideashell.data.mcp.McpAuthException
import com.carpe.ideashell.system.openIdeaShellNote
import com.carpe.ideashell.ui.components.MarkdownText
import com.carpe.ideashell.ui.glass.GlassSurface
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import kotlinx.coroutines.CancellationException

/** 笔记全文页：只读，正文按 Markdown 渲染，可复制 / 分享；全文在内存里缓存，来回翻看不重复请求 */
@Composable
fun NoteDetailScreen(
    noteId: String,
    onBack: () -> Unit,
    /** 点标签：是项目就进项目页，不是就去搜索这个词 */
    onOpenTag: (String) -> Unit,
) {
    val context = LocalContext.current
    val container = (context.applicationContext as IdeashellApp).container
    val clipboard = LocalClipboardManager.current
    val snackbar = remember { SnackbarHostState() }
    var attempt by remember { mutableIntStateOf(0) }

    val state by produceState<Async<NoteDetail>>(Async(loading = true), noteId, attempt) {
        value = Async(loading = true)
        value = try {
            Async(data = container.notes.note(noteId, force = attempt > 0))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Async(
                error = if (e is McpAuthException) "闪念贝壳 API Key 无效或已失效" else (e.message ?: "加载失败"),
            )
        }
    }
    val note = state.data
    val scope = rememberCoroutineScope()

    // 加入重温：整篇（顶栏循环图标）/ 选中的一段（底部胶囊）。Daily Note 只支持选中一段，整篇不支持
    val revisitKeys by container.revisit.keys.collectAsStateWithLifecycle()
    val probe = rememberSelectionProbe()
    val isDaily = note != null && isDailyNote(note)
    val noteKey = RevisitRepository.noteKey(noteId)
    val inRevisit = noteKey in revisitKeys

    // 带 #重温 标签的笔记打开时自动加入
    LaunchedEffect(note?.id) {
        note?.let { runCatching { container.revisit.autoAddIfTagged(it) } }
    }

    fun toast(text: String, undo: (suspend () -> Unit)? = null) {
        scope.launch {
            snackbar.currentSnackbarData?.dismiss()
            val result = snackbar.showSnackbar(text, actionLabel = if (undo != null) "撤销" else null)
            if (result == SnackbarResult.ActionPerformed) undo?.invoke()
        }
    }

    fun toggleNoteRevisit(n: NoteDetail) {
        scope.launch {
            if (inRevisit) {
                container.revisit.setArchived(noteKey, true)
                toast("已移出重温") { container.revisit.setArchived(noteKey, false) }
            } else {
                val info = NoteInfo(id = n.id, title = n.title, summary = n.summary, tags = n.tags, createdAt = n.createdAt)
                container.revisit.addNote(info, n)
                toast("已加入重温 · 明天开始出现") { container.revisit.setArchived(noteKey, true) }
            }
        }
    }

    /** Daily Note 里的一条：一点就加入 / 移出重温 */
    fun toggleEntry(n: NoteDetail, entry: DailyEntry, inEntryRevisit: Boolean) {
        val key = RevisitRepository.snippetKey(n.id, entry.text)
        scope.launch {
            if (inEntryRevisit) {
                container.revisit.setArchived(key, true)
                toast("已移出重温") { container.revisit.setArchived(key, false) }
            } else {
                val date = runCatching { java.time.LocalDate.parse(n.title.trim()) }.getOrNull()
                val clock = runCatching { java.time.LocalTime.parse(entry.time) }.getOrDefault(java.time.LocalTime.NOON)
                container.revisit.addSnippet(
                    noteId = n.id,
                    noteTitle = n.title,
                    text = entry.text,
                    sourceLabel = "Daily Note",
                    recordedAt = date?.let { RevisitRepository.millisOf(it.atTime(clock)) },
                )
                toast("已加入重温 · 明天开始出现") { container.revisit.setArchived(key, true) }
            }
        }
    }

    fun addSelection(n: NoteDetail) {
        val copy = probe.copy ?: return
        // 借用「复制」拿到选中的文字，随后把剪贴板还原，不弄丢用户原来复制的东西
        val previous = clipboard.getText()
        copy()
        val picked = clipboard.getText()?.text?.trim().orEmpty()
        if (previous != null) clipboard.setText(previous)
        if (picked.isEmpty()) return
        scope.launch {
            val daily = isDailyNote(n)
            val recorded = if (daily) {
                runCatching { java.time.LocalDate.parse(n.title.trim()) }.getOrNull()
                    ?.let { RevisitRepository.startOfDay(it) }
            } else {
                NoteTime.parse(n.createdAt)?.toEpochMilli()
            }
            val result = container.revisit.addSnippet(
                noteId = n.id,
                noteTitle = n.title,
                text = picked,
                sourceLabel = if (daily) "Daily Note" else "摘录",
                recordedAt = recorded,
            )
            val key = RevisitRepository.snippetKey(n.id, picked)
            when (result) {
                com.carpe.ideashell.data.revisit.AddResult.EXISTS -> toast("这一段已经在重温里了")
                else -> toast("已把选中的这段加入重温 · 明天开始出现") { container.revisit.setArchived(key, true) }
            }
        }
    }

    var message by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(message) {
        message?.let {
            snackbar.showSnackbar(it)
            message = null
        }
    }

    CompositionLocalProvider(LocalTextToolbar provides probe.toolbar) {
    Box(Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.statusBars)
                .padding(horizontal = 16.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                RoundAction(Icons.AutoMirrored.Filled.ArrowBack, "返回", onBack)
                Spacer(Modifier.weight(1f))
                RoundAction(Icons.Filled.Refresh, "刷新") { attempt++ }
                if (note != null) {
                    if (!isDaily) {
                        RoundAction(
                            painterResource(R.drawable.ic_revisit),
                            if (inRevisit) "移出重温" else "加入重温",
                            active = inRevisit,
                        ) { toggleNoteRevisit(note) }
                    }
                    RoundAction(Icons.Filled.Share, "分享") {
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_SUBJECT, note.title)
                            putExtra(Intent.EXTRA_TEXT, noteAsMarkdown(note))
                        }
                        context.startActivity(Intent.createChooser(send, "分享笔记"))
                    }
                    // 跳到闪念贝壳 App 里的这条笔记（没装 / 打不开时退回网页版）
                    RoundAction(painterResource(R.drawable.ic_open_in_new), "在闪念贝壳中打开") { openIdeaShellNote(context, noteId) }
                }
            }

            Column(
                modifier = Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                when {
                    note != null -> {
                        NoteBody(
                            note = note,
                            onOpenTag = onOpenTag,
                            daily = isDaily,
                            revisitKeys = revisitKeys,
                            onToggleEntry = { entry, inRev -> toggleEntry(note, entry, inRev) },
                        )
                    }

                    state.error != null -> GlassSurface(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("没能打开这条笔记", style = MaterialTheme.typography.titleMedium)
                            Text(state.error.orEmpty(), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            OutlinedButton(onClick = { attempt++ }) { Text("重试") }
                        }
                    }

                    else -> Box(Modifier.fillMaxWidth().padding(vertical = 80.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator()
                    }
                }
                Spacer(Modifier.height(LocalBottomBarPadding.current + 8.dp))
            }
        }
        if (note != null) {
            RevisitSelectionPill(
                visible = probe.copy != null,
                bottomPadding = LocalBottomBarPadding.current + 8.dp,
                onClick = { addSelection(note) },
            )
        }
        SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).padding(bottom = LocalBottomBarPadding.current))
    }
    }
}

/** Daily Note：标题是日期（YYYY-MM-DD）或带 daily-note 标签 */
private fun isDailyNote(note: NoteDetail): Boolean =
    note.tags.any { it.equals("daily-note", ignoreCase = true) } ||
        Regex("^\\d{4}-\\d{2}-\\d{2}$").matches(note.title.trim())

@Composable
private fun NoteBody(
    note: NoteDetail,
    onOpenTag: (String) -> Unit,
    daily: Boolean,
    revisitKeys: Set<String>,
    onToggleEntry: (DailyEntry, Boolean) -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    Text(note.title.ifEmpty { "无标题" }, style = MaterialTheme.typography.headlineSmall)

    val whenText = note.localDate?.let { d ->
        "${TimeRanges.dayLabel(d)}${note.localClock?.let { " $it" }.orEmpty()}"
    }
    if (whenText != null) {
        Text(whenText, style = MaterialTheme.typography.labelLarge, color = scheme.onSurfaceVariant)
    }

    if (note.tags.isNotEmpty()) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            note.tags.take(6).forEach { tag ->
                GlassSurface(shape = CircleShape, elevated = false, tint = scheme.primary, onClick = { onOpenTag(tag) }) {
                    Text(
                        "#$tag",
                        style = MaterialTheme.typography.labelMedium,
                        color = scheme.primary,
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                    )
                }
            }
        }
    }

    val summary = note.summary
    // 短笔记的摘要和正文重复，不再多显示一遍
    if (summary != null && !note.content.startsWith(summary.trim())) {
        GlassSurface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(18.dp), elevated = false) {
            Text(
                "摘要　$summary",
                style = MaterialTheme.typography.bodyMedium,
                color = scheme.onSurfaceVariant,
                modifier = Modifier.padding(14.dp),
            )
        }
    }

    if (note.content.isBlank()) {
        Text(
            if (summary == null) "（空白笔记）" else "（正文只有语音或附件，没有文字）",
            style = MaterialTheme.typography.bodyMedium,
            color = scheme.onSurfaceVariant,
        )
    } else if (daily) {
        DailyBody(note, revisitKeys, onToggleEntry)
    } else {
        MarkdownText(note.content)
    }
}

/**
 * Daily Note 全文：条目以外的内容（今日简报等）照常渲染；每一条拆成一行，
 * 时间在上、文字在下，右侧一个循环按钮——一点就把这一条加入重温，已加入的变成橙色。
 */
@Composable
private fun DailyBody(note: NoteDetail, revisitKeys: Set<String>, onToggleEntry: (DailyEntry, Boolean) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val sections = remember(note.content) { DailyFormat.sections(note.content) }
    if (sections.other.isNotBlank()) MarkdownText(sections.other)
    Column {
        sections.entries.forEachIndexed { i, entry ->
            val inRevisit = RevisitRepository.snippetKey(note.id, entry.text) in revisitKeys
            if (i > 0) {
                androidx.compose.material3.HorizontalDivider(thickness = 0.5.dp, color = scheme.outline.copy(alpha = 0.35f))
            }
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        entry.time,
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = androidx.compose.ui.text.font.FontWeight.Black,
                        color = scheme.primary,
                    )
                    MarkdownText(entry.text)
                }
                Box(
                    modifier = Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(if (inRevisit) Brand.Orange else scheme.surfaceContainerHigh)
                        .clickable(role = Role.Button) { onToggleEntry(entry, inRevisit) },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        painterResource(R.drawable.ic_revisit),
                        contentDescription = if (inRevisit) "移出重温" else "加入重温",
                        tint = if (inRevisit) Brand.Brown else scheme.onSurfaceVariant,
                        modifier = Modifier.size(20.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun RoundAction(icon: androidx.compose.ui.graphics.vector.ImageVector, description: String, onClick: () -> Unit) {
    RoundAction(androidx.compose.ui.graphics.vector.rememberVectorPainter(icon), description, onClick = onClick)
}

@Composable
private fun RoundAction(
    icon: androidx.compose.ui.graphics.painter.Painter,
    description: String,
    active: Boolean = false,
    onClick: () -> Unit,
) {
    if (active) {
        // 已加入重温：橙色实心，一眼看出状态
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(CircleShape)
                .background(Brand.Orange)
                .clickable(role = Role.Button, onClick = onClick),
        ) {
            Icon(
                icon,
                contentDescription = description,
                tint = Brand.Brown,
                modifier = Modifier.align(Alignment.Center).size(22.dp),
            )
        }
        return
    }
    GlassSurface(modifier = Modifier.size(44.dp), shape = CircleShape, onClick = onClick) {
        Icon(
            icon,
            contentDescription = description,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.align(Alignment.Center).size(22.dp),
        )
    }
}

private fun noteAsMarkdown(note: NoteDetail): String =
    buildString {
        if (note.title.isNotEmpty()) append("# ").append(note.title).append("\n\n")
        append(note.content)
    }.trim()
