package com.carpe.ideashell.ui.focus

import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.ui.theme.ApplyEdgeToEdge
import com.carpe.ideashell.ui.theme.Brand
import com.carpe.ideashell.ui.theme.IdeashellTheme
import com.carpe.ideashell.ui.theme.isDark
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/**
 * 专注通知上的「记录」：弹一个小输入面板，写下专注过程中关于当前任务的内容。
 * 第一次记录时在闪念贝壳里为该任务创建任务笔记，之后每条都追加到笔记的「进展记录」，并同步成滴答任务评论。
 * 保存后马上关闭，写入在后台完成；失败会用一条通知带上原文，不会白写。
 */
class FocusRecordActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val container = (application as IdeashellApp).container
        val run = container.focus.session.value
        val taskId = run?.taskId
        if (run == null || run.kind.isBreak || taskId.isNullOrBlank()) {
            Toast.makeText(this, "当前没有绑定任务的专注", Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        val taskTitle = TodoMeta.cleanTitle(run.title).ifBlank { run.title }

        setContent {
            val settings by container.settings.state.collectAsStateWithLifecycle()
            IdeashellTheme(settings.themeMode) {
                ApplyEdgeToEdge(isDark(settings.themeMode))
                RecordPanel(
                    taskTitle = taskTitle,
                    onClose = { finish() },
                    onSubmit = { text ->
                        container.appScope.launch {
                            try {
                                val synced = container.projects.recordForTask(taskId, text)
                                val brief = text.take(24) + (if (text.length > 24) "…" else "")
                                container.focus.refreshNotification("已记录：" + brief + (if (synced) "" else "（滴答评论未同步）"))
                            } catch (e: CancellationException) {
                                throw e
                            } catch (e: Exception) {
                                container.focus.notifier.showRecordResult("记录失败", "${e.message ?: "未知错误"}\n\n你写的内容：$text")
                            }
                        }
                        Toast.makeText(this, "已记录到任务笔记", Toast.LENGTH_SHORT).show()
                        finish()
                    },
                )
            }
        }
    }

    override fun finish() {
        super.finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}

@Composable
private fun RecordPanel(taskTitle: String, onClose: () -> Unit, onSubmit: (String) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    var text by remember { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    val canSave = text.isNotBlank()

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.32f))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onClose),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .imePadding()
                .navigationBarsPadding()
                .padding(12.dp)
                .clip(RoundedCornerShape(28.dp))
                .background(scheme.surface)
                // 点面板本身不关闭
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = {})
                .padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("记录到任务", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = scheme.onSurfaceVariant)
            Text(taskTitle, style = MaterialTheme.typography.titleMedium, maxLines = 1)
            BasicTextField(
                value = text,
                onValueChange = { text = it },
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = scheme.onSurface),
                cursorBrush = SolidColor(scheme.primary),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 96.dp, max = 200.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(scheme.onSurface.copy(alpha = 0.06f))
                    .padding(14.dp)
                    .focusRequester(focus),
                decorationBox = { inner ->
                    Box {
                        if (text.isEmpty()) {
                            Text("专注时的想法、进展、卡点…", style = MaterialTheme.typography.bodyLarge, color = scheme.onSurfaceVariant)
                        }
                        inner()
                    }
                },
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End)) {
                Box(
                    modifier = Modifier
                        .height(44.dp)
                        .clip(CircleShape)
                        .background(scheme.surfaceContainerHigh)
                        .clickable(role = Role.Button, onClick = onClose)
                        .padding(horizontal = 22.dp),
                    contentAlignment = Alignment.Center,
                ) { Text("取消", fontWeight = FontWeight.Bold) }
                Box(
                    modifier = Modifier
                        .height(44.dp)
                        .clip(CircleShape)
                        .background(if (canSave) Brand.Orange else scheme.onSurface.copy(alpha = 0.12f))
                        .clickable(enabled = canSave, role = Role.Button, onClick = { onSubmit(text.trim()) })
                        .padding(horizontal = 26.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("记录", fontWeight = FontWeight.ExtraBold, color = if (canSave) Brand.Brown else scheme.onSurfaceVariant)
                }
            }
        }
    }
}
