package com.carpe.ideashell.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.core.capture.CapturePlan
import com.carpe.ideashell.core.capture.CapturePlanner
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.core.parse.FolderInfo
import com.carpe.ideashell.ui.glass.GlassSurface

private val KIND_CHOICES: List<Pair<CaptureKind?, String>> = listOf(
    null to "自动",
    CaptureKind.TODO to "待办",
    CaptureKind.DAILY to "日记",
    CaptureKind.NOTE to "笔记",
)

/**
 * 万能输入框：输入内容 → 实时显示识别结果（类型 / 日期 / 标签 / 文件夹）→ 点发送。
 * 预览与保存使用同一份 [CapturePlanner] 计划，所见即所存；识别不对时点上面的类型即可改。
 */
@Composable
fun CaptureComposer(
    text: String,
    onTextChange: (String) -> Unit,
    override: CaptureKind?,
    onOverrideChange: (CaptureKind?) -> Unit,
    folders: List<FolderInfo>,
    onSubmit: () -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "记点什么…",
    minLines: Int = 3,
    focusRequester: FocusRequester? = null,
) {
    val plan = remember(text, override, folders) { CapturePlanner.plan(text, override, folders) }

    GlassSurface(
        modifier = modifier
            .fillMaxWidth()
            .animateContentSize(),
        shape = RoundedCornerShape(28.dp),
    ) {
        Column(Modifier.padding(start = 8.dp, end = 12.dp, top = 8.dp, bottom = 12.dp)) {
            TextField(
                value = text,
                onValueChange = onTextChange,
                modifier = Modifier
                    .fillMaxWidth()
                    .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier),
                placeholder = {
                    Text(
                        placeholder,
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.65f),
                    )
                },
                textStyle = MaterialTheme.typography.bodyLarge,
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
                    PlanPreview(plan, Modifier.padding(start = 16.dp, top = 4.dp, bottom = 8.dp))
                }
            }

            Row(
                modifier = Modifier.padding(start = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    modifier = Modifier
                        .weight(1f)
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    KIND_CHOICES.forEach { (kind, label) ->
                        FilterChip(
                            selected = override == kind,
                            onClick = { onOverrideChange(kind) },
                            label = { Text(label) },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                                selectedLabelColor = MaterialTheme.colorScheme.onPrimaryContainer,
                            ),
                            border = FilterChipDefaults.filterChipBorder(
                                enabled = true,
                                selected = override == kind,
                                borderColor = MaterialTheme.colorScheme.outlineVariant,
                                selectedBorderColor = Color.Transparent,
                            ),
                        )
                    }
                }
                Spacer(Modifier.width(8.dp))
                FilledIconButton(
                    onClick = onSubmit,
                    enabled = plan != null,
                    modifier = Modifier.size(48.dp),
                ) {
                    Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "保存")
                }
            }
        }
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
        plan.folderName?.let { InfoPill(text = "📁 $it${if (plan.folderInferred) "（推断）" else ""}") }
        plan.tags.forEach { InfoPill(text = "#$it") }
    }
}
