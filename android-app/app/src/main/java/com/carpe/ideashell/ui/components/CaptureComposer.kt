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
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.runtime.mutableStateOf
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.carpe.ideashell.R
import com.carpe.ideashell.core.capture.CapturePlanner
import com.carpe.ideashell.core.parse.CaptureKind
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
fun resolveKind(text: String, override: CaptureKind?, folders: List<FolderInfo>, hasImages: Boolean): CaptureKind? {
    if (hasImages) return CaptureKind.NOTE
    return CapturePlanner.plan(text, override, folders)?.kind
}

/**
 * 快记面板里的输入区（对标滴答清单的添加面板）：
 * - 上面是大块输入区，键盘右下角的按键就是「发送」（[onSubmit]），和聊天、搜索一个习惯；
 * - 选了图片时，在输入区下面的浅灰块里显示缩略图；
 * - 最下面一行工具图标：拍照、相册。
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
    onSubmit: () -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "准备做什么？",
    minLines: Int = 2,
    focusRequester: FocusRequester? = null,
    images: List<String> = emptyList(),
    onRemoveImage: (String) -> Unit = {},
    onPickImages: (() -> Unit)? = null,
    onTakePhoto: (() -> Unit)? = null,
) {
    // 识别结果（日期 / 标签 / 重要 / 文件夹）显示在底部工具栏上，与保存时用的是同一份计划
    val plan = remember(text, override, folders) { CapturePlanner.plan(text, override, folders) }
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
    Column(
        modifier = modifier
            .fillMaxWidth()
            .animateContentSize()
            .dragAndDropTarget(
                shouldStartDragAndDrop = { event -> event.mimeTypes().any { it.startsWith("text/") } },
                target = dropTarget,
            ),
    ) {
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
                .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier),
            placeholder = {
                Text(placeholder, style = inputStyle, color = MaterialTheme.colorScheme.outline.copy(alpha = 0.6f))
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

        // 底部一行工具栏（对标滴答）：日期 / 标签 / 重要 / 拍照 / 相册 / 模板，右边是文件夹。
        // 图标本身就是识别结果的显示位：识别到的内容（时间、标签、重要、文件夹）会以品牌色文字出现在图标旁；
        // 点图标可以辅助输入，识别到的内容仍然以输入框里的文字为准。
        val kind = plan?.kind
        val todoLike = kind == null || kind == CaptureKind.TODO
        val folderLike = kind == null || kind == CaptureKind.NOTE
        val dateText = if (plan != null && plan.kind == CaptureKind.TODO && plan.todoDate != null) {
            CapturePlanner.describeWhen(plan.todoDate, plan.todoTime)
        } else {
            null
        }
        val tagText = plan?.tags?.takeIf { it.isNotEmpty() }?.let { "#${it.first()}" + if (it.size > 1) " +${it.size - 1}" else "" }
        val important = plan != null && plan.kind == CaptureKind.TODO && plan.important
        var dateMenu by remember { mutableStateOf(false) }
        var folderMenu by remember { mutableStateOf(false) }

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
                Box {
                    ToolIcon(R.drawable.ic_calendar, "日期", { dateMenu = true }, label = dateText, active = dateText != null, enabled = todoLike)
                    DropdownMenu(expanded = dateMenu, onDismissRequest = { dateMenu = false }) {
                        listOf("今天", "明天", "后天", "下周一").forEach { word ->
                            DropdownMenuItem(
                                text = { Text(word) },
                                onClick = {
                                    dateMenu = false
                                    setText("$word ${text.trimStart()}".trimEnd())
                                    focusRequester?.let { runCatching { it.requestFocus() } }
                                },
                            )
                        }
                    }
                }
                ToolIcon(
                    R.drawable.ic_tag, "标签",
                    {
                        setText(if (text.isBlank()) "#" else text.trimEnd() + " #")
                        focusRequester?.let { runCatching { it.requestFocus() } }
                    },
                    label = tagText, active = tagText != null,
                )
                ToolIcon(
                    R.drawable.ic_flag, "重要",
                    {
                        setText(
                            if (RE_IMPORTANT.containsMatchIn(text)) text.replace(RE_IMPORTANT, "").trimEnd()
                            else if (text.isBlank()) "!重要" else text.trimEnd() + " !重要",
                        )
                    },
                    active = important, activeColor = MaterialTheme.colorScheme.error, enabled = todoLike,
                )
                if (onTakePhoto != null) ToolIcon(R.drawable.ic_camera, "拍照", onTakePhoto)
                if (onPickImages != null) ToolIcon(R.drawable.ic_image, "插入图片", onPickImages)
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
                    DropdownMenu(expanded = folderMenu, onDismissRequest = { folderMenu = false }) {
                        DropdownMenuItem(
                            text = { Text("自动判断") },
                            onClick = {
                                folderMenu = false
                                setText(text.replace(RE_FOLDER_TOKEN, "").trim())
                            },
                        )
                        folders.forEach { f ->
                            DropdownMenuItem(
                                text = { Text(f.name) },
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

private val RE_IMPORTANT = Regex("\\s*[!！]重要")
private val RE_FOLDER_TOKEN = Regex("(^|\\s)@[^\\s#@]+")

/** 面板右上角的圆角确认键（对标滴答）：以面板右上角为圆心的四分之一圆，可保存时是品牌色，否则是浅色 */
@Composable
fun SubmitCorner(enabled: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    Box(
        modifier = modifier
            .size(56.dp)
            .clip(RoundedCornerShape(bottomStart = 56.dp))
            .background(if (enabled) scheme.primary else scheme.primaryContainer)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
    ) {
        Icon(
            Icons.Filled.Check,
            contentDescription = "保存",
            tint = if (enabled) scheme.onPrimary else scheme.onPrimaryContainer.copy(alpha = 0.55f),
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
private fun ToolIcon(
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
