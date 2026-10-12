package com.carpe.ideashell.ui.capture

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import com.carpe.ideashell.ui.glass.GlassSurface
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
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
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.core.capture.ClipInput
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.core.parse.CaptureParser
import com.carpe.ideashell.ui.components.CaptureComposer
import com.carpe.ideashell.ui.components.InfoPill
import kotlinx.coroutines.delay

/** 轻量输入面板：半透明遮罩 + 从底部升起的卡片，键盘弹出时整体上移 */
@Composable
fun QuickCaptureScreen(
    viewModel: QuickCaptureViewModel,
    readClipboard: () -> String?,
    onClose: () -> Unit,
    onOpenApp: () -> Unit,
) {
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { visible = true }
    val scrim by animateFloatAsState(if (visible) 0.42f else 0f, tween(220), label = "scrim")
    val noRipple = remember { MutableInteractionSource() }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = scrim))
            .clickable(interactionSource = noRipple, indication = null, onClick = onClose),
    ) {
        AnimatedVisibility(
            visible = visible,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .imePadding(),
            enter = slideInVertically(tween(280)) { it } + fadeIn(tween(200)),
            exit = slideOutVertically(tween(200)) { it } + fadeOut(tween(160)),
        ) {
            val sheetShape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    // 吃掉点击，避免点到卡片时误触发「点遮罩关闭」
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
                    .clip(sheetShape)
                    .background(MaterialTheme.colorScheme.surfaceContainerLowest),
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .navigationBarsPadding()
                        .padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 12.dp),
                ) {
                    AnimatedContent(
                        targetState = viewModel.state,
                        transitionSpec = { fadeIn(tween(180)) togetherWith fadeOut(tween(120)) },
                        label = "quick-state",
                    ) { state ->
                        when (state) {
                            QuickState.Composing -> ComposingContent(viewModel, readClipboard, onOpenApp)
                            is QuickState.Saved -> SavedContent(state, viewModel, onClose)
                            QuickState.Undone -> UndoneContent(onClose)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ComposingContent(
    viewModel: QuickCaptureViewModel,
    readClipboard: () -> String?,
    onOpenApp: () -> Unit,
) {
    val connected by viewModel.connected.collectAsStateWithLifecycle()
    val folders by viewModel.folders.collectAsStateWithLifecycle()
    val clip = viewModel.clip
    val focus = remember { FocusRequester() }

    LaunchedEffect(connected) {
        if (connected) {
            delay(160)
            runCatching { focus.requestFocus() }
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (clip != null) {
            Text(
                text = "${clip.kindTag}到闪念",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        if (!connected) {
            NotConnected(onOpenApp)
            return@Column
        }

        if (clip != null) {
            ClipPreviewCard(clip)
            ClipAnnotation(
                text = viewModel.text,
                onTextChange = { viewModel.text = it },
                folders = folders.map { it.name },
                kindTag = clip.kindTag,
                focusRequester = focus,
                onSubmit = { viewModel.submit(readClipboard) },
            )
        } else {
            CaptureComposer(
                text = viewModel.text,
                onTextChange = { viewModel.text = it },
                override = viewModel.override,
                onOverrideChange = { viewModel.override = it },
                folders = folders,
                onSubmit = { viewModel.submit(readClipboard) },
                focusRequester = focus,
                minLines = 2,
            )
        }

        viewModel.error?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
private fun NotConnected(onOpenApp: () -> Unit) {
    GlassSurface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        tint = MaterialTheme.colorScheme.onSurfaceVariant,
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("还没有连接闪念贝壳", style = MaterialTheme.typography.titleSmall)
            Text(
                "先在 App 里填好 API Key，之后从这里就能一步记下。",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Button(onClick = onOpenApp) { Text("去连接") }
        }
    }
}

/** 被分享 / 选中的内容预览：左侧强调条 + 来源 + 标题 + 摘要 */
@Composable
private fun ClipPreviewCard(clip: ClipInput) {
    GlassSurface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        tint = MaterialTheme.colorScheme.onSurfaceVariant,
    ) {
        Row(Modifier.height(IntrinsicSize.Min)) {
            Box(
                Modifier
                    .width(4.dp)
                    .fillMaxHeight()
                    .background(MaterialTheme.colorScheme.primary),
            )
            Column(
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                clip.appName?.takeIf { it.isNotBlank() }?.let {
                    Text(
                        "来自 $it",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
                clip.pageTitle?.takeIf { it.isNotBlank() }?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.titleSmall,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (clip.quote.isNotBlank()) {
                    Text(
                        clip.quote,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 5,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                clip.url?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

/** 摘录 / 收藏的批注框：可选，支持 #标签 和 @文件夹 */
@Composable
private fun ClipAnnotation(
    text: String,
    onTextChange: (String) -> Unit,
    folders: List<String>,
    kindTag: String,
    focusRequester: FocusRequester,
    onSubmit: () -> Unit,
) {
    val analysis = remember(text) { CaptureParser.analyze(text) }

    GlassSurface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        tint = MaterialTheme.colorScheme.onSurfaceVariant,
    ) {
        Column(Modifier.padding(start = 8.dp, end = 12.dp, top = 4.dp, bottom = 12.dp)) {
            TextField(
                value = text,
                onValueChange = onTextChange,
                modifier = Modifier
                    .fillMaxWidth()
                    .focusRequester(focusRequester),
                placeholder = {
                    Text(
                        "写点批注（可选）  #标签  @文件夹",
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.65f),
                    )
                },
                minLines = 1,
                maxLines = 4,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                    disabledContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                    disabledIndicatorColor = Color.Transparent,
                ),
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Row(
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = 12.dp)
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    InfoPill(text = kindTag, container = MaterialTheme.colorScheme.secondaryContainer, content = MaterialTheme.colorScheme.onSecondaryContainer)
                    analysis.folderName?.let { name ->
                        val hit = folders.any { it.equals(name, ignoreCase = true) }
                        InfoPill(text = "$name${if (hit) "" else "（新建）"}")
                    }
                    analysis.tags.forEach { InfoPill(text = "#$it") }
                }
                Spacer(Modifier.width(8.dp))
                com.carpe.ideashell.ui.components.SendButton(onClick = onSubmit, enabled = true)
            }
        }
    }
}

@Composable
private fun SavedContent(state: QuickState.Saved, viewModel: QuickCaptureViewModel, onClose: () -> Unit) {
    val haptic = LocalHapticFeedback.current
    var shown by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(
        targetValue = if (shown) 1f else 0.4f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioMediumBouncy, stiffness = Spring.StiffnessMedium),
        label = "check-scale",
    )

    LaunchedEffect(Unit) {
        shown = true
        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
        delay(2800)
        onClose()
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Surface(
            modifier = Modifier
                .size(56.dp)
                .graphicsLayer {
                    scaleX = scale
                    scaleY = scale
                },
            shape = CircleShape,
            color = MaterialTheme.colorScheme.primaryContainer,
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    Icons.Filled.Check,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onPrimaryContainer,
                    modifier = Modifier.size(30.dp),
                )
            }
        }
        Spacer(Modifier.height(4.dp))
        Text("已保存", style = MaterialTheme.typography.titleLarge)
        Text(
            state.receipt.summary,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            state.receipt.detail,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        viewModel.error?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        }
        TextButton(onClick = { viewModel.undo() }) { Text("撤销") }
    }
}

@Composable
private fun UndoneContent(onClose: () -> Unit) {
    LaunchedEffect(Unit) {
        delay(800)
        onClose()
    }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("已撤销", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
