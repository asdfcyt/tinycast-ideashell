package com.carpe.ideashell.ui.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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
import com.carpe.ideashell.core.template.Template
import com.carpe.ideashell.core.template.Templates
import com.carpe.ideashell.ui.components.ConfirmDialog
import com.carpe.ideashell.ui.glass.GlassSurface

private sealed interface Step {
    data object Pick : Step
    data class Fill(val template: Template) : Step
    data class Edit(val template: Template?) : Step
}

/**
 * 模板录入：选一个模板 → 依次填字段 → 存成一条结构化笔记。
 * 标题固定「模板名 日期」，正文每个字段一段 `**字段**：值`，模板自带标签与文件夹。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TemplateSheet(
    templates: List<Template>,
    onDismiss: () -> Unit,
    onSubmit: (Template, Map<String, String>) -> Boolean,
    onSave: (Template, replacing: String?) -> Unit,
    onDelete: (String) -> Unit,
) {
    var step by remember { mutableStateOf<Step>(Step.Pick) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.94f),
        shape = RoundedCornerShape(topStart = 32.dp, topEnd = 32.dp),
    ) {
        Column(
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            when (val s = step) {
                Step.Pick -> PickStep(
                    templates = templates,
                    onPick = { step = Step.Fill(it) },
                    onNew = { step = Step.Edit(null) },
                )

                is Step.Fill -> FillStep(
                    template = s.template,
                    onBack = { step = Step.Pick },
                    onEdit = { step = Step.Edit(s.template) },
                    onSubmit = { values -> if (onSubmit(s.template, values)) onDismiss() },
                    onDelete = { onDelete(s.template.name); step = Step.Pick },
                )

                is Step.Edit -> EditStep(
                    template = s.template,
                    onBack = { step = if (s.template != null) Step.Fill(s.template) else Step.Pick },
                    onSave = { t ->
                        onSave(t, s.template?.name)
                        step = Step.Fill(t)
                    },
                )
            }
        }
    }
}

@Composable
private fun PickStep(templates: List<Template>, onPick: (Template) -> Unit, onNew: () -> Unit) {
    Text("用模板记录", style = MaterialTheme.typography.titleLarge)
    Text(
        "模板把常记的一类事固定成几个字段，填完存成一条结构化笔记，日后好检索、好对比。",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    templates.forEach { t ->
        GlassSurface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(20.dp),
            onClick = { onPick(t) },
        ) {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(t.name, style = MaterialTheme.typography.titleMedium)
                    Text(
                        if (t.builtin) "内置" else "自定义",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
                Text(
                    t.fields.joinToString(" · ") { it.name },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
    OutlinedButton(onClick = onNew, modifier = Modifier.fillMaxWidth()) { Text("新建模板") }
}

@Composable
private fun FillStep(
    template: Template,
    onBack: () -> Unit,
    onEdit: () -> Unit,
    onSubmit: (Map<String, String>) -> Unit,
    onDelete: () -> Unit,
) {
    var values by remember(template.name) { mutableStateOf(emptyMap<String, String>()) }
    var confirmDelete by remember { mutableStateOf(false) }

    Row(verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = onBack) { Text("‹ 选择模板") }
    }
    Text(template.name, style = MaterialTheme.typography.titleLarge)
    val extra = buildList {
        if (template.tags.isNotEmpty()) add(template.tags.joinToString(" ") { "#$it" })
        template.folderName?.let { add("📁$it") }
    }
    if (extra.isNotEmpty()) {
        Text(extra.joinToString(" · "), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    template.fields.forEachIndexed { i, f ->
        OutlinedTextField(
            value = values[f.name].orEmpty(),
            onValueChange = { v -> values = values + (f.name to v) },
            label = { Text(f.name) },
            singleLine = !f.multiline,
            minLines = if (f.multiline) 2 else 1,
            modifier = Modifier.fillMaxWidth(),
        )
    }
    Button(onClick = { onSubmit(values) }, modifier = Modifier.fillMaxWidth().height(52.dp)) { Text("保存") }
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        TextButton(onClick = onEdit) { Text(if (template.builtin) "改成自定义模板" else "编辑模板") }
        if (!template.builtin) {
            TextButton(onClick = { confirmDelete = true }) { Text("删除", color = MaterialTheme.colorScheme.error) }
        }
    }
    if (confirmDelete) {
        ConfirmDialog(
            title = "删除模板「${template.name}」？",
            text = "只删除模板本身，已经保存的笔记不受影响。",
            confirmLabel = "删除",
            onDismiss = { confirmDelete = false },
            onConfirm = { confirmDelete = false; onDelete() },
        )
    }
}

@Composable
private fun EditStep(template: Template?, onBack: () -> Unit, onSave: (Template) -> Unit) {
    var name by remember { mutableStateOf(template?.name.orEmpty()) }
    var fields by remember { mutableStateOf(template?.let { Templates.fieldsToText(it) }.orEmpty()) }
    var tags by remember { mutableStateOf(template?.tags?.joinToString(" ").orEmpty()) }
    var folder by remember { mutableStateOf(template?.folderName.orEmpty()) }
    val built = Templates.build(name, fields, tags, folder)

    TextButton(onClick = onBack) { Text("‹ 返回") }
    Text(if (template == null) "新建模板" else "编辑模板", style = MaterialTheme.typography.titleLarge)
    OutlinedTextField(
        value = name,
        onValueChange = { name = it },
        label = { Text("模板名") },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
    OutlinedTextField(
        value = fields,
        onValueChange = { fields = it },
        label = { Text("字段（每行一个）") },
        supportingText = { Text("字段名末尾加 + 表示多行输入框，如「想法+」") },
        minLines = 4,
        modifier = Modifier.fillMaxWidth(),
    )
    OutlinedTextField(
        value = tags,
        onValueChange = { tags = it },
        label = { Text("标签（空格分隔，可选）") },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
    OutlinedTextField(
        value = folder,
        onValueChange = { folder = it },
        label = { Text("存入文件夹（可选）") },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
    Button(
        onClick = { built?.let(onSave) },
        enabled = built != null,
        modifier = Modifier.fillMaxWidth().height(52.dp),
    ) { Text("保存模板") }
}
