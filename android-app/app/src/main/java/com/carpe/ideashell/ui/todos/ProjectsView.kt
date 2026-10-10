package com.carpe.ideashell.ui.todos

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.core.template.Templates
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.project.Project
import com.carpe.ideashell.data.project.ProjectStats
import com.carpe.ideashell.data.project.ProjectStatus
import com.carpe.ideashell.data.project.TaskNoteEntry
import com.carpe.ideashell.domain.Dossier
import com.carpe.ideashell.ui.components.ConfirmDialog
import com.carpe.ideashell.ui.components.DividedRows
import com.carpe.ideashell.ui.components.EmptyNote
import com.carpe.ideashell.ui.components.FormDialog
import com.carpe.ideashell.ui.components.FormField
import com.carpe.ideashell.ui.components.GroupLabel
import com.carpe.ideashell.ui.components.ListGroup
import com.carpe.ideashell.ui.components.MarkdownText
import com.carpe.ideashell.ui.components.MenuPropertyRow
import com.carpe.ideashell.ui.components.PropertyRow
import com.carpe.ideashell.ui.components.RowDivider
import com.carpe.ideashell.ui.components.TextPromptDialog
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import java.time.LocalDate

private val STALE_CHOICES = listOf(3, 7, 14, 30, 60)

private fun relatedOpen(p: Project, ctx: TodoCtx?): List<DidaTask> {
    val o = ctx?.overview ?: return emptyList()
    return (o.overdue + o.upcoming + o.undated).filter { p.matches(it.title, it.tags) }
}

// ───────────────────────── 项目列表 ─────────────────────────

internal fun LazyListScope.projectsSection(
    projects: List<Project>,
    stats: Map<String, ProjectStats>,
    ctx: TodoCtx?,
    today: LocalDate,
    onAdd: () -> Unit,
    onOpen: (String) -> Unit,
) {
    item(key = "p-head") {
        GroupLabel(
            text = "项目",
            count = projects.size,
            trailing = { TextButton(onClick = onAdd) { Text("新增") } },
        )
    }
    if (projects.isEmpty()) {
        item(key = "p-empty") {
            EmptyNote(
                title = "还没有项目",
                text = "项目是用关键词（和标签）钉住的一件事：笔记里出现关键词、或带这些标签，都算一次提及；" +
                    "待办标题含关键词、或带该标签，就归入这个项目。久不提及会提醒你「该记一条了」。",
                action = { Button(onClick = onAdd) { Text("新增项目") } },
            )
        }
        return
    }
    val sorted = projects.sortedWith(compareBy({ it.status.ordinal }, { it.keyword.lowercase() }))
    item(key = "p-list") {
        ListGroup(Modifier.animateItem()) {
            DividedRows(sorted) { p -> ProjectRow(p, stats[p.keyword], relatedOpen(p, ctx).size, today) { onOpen(p.keyword) } }
        }
    }
}

@Composable
private fun ProjectRow(p: Project, s: ProjectStats?, openTasks: Int, today: LocalDate, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val gap = s?.lastDay?.let { Dossier.daysBetween(it, today) }
    val stale = p.status != ProjectStatus.PAUSED && gap != null && gap >= p.staleDays
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(p.keyword, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f, fill = false))
            if (p.status != ProjectStatus.ACTIVE) {
                Text(p.status.label, style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant)
            }
            if (stale) Text("该记一条了", style = MaterialTheme.typography.labelMedium, color = scheme.error)
        }
        if (p.next.isNotBlank()) {
            Text(p.next, style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        val facts = buildList {
            when {
                s == null -> add("统计中…")
                s.lastDay == null -> add("还没有提及记录")
                else -> {
                    add("最近提及 ${Dossier.ago(gap ?: 0)}")
                    add("近 30 天 ${s.count30} 条")
                }
            }
            if (openTasks > 0) add("待办 $openTasks")
        }
        Text(
            facts.joinToString(" · "),
            style = MaterialTheme.typography.labelMedium,
            color = scheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
internal fun AddProjectDialog(onDismiss: () -> Unit, onConfirm: (keyword: String, tags: List<String>) -> Unit) {
    FormDialog(
        title = "新增项目",
        hint = "关键词 + 标签一起定义这个项目：笔记里出现关键词、或带这些标签，都算一次提及；待办标题含它们也归入该项目。",
        fields = listOf(
            FormField("关键词", required = true, placeholder = "例如 篆刻、论文、某位朋友的名字"),
            FormField("额外标签", placeholder = "可选，空格分隔，如 书法 练字"),
        ),
        confirmLabel = "添加",
        onDismiss = onDismiss,
        onConfirm = { v -> onConfirm(v[0], Templates.splitTags(v[1])) },
    )
}

// ───────────────────────── 项目主页 ─────────────────────────

private fun clip(text: String, max: Int = 1200): String =
    if (text.length > max) text.take(max).trimEnd() + "\n\n…（后面的内容请打开笔记查看）" else text

private enum class PageDialog { NEXT, LOG, TAGS, REMOVE }

/**
 * 项目主页（防弹笔记法的「项目主控台」）：下一步、项目主页笔记、要交付的成果（任务笔记）、相关待办、最近提及。
 * 每一块是「分组标题 + 一张容器」，操作都是文字按钮，整页只有「记一条」一个主按钮。
 */
@Composable
internal fun ProjectPage(
    project: Project,
    viewModel: TodoViewModel,
    stats: ProjectStats?,
    ctx: TodoCtx?,
    homeId: String?,
    taskNotes: List<TaskNoteEntry>,
    onBack: () -> Unit,
    onOpenNote: (String) -> Unit,
    onOpenDossier: (String) -> Unit,
    onProgress: (task: DidaTask?, noteId: String, text: String) -> Unit,
) {
    var dialog by remember { mutableStateOf<PageDialog?>(null) }
    var progressFor by remember { mutableStateOf<TaskNoteEntry?>(null) }
    val clipboard = LocalClipboardManager.current
    val scheme = MaterialTheme.colorScheme
    val today = LocalDate.now()
    val tasks = relatedOpen(project, ctx)

    LaunchedEffect(project.keyword, homeId, taskNotes.size) { viewModel.loadProjectPage(project) }
    LaunchedEffect(project.keyword) { if (stats == null) viewModel.refreshStats(project) }

    LazyColumn(
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = LocalBottomBarPadding.current + 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        item(key = "top") {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 4.dp, bottom = 4.dp)) {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回") }
                Column(Modifier.padding(start = 4.dp)) {
                    Text(project.keyword, style = MaterialTheme.typography.headlineSmall)
                    Text("项目主页 · ${project.status.label}", style = MaterialTheme.typography.bodySmall, color = scheme.onSurfaceVariant)
                }
            }
        }

        // 下一步：整页唯一的主操作是「记一条」
        item(key = "next") {
            Column {
                GroupLabel("下一步")
                ListGroup(Modifier.padding(top = 2.dp)) {
                    Column(Modifier.padding(horizontal = 16.dp, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(
                            project.next.ifBlank { "还没写。写成能直接开始的动作，例如「临《洛神赋》第三段，写 5 遍」。" },
                            style = MaterialTheme.typography.bodyLarge,
                            color = if (project.next.isBlank()) scheme.onSurfaceVariant else scheme.onSurface,
                        )
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            Button(onClick = { dialog = PageDialog.LOG }) { Text("记一条") }
                            TextButton(onClick = { dialog = PageDialog.NEXT }) { Text(if (project.next.isBlank()) "写下一步" else "修改") }
                        }
                    }
                }
            }
        }

        // 项目主页笔记
        item(key = "home") {
            Column {
                GroupLabel(
                    "项目主页笔记",
                    trailing = {
                        if (viewModel.pageBusy) CircularProgressIndicator(Modifier.padding(end = 12.dp).size(18.dp), strokeWidth = 2.dp)
                    },
                )
                ListGroup(Modifier.padding(top = 2.dp)) {
                    Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (homeId == null) {
                            Text(
                                "把项目的目标、要交付的成果、任务笔记汇总、资料链接、里程碑与复盘汇到一条笔记里。",
                                style = MaterialTheme.typography.bodyMedium,
                                color = scheme.onSurfaceVariant,
                            )
                            TextButton(onClick = { viewModel.createHome(project) }, enabled = !viewModel.pageBusy) { Text("创建项目主页笔记") }
                        } else {
                            val text = viewModel.homeText
                            if (text == null) {
                                Text("正在读取项目主页笔记…", style = MaterialTheme.typography.bodySmall, color = scheme.onSurfaceVariant)
                            } else {
                                MarkdownText(clip(text))
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                TextButton(onClick = { onOpenNote(homeId) }) { Text("打开全文") }
                                TextButton(onClick = { viewModel.refreshHome(project) }, enabled = !viewModel.pageBusy) { Text("更新汇总") }
                            }
                        }
                    }
                }
            }
        }

        // 要交付的成果（任务笔记）
        item(key = "notes") {
            Column {
                GroupLabel("要交付的成果", count = taskNotes.size)
                if (taskNotes.isEmpty()) {
                    Text(
                        "一个任务，一条笔记。在待办里点开属于本项目的任务，选「任务笔记」创建。",
                        style = MaterialTheme.typography.bodySmall,
                        color = scheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 8.dp, top = 2.dp, bottom = 4.dp),
                    )
                } else {
                    ListGroup(Modifier.padding(top = 2.dp)) {
                        DividedRows(taskNotes) { e ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { onOpenNote(e.ref.noteId) }
                                    .padding(start = 16.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(e.ref.deliverable, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                    val text = viewModel.noteTexts[e.ref.noteId]
                                    Text(
                                        when {
                                            text == null -> "正在读取…"
                                            text.isBlank() -> "（笔记内容为空）"
                                            else -> text.replace(Regex("\\s+"), " ").take(120)
                                        },
                                        style = MaterialTheme.typography.bodySmall,
                                        color = scheme.onSurfaceVariant,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                                TextButton(onClick = { progressFor = e }) { Text("记进展") }
                            }
                        }
                    }
                }
            }
        }

        // 相关待办
        item(key = "tasks") {
            Column {
                GroupLabel("相关任务", count = tasks.size)
                if (ctx == null || tasks.isEmpty()) {
                    Text(
                        "近期没有相关任务：任务标题或标签含项目关键词即归入。",
                        style = MaterialTheme.typography.bodySmall,
                        color = scheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 8.dp, top = 2.dp, bottom = 4.dp),
                    )
                } else {
                    ListGroup(Modifier.padding(top = 2.dp)) {
                        DividedRows(tasks, inset = 56.dp) { t -> ctx.TaskItem(t) }
                    }
                }
            }
        }

        // 最近提及与简报
        item(key = "brief") {
            Column {
                GroupLabel("最近提及")
                ListGroup(Modifier.padding(top = 2.dp)) {
                    Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        if (stats == null) {
                            Text("统计中…", style = MaterialTheme.typography.bodySmall, color = scheme.onSurfaceVariant)
                        } else {
                            val gap = stats.lastDay?.let { Dossier.daysBetween(it, today) }
                            Text(
                                if (stats.lastDay == null) "还没有提及记录" else "最近一次 ${stats.lastDay}（${Dossier.ago(gap ?: 0)}）· 近 30 天 ${stats.count30} 条 · 共 ${stats.total} 条",
                                style = MaterialTheme.typography.bodyMedium,
                            )
                            if (stats.series.any { it > 0 }) {
                                Text(Dossier.sparkline(stats.series), color = scheme.primary)
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            TextButton(onClick = { onOpenDossier(project.keyword) }) { Text("查看档案") }
                            if (stats != null && stats.brief.isNotBlank()) {
                                TextButton(onClick = { clipboard.setText(AnnotatedString(stats.brief)) }) { Text("复制简报") }
                            }
                            TextButton(onClick = { viewModel.refreshStats(project) }) { Text("重新统计") }
                        }
                    }
                }
            }
        }

        // 项目设置：一行一项，当前值在右边
        item(key = "settings") {
            Column {
                GroupLabel("设置")
                ListGroup(Modifier.padding(top = 2.dp)) {
                    MenuPropertyRow("状态", project.status.label) { close ->
                        ProjectStatus.entries.forEach { st ->
                            DropdownMenuItem(text = { Text(st.label) }, onClick = { close(); viewModel.setStatus(project.keyword, st) })
                        }
                    }
                    RowDivider()
                    MenuPropertyRow("多久没提及就提醒", "${project.staleDays} 天") { close ->
                        STALE_CHOICES.forEach { d ->
                            DropdownMenuItem(text = { Text("$d 天") }, onClick = { close(); viewModel.setStale(project.keyword, d) })
                        }
                    }
                    RowDivider()
                    PropertyRow(
                        label = "额外标签",
                        value = project.tags.joinToString(" ") { "#$it" }.ifEmpty { "无" },
                        onClick = { dialog = PageDialog.TAGS },
                    )
                    RowDivider()
                    PropertyRow(
                        label = "移除项目",
                        value = "",
                        labelColor = scheme.error,
                        onClick = { dialog = PageDialog.REMOVE },
                    )
                }
                Text(
                    "搁置的项目不再提醒。",
                    style = MaterialTheme.typography.bodySmall,
                    color = scheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 8.dp, top = 4.dp),
                )
            }
        }
    }

    when (dialog) {
        PageDialog.NEXT -> TextPromptDialog(
            title = "下一步 · ${project.keyword}",
            label = "下一步",
            hint = "写成能直接开始的动作。",
            initial = project.next,
            required = false,
            minLines = 2,
            onDismiss = { dialog = null },
            onConfirm = { viewModel.setNext(project.keyword, it); dialog = null },
        )

        PageDialog.LOG -> TextPromptDialog(
            title = "记一条「${project.keyword}」",
            label = "内容",
            hint = "保存为一条带 ${project.terms.joinToString(" ") { "#$it" }} 的独立笔记（不写入 Daily Note）；有同名滴答习惯会自动打卡。",
            minLines = 4,
            onDismiss = { dialog = null },
            onConfirm = { viewModel.logToProject(project, it); dialog = null },
        )

        PageDialog.TAGS -> TextPromptDialog(
            title = "项目标签",
            label = "标签（空格分隔）",
            initial = project.tags.joinToString(" "),
            required = false,
            singleLine = true,
            onDismiss = { dialog = null },
            onConfirm = { viewModel.setTags(project.keyword, Templates.splitTags(it)); dialog = null },
        )

        PageDialog.REMOVE -> ConfirmDialog(
            title = "移除项目「${project.keyword}」？",
            text = "只会移除项目本身；已有的笔记、任务笔记和项目主页笔记都不会被删除。",
            confirmLabel = "移除",
            onDismiss = { dialog = null },
            onConfirm = { dialog = null; viewModel.removeProject(project.keyword) },
        )

        null -> Unit
    }

    progressFor?.let { e ->
        TextPromptDialog(
            title = "记一条进展",
            label = "进展",
            hint = e.ref.deliverable,
            minLines = 3,
            onDismiss = { progressFor = null },
            onConfirm = { text ->
                progressFor = null
                val task = ctx?.overview?.findOpen(e.taskId)
                onProgress(task, e.ref.noteId, text)
            },
        )
    }
}
