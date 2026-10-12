package com.carpe.ideashell.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import com.carpe.ideashell.R
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTarget
import androidx.compose.ui.draganddrop.mimeTypes
import androidx.compose.ui.draganddrop.toAndroidDragEvent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.core.capture.CapturePlan
import com.carpe.ideashell.core.capture.CapturePlanner
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.core.parse.FolderInfo

private val KIND_CHOICES: List<Pair<CaptureKind?, String>> = listOf(
    null to "自动",
    CaptureKind.TODO to "待办",
    CaptureKind.DAILY to "日记",
    CaptureKind.NOTE to "笔记",
)

/**
 * 万能输入框：输入内容 → 实时显示识别结果（类型 / 日期 / 标签 / 文件夹）→ 点发送。
 * 预览与保存使用同一份 [CapturePlanner] 计划，所见即所存；识别不对时点上面的类型即可改。
 *
 * 也是系统拖拽的落点：荣耀任意门 / 分屏 / 悬浮窗里把别的应用中的文字拖进来，会追加到输入框里（免鉴权的标准 Drag & Drop）。
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun CaptureComposer(
    text: String,
    onTextChange: (String) -> Unit,
    override: CaptureKind?,
    onOverrideChange: (CaptureKind?) -> Unit,
    folders: List<FolderInfo>,
    onSubmit: () -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "准备做什么？",
    minLines: Int = 3,
    focusRequester: FocusRequester? = null,
) {
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

    // 平铺在弹层里（没有自己的卡片）：大号输入区 + 识别结果 + 底部一行工具栏，对标滴答清单的快速添加面板
    Box(
        modifier = modifier
            .fillMaxWidth()
            .animateContentSize()
            .dragAndDropTarget(
                shouldStartDragAndDrop = { event -> event.mimeTypes().any { it.startsWith("text/") } },
                target = dropTarget,
            ),
    ) {
        Column(Modifier.padding(top = 4.dp, bottom = 4.dp)) {
            TextField(
                value = text,
                onValueChange = onTextChange,
                modifier = Modifier
                    .fillMaxWidth()
                    .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier),
                placeholder = {
                    Text(
                        placeholder,
                        style = MaterialTheme.typography.titleLarge.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Normal),
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.65f),
                    )
                },
                textStyle = MaterialTheme.typography.titleLarge.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Normal),
                minLines = minLines,
                maxLines = 8,
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

            AnimatedVisibility(visible = plan != null, enter = fadeIn(), exit = fadeOut()) {
                if (plan != null) {
                    PlanPreview(plan, Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 8.dp))
                }
            }

            // 底部一行：四段分段控件（自动 / 待办 / 日记 / 笔记）+ 圆形发送键。
            // 分段控件占满剩余宽度，四项等分，不会再被发送键挤到屏幕外。
            Row(
                modifier = Modifier.padding(start = 16.dp, end = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                SegmentedTabs(
                    labels = KIND_CHOICES.map { it.second },
                    selected = KIND_CHOICES.indexOfFirst { it.first == override }.coerceAtLeast(0),
                    onSelect = { onOverrideChange(KIND_CHOICES[it].first) },
                    modifier = Modifier.weight(1f),
                    outerPadding = PaddingValues(0.dp),
                    height = 36.dp,
                )
                SendButton(onClick = onSubmit, enabled = plan != null)
            }
        }
    }
}

/** 圆形发送键（iOS 信息 App 的向上箭头）：可发送时是品牌青绿，否则是灰色；44dp，满足触控下限 */
@Composable
fun SendButton(onClick: () -> Unit, enabled: Boolean, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    Box(
        modifier = modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(if (enabled) scheme.primary else scheme.surfaceContainerHigh)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painterResource(R.drawable.ic_send_up),
            contentDescription = "保存",
            tint = if (enabled) scheme.onPrimary else scheme.onSurfaceVariant.copy(alpha = 0.5f),
            modifier = Modifier.size(24.dp),
        )
    }
}

/** 识别结果一行：类型 · 日期 · 重要 · 文件夹 · 标签 */
@Composable
private fun PlanPreview(plan: CapturePlan, modifier: Modifier = Modifier) {
    val colors = kindColors(plan.kind)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        InfoPill(
            text = if (plan.isForced) plan.kind.label else "自动识别 · ${plan.kind.label}",
            icon = kindIcon(plan.kind),
            container = colors.container,
            content = colors.onContainer,
        )
        if (plan.kind == CaptureKind.TODO) {
            InfoPill(
                text = CapturePlanner.describeWhen(plan.todoDate, plan.todoTime),
                icon = Icons.Filled.DateRange,
            )
            if (plan.important) {
                InfoPill(
                    text = "重要",
                    container = MaterialTheme.colorScheme.errorContainer,
                    content = MaterialTheme.colorScheme.onErrorContainer,
                )
            }
        }
        plan.folderName?.let { InfoPill(text = "$it${if (plan.folderInferred) "（推断）" else ""}") }
        plan.tags.forEach { InfoPill(text = "#$it") }
    }
}
