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
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.core.parse.TimeRanges
import com.carpe.ideashell.data.ideashell.NoteDetail
import com.carpe.ideashell.data.mcp.McpAuthException
import com.carpe.ideashell.ui.components.MarkdownText
import com.carpe.ideashell.ui.glass.GlassSurface
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import kotlinx.coroutines.CancellationException

/** 笔记全文页：只读，正文按 Markdown 渲染，可复制 / 分享；全文在内存里缓存，来回翻看不重复请求 */
@Composable
fun NoteDetailScreen(
    noteId: String,
    onBack: () -> Unit,
    /** 点标签 / 「看档案」时跳到该关键词的档案 */
    onOpenDossier: (String) -> Unit,
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

    var message by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(message) {
        message?.let {
            snackbar.showSnackbar(it)
            message = null
        }
    }

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
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                RoundAction(Icons.AutoMirrored.Filled.ArrowBack, "返回", onBack)
                Spacer(Modifier.weight(1f))
                if (note != null) {
                    PillAction("复制") {
                        clipboard.setText(AnnotatedString(noteAsMarkdown(note)))
                        message = "已复制全文"
                    }
                    RoundAction(Icons.Filled.Share, "分享") {
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_SUBJECT, note.title)
                            putExtra(Intent.EXTRA_TEXT, noteAsMarkdown(note))
                        }
                        context.startActivity(Intent.createChooser(send, "分享笔记"))
                    }
                }
                RoundAction(Icons.Filled.Refresh, "刷新") { attempt++ }
            }

            Column(
                modifier = Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                when {
                    note != null -> NoteBody(note, onOpenDossier)

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
        SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).padding(bottom = LocalBottomBarPadding.current))
    }
}

@Composable
private fun NoteBody(note: NoteDetail, onOpenDossier: (String) -> Unit) {
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
                GlassSurface(shape = CircleShape, elevated = false, tint = scheme.primary, onClick = { onOpenDossier(tag) }) {
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
    } else {
        MarkdownText(note.content)
    }
}

@Composable
private fun PillAction(text: String, onClick: () -> Unit) {
    GlassSurface(modifier = Modifier.height(44.dp), shape = CircleShape, onClick = onClick) {
        Text(
            text,
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.align(Alignment.Center).padding(horizontal = 16.dp),
        )
    }
}

@Composable
private fun RoundAction(icon: androidx.compose.ui.graphics.vector.ImageVector, description: String, onClick: () -> Unit) {
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
