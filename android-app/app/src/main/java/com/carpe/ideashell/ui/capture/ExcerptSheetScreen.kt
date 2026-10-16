package com.carpe.ideashell.ui.capture

import com.carpe.ideashell.ui.glass.BlurBehindWindow
import com.carpe.ideashell.ui.glass.isDarkSurface
import com.carpe.ideashell.ui.glass.rememberCrossWindowBlur
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.activity.compose.BackHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.carpe.ideashell.ui.components.SubmitCorner
import com.carpe.ideashell.ui.glass.GlassSurface

/** 摘录抽屉：遮罩 + 从底部升起的卡片（摘录原文、想法、来源、标签），键盘弹出时整体上移 */
@Composable
fun ExcerptSheetScreen(
    quote: String,
    appName: String,
    initialSource: String,
    initialTags: String,
    initialThought: String,
    initialAppend: Boolean,
    onSave: (source: String, tags: String, thought: String, append: Boolean) -> Unit,
    /** 点遮罩 / 返回键放弃：带上已写的内容，由调用方暂存成草稿 */
    onClose: (source: String, tags: String, thought: String, append: Boolean) -> Unit,
) {
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { visible = true }
    val scrim by animateFloatAsState(if (visible) 0.5f else 0f, tween(220), label = "scrim")
    val noRipple = remember { MutableInteractionSource() }
    var thought by rememberSaveable { mutableStateOf(initialThought) }
    var source by rememberSaveable { mutableStateOf(initialSource) }
    var tags by rememberSaveable { mutableStateOf(initialTags) }
    var append by rememberSaveable { mutableStateOf(initialAppend) }
    val send = { onSave(source, tags, thought, append) }
    val dismiss = { onClose(source, tags, thought, append) }
    // 返回键（键盘收起之后的那一下）和点遮罩一样：放弃，但想法暂存
    BackHandler(onBack = dismiss)
    val focus = remember { FocusRequester() }
    LaunchedEffect(visible) { if (visible) runCatching { focus.requestFocus() } }

    // 玻璃：面半透明 + 整个窗口背后磨砂；系统不允许跨窗口模糊时保持实心
    val blurOk = rememberCrossWindowBlur()
    if (blurOk && visible) BlurBehindWindow(radiusPx = com.carpe.ideashell.ui.glass.SheetBlurPx)
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = if (blurOk) scrim * 0.6f else scrim))
            .clickable(interactionSource = noRipple, indication = null, onClick = dismiss),
    ) {
        AnimatedVisibility(
            visible = visible,
            modifier = Modifier.align(Alignment.BottomCenter).imePadding(),
            enter = slideInVertically(tween(280)) { it } + fadeIn(tween(200)),
            exit = slideOutVertically(tween(200)) { it } + fadeOut(tween(160)),
        ) {
            Column(Modifier.padding(start = 8.dp, end = 8.dp, bottom = 8.dp)) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
                        .clip(RoundedCornerShape(28.dp))
                        .background(
                            MaterialTheme.colorScheme.surfaceContainerLowest.copy(alpha = if (blurOk) (if (isDarkSurface()) 0.80f else 0.84f) else 1f),
                        ),
                ) {
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 12.dp, bottom = 12.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        // 来源 / 标签：紧凑的一行放在最上面（右边留给保存键）
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(end = 52.dp),
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            CompactField(
                                value = source,
                                onChange = { source = it },
                                label = "标题",
                                placeholder = "书名 / 文章标题",
                                modifier = Modifier.weight(1.25f),
                                onSend = send,
                            )
                            CompactField(
                                value = tags,
                                onChange = { tags = it },
                                label = "#",
                                placeholder = "标签",
                                modifier = Modifier.weight(1f),
                                onSend = send,
                            )
                            AppendToggle(append = append, onToggle = { append = !append })
                        }
                        QuoteCard(quote)
                        Field(
                            value = thought,
                            onChange = { thought = it },
                            placeholder = "写下你的想法（可选）",
                            minLines = 2,
                            maxLines = 5,
                            modifier = Modifier.focusRequester(focus),
                            onSend = send,
                        )
                    }
                    SubmitCorner(
                        enabled = true,
                        onClick = send,
                        modifier = Modifier.align(Alignment.TopEnd),
                    )
                }
            }
        }
    }
}

@Composable
private fun QuoteCard(quote: String) {
    GlassSurface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        tint = MaterialTheme.colorScheme.onSurfaceVariant,
    ) {
        Row(Modifier.height(IntrinsicSize.Min)) {
            Box(Modifier.width(4.dp).fillMaxHeight().background(MaterialTheme.colorScheme.primary))
            Text(
                quote,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 4,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            )
        }
    }
}

@Composable
private fun Field(
    value: String,
    onChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    label: String? = null,
    singleLine: Boolean = false,
    minLines: Int = 1,
    maxLines: Int = 1,
    onSend: () -> Unit = {},
) {
    GlassSurface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        tint = MaterialTheme.colorScheme.onSurfaceVariant,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (label != null) {
                Text(
                    label,
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 16.dp),
                )
            }
            TextField(
                value = value,
                onValueChange = onChange,
                modifier = modifier.fillMaxWidth().onPreviewKeyEvent { e ->
                    // 实体键盘 / 部分输入法的回车是按键事件：回车 = 发送，Shift + 回车才换行
                    if (e.key == Key.Enter && !e.isShiftPressed) {
                        if (e.type == KeyEventType.KeyDown) onSend()
                        true
                    } else {
                        false
                    }
                },
                placeholder = {
                    Text(placeholder, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.65f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                },
                textStyle = MaterialTheme.typography.bodyLarge.copy(fontSize = 16.sp),
                singleLine = singleLine,
                minLines = minLines,
                maxLines = if (singleLine) 1 else maxLines,
                // 键盘的回车键是「发送」，不是换行
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { onSend() }),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                    disabledContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                    disabledIndicatorColor = Color.Transparent,
                ),
            )
        }
    }
}

/** 紧凑的单行小输入框：胶囊底，左边一个小标签（「来源」/「#」），文字 14sp */
@Composable
private fun CompactField(
    value: String,
    onChange: (String) -> Unit,
    label: String,
    placeholder: String,
    modifier: Modifier = Modifier,
    onSend: () -> Unit = {},
) {
    val scheme = MaterialTheme.colorScheme
    BasicTextField(
        value = value,
        onValueChange = { onChange(it.replace('\n', ' ')) },
        modifier = modifier,
        singleLine = true,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
        keyboardActions = KeyboardActions(onSend = { onSend() }),
        textStyle = MaterialTheme.typography.bodyMedium.copy(fontSize = 14.sp, color = scheme.onSurface),
        cursorBrush = SolidColor(scheme.primary),
        decorationBox = { inner ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(36.dp)
                    .clip(CircleShape)
                    .background(scheme.surfaceContainerHigh)
                    .padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    label,
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Bold,
                    color = scheme.primary,
                )
                Box(Modifier.padding(start = 6.dp).weight(1f), contentAlignment = Alignment.CenterStart) {
                    if (value.isEmpty()) {
                        Text(
                            placeholder,
                            fontSize = 14.sp,
                            color = scheme.onSurfaceVariant.copy(alpha = 0.6f),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    inner()
                }
            }
        },
    )
}

/** 「追加 / 新建」开关：开 = 接着同一来源上一篇写（橙色），关 = 这条另起一篇 */
@Composable
private fun AppendToggle(append: Boolean, onToggle: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Box(
        modifier = Modifier
            .height(36.dp)
            .clip(CircleShape)
            .background(if (append) scheme.primary else scheme.surfaceContainerHigh)
            .clickable(role = Role.Switch, onClick = onToggle)
            .semantics { contentDescription = if (append) "追加进同一篇，点一下改为新建" else "新建一篇，点一下改为追加" }
            .padding(horizontal = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            if (append) "追加" else "新建",
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.Bold,
            color = if (append) scheme.onPrimary else scheme.onSurfaceVariant,
        )
    }
}
