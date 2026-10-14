package com.carpe.ideashell.ui.search

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.project.Project
import com.carpe.ideashell.data.project.ProjectFocusLog
import com.carpe.ideashell.domain.NoteText
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import com.carpe.ideashell.ui.components.DoneMark
import com.carpe.ideashell.ui.components.CircleIconButton
import com.carpe.ideashell.ui.components.DividedRows
import com.carpe.ideashell.ui.components.EmptyNote
import com.carpe.ideashell.ui.components.GroupLabel
import com.carpe.ideashell.ui.components.ListGroup
import com.carpe.ideashell.ui.components.NoticeLine
import com.carpe.ideashell.ui.components.ScreenHeader
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import com.carpe.ideashell.ui.review.ConnectIdeashellCard
import com.carpe.ideashell.ui.review.GlassSearchField
import com.carpe.ideashell.ui.review.InfoCard
import com.carpe.ideashell.ui.review.LoadingBlock
import com.carpe.ideashell.ui.review.NoteRow

private const val TASK_LIMIT = 10
private const val FOCUS_LIMIT = 8

/**
 * 搜索：一个输入框，下面按「项目 / 待办 / 笔记」分组；笔记上方有这个词的「提及概览」（原来回顾里的档案）。
 * 项目和待办边输边过滤（都在本机）；笔记是语义搜索，回车后才发起。
 */
@Composable
fun SearchScreen(
    onBack: () -> Unit,
    onOpenConnection: () -> Unit,
    onOpenNote: (String) -> Unit,
    onOpenProject: (String) -> Unit,
    onOpenTask: (String) -> Unit,
    viewModel: SearchViewModel = viewModel(factory = SearchViewModel.Factory),
) {
    val connected by viewModel.ideashellConnected.collectAsStateWithLifecycle()
    val todoData by viewModel.todoData.collectAsStateWithLifecycle()
    val workspace by viewModel.workspace.collectAsStateWithLifecycle()
    val notes by viewModel.notes.collectAsStateWithLifecycle()
    val overview by viewModel.overview.collectAsStateWithLifecycle()
    val query = viewModel.query.trim()
    val submitted = viewModel.submitted

    val projects = viewModel.matchProjects(query, workspace.projects)
    val tasks = viewModel.matchTasks(query, todoData)
    val focusLogs = viewModel.matchFocus(query, workspace)

    Scaffold(
        containerColor = Color.Transparent,
        contentWindowInsets = WindowInsets.statusBars,
    ) { padding ->
        Column(Modifier.padding(padding)) {
            ScreenHeader(
                title = "搜索",
                subtitle = "笔记、待办、项目和专注记录，一处找",
                action = { CircleIconButton(Icons.AutoMirrored.Filled.ArrowBack, "返回", onBack) },
            )
            GlassSearchField(
                value = viewModel.query,
                onValueChange = { viewModel.query = it },
                placeholder = "输入关键词，或用一句话描述想找的内容",
                onSearch = { viewModel.submit() },
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            )

            LazyColumn(
                contentPadding = PaddingValues(
                    start = 16.dp, end = 16.dp, top = 4.dp,
                    bottom = LocalBottomBarPadding.current + 8.dp,
                ),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                if (query.isEmpty()) {
                    emptyQuery(viewModel)
                    return@LazyColumn
                }

                if (projects.isNotEmpty()) {
                    item(key = "s-projects") {
                        Column {
                            GroupLabel("项目", count = projects.size)
                            ListGroup(Modifier.padding(top = 2.dp)) {
                                DividedRows(projects) { p -> ProjectHit(p) { onOpenProject(p.keyword) } }
                            }
                        }
                    }
                }

                if (tasks.isNotEmpty()) {
                    item(key = "s-tasks") {
                        Column {
                            GroupLabel("待办", count = tasks.size)
                            ListGroup(Modifier.padding(top = 2.dp)) {
                                DividedRows(tasks.take(TASK_LIMIT)) { t -> TaskHit(t) { onOpenTask(t.id) } }
                            }
                            if (tasks.size > TASK_LIMIT) {
                                Text(
                                    "还有 ${tasks.size - TASK_LIMIT} 项，输入更具体的词缩小范围",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(start = 8.dp, top = 4.dp),
                                )
                            }
                        }
                    }
                }

                if (focusLogs.isNotEmpty()) {
                    item(key = "s-focus") {
                        Column {
                            GroupLabel("专注记录", count = focusLogs.size)
                            ListGroup(Modifier.padding(top = 2.dp)) {
                                DividedRows(focusLogs.take(FOCUS_LIMIT)) { f -> FocusHit(f) { onOpenProject(f.project) } }
                            }
                            if (focusLogs.size > FOCUS_LIMIT) {
                                Text(
                                    "还有 ${focusLogs.size - FOCUS_LIMIT} 条，输入更具体的词缩小范围",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(start = 8.dp, top = 4.dp),
                                )
                            }
                        }
                    }
                }

                // 笔记（语义搜索）
                when {
                    !connected -> item(key = "s-connect") { ConnectIdeashellCard(onOpenConnection) }

                    submitted != query -> item(key = "s-go") {
                        Column {
                            GroupLabel("笔记")
                            ListGroup(Modifier.padding(top = 2.dp)) {
                                Row(
                                    Modifier
                                        .fillMaxWidth()
                                        .heightIn(min = 52.dp)
                                        .clickable { viewModel.submit() }
                                        .padding(horizontal = 16.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Text(
                                        "搜索笔记「${NoteText.truncate(query, 16)}」",
                                        style = MaterialTheme.typography.bodyLarge,
                                        color = MaterialTheme.colorScheme.primary,
                                    )
                                }
                            }
                        }
                    }

                    notes.loading && notes.data == null -> item(key = "s-loading") { LoadingBlock() }

                    notes.error != null && notes.data == null -> item(key = "s-error") {
                        InfoCard("搜索失败", notes.error.orEmpty(), "重试") { viewModel.submit(submitted) }
                    }

                    else -> {
                        val list = notes.data.orEmpty()
                        // 提及概览：原来「回顾」里的档案。已经是项目的词指向项目页，还不是的可以一键设为项目
                        item(key = "s-overview") {
                            MentionOverview(
                                keyword = submitted,
                                open = viewModel.overviewOpen,
                                state = overview,
                                project = workspace.projects.firstOrNull { it.keyword.equals(submitted, ignoreCase = true) },
                                onToggle = viewModel::toggleOverview,
                                onRetry = { viewModel.loadOverview(force = true) },
                                onMakeProject = { viewModel.makeProject(submitted) },
                                onOpenProject = onOpenProject,
                            )
                        }
                        item(key = "s-notes") {
                            Column {
                                GroupLabel(text = "笔记", count = list.size)
                                if (list.isEmpty()) {
                                    Text(
                                        "没有找到相关笔记，换个说法或缩短描述再试一次。",
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.padding(start = 8.dp, top = 4.dp),
                                    )
                                } else {
                                    ListGroup(Modifier.padding(top = 2.dp)) {
                                        DividedRows(list) { n -> NoteRow(n, onClick = { onOpenNote(n.id) }) }
                                    }
                                }
                            }
                        }
                        notes.error?.let { err -> item(key = "s-stale") { NoticeLine(err) } }
                    }
                }
            }
        }
    }
}

/** 没有输入时：最近搜索 + 一句用法提示 */
private fun androidx.compose.foundation.lazy.LazyListScope.emptyQuery(viewModel: SearchViewModel) {
    if (viewModel.recent.isNotEmpty()) {
        item(key = "s-recent") {
            Column {
                GroupLabel(
                    text = "最近搜索",
                    trailing = { TextButton(onClick = viewModel::clearRecent) { Text("清除") } },
                )
                ListGroup(Modifier.padding(top = 2.dp)) {
                    DividedRows(viewModel.recent.toList()) { q ->
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .heightIn(min = 52.dp)
                                .clickable { viewModel.submit(q) }
                                .padding(horizontal = 16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(q, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
        }
    }
    item(key = "s-hint") {
        EmptyNote(
            title = "想找什么？",
            text = "项目、待办和专注记录会边输边过滤；笔记按意思搜索，不必记得原话，例如「上次聊过的合作方案」。回车开始搜索笔记，搜完可以展开「提及概览」。",
        )
    }
}

@Composable
private fun ProjectHit(p: Project, onClick: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(p.keyword, style = MaterialTheme.typography.bodyLarge)
        val sub = buildList {
            add(p.status.label)
            if (p.tags.isNotEmpty()) add(p.tags.joinToString(" ") { "#$it" })
            if (p.next.isNotBlank()) add("下一步：${p.next}")
        }.joinToString(" · ")
        Text(
            sub,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** 一条专注记录：任务标题（没有就用项目名）+ 项目 · 日期时间 · 时长 */
@Composable
private fun FocusHit(f: ProjectFocusLog, onClick: () -> Unit) {
    val zone = java.time.ZoneId.systemDefault()
    val start = java.time.Instant.ofEpochMilli(f.startMs).atZone(zone)
    val minutes = ((f.endMs - f.startMs) / 60_000L).toInt().coerceAtLeast(1)
    Column(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            f.title.ifBlank { f.project },
            style = MaterialTheme.typography.bodyLarge,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            listOf(f.project, start.format(java.time.format.DateTimeFormatter.ofPattern("M月d日 HH:mm")), "${minutes} 分钟")
                .joinToString(" · "),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun TaskHit(t: DidaTask, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(32.dp), contentAlignment = Alignment.CenterStart) { DoneMark(t.done) }
        Text(
            TodoMeta.cleanTitle(t.title),
            style = MaterialTheme.typography.bodyLarge,
            textDecoration = if (t.done) TextDecoration.LineThrough else null,
            color = if (t.done) scheme.onSurface.copy(alpha = 0.55f) else scheme.onSurface,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        val whenText = listOfNotNull(t.date?.drop(5), t.time).joinToString(" ")
        if (whenText.isNotEmpty()) {
            Text(
                whenText,
                style = MaterialTheme.typography.labelMedium,
                color = scheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 8.dp),
            )
        }
    }
}
