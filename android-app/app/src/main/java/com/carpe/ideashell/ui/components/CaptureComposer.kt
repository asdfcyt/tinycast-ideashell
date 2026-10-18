package com.carpe.ideashell.ui.components

import android.graphics.BitmapFactory
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTarget
import androidx.compose.ui.draganddrop.mimeTypes
import androidx.compose.ui.draganddrop.toAndroidDragEvent
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalTextToolbar
import androidx.compose.ui.platform.TextToolbar
import androidx.compose.ui.platform.TextToolbarStatus
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.carpe.ideashell.R
import com.carpe.ideashell.ui.theme.Brand
import com.carpe.ideashell.core.capture.CapturePlanner
import com.carpe.ideashell.core.capture.CaptureSchedule
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.core.voice.VoiceIntent
import com.carpe.ideashell.core.parse.FolderInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** 面板上方的类型选择：null 是「自动」 */
internal val KIND_CHOICES: List<Pair<CaptureKind?, String>> = listOf(
    null to "自动",
    CaptureKind.TODO to "待办",
    CaptureKind.DAILY to "日记",
    CaptureKind.NOTE to "笔记",
)

/**
 * 按当前输入会保存成哪种类型（上方圆形图标据此高亮：自动识别成什么就亮哪个）；没有内容时为 null。
 * 带图片时一律按笔记存（待办装不下图片，Daily Note 也不能带图），规则与保存时一致。
 */
fun resolveKind(
    text: String,
    override: CaptureKind?,
    folders: List<FolderInfo>,
    hasImages: Boolean,
    schedule: CaptureSchedule? = null,
): CaptureKind? {
    if (hasImages) return CaptureKind.NOTE
    return CapturePlanner.plan(text, override, folders, schedule = schedule)?.kind
}

/**
 * 快记面板里的输入区（对标滴答清单的添加面板）：
 * - 上面是大块输入区，键盘右下角的按键就是「发送」（[onSubmit]），和聊天、搜索一个习惯；
 * - 选了图片时，在输入区下面的浅灰块里显示缩略图；
 * - 最下面一行工具图标：日期、标签、重要、相机（拍照 / 相册 / 文字识别合一）。
 * 发送用面板右上角的圆角确认键，不在这里。
 *
 * 也是系统拖拽的落点：荣耀任意门 / 分屏 / 悬浮窗里把别的应用中的文字拖进来，会追加到输入框里（免鉴权的标准 Drag & Drop）。
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun CaptureComposer(
    text: String,
    onTextChange: (String) -> Unit,
    override: CaptureKind?,
    folders: List<FolderInfo>,
    canSubmit: Boolean,
    /** 在日期时间面板里选定的时间：不写进输入框，由调用方保存，提交时一并带上 */
    schedule: CaptureSchedule? = null,
    onScheduleChange: (CaptureSchedule?) -> Unit = {},
    onSubmit: () -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "准备做什么？",
    minLines: Int = 2,
    focusRequester: FocusRequester? = null,
    images: List<String> = emptyList(),
    onRemoveImage: (String) -> Unit = {},
    onCamera: (() -> Unit)? = null,
    /** 调用闪念贝壳 App 的语音录音 / AI 对话（AI 会带上输入框里已有的文字） */
    onVoice: (() -> Unit)? = null,
    onAskAi: (() -> Unit)? = null,
    /** 还没输入内容时，占位文字末尾的「选择模板」下划线链接；为 null 时不显示 */
    onTemplates: (() -> Unit)? = null,
    /** 按住说话（腾讯云识别 + 大模型整理）；为 null 时不显示按钮 */
    voice: VoiceInputController? = null,
    /** 大模型整理过语音后的「还原」提示；为 null 不显示 */
    voiceUndo: VoiceUndo? = null,
    /** 一句话里拆出的多件事（≥2 项）预览；空表示没有 */
    voiceItems: List<VoiceIntent> = emptyList(),
    onVoiceItemRemove: (Int) -> Unit = {},
    onVoiceRevert: () -> Unit = {},
    /** 点「纠错」：（识别成了, 应该是）记进词库并改掉当前文字 */
    onVoiceCorrect: (String, String) -> Unit = { _, _ -> },
    onVoiceUndoDismiss: () -> Unit = {},
) {
    var correcting by remember { mutableStateOf(false) }
    if (correcting && voiceUndo != null) {
        VoiceCorrectDialog(
            raw = voiceUndo.raw,
            onConfirm = onVoiceCorrect,
            onDismiss = { correcting = false },
        )
    }
    // 面板收起 / 重组掉时，没锁定的录音直接丢掉，不让麦克风一直开着
    if (voice != null) {
        DisposableEffect(voice) {
            onDispose { if (voice.phase == VoicePhase.RECORDING) voice.cancel() }
        }
    }
    // 识别结果（日期 / 标签 / 重要 / 文件夹）显示在底部工具栏上，与保存时用的是同一份计划
    val plan = remember(text, override, folders, schedule) { CapturePlanner.plan(text, override, folders, schedule = schedule) }
    val context = LocalContext.current
    val latestText = rememberUpdatedState(text)
    val latestOnChange = rememberUpdatedState(onTextChange)
    val dropTarget = remember(context) {
        object : DragAndDropTarget {
            override fun onDrop(event: DragAndDropEvent): Boolean {
                val clip = event.toAndroidDragEvent().clipData ?: return false
                val dropped = (0 until clip.itemCount)
                    .mapNotNull { clip.getItemAt(it).coerceToText(context)?.toString()?.trim()?.takeIf(String::isNotEmpty) }
                    .joinToString("\n")
                if (dropped.isEmpty()) return false
                val current = latestText.value
                latestOnChange.value(if (current.isBlank()) dropped else current.trimEnd() + "\n" + dropped)
                return true
            }
        }
    }

    // 输入框用 TextFieldValue 自己管光标：点工具栏往文字里加内容（# / @文件夹 / 日期词）后，光标要停在末尾继续输入
    var field by remember { mutableStateOf(TextFieldValue(text, TextRange(text.length))) }
    LaunchedEffect(text) {
        if (field.text != text) field = TextFieldValue(text, TextRange(text.length))
    }
    fun setText(value: String) {
        field = TextFieldValue(value, TextRange(value.length))
        onTextChange(value)
    }

    val inputStyle = MaterialTheme.typography.bodyLarge.copy(fontSize = 17.sp, lineHeight = 24.sp)

    // 优先级 / 文件夹菜单不抢焦点（抢了键盘就收起来了），所以「点别处 / 继续输入就关掉」要自己处理
    var priorityMenu by remember { mutableStateOf(false) }
    var folderMenu by remember { mutableStateOf(false) }
    LaunchedEffect(field.text) {
        priorityMenu = false
        folderMenu = false
    }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .animateContentSize()
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        if (event.changes.any { it.pressed && !it.previousPressed }) {
                            priorityMenu = false
                            folderMenu = false
                        }
                    }
                }
            }
            .dragAndDropTarget(
                shouldStartDragAndDrop = { event -> event.mimeTypes().any { it.startsWith("text/") } },
                target = dropTarget,
            ),
    ) {
        // 按住输入框说话：长按够时间就开始录音，松手识别（点按、拖动、双击选词不受影响）
        Box(Modifier.fillMaxWidth().then(if (voice != null) Modifier.voiceHoldGesture(voice, inField = true) else Modifier)) {
        // 空的时候：占位文字后面跟一个下划线的「选择模板」链接（点开选模板录入）；链接要能点，所以画在输入框上面一层
        val showTemplateLink = onTemplates != null && field.text.isEmpty()
        // 语音输入开着时，占位文字直接说明怎么用，替代「准备做什么？」
        val voiceOn = voice != null && voice.enabled
        val hintText = if (voiceOn) "按住说话，松手识别" else placeholder
        // 录音 / 识别时，输入区让给波形面板
        val voiceActive = voice != null && voice.phase != VoicePhase.IDLE
        // 按住输入框说话时，输入框自己的长按菜单（粘贴 / 自动填充）不要弹出来
        val baseToolbar = LocalTextToolbar.current
        val toolbar = remember(baseToolbar, voice) {
            if (voice == null) baseToolbar else VoiceAwareToolbar(baseToolbar) { voice.phase != VoicePhase.IDLE }
        }
        CompositionLocalProvider(LocalTextToolbar provides toolbar) {
        TextField(
            value = field,
            onValueChange = {
                field = it
                if (it.text != text) onTextChange(it.text)
            },
            modifier = Modifier
                .fillMaxWidth()
                // 右上角有确认键，第一行右边留出位置
                .padding(end = 36.dp)
                .alpha(if (voiceActive) 0f else 1f)
                .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier),
            placeholder = {
                if (!showTemplateLink) {
                    Text(hintText, style = inputStyle, color = MaterialTheme.colorScheme.outline.copy(alpha = 0.6f))
                }
            },
            textStyle = inputStyle,
            minLines = minLines,
            maxLines = 8,
            // 键盘右下角的按键就是「发送」：输入完直接按它保存
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { if (canSubmit) onSubmit() }),
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
        if (showTemplateLink && !voiceActive) {
            val hint = MaterialTheme.colorScheme.outline.copy(alpha = 0.6f)
            val linkColor = MaterialTheme.colorScheme.onSurfaceVariant
            Text(
                text = buildAnnotatedString {
                    append(hintText + if (voiceOn) "，或" else "或")
                    withLink(
                        LinkAnnotation.Clickable(
                            tag = "template",
                            styles = TextLinkStyles(SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline)),
                            linkInteractionListener = { onTemplates?.invoke() },
                        ),
                    ) { append("选择模板") }
                },
                style = inputStyle,
                color = hint,
                modifier = Modifier.padding(start = 16.dp, top = 16.dp, end = 52.dp),
            )
        }
        if (voice != null && voiceActive) VoiceWavePanel(voice, Modifier.matchParentSize())
        }

        if (images.isNotEmpty()) {
            Row(
                modifier = Modifier
                    .padding(horizontal = 12.dp)
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(MaterialTheme.colorScheme.surfaceContainerLow)
                    .horizontalScroll(rememberScrollState())
                    .padding(start = 10.dp, end = 6.dp, top = 8.dp, bottom = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                images.forEach { path -> ImageThumb(path, onRemove = { onRemoveImage(path) }) }
            }
        }

        if (voice != null && voiceItems.isNotEmpty() && voice.phase == VoicePhase.IDLE) {
            VoiceItemsPreview(voiceItems, onRemove = onVoiceItemRemove)
        }
        if (voice != null && voiceUndo != null && voice.phase == VoicePhase.IDLE) {
            VoiceUndoBar(
                voiceUndo,
                onRevert = onVoiceRevert,
                onCorrect = { correcting = true },
                onDismiss = onVoiceUndoDismiss,
            )
        }

        // 底部一行工具栏（对标滴答）：日期 / 标签 / 重要 / 相机，右边是文件夹。
        // 图标本身就是识别结果的显示位：识别到的内容（时间、标签、重要、文件夹）会以品牌色文字出现在图标旁；
        // 点图标可以辅助输入，识别到的内容仍然以输入框里的文字为准。
        val kind = plan?.kind
        val todoLike = kind == null || kind == CaptureKind.TODO
        val folderLike = kind == null || kind == CaptureKind.NOTE
        val dateText = when {
            plan != null && plan.kind == CaptureKind.TODO && plan.todoDate != null ->
                CapturePlanner.describeWhen(plan.todoDate, plan.todoTime) + (plan.repeat?.let { " · ${it.label()}" } ?: "")
            // 还没输入文字时 plan 为空，但预选的日期（待办页选了某天再点「+」）也要显示出来
            plan == null && schedule != null ->
                CapturePlanner.describeWhen(schedule.date.toString(), schedule.time?.let { "%02d:%02d".format(it.hour, it.minute) }) +
                    (schedule.repeat?.let { " · ${it.label()}" } ?: "")
            else -> null
        }
        val tagText = plan?.tags?.takeIf { it.isNotEmpty() }?.let { "#${it.first()}" + if (it.size > 1) " +${it.size - 1}" else "" }
        val priority = if (plan != null && plan.kind == CaptureKind.TODO) plan.priority else 0
        var dateSheet by remember { mutableStateOf(false) }
        if (dateSheet) {
            val curDate = plan?.todoDate?.let { runCatching { java.time.LocalDate.parse(it) }.getOrNull() }
                ?: schedule?.date.takeIf { plan == null }
            val curTime = plan?.todoTime?.let { runCatching { java.time.LocalTime.parse(it) }.getOrNull() }
                ?: schedule?.time.takeIf { plan == null }
            DateTimeSheet(
                initialDate = curDate,
                initialTime = curTime,
                initialRepeat = plan?.repeat ?: schedule?.repeat.takeIf { plan == null },
                onConfirm = { d, t, r ->
                    dateSheet = false
                    // 选的时间不往输入框里写，只记在 schedule 里（工具栏上的日期会显示）；文字里原有的日期时间词去掉，免得重复
                    onScheduleChange(if (d == null) null else CaptureSchedule(d, t, r))
                    setText(stripDateTime(text))
                    focusRequester?.let { runCatching { it.requestFocus() } }
                },
                onDismiss = { dateSheet = false },
            )
        }

        Row(
            modifier = Modifier.padding(start = 4.dp, end = 8.dp, top = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                modifier = Modifier
                    .weight(1f)
                    .horizontalScroll(rememberScrollState()),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ToolIcon(R.drawable.ic_calendar, "日期", { dateSheet = true }, label = dateText, active = dateText != null, enabled = todoLike)
                ToolIcon(
                    R.drawable.ic_tag, "标签",
                    {
                        setText(if (text.isBlank()) "#" else text.trimEnd() + " #")
                        focusRequester?.let { runCatching { it.requestFocus() } }
                    },
                    label = tagText, active = tagText != null,
                )
                // 优先级：点开菜单选 无 / 低 / 中 / 高（与滴答一致），选择后以 `!高` `!中` `!低` 写进输入框，随时可手动改
                Box {
                    ToolIcon(
                        R.drawable.ic_flag, "优先级",
                        { priorityMenu = true },
                        label = if (priority > 0) CapturePlanner.priorityName(priority) else null,
                        active = priority > 0, activeColor = priorityColor(priority), enabled = todoLike,
                    )
                    AppMenu(expanded = priorityMenu, onDismissRequest = { priorityMenu = false }, keepKeyboard = true) {
                        listOf("无" to 0, "低" to 1, "中" to 3, "高" to 5).forEach { (label, value) ->
                            AppMenuItem(
                                text = { Text(label) },
                                selected = priority == value,
                                onClick = {
                                    priorityMenu = false
                                    setText(withPriority(text, value))
                                    focusRequester?.let { runCatching { it.requestFocus() } }
                                },
                            )
                        }
                    }
                }
                // 拍照 / 相册 / 识别文字合并成一个入口：点开全屏相机页，左下相册、中间快门、右下识别文字开关
                if (onCamera != null) ToolIcon(R.drawable.ic_camera, "拍照、相册与文字识别", onCamera)
                if (onVoice != null) ToolIcon(R.drawable.ic_mic, "语音记（用闪念贝壳录音）", onVoice)
                if (onAskAi != null) ToolIcon(R.drawable.ic_sparkle, "问闪念贝壳 AI（带上输入框里的文字）", onAskAi)
            }
            if (folderLike && folders.isNotEmpty()) {
                Box {
                    Row(
                        modifier = Modifier
                            .height(40.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .clickable(role = Role.Button) { folderMenu = true }
                            .padding(start = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            plan?.folderName ?: "文件夹",
                            style = MaterialTheme.typography.bodyMedium,
                            color = if (plan?.folderName != null) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.widthIn(max = 96.dp),
                        )
                        Icon(Icons.Filled.ArrowDropDown, contentDescription = null, tint = MaterialTheme.colorScheme.onSurface)
                    }
                    AppMenu(expanded = folderMenu, onDismissRequest = { folderMenu = false }, keepKeyboard = true) {
                        AppMenuItem(
                            text = { Text("自动判断") },
                            selected = plan?.folderName == null,
                            onClick = {
                                folderMenu = false
                                setText(text.replace(RE_FOLDER_TOKEN, "").trim())
                            },
                        )
                        folders.forEach { f ->
                            AppMenuItem(
                                text = { Text(f.name) },
                                selected = plan?.folderName == f.name,
                                onClick = {
                                    folderMenu = false
                                    val cleaned = text.replace(RE_FOLDER_TOKEN, "").trimEnd()
                                    setText(if (cleaned.isBlank()) "@${f.name}" else "$cleaned @${f.name}")
                                },
                            )
                        }
                    }
                }
            }
        }
    }
}

/** 和滴答、任务列表里一致的优先级颜色：高红 / 中琥珀 / 低蓝 */
private fun priorityColor(priority: Int): Color = when {
    priority >= 5 -> Color(0xFFE5484D)
    priority >= 3 -> Color(0xFFF5A524)
    else -> Color(0xFF3E8BFF)
}

/** 把输入框里的优先级标记换成 [priority]（0 = 去掉标记） */
private fun withPriority(text: String, priority: Int): String {
    val cleaned = CapturePlanner.stripPriority(text)
    val mark = when {
        priority >= 5 -> "!高"
        priority >= 3 -> "!中"
        priority >= 1 -> "!低"
        else -> return cleaned
    }
    return if (cleaned.isBlank()) mark else "$cleaned $mark"
}

private val RE_FOLDER_TOKEN = Regex("(^|\\s)@[^\\s#@]+")

/** 面板右上角的圆角确认键（对标滴答）：以面板右上角为圆心的四分之一圆，可保存时是品牌色，否则是浅色 */
@Composable
fun SubmitCorner(enabled: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    Box(
        modifier = modifier
            .size(56.dp)
            .clip(RoundedCornerShape(bottomStart = 56.dp))
            .background(if (enabled) Brand.Orange else scheme.primaryContainer)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
    ) {
        Icon(
            Icons.Filled.Check,
            contentDescription = "保存",
            tint = if (enabled) Brand.Brown else scheme.onPrimaryContainer.copy(alpha = 0.55f),
            modifier = Modifier
                .align(Alignment.Center)
                .padding(start = 12.dp, bottom = 12.dp)
                .size(24.dp),
        )
    }
}

/**
 * 工具栏上的图标按钮：深色线性图标，触控区高 40dp；有识别结果时 [label] 以 [activeColor] 显示在图标右边。
 * [enabled] 为 false 表示当前类型用不上（例如笔记没有日期），图标变淡且不可点。
 */
@Composable
internal fun ToolIcon(
    icon: Int,
    description: String,
    onClick: () -> Unit,
    label: String? = null,
    active: Boolean = false,
    activeColor: Color = MaterialTheme.colorScheme.primary,
    enabled: Boolean = true,
) {
    val tint = when {
        !enabled -> MaterialTheme.colorScheme.onSurface.copy(alpha = 0.28f)
        active -> activeColor
        else -> MaterialTheme.colorScheme.onSurface
    }
    Row(
        modifier = Modifier
            .height(40.dp)
            .widthIn(min = 40.dp)
            .clip(RoundedCornerShape(10.dp))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Icon(painterResource(icon), contentDescription = description, tint = tint, modifier = Modifier.size(24.dp))
        if (label != null) {
            Spacer(Modifier.width(4.dp))
            Text(label, style = MaterialTheme.typography.bodyMedium, color = tint, maxLines = 1)
        }
    }
}

/** 图片缩略图（64dp，右上角带删除）：按小尺寸解码，不占内存 */
@Composable
private fun ImageThumb(path: String, onRemove: () -> Unit) {
    val bitmap by produceState<androidx.compose.ui.graphics.ImageBitmap?>(null, path) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                val opts = BitmapFactory.Options().apply { inSampleSize = 8 }
                BitmapFactory.decodeFile(path, opts)?.asImageBitmap()
            }.getOrNull()
        }
    }
    Box(Modifier.size(68.dp).padding(top = 4.dp, end = 4.dp)) {
        Box(
            Modifier
                .fillMaxSize()
                .clip(RoundedCornerShape(10.dp))
                .background(MaterialTheme.colorScheme.surfaceContainerHigh),
        ) {
            bitmap?.let { Image(it, contentDescription = "已选图片", contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
        }
        Box(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .size(22.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.inverseSurface)
                .clickable(role = Role.Button, onClick = onRemove),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.Close, contentDescription = "移除图片", tint = MaterialTheme.colorScheme.inverseOnSurface, modifier = Modifier.size(14.dp))
        }
    }
}

/**
 * 把选好的日期 / 时间写回输入框：先去掉原来识别到的日期和时间，再在最前面写入标准格式（yyyy-MM-dd HH:mm），
 * 并加上「待办」前缀确保一定存成待办。选「没有日期」时只去掉日期，保留原来的待办前缀。
 */
internal fun stripDateTime(text: String): String {
    val a = com.carpe.ideashell.core.parse.CaptureParser.analyze(text)
    val base = if (a.text.isBlank()) "" else com.carpe.ideashell.core.parse.TodoParser.parse(a.text).content
    val keepTodo = a.forced == CaptureKind.TODO
    return ((if (keepTodo) "待办 " else "") + base).trimEnd()
}

/** 转发给系统的文字菜单，但在 [blocked] 为 true（正在语音录入）时不弹出 */
private class VoiceAwareToolbar(
    private val base: TextToolbar,
    private val blocked: () -> Boolean,
) : TextToolbar {
    override val status: TextToolbarStatus get() = base.status

    override fun showMenu(
        rect: Rect,
        onCopyRequested: (() -> Unit)?,
        onPasteRequested: (() -> Unit)?,
        onCutRequested: (() -> Unit)?,
        onSelectAllRequested: (() -> Unit)?,
    ) {
        if (blocked()) return
        base.showMenu(rect, onCopyRequested, onPasteRequested, onCutRequested, onSelectAllRequested)
    }

    override fun hide() = base.hide()
}
