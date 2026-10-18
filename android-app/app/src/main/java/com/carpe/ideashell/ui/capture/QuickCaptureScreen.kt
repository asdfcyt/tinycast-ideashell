package com.carpe.ideashell.ui.capture

import com.carpe.ideashell.ui.glass.GlassButton
import androidx.compose.ui.graphics.Brush
import androidx.compose.foundation.border
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.ui.platform.LocalContext
import com.carpe.ideashell.system.IdeashellBridge
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.sp
import com.carpe.ideashell.R
import com.carpe.ideashell.data.capture.CaptureImages
import com.carpe.ideashell.ui.components.KIND_CHOICES
import com.carpe.ideashell.ui.components.kindIcon
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
import com.carpe.ideashell.ui.glass.glassButton
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
import androidx.compose.foundation.layout.widthIn
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
import com.carpe.ideashell.ui.home.TemplateSheet
import com.carpe.ideashell.ui.components.SubmitCorner
import com.carpe.ideashell.ui.components.resolveKind
import com.carpe.ideashell.ui.components.InfoPill
import com.carpe.ideashell.ui.glass.BlurBehindWindow
import com.carpe.ideashell.ui.glass.isDarkSurface
import com.carpe.ideashell.ui.glass.rememberCrossWindowBlur
import com.carpe.ideashell.ui.theme.Brand
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
    val scrim by animateFloatAsState(if (visible) 0.5f else 0f, tween(220), label = "scrim")
    val noRipple = remember { MutableInteractionSource() }
    val context = LocalContext.current
    val connected by viewModel.connected.collectAsStateWithLifecycle()
    val folders by viewModel.folders.collectAsStateWithLifecycle()
    // 按当前输入会保存成哪种类型：上方圆形图标据此高亮（自动识别成什么就亮哪个）
    val hasImages = viewModel.images.isNotEmpty()
    // 追加开着：一律是笔记
    val resolvedKind = remember(viewModel.text, viewModel.override, folders, hasImages, viewModel.schedule, viewModel.append) {
        resolveKind(viewModel.text, if (viewModel.append) CaptureKind.NOTE else viewModel.override, folders, hasImages, viewModel.schedule)
    }
    val canSubmit = viewModel.clip != null || resolvedKind != null || viewModel.voiceItems.isNotEmpty()
    val composing = connected && viewModel.state == QuickState.Composing

    val haptic = LocalHapticFeedback.current
    val saved = viewModel.state as? QuickState.Saved
    LaunchedEffect(saved) {
        if (saved != null) {
            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
            Toast.makeText(context, "已保存 · ${saved.receipt.detail}", Toast.LENGTH_SHORT).show()
            onClose()
        }
    }

    // 相机、相册、文字识别合成一个入口：全屏相机页（左下相册 / 中间快门 / 右下识别文字），识别出的文字追加到输入框
    val cameraLauncher = rememberLauncherForActivityResult(CameraCaptureContract()) { result ->
        if (result != null) viewModel.applyCameraResult(result)
    }
    val openCamera = {
        cameraLauncher.launch((CaptureImages.MAX_COUNT - viewModel.images.size).coerceAtLeast(0))
    }
    // 快速设置磁贴「语音记一条」：面板就绪后直接开始录音（锁定模式，说完点「完成」）
    val micPermission = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            if (viewModel.voice.start()) viewModel.voice.lock()
        } else {
            Toast.makeText(context, "没有麦克风权限，无法语音输入", Toast.LENGTH_SHORT).show()
        }
    }
    LaunchedEffect(viewModel.voiceStartRequest, composing) {
        if (viewModel.voiceStartRequest && composing) {
            viewModel.voiceStartRequest = false
            val granted = androidx.core.content.ContextCompat.checkSelfPermission(
                context, android.Manifest.permission.RECORD_AUDIO,
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
            if (granted) {
                if (viewModel.voice.start()) viewModel.voice.lock()
            } else {
                micPermission.launch(android.Manifest.permission.RECORD_AUDIO)
            }
        }
    }
    // 语音里说了「帮我查一下…」：把整理好的问题交给闪念贝壳 AI（尽量自动发送）；转交失败就把问题放进输入框，不丢
    LaunchedEffect(viewModel.askRequest) {
        val question = viewModel.askRequest ?: return@LaunchedEffect
        viewModel.askRequest = null
        if (IdeashellBridge.askAi(context, question, preferAutoSend = true)) {
            onClose()
        } else {
            viewModel.text = if (viewModel.text.isBlank()) question else viewModel.text.trimEnd() + "\n" + question
        }
    }
    // 闪念贝壳的语音录音 / AI：交给它的 App 处理，这里收起面板；问 AI 会把已写的文字带过去，成功转交后清空输入
    val bridgeContext = LocalContext.current
    val openVoice = {
        if (IdeashellBridge.startVoiceRecording(bridgeContext)) onClose()
    }
    val openAskAi = {
        if (IdeashellBridge.askAi(bridgeContext, viewModel.text)) {
            viewModel.text = ""
            onClose()
        }
    }

    // 玻璃：面半透明 + 整个窗口背后磨砂；系统不允许跨窗口模糊时保持实心
    val blurOk = rememberCrossWindowBlur()
    if (blurOk && visible) com.carpe.ideashell.ui.glass.SheetBlurBehind()
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = if (blurOk) scrim * 0.6f else scrim))
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
            val sheetShape = RoundedCornerShape(28.dp)
            Column(Modifier.padding(start = 8.dp, end = 8.dp, bottom = 8.dp)) {
                // 类型选择浮在面板上方（对标滴答清单的「任务 / 笔记 / 习惯」）；分享进来的内容、未连接、保存完成时不显示
                if (composing && viewModel.clip == null) {
                    KindSelector(
                        active = if (viewModel.append) CaptureKind.NOTE else resolvedKind ?: viewModel.override,
                        override = viewModel.override,
                        append = viewModel.append,
                        onSelect = viewModel::selectKind,
                        onAppend = viewModel::toggleAppend,
                        glass = blurOk,
                    )
                }
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        // 吃掉点击，避免点到卡片时误触发「点遮罩关闭」
                        .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
                        .clip(sheetShape)
                        .background(
                            MaterialTheme.colorScheme.surfaceContainerLowest.copy(alpha = if (blurOk) (if (isDarkSurface()) 0.80f else 0.84f) else 1f),
                        ),
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 4.dp, bottom = 4.dp),
                    ) {
                        AnimatedContent(
                            targetState = viewModel.state,
                            transitionSpec = { fadeIn(tween(180)) togetherWith fadeOut(tween(120)) },
                            label = "quick-state",
                        ) { state ->
                            when (state) {
                                QuickState.Composing -> ComposingContent(viewModel, readClipboard, onOpenApp, canSubmit, openCamera, openVoice, openAskAi)
                                // 保存成功后面板直接收起（只给一下震动和一句 Toast），不再停留一个带「撤销」的确认窗口；
                                // 收起前仍画输入内容，避免面板先塌成一条空白
                                is QuickState.Saved -> ComposingContent(viewModel, readClipboard, onOpenApp, canSubmit, openCamera, openVoice, openAskAi)
                            }
                        }
                    }
                    // 右上角的圆角确认键
                    if (composing) {
                        SubmitCorner(
                            enabled = canSubmit,
                            onClick = { viewModel.submit(readClipboard) },
                            modifier = Modifier.align(Alignment.TopEnd),
                        )
                    }
                }
            }
        }
    }

    if (viewModel.showTemplates) {
        TemplateSheet(
            templates = viewModel.templates.collectAsStateWithLifecycle().value,
            onDismiss = { viewModel.showTemplates = false },
            onSubmit = viewModel::submitTemplate,
            onSave = viewModel::saveTemplate,
            onDelete = viewModel::deleteTemplate,
        )
    }
}

/**
 * 面板上方的类型选择：自动 / 待办 / 日记 / 笔记，圆形图标 + 文字（对标滴答清单）。
 * 亮的（白底彩色图标）是当前会保存成的类型：自动识别时，识别成什么就亮哪个；还没输入内容时亮「自动」。
 * 手动点一个类型就固定为它，再点一次它、或点「自动」，回到自动识别。
 */
@Composable
private fun KindSelector(
    active: CaptureKind?,
    override: CaptureKind?,
    append: Boolean,
    onSelect: (CaptureKind?) -> Unit,
    onAppend: () -> Unit,
    glass: Boolean = false,
) {
    // 玻璃态：背后是磨砂的浅色页面，按钮是半透明白底 + 渐变亮边，文字用主题色；否则是深色遮罩上的「白字淡白圆」
    val dark = isDarkSurface()
    val idleBg = if (glass) Color.White.copy(alpha = if (dark) 0.16f else 0.55f) else Color.White.copy(alpha = 0.28f)
    val idleFg = if (glass) MaterialTheme.colorScheme.onSurface else Color.White
    val rim = if (glass) {
        Modifier.border(
            0.8.dp,
            Brush.verticalGradient(listOf(Color.White.copy(alpha = if (dark) 0.35f else 0.95f), Color.White.copy(alpha = if (dark) 0.06f else 0.2f))),
            CircleShape,
        )
    } else Modifier
    Row(
        modifier = Modifier.padding(start = 16.dp, bottom = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        KIND_CHOICES.forEach { (kind, label) ->
            val lit = if (kind == null) (override == null && active == null) else kind == active
            Column(
                modifier = Modifier
                    .widthIn(min = 44.dp)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        role = Role.Tab,
                        onClick = { onSelect(if (kind == null || kind == override) null else kind) },
                    ),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box(
                    modifier = Modifier
                        .size(38.dp)
                        .then(if (lit) Modifier.glassButton(CircleShape, Brand.Orange) else Modifier.then(rim).clip(CircleShape).background(idleBg)),
                    contentAlignment = Alignment.Center,
                ) {
                    val tint = if (lit) Brand.Brown else idleFg
                    if (kind == null) {
                        Icon(painterResource(R.drawable.ic_auto), contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
                    } else {
                        Icon(kindIcon(kind), contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
                    }
                }
                Spacer(Modifier.height(3.dp))
                Text(label, style = MaterialTheme.typography.labelSmall.copy(fontSize = 12.sp), color = idleFg)
            }
        }
        // 追加：开着时保存成「追加到上一篇快记笔记」（类型固定为笔记）；亮起表示已开启，再点一次关闭
        Column(
            modifier = Modifier
                .widthIn(min = 44.dp)
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    role = Role.Switch,
                    onClick = onAppend,
                ),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .then(if (append) Modifier.glassButton(CircleShape, Brand.Orange) else Modifier.then(rim).clip(CircleShape).background(idleBg)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(painterResource(R.drawable.ic_append), contentDescription = null, tint = if (append) Brand.Brown else idleFg, modifier = Modifier.size(20.dp))
            }
            Spacer(Modifier.height(3.dp))
            Text("追加", style = MaterialTheme.typography.labelSmall.copy(fontSize = 12.sp), color = idleFg)
        }
    }
}

@Composable
private fun ComposingContent(
    viewModel: QuickCaptureViewModel,
    readClipboard: () -> String?,
    onOpenApp: () -> Unit,
    canSubmit: Boolean,
    onOpenCamera: () -> Unit,
    onVoice: () -> Unit,
    onAskAi: () -> Unit,
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

    // 语音识别完且开了「松手直接发送」：等输入框更新后直接保存
    LaunchedEffect(viewModel.pendingAutoSubmit) {
        if (viewModel.pendingAutoSubmit) {
            viewModel.pendingAutoSubmit = false
            viewModel.submit(readClipboard)
        }
    }

    // 普通输入时输入区自己带边距，铺满整个面板；分享 / 未连接时才加外边距
    val plain = clip == null && connected
    Column(
        modifier = if (plain) Modifier else Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (clip != null) {
            Text(
                text = "${clip.kindTag}到拾忆",
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
            if (viewModel.append) {
                // 追加开着：把目标笔记的标题亮出来，用户看一眼，点保存就是确认
                val target = viewModel.appendTarget
                val withImages = viewModel.images.isNotEmpty()
                Text(
                    text = when {
                        withImages -> "带图片的内容会另存一篇新笔记"
                        target != null -> "追加到「$target」"
                        else -> "还没有上一篇笔记，这条会新建一篇"
                    },
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(start = 20.dp, end = 64.dp, top = 14.dp),
                )
            }
            CaptureComposer(
                text = viewModel.text,
                onTextChange = { viewModel.text = it },
                override = viewModel.override,
                schedule = viewModel.schedule,
                onScheduleChange = { viewModel.schedule = it },
                folders = folders,
                canSubmit = canSubmit,
                onSubmit = { viewModel.submit(readClipboard) },
                focusRequester = focus,
                images = viewModel.images,
                onRemoveImage = viewModel::removeImage,
                onCamera = onOpenCamera,
                onVoice = onVoice,
                onAskAi = onAskAi,
                onTemplates = { viewModel.showTemplates = true },
                voice = viewModel.voice,
                voiceUndo = viewModel.voiceUndo,
                voiceItems = viewModel.voiceItems,
                onVoiceItemRemove = viewModel::removeVoiceItem,
                onVoiceRevert = viewModel::revertVoice,
                onVoiceCorrect = viewModel::correctVoice,
                onVoiceUndoDismiss = viewModel::dismissVoiceUndo,
            )
        }

        viewModel.error?.let {
            Text(
                it,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
                modifier = if (plain) Modifier.padding(start = 16.dp, end = 16.dp, bottom = 8.dp) else Modifier,
            )
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
            GlassButton(onClick = onOpenApp) { Text("去连接") }
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
                textStyle = MaterialTheme.typography.bodyLarge.copy(fontSize = 16.sp),
                minLines = 1,
                maxLines = 4,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { onSubmit() }),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                    disabledContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                    disabledIndicatorColor = Color.Transparent,
                ),
            )
            if (analysis.folderName != null || analysis.tags.isNotEmpty()) {
                Row(
                    modifier = Modifier
                        .padding(start = 12.dp, bottom = 4.dp)
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    analysis.folderName?.let { name ->
                        val hit = folders.any { it.equals(name, ignoreCase = true) }
                        InfoPill(text = "$name${if (hit) "" else "（新建）"}")
                    }
                    analysis.tags.forEach { InfoPill(text = "#$it") }
                }
            }
        }
    }
}
