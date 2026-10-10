package com.carpe.ideashell.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/** 一个输入框的对话框；[required] 为 true 时内容为空不能确认 */
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
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (hint != null) {
                    Text(hint, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                OutlinedTextField(
                    value = value,
                    onValueChange = { value = it },
                    label = { Text(label) },
                    singleLine = singleLine,
                    minLines = if (singleLine) 1 else minLines,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = !required || value.isNotBlank(),
                onClick = { onConfirm(value.trim()) },
            ) { Text(confirmLabel) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

/** 多个输入框的表单对话框：[fields] 依次为（名称，是否多行，提示）；全部填完（必填项）才能确认 */
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
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (hint != null) {
                    Text(hint, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                fields.forEachIndexed { i, f ->
                    OutlinedTextField(
                        value = values.value[i],
                        onValueChange = { v -> values.value = values.value.toMutableList().also { it[i] = v } },
                        label = { Text(if (f.required) "${f.label} *" else f.label) },
                        placeholder = if (f.placeholder != null) ({ Text(f.placeholder) }) else null,
                        singleLine = !f.multiline,
                        minLines = if (f.multiline) 2 else 1,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        },
        confirmButton = {
            TextButton(enabled = ok, onClick = { onConfirm(values.value.map { it.trim() }) }) { Text(confirmLabel) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
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
