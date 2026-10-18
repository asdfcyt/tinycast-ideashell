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
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.ui.theme.ApplyEdgeToEdge
import com.carpe.ideashell.ui.theme.Brand
import com.carpe.ideashell.ui.theme.IdeashellTheme
import com.carpe.ideashell.ui.theme.isDark
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import com.carpe.ideashell.R
import com.carpe.ideashell.data.capture.CaptureImages
import com.carpe.ideashell.ui.capture.CameraCaptureContract
import com.carpe.ideashell.ui.components.SubmitCorner
import com.carpe.ideashell.ui.components.ToolIcon
import com.carpe.ideashell.ui.glass.SheetBlurBehind
import com.carpe.ideashell.ui.glass.isDarkSurface
import com.carpe.ideashell.ui.glass.rememberCrossWindowBlur
import kotlinx.coroutines.delay
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
        val project = run?.project
        if (run == null || run.kind.isBreak || (taskId.isNullOrBlank() && project.isNullOrBlank())) {
            Toast.makeText(this, "当前没有绑定任务或项目的专注", Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        val taskTitle = TodoMeta.cleanTitle(run.title).ifBlank { run.title }
        val target = if (taskId.isNullOrBlank()) "记录到项目" else "记录到任务"
        val saved = when {
            taskId.isNullOrBlank() -> "已记录到「$project」的里程碑与进展"
            project.isNullOrBlank() -> "已记录到任务笔记"
            else -> "已记录到任务笔记和「$project」的里程碑"
        }

        // 写到一半被点到外面 / 返回键关掉时，文字存在本机，下次从通知点「记录」自动放回来；提交后清掉
        val prefs = getSharedPreferences("focus_record_draft", MODE_PRIVATE)
        val draftKey = "draft:" + (taskId?.takeIf { it.isNotBlank() } ?: ("project:" + project.orEmpty()))
        val initial = prefs.getString(draftKey, "").orEmpty()

        setContent {
            val settings by container.settings.state.collectAsStateWithLifecycle()
            IdeashellTheme(settings.themeMode) {
                ApplyEdgeToEdge(isDark(settings.themeMode))
                RecordPanel(
                    heading = target,
                    taskTitle = taskTitle,
                    initial = initial,
                    onTextChange = { t -> if (t.isBlank()) prefs.edit().remove(draftKey).apply() else prefs.edit().putString(draftKey, t).apply() },
                    onClose = { finish() },
                    onSubmit = { text ->
                        prefs.edit().remove(draftKey).apply()
                        container.appScope.launch {
                            try {
                                val synced = container.projects.recordFocus(taskId, project, text)
                                container.focus.addRecord(text)
                                // 刷新通知时不再往正文里塞「已记录：…」：它让这一次刷新和每分钟的心跳不一样，
                                // 荣耀 MagicOS 会把它当成新提醒弹开并追问「不允许 / 始终允许」。
                                // 记录成功已有 Toast 和进度条上新增的记录点；评论没同步的情况改用 Toast 说明
                                container.focus.refreshNotification(null)
                                if (!synced) {
                                    android.os.Handler(android.os.Looper.getMainLooper()).post {
                                        Toast.makeText(applicationContext, "滴答评论没能同步，已保存在任务笔记里", Toast.LENGTH_LONG).show()
                                    }
                                }
                            } catch (e: CancellationException) {
                                throw e
                            } catch (e: Exception) {
                                container.focus.notifier.showRecordResult("记录失败", "${e.message ?: "未知错误"}\n\n你写的内容：$text")
                            }
                        }
                        Toast.makeText(this, saved, Toast.LENGTH_SHORT).show()
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
private fun RecordPanel(
    heading: String,
    taskTitle: String,
    initial: String,
    onTextChange: (String) -> Unit,
    onClose: () -> Unit,
    onSubmit: (String) -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    val context = LocalContext.current
    var field by remember { mutableStateOf(TextFieldValue(initial, TextRange(initial.length))) }
    val text = field.text
    val focus = remember { FocusRequester() }
    val canSave = text.isNotBlank()

    // 和快记面板一样的样式与相机入口：半透明遮罩 + 从底部升起的卡片，键盘弹出时整体上移
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        visible = true
        delay(160)
        runCatching { focus.requestFocus() }
    }
    val scrim by animateFloatAsState(if (visible) 0.5f else 0f, tween(220), label = "scrim")

    // 拍照 / 相册 → 文字识别：只要识别出的文字，追加到输入框末尾（已有内容另起一行）；-1 表示相机页不收图片
    val cameraLauncher = rememberLauncherForActivityResult(CameraCaptureContract()) { result ->
        if (result == null) return@rememberLauncherForActivityResult
        CaptureImages.delete(result.images)
        val recognized = result.text
        if (recognized == null) {
            Toast.makeText(context, "没有识别出文字", Toast.LENGTH_SHORT).show()
        } else {
            val merged = if (text.isBlank()) recognized else text.trimEnd() + "\n" + recognized
            field = TextFieldValue(merged, TextRange(merged.length))
            onTextChange(merged)
        }
        runCatching { focus.requestFocus() }
    }

    // 玻璃：面半透明 + 整个窗口背后磨砂（和快记、摘录面板一致）；系统不允许跨窗口模糊时保持实心
    val blurOk = rememberCrossWindowBlur()
    if (blurOk && visible) SheetBlurBehind()
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = if (blurOk) scrim * 0.6f else scrim))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onClose),
    ) {
        AnimatedVisibility(
            visible = visible,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .imePadding(),
            enter = slideInVertically(tween(280)) { it } + fadeIn(tween(200)),
            exit = slideOutVertically(tween(200)) { it } + fadeOut(tween(160)),
        ) {
            Box(
                modifier = Modifier
                    .padding(start = 8.dp, end = 8.dp, bottom = 8.dp)
                    .navigationBarsPadding()
                    .fillMaxWidth()
                    // 吃掉点击，避免点到卡片时误触发「点遮罩关闭」
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
                    .clip(RoundedCornerShape(28.dp))
                    .background(
                        scheme.surfaceContainerLowest.copy(alpha = if (blurOk) (if (isDarkSurface()) 0.80f else 0.84f) else 1f),
                    ),
            ) {
                Column(Modifier.fillMaxWidth().padding(top = 4.dp, bottom = 4.dp)) {
                    Column(
                        modifier = Modifier.padding(start = 20.dp, end = 64.dp, top = 14.dp),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        Text(heading, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = scheme.onSurfaceVariant)
                        Text(taskTitle, style = MaterialTheme.typography.titleMedium, maxLines = 1)
                    }
                    val inputStyle = MaterialTheme.typography.bodyLarge.copy(fontSize = 17.sp, lineHeight = 24.sp)
                    TextField(
                        value = field,
                        onValueChange = { field = it; onTextChange(it.text) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .focusRequester(focus),
                        placeholder = {
                            Text("专注时的想法、进展、卡点…", style = inputStyle, color = scheme.outline.copy(alpha = 0.6f))
                        },
                        textStyle = inputStyle,
                        minLines = 2,
                        maxLines = 8,
                        // 键盘右下角的按键就是「发送」，和快记面板一致
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Send),
                        keyboardActions = KeyboardActions(onSend = { if (canSave) onSubmit(text.trim()) }),
                        colors = TextFieldDefaults.colors(
                            focusedContainerColor = Color.Transparent,
                            unfocusedContainerColor = Color.Transparent,
                            disabledContainerColor = Color.Transparent,
                            focusedIndicatorColor = Color.Transparent,
                            unfocusedIndicatorColor = Color.Transparent,
                            disabledIndicatorColor = Color.Transparent,
                        ),
                    )
                    Row(
                        modifier = Modifier.padding(start = 4.dp, end = 8.dp, top = 2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        ToolIcon(R.drawable.ic_camera, "拍照、相册与文字识别", { cameraLauncher.launch(-1) })
                    }
                }
                SubmitCorner(
                    enabled = canSave,
                    onClick = { onSubmit(text.trim()) },
                    modifier = Modifier.align(Alignment.TopEnd),
                )
            }
        }
    }
}
