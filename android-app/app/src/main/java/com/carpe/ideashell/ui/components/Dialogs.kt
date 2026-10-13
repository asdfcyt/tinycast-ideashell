package com.carpe.ideashell.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * 输入用的抽屉（和任务详情同一套样式）：底部弹出，标题 + 说明 + 白色圆角的输入行，下面一个主按钮和「取消」。
 * 键盘弹出时整体上移，输入行不会被挡住。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InputSheet(
    title: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
    confirmLabel: String = "保存",
    confirmEnabled: Boolean = true,
    hint: String? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
    ) {
        Column(
            modifier = Modifier
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(Modifier.padding(horizontal = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, style = MaterialTheme.typography.titleLarge)
                if (hint != null) {
                    Text(hint, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            content()
            Button(
                onClick = onConfirm,
                enabled = confirmEnabled,
                modifier = Modifier.fillMaxWidth().height(52.dp),
            ) { Text(confirmLabel) }
        }
    }
}

/** 一个输入框的抽屉；[required] 为 true 时内容为空不能确认 */
@Composable
fun TextPromptDialog(
    title: String,
    label: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
    initial: String = "",
    hint: String? = null,
    singleLine: Boolean = false,
    required: Boolean = true,
    confirmLabel: String = "保存",
    minLines: Int = 1,
) {
    var value by remember { mutableStateOf(initial) }
    InputSheet(
        title = title,
        hint = hint,
        confirmLabel = confirmLabel,
        confirmEnabled = !required || value.isNotBlank(),
        onDismiss = onDismiss,
        onConfirm = { onConfirm(value.trim()) },
    ) {
        ListGroup {
            AppTextField(
                value = value,
                onValueChange = { value = it },
                // 抽屉标题已经说明了这是什么，输入行里不再重复名称（[label] 仅保留给调用方，不显示）
                label = null,
                placeholder = "点这里输入",
                singleLine = singleLine,
                minLines = if (singleLine) 1 else maxOf(minLines, 3),
            )
        }
    }
}

/** 多个输入框的表单抽屉：[fields] 依次为（名称，是否多行，提示）；全部填完（必填项）才能确认 */
class FormField(
    val label: String,
    val multiline: Boolean = false,
    val placeholder: String? = null,
    val required: Boolean = false,
    val initial: String = "",
)

@Composable
fun FormDialog(
    title: String,
    fields: List<FormField>,
    onDismiss: () -> Unit,
    onConfirm: (List<String>) -> Unit,
    hint: String? = null,
    confirmLabel: String = "保存",
) {
    val values = remember { mutableStateOf(fields.map { it.initial }) }
    val ok = fields.indices.all { i -> !fields[i].required || values.value[i].isNotBlank() }
    InputSheet(
        title = title,
        hint = hint,
        confirmLabel = confirmLabel,
        confirmEnabled = ok,
        onDismiss = onDismiss,
        onConfirm = { onConfirm(values.value.map { it.trim() }) },
    ) {
        ListGroup {
            fields.forEachIndexed { i, f ->
                if (i > 0) RowDivider()
                AppTextField(
                    value = values.value[i],
                    onValueChange = { v -> values.value = values.value.toMutableList().also { it[i] = v } },
                    label = if (f.required) "${f.label} *" else f.label,
                    placeholder = f.placeholder ?: "点这里输入",
                    singleLine = !f.multiline,
                    minLines = if (f.multiline) 3 else 1,
                )
            }
        }
    }
}

@Composable
fun ConfirmDialog(
    title: String,
    text: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
    confirmLabel: String = "确定",
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(text) },
        confirmButton = { TextButton(onClick = onConfirm) { Text(confirmLabel) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}
