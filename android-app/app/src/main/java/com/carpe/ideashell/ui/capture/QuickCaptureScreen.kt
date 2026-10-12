package com.carpe.ideashell.ui.capture

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.sp
import com.carpe.ideashell.R
import com.carpe.ideashell.data.capture.CaptureImages
import com.carpe.ideashell.ui.components.KIND_CHOICES
import com.carpe.ideashell.ui.components.kindIcon
import java.io.File
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
    val resolvedKind = remember(viewModel.text, viewModel.override, folders, hasImages) {
        resolveKind(viewModel.text, viewModel.override, folders, hasImages)
    }
    val canSubmit = viewModel.clip != null || resolvedKind != null
    val composing = connected && viewModel.state == QuickState.Composing

    // 相册：系统自带的照片选择器，不需要任何权限；拍照：交给系统相机，写到我们给的临时文件里
    val pickLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(CaptureImages.MAX_COUNT),
    ) { uris -> viewModel.addImages(context, uris) }
    var cameraTarget by rememberSaveable { mutableStateOf<String?>(null) }
    val cameraLauncher = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        val target = cameraTarget
        cameraTarget = null
        if (ok && target != null) viewModel.addImages(context, listOf(Uri.parse(target)))
    }
    val pickImages = {
        pickLauncher.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
    }
    val takePhoto = {
        val dir = File(context.cacheDir, "camera").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        val file = File(dir, "shot_${System.currentTimeMillis()}.jpg")
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        cameraTarget = uri.toString()
        cameraLauncher.launch(uri)
    }

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
            val sheetShape = RoundedCornerShape(16.dp)
            Column(Modifier.padding(start = 4.dp, end = 4.dp, bottom = 4.dp)) {
                // 类型选择浮在面板上方（对标滴答清单的「任务 / 笔记 / 习惯」）；分享进来的内容、未连接、保存完成时不显示
                if (composing && viewModel.clip == null) {
                    KindSelector(
                        active = resolvedKind,
                        override = viewModel.override,
                        onSelect = { viewModel.override = it },
                        onTemplates = { viewModel.showTemplates = true },
                    )
                }
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
                            .padding(top = 4.dp, bottom = 4.dp),
                    ) {
                        AnimatedContent(
                            targetState = viewModel.state,
                            transitionSpec = { fadeIn(tween(180)) togetherWith fadeOut(tween(120)) },
                            label = "quick-state",
                        ) { state ->
                            when (state) {
                                QuickState.Composing -> ComposingContent(viewModel, readClipboard, onOpenApp, canSubmit, pickImages, takePhoto)
                                is QuickState.Saved -> SavedContent(state, viewModel, onClose)
                                QuickState.Undone -> UndoneContent(onClose)
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
private fun KindSelector(active: CaptureKind?, override: CaptureKind?, onSelect: (CaptureKind?) -> Unit, onTemplates: () -> Unit) {
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
                        .clip(CircleShape)
                        .background(if (lit) Color.White else Color.White.copy(alpha = 0.28f)),
                    contentAlignment = Alignment.Center,
                ) {
                    val tint = if (lit) Color(0xFF0F766E) else Color.White
                    if (kind == null) {
                        Icon(painterResource(R.drawable.ic_auto), contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
                    } else {
                        Icon(kindIcon(kind), contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
                    }
                }
                Spacer(Modifier.height(3.dp))
                Text(label, style = MaterialTheme.typography.labelSmall.copy(fontSize = 12.sp), color = Color.White)
            }
        }
        // 模板：不是类型，点开选模板录入，所以永远是未选中的样子
        Column(
            modifier = Modifier
                .widthIn(min = 44.dp)
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    role = Role.Button,
                    onClick = onTemplates,
                ),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.28f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(painterResource(R.drawable.ic_template), contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
            }
            Spacer(Modifier.height(3.dp))
            Text("模板", style = MaterialTheme.typography.labelSmall.copy(fontSize = 12.sp), color = Color.White)
        }
    }
}

@Composable
private fun ComposingContent(
    viewModel: QuickCaptureViewModel,
    readClipboard: () -> String?,
    onOpenApp: () -> Unit,
    canSubmit: Boolean,
    onPickImages: () -> Unit,
    onTakePhoto: () -> Unit,
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

    // 普通输入时输入区自己带边距，铺满整个面板；分享 / 未连接时才加外边距
    val plain = clip == null && connected
    Column(
        modifier = if (plain) Modifier else Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
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
                folders = folders,
                canSubmit = canSubmit,
                onSubmit = { viewModel.submit(readClipboard) },
                focusRequester = focus,
                images = viewModel.images,
                onRemoveImage = viewModel::removeImage,
                onPickImages = onPickImages,
                onTakePhoto = onTakePhoto,
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
        delay(1200)
        onClose()
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
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
