package com.carpe.ideashell.ui.review

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.data.ideashell.NoteBrief
import com.carpe.ideashell.data.ideashell.NoteInfo
import com.carpe.ideashell.domain.Dossier
import com.carpe.ideashell.domain.DossierData
import com.carpe.ideashell.domain.DossierStats
import com.carpe.ideashell.domain.MemoryData
import com.carpe.ideashell.ui.components.DividedRows
import com.carpe.ideashell.ui.components.GroupLabel
import com.carpe.ideashell.ui.components.MarkdownText
import com.carpe.ideashell.ui.components.ListGroup
import com.carpe.ideashell.ui.components.NoticeLine
import com.carpe.ideashell.ui.components.RowDivider
import java.time.LocalDate

// ───────────────────────── Daily Note ─────────────────────────

private val RE_DAY = Regex("\\d{4}-\\d{2}-\\d{2}")

fun LazyListScope.dailyItems(
    state: Async<List<NoteBrief>>,
    today: Async<TodayDaily>,
    folderName: String,
    onOpenNote: (String) -> Unit,
    onRetry: () -> Unit,
) {
    val list = state.data
    when {
        list == null && state.error != null -> item(key = "dn-error") {
            InfoCard("没能加载 Daily Note", state.error.orEmpty(), "重试", onRetry)
        }

        list == null -> item(key = "dn-loading") { LoadingBlock() }

        else -> {
            state.error?.let { err -> item(key = "dn-stale") { NoticeLine(err) } }
            val todayDate = LocalDate.now()

            // 今天：直接把正文摊开，不用再点进去
            item(key = "dn-today") {
                TodayDailyBlock(todayDate, today, folderName, onOpenNote, onRetry)
            }

            // 往期：已按日期倒序，按「年-月」分组后顺序不变；今天那一篇上面已经展示，这里去掉
            val past = list.filter { RE_DAY.find(it.title)?.value != todayDate.toString() }
            if (past.isNotEmpty()) {
                item(key = "dn-past") {
                    GroupLabel(text = "往期", count = past.size)
                }
                past.groupBy { RE_DAY.find(it.title)?.value?.take(7) ?: "其他" }.forEach { (month, notes) ->
                    item(key = "dn-$month") {
                        Column(Modifier.animateItem()) {
                            GroupLabel(
                                text = if (month == "其他") "其他" else "${month.take(4)} 年 ${month.drop(5).trimStart('0')} 月",
                                count = notes.size,
                            )
                            ListGroup(Modifier.padding(top = 2.dp)) {
                                DividedRows(notes) { DailyRow(it, todayDate, onOpenNote) }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** 今天的 Daily Note：标题 + 全文（Markdown）；还没有时给出写法提示 */
@Composable
private fun TodayDailyBlock(
    today: LocalDate,
    state: Async<TodayDaily>,
    folderName: String,
    onOpenNote: (String) -> Unit,
    onRetry: () -> Unit,
) {
    val note = state.data?.note
    Column {
        GroupLabel(
            text = "今天 · ${dayTitle(today)}",
            color = MaterialTheme.colorScheme.primary,
            trailing = {
                if (note != null) {
                    TextButton(onClick = { onOpenNote(note.id) }) { Text("打开全文") }
                }
            },
        )
        ListGroup(Modifier.padding(top = 2.dp)) {
            when {
                state.data == null && state.error != null -> Column(
                    Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        "今天的内容没能加载：${state.error}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    TextButton(onClick = onRetry) { Text("重试") }
                }

                state.data == null -> LoadingBlock()

                note == null -> Text(
                    "今天还没有 Daily Note。在「记录」页用「日记 …」开头写一句，内容会追加到当天的 Daily Note（文件夹「$folderName」）。",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(16.dp),
                )

                note.content.isBlank() -> Text(
                    "今天的 Daily Note 还是空的。",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(16.dp),
                )

                else -> Box(Modifier.padding(horizontal = 16.dp, vertical = 14.dp)) {
                    MarkdownText(note.content)
                }
            }
        }
    }
}

@Composable
private fun DailyRow(note: NoteBrief, today: LocalDate, onOpenNote: (String) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val date = RE_DAY.find(note.title)?.value?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onOpenNote(note.id) }
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            date?.let { dayTitle(it) } ?: note.title,
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.weight(1f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (date == today) {
            Text("今天", style = MaterialTheme.typography.labelMedium, color = scheme.primary)
        } else if (date != null && date == today.minusDays(1)) {
            Text("昨天", style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant)
        }
    }
}

// ───────────────────────── 往日回顾 ─────────────────────────

fun LazyListScope.memoryItems(
    state: Async<MemoryData>,
    randomNote: NoteInfo?,
    onShuffle: () -> Unit,
    onOpenNote: (String) -> Unit,
    onRetry: () -> Unit,
) {
    val data = state.data
    when {
        data == null && state.error != null -> item(key = "ml-error") {
            InfoCard("没能加载往日回顾", state.error.orEmpty(), "重试", onRetry)
        }

        data == null -> item(key = "ml-loading") { LoadingBlock() }

        else -> {
            state.error?.let { err -> item(key = "ml-stale") { NoticeLine(err) } }
            if (data.truncated) {
                item(key = "ml-truncated") { NoticeLine("部分时间段的笔记太多没有取全，回顾可能不完整。") }
            }

            if (randomNote != null) {
                item(key = "ml-random") {
                    Column(Modifier.animateItem()) {
                        GroupLabel(
                            text = "随机回顾",
                            trailing = { TextButton(onClick = onShuffle) { Text("换一条") } },
                        )
                        ListGroup(Modifier.padding(top = 2.dp)) {
                            NoteRow(randomNote, onClick = { onOpenNote(randomNote.id) })
                        }
                    }
                }
            }

            if (data.sameDay.isEmpty()) {
                item(key = "ml-empty") {
                    InfoCard("往年的今天没有记录", "往日回顾按日历推算：1 / 2 周前、1 / 2 / 3 / 6 个月前，以及过去 5 年的同一天。")
                }
            } else {
                data.sameDay.forEach { group ->
                    item(key = "ml-${group.date}") {
                        Column(Modifier.animateItem()) {
                            GroupLabel(
                                text = group.label,
                                trailing = {
                                    Text(
                                        group.date.toString(),
                                        style = MaterialTheme.typography.labelMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.padding(end = 8.dp),
                                    )
                                },
                            )
                            ListGroup(Modifier.padding(top = 2.dp)) {
                                DividedRows(group.notes) { note ->
                                    NoteRow(note, onClick = { onOpenNote(note.id) }, showDate = false)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// ───────────────────────── 人物 / 主题档案 ─────────────────────────

fun LazyListScope.dossierItems(
    text: String,
    onTextChange: (String) -> Unit,
    state: Async<DossierData>,
    onSearch: () -> Unit,
    onCopyBrief: () -> Unit,
    onOpenNote: (String) -> Unit,
    onRetry: () -> Unit,
) {
    item(key = "ds-field") {
        GlassSearchField(text, onTextChange, "人名、项目名或主题", onSearch)
    }

    val data = state.data
    when {
        state.loading && data == null -> item(key = "ds-loading") { LoadingBlock() }

        state.error != null && data == null -> item(key = "ds-error") {
            InfoCard("档案生成失败", state.error.orEmpty(), "重试", onRetry)
        }

        data == null -> item(key = "ds-hint") {
            InfoCard(
                "人物 / 主题档案",
                "输入一个名字或关键词，聚合所有提到它的笔记、相关待办和录音发言，统计首次 / 最近提及与近 12 个月的频率。",
            )
        }

        else -> {
            item(key = "ds-summary") { DossierSummary(data, onCopyBrief) }

            val direct = data.direct
            if (direct.isNotEmpty()) {
                item(key = "ds-direct") {
                    Column {
                        GroupLabel("直接提及", count = direct.size)
                        ListGroup(Modifier.padding(top = 2.dp)) {
                            DividedRows(direct) { n ->
                                NoteRow(
                                    n.note,
                                    onClick = { onOpenNote(n.note.id) },
                                    snippet = (if (n.viaSpeaker && n.mentions == 0) "有其发言　" else "") + n.snippet,
                                )
                            }
                        }
                    }
                }
            }

            val related = data.related
            if (related.isNotEmpty()) {
                item(key = "ds-related") {
                    Column {
                        GroupLabel("可能相关 · 语义相近", count = related.size)
                        ListGroup(Modifier.padding(top = 2.dp)) {
                            DividedRows(related) { n -> NoteRow(n.note, onClick = { onOpenNote(n.note.id) }) }
                        }
                    }
                }
            }

            if (data.todos.isNotEmpty()) {
                item(key = "ds-todos") {
                    val scheme = MaterialTheme.colorScheme
                    Column {
                        GroupLabel("相关待办 · ${data.todos.count { !it.done }} 未完成 · ${data.todos.count { it.done }} 已完成")
                        ListGroup(Modifier.padding(top = 2.dp)) {
                            DividedRows(data.todos.take(20)) { t ->
                                Row(
                                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Text(
                                        if (t.done) "✓" else "○",
                                        color = if (t.done) scheme.primary else scheme.onSurfaceVariant,
                                        modifier = Modifier.width(28.dp),
                                    )
                                    Text(
                                        t.title,
                                        style = MaterialTheme.typography.bodyMedium,
                                        textDecoration = if (t.done) TextDecoration.LineThrough else null,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f),
                                    )
                                    val whenText = listOfNotNull(t.date, t.time).joinToString(" ")
                                    if (whenText.isNotEmpty()) {
                                        Text(whenText, style = MaterialTheme.typography.labelSmall, color = scheme.onSurfaceVariant, modifier = Modifier.padding(start = 8.dp))
                                    }
                                }
                            }
                            if (data.todos.size > 20) {
                                RowDivider()
                                Text(
                                    "另有 ${data.todos.size - 20} 条",
                                    style = MaterialTheme.typography.labelMedium,
                                    color = scheme.onSurfaceVariant,
                                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DossierSummary(data: DossierData, onCopyBrief: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Column {
        GroupLabel(
            text = "「${data.query}」档案",
            trailing = { TextButton(onClick = onCopyBrief) { Text("复制简报") } },
        )
        ListGroup(Modifier.padding(top = 2.dp)) {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    "直接提及 ${data.directCount} 条笔记，另有 ${data.related.size} 条语义相关",
                    style = MaterialTheme.typography.bodyMedium,
                    color = scheme.onSurfaceVariant,
                )

                val stats = data.stats
                if (stats == null && data.todos.isEmpty()) {
                    Text(
                        "没有找到直接提及的记录。下方「可能相关」是语义相近的笔记，换个叫法（全名 / 昵称 / 项目代号）再试试。",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
                if (stats != null) {
                    val today = LocalDate.now()
                    FactRow("首次提及", "${stats.firstDay}　${Dossier.ago(Dossier.daysBetween(stats.firstDay, today))}")
                    FactRow("最近提及", "${stats.lastDay}　${Dossier.ago(stats.gapDays)}")
                    FactRow("累计提及", "${stats.totalMentions} 次 · ${stats.distinctDays} 个日期")
                    if (stats.monthCounts.any { it > 0 }) MonthBars(stats)
                }
                if (data.speakers.isNotEmpty()) {
                    FactRow("说话人", "${data.speakers.joinToString("、") { it.name }}　有发言的笔记 ${data.voiceCount} 条")
                }
                if (data.topTags.isNotEmpty()) {
                    FactRow("常伴随标签", data.topTags.joinToString("　") { "#${it.first} ${it.second}" })
                }
                stats?.takeIf { it.gapDays >= 30 }?.let {
                    Text(
                        "距上次提及已 ${it.gapDays} 天，见面 / 推进前也许值得先补一条近况。",
                        style = MaterialTheme.typography.bodySmall,
                        color = scheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun FactRow(label: String, value: String) {
    Row(verticalAlignment = Alignment.Top) {
        Text(
            label,
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(76.dp),
        )
        Text(value, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
    }
}

/** 近 12 个月每月提及笔记数的柱状图 */
@Composable
private fun MonthBars(stats: DossierStats) {
    val scheme = MaterialTheme.colorScheme
    val max = (stats.monthCounts.maxOrNull() ?: 1).coerceAtLeast(1)
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth().height(44.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            stats.monthCounts.forEach { c ->
                Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.BottomCenter) {
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .fillMaxHeight(if (c == 0) 0.06f else (0.18f + 0.82f * c / max))
                            .clip(CircleShape)
                            .background(if (c == 0) scheme.onSurface.copy(alpha = 0.12f) else scheme.primary),
                    )
                }
            }
        }
        Row(Modifier.fillMaxWidth()) {
            Text(stats.monthLabels.first().drop(2), style = MaterialTheme.typography.labelSmall, color = scheme.onSurfaceVariant, modifier = Modifier.weight(1f))
            Text("近 12 个月", style = MaterialTheme.typography.labelSmall, color = scheme.onSurfaceVariant)
            Text(
                stats.monthLabels.last().drop(2),
                style = MaterialTheme.typography.labelSmall,
                color = scheme.onSurfaceVariant,
                modifier = Modifier.weight(1f),
                textAlign = TextAlign.End,
            )
        }
    }
}
