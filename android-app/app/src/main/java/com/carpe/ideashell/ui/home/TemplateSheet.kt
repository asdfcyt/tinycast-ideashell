package com.carpe.ideashell.ui.home

import com.carpe.ideashell.ui.glass.GlassOutlinedButton
import com.carpe.ideashell.ui.theme.Brand
import com.carpe.ideashell.ui.glass.GlassButton
import com.carpe.ideashell.ui.glass.GlassSheet
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
import com.carpe.ideashell.ui.components.AppTextField
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
import com.carpe.ideashell.ui.components.ListGroup
import com.carpe.ideashell.ui.components.RowDivider
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

    GlassSheet(onDismiss = onDismiss, topRadius = 32.dp) {
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
    GlassOutlinedButton(onClick = onNew, modifier = Modifier.fillMaxWidth()) { Text("新建模板") }
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

    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        TextButton(onClick = onBack) { Text("‹ 选择模板") }
        Text(
            template.name,
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.weight(1f),
            maxLines = 1,
        )
        TextButton(onClick = onEdit) { Text(if (template.builtin) "改成自定义" else "编辑") }
        if (!template.builtin) {
            TextButton(onClick = { confirmDelete = true }) { Text("删除", color = MaterialTheme.colorScheme.error) }
        }
    }
    val extra = buildList {
        if (template.tags.isNotEmpty()) add(template.tags.joinToString(" ") { "#$it" })
        template.folderName?.let { add("📁$it") }
    }
    if (extra.isNotEmpty()) {
        Text(extra.joinToString(" · "), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    ListGroup {
        template.fields.forEachIndexed { i, f ->
            if (i > 0) RowDivider()
            AppTextField(
                value = values[f.name].orEmpty(),
                onValueChange = { v -> values = values + (f.name to v) },
                label = f.name,
                placeholder = "点这里输入",
                singleLine = !f.multiline,
                minLines = if (f.multiline) 2 else 1,
                compact = true,
            )
        }
    }
    GlassButton(
        onClick = { onSubmit(values) },
        tint = Brand.Orange,
        contentColor = Brand.Brown,
        modifier = Modifier.fillMaxWidth().height(48.dp),
    ) { Text("保存") }
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
    ListGroup {
        AppTextField(
            value = name,
            onValueChange = { name = it },
            label = "模板名",
            placeholder = "例如：读书笔记",
            singleLine = true,
        )
        RowDivider()
        AppTextField(
            value = fields,
            onValueChange = { fields = it },
            label = "字段（每行一个）",
            placeholder = "每行一个字段名",
            supportingText = "字段名末尾加 + 表示多行输入框，如「想法+」",
            minLines = 4,
        )
        RowDivider()
        AppTextField(
            value = tags,
            onValueChange = { tags = it },
            label = "标签（可选）",
            placeholder = "空格分隔，如 读书 灵感",
            singleLine = true,
        )
        RowDivider()
        AppTextField(
            value = folder,
            onValueChange = { folder = it },
            label = "文件夹（可选）",
            placeholder = "文件夹名",
            singleLine = true,
        )
    }
    GlassButton(
        onClick = { built?.let(onSave) },
        enabled = built != null,
        tint = Brand.Orange,
        contentColor = Brand.Brown,
        modifier = Modifier.fillMaxWidth().height(52.dp),
    ) { Text("保存模板") }
}
