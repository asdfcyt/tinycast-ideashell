package com.carpe.ideashell.ui.todos

import androidx.compose.foundation.clickable
import com.carpe.ideashell.ui.theme.Brand
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.draw.clip
import androidx.compose.material3.Icon
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.Icons
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.carpe.ideashell.core.notes.NoteSections
import com.carpe.ideashell.ui.components.GroupLabel
import com.carpe.ideashell.ui.components.ListGroup
import com.carpe.ideashell.ui.components.MarkdownText
import com.carpe.ideashell.ui.components.RowPill

/*
 * 项目主页笔记在闪念贝壳里是一篇完整的笔记，用 `## 小节` 划分；
 * 这里把每个小节拆成独立的组件来显示，往组件里「添加」的内容会写回那篇笔记对应的小节。
 *
 *   目标 / 交付成果      整节文字，可编辑
 *   里程碑与进展         带时间的记录，最新在上，可追加一行
 *   资料与链接           列表，链接可点开，可追加
 *   复盘与经验           带时间的段落，最新在上，可追加
 *   项目状态（自动汇总）  只读，「更新汇总」按钮重新生成
 * 「任务笔记（自动汇总）」不单独显示：页面上的「任务笔记」组件本来就是实时的。
 */

/** 点了某个组件的「添加 / 编辑」：对话框要写哪个小节、怎么写 */
internal class HomeEditTarget(
    val section: String,
    val title: String,
    val label: String,
    val hint: String,
    val initial: String,
    val mode: HomeEditMode,
)

private const val SEC_GOAL = "目标"
private const val SEC_DELIVER = "交付成果"
private const val SEC_LINKS = "资料与链接"
private const val SEC_MILESTONE = "里程碑与进展"
private const val SEC_REVIEW = "复盘与经验"
private const val SEC_STATUS = "项目状态（自动汇总）"

private val STAMPED = Regex("^(\\d{4})-(\\d{2}-\\d{2})(?: (\\d{2}:\\d{2}))?[\\s：:]*(.*)$", RegexOption.DOT_MATCHES_ALL)
private val MD_LINK = Regex("\\[([^\\]]+)]\\(([^)\\s]+)\\)")
private val BARE_URL = Regex("https?://[^\\s)]+")
private val BOARD_ID = Regex("/boards/([a-f0-9]+)", RegexOption.IGNORE_CASE)

/** 去掉 Markdown 链接的外壳，只留文字 */
private fun plain(text: String): String = MD_LINK.replace(text) { it.groupValues[1] }

private fun firstUrl(text: String): String? =
    MD_LINK.find(text)?.groupValues?.get(2) ?: BARE_URL.find(text)?.value

/** 小节正文按行拆成条目：去掉列表符号和占位行 */
private fun itemsOf(body: String?): List<String> =
    body.orEmpty().lines()
        .filterNot { NoteSections.isPlaceholderLine(it) }
        .map { it.trim().removePrefix("-").removePrefix("*").trim() }
        .filter { it.isNotEmpty() }

/** 小节正文按空行拆成段落 */
private fun paragraphsOf(body: String?): List<String> =
    body.orEmpty().split(Regex("\\n\\s*\\n"))
        .map { it.trim() }
        .filter { it.isNotEmpty() && !NoteSections.isPlaceholderLine(it) }

private fun withoutPlaceholder(body: String?): String =
    body.orEmpty().lines().filterNot { NoteSections.isPlaceholderLine(it) }.joinToString("\n").trim()

@Composable
private fun SectionCard(
    title: String,
    modifier: Modifier = Modifier,
    count: Int? = null,
    action: String? = null,
    onAction: () -> Unit = {},
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        GroupLabel(
            title,
            count = count,
            trailing = if (action != null) {
                { TextButton(onClick = onAction) { Text(action) } }
            } else {
                null
            },
        )
        ListGroup {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp), content = content)
        }
    }
}

@Composable
private fun Hint(text: String) {
    Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** 主页笔记还没建：一行入口，点一下创建；已经有就什么都不放（组件在下面） */
internal fun LazyListScope.homeCreateEntry(homeId: String?, busy: Boolean, onCreate: () -> Unit) {
    if (homeId != null) return
    item(key = "home-create") {
        RowPill(onClick = onCreate) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("创建项目主页笔记", style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
                    Text(
                        "目标、交付成果、里程碑、资料、复盘会在这里分成组件，往里添加的内容同步到闪念贝壳的那篇笔记。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                if (busy) CircularProgressIndicator(Modifier.padding(start = 12.dp).size(18.dp), strokeWidth = 2.dp)
            }
        }
    }
}

/** 页面靠上的两个组件：目标、交付成果（整节文字，可编辑） */
internal fun LazyListScope.homeTopSections(homeId: String?, text: String?, onEdit: (HomeEditTarget) -> Unit) {
    if (homeId == null) return
    if (text == null) {
        item(key = "home-loading") { Hint("正在读取项目主页笔记…") }
        return
    }
    textSection("home-goal", "目标", SEC_GOAL, "这个项目最终要达成什么？", NoteSections.sectionBody(text, SEC_GOAL), onEdit)
    textSection("home-deliver", "交付成果", SEC_DELIVER, "要交付的成果，而不是要做的事情。例如「完成一篇可发表的论文初稿」", NoteSections.sectionBody(text, SEC_DELIVER), onEdit)
}

private fun LazyListScope.textSection(
    key: String,
    title: String,
    section: String,
    hint: String,
    body: String?,
    onEdit: (HomeEditTarget) -> Unit,
) {
    item(key = key) {
        val shown = withoutPlaceholder(body)
        SectionCard(
            title = title,
            action = if (shown.isEmpty()) "写下" else "编辑",
            onAction = { onEdit(HomeEditTarget(section, title, title, hint, shown, HomeEditMode.REPLACE)) },
        ) {
            if (shown.isEmpty()) Hint(hint) else MarkdownText(shown)
        }
    }
}

/** 页面靠下的组件：里程碑与进展、资料与链接、复盘与经验、项目状态，最后是「打开完整笔记」 */
internal fun LazyListScope.homeBottomSections(
    project: com.carpe.ideashell.data.project.Project,
    homeId: String?,
    text: String?,
    busy: Boolean,
    onEdit: (HomeEditTarget) -> Unit,
    onRefresh: () -> Unit,
    onOpenNote: (String) -> Unit,
) {
    if (homeId == null || text == null) return

    // 里程碑与进展：每个完成的任务笔记一张卡（成果 + 完成日期 + 复盘总结），最新在上，默认 4 项
    item(key = "home-milestone") {
        val entries = remember(text) { milestoneEntries(itemsOf(NoteSections.sectionBody(text, SEC_MILESTONE))) }
        var expanded by remember { mutableStateOf(false) }
        val shown = if (expanded) entries else entries.take(MILESTONE_PREVIEW)
        SectionCard(
            title = "里程碑与进展",
            count = entries.size.takeIf { it > 0 },
            action = "记一条",
            onAction = {
                onEdit(
                    HomeEditTarget(
                        SEC_MILESTONE, "记一条进展 · ${project.keyword}", "进展", "会自动带上当前时间，写进笔记的「里程碑与进展」。", "", HomeEditMode.MILESTONE,
                    ),
                )
            },
        ) {
            if (entries.isEmpty()) Hint("还没有里程碑。任务完成后，任务笔记的复盘总结会汇到这里。")
            shown.forEachIndexed { i, e ->
                if (i > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
                when (e) {
                    is MilestoneEntry.Done -> MilestoneCard(e, onOpenNote)
                    is MilestoneEntry.Note -> NoteLine(e)
                }
            }
            if (entries.size > MILESTONE_PREVIEW) {
                TextButton(onClick = { expanded = !expanded }) { Text(if (expanded) "收起" else "还有 ${entries.size - MILESTONE_PREVIEW} 项 ›") }
            }
        }
    }

    // 资料与链接：链接可点开
    item(key = "home-links") {
        val all = itemsOf(NoteSections.sectionBody(text, SEC_LINKS))
        SectionCard(
            title = "资料与链接",
            count = all.size.takeIf { it > 0 },
            action = "添加",
            onAction = {
                onEdit(
                    HomeEditTarget(
                        SEC_LINKS, "添加资料 · ${project.keyword}", "链接或说明", "一行一条；链接可以写成 [名称](网址)。", "", HomeEditMode.LINK,
                    ),
                )
            },
        ) {
            if (all.isEmpty()) Hint("把资料、链接贴在这里。")
            all.forEach { line -> LinkRow(line, onOpenNote) }
        }
    }

    // 复盘与经验：最新在上，默认 3 段
    item(key = "home-review") {
        val all = paragraphsOf(NoteSections.sectionBody(text, SEC_REVIEW)).asReversed()
        var expanded by remember { mutableStateOf(false) }
        val shown = if (expanded) all else all.take(3)
        SectionCard(
            title = "复盘与经验",
            count = all.size.takeIf { it > 0 },
            action = "写复盘",
            onAction = {
                onEdit(
                    HomeEditTarget(
                        SEC_REVIEW, "写复盘 · ${project.keyword}", "复盘", "做得好的、踩过的坑、下次怎么做。会自动带上当前时间。", "", HomeEditMode.REVIEW,
                    ),
                )
            },
        ) {
            if (all.isEmpty()) Hint("项目告一段落，或者踩了坑，就在这里记一笔。")
            shown.forEach { para -> ReviewBlock(para) }
            if (all.size > 3) {
                TextButton(onClick = { expanded = !expanded }) { Text(if (expanded) "收起" else "还有 ${all.size - 3} 段 ›") }
            }
        }
    }

    // 项目状态（自动汇总）：只读
    item(key = "home-status") {
        val body = withoutPlaceholder(NoteSections.sectionBody(text, SEC_STATUS))
        SectionCard(
            title = "项目状态",
            action = if (busy) "更新中…" else "更新汇总",
            onAction = { if (!busy) onRefresh() },
        ) {
            if (body.isEmpty()) Hint("点右上角「更新汇总」：写入下一步、成果进度、近 7 天专注。") else MarkdownText(body)
        }
    }

    item(key = "home-full") {
        RowPill(onClick = { onOpenNote(homeId) }) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("打开完整的项目主页笔记", style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                Text("›", style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun openLink(url: String, onOpenNote: (String) -> Unit): () -> Unit {
    val uri = LocalUriHandler.current
    return {
        val id = BOARD_ID.find(url)?.groupValues?.get(1)
        if (id != null) onOpenNote(id) else runCatching { uri.openUri(url) }
    }
}

private const val MILESTONE_PREVIEW = 4

/** 里程碑区的一项：完成的成果（带复盘总结），或一句单独的记录 */
private sealed interface MilestoneEntry {
    val stamp: String

    /** [review]：任务笔记复盘总结；[process]：完成之前记过的进展 / 专注记录（折叠） */
    class Done(
        override val stamp: String,
        val title: String,
        val url: String?,
        val review: List<String>,
        val process: List<Pair<String, String>>,
    ) : MilestoneEntry

    class Note(override val stamp: String, val text: String) : MilestoneEntry
}

private val RE_DONE = Regex("^完成[：:]\\s*(.*?)(?:（\\[任务笔记]\\(([^)\\s]+)\\)）)?$", RegexOption.DOT_MATCHES_ALL)
private val RE_TAGGED = Regex("^〔([^〕]*)〕\\s*(.*)$", RegexOption.DOT_MATCHES_ALL)
private val RE_REVIEW = Regex("^复盘[：:]\\s*(.*)$", RegexOption.DOT_MATCHES_ALL)

private fun stampOf(m: MatchResult): String =
    "${m.groupValues[1]}-${m.groupValues[2]}" + m.groupValues[3].takeIf { it.isNotEmpty() }?.let { " $it" }.orEmpty()

/**
 * 把「里程碑与进展」里的行整理成条目：「完成：成果」是一张卡，带上同一成果的「〔成果〕复盘：…」作为复盘总结，
 * 同一成果的其他「〔成果〕…」记录归为折叠的过程；没有对应完成行的记录单独成行。最新在上。
 */
private fun milestoneEntries(lines: List<String>): List<MilestoneEntry> {
    class Ln(val stamp: String, val body: String)
    val rows = lines.map { line ->
        val m = STAMPED.find(line)
        if (m != null) Ln(stampOf(m), m.groupValues[4].ifEmpty { line }) else Ln("", line)
    }
    val doneTitles = rows.mapNotNull { r -> RE_DONE.find(r.body)?.groupValues?.get(1)?.trim()?.takeIf { it.isNotEmpty() } }.toSet()
    val review = HashMap<String, MutableList<String>>()
    val process = HashMap<String, MutableList<Pair<String, String>>>()
    val out = mutableListOf<MilestoneEntry>()
    for (r in rows) {
        val done = RE_DONE.find(r.body)
        if (done != null) continue
        val tagged = RE_TAGGED.find(r.body)
        val tag = tagged?.groupValues?.get(1)?.trim()
        if (tagged != null && tag != null && tag in doneTitles) {
            val rest = tagged.groupValues[2].trim()
            val rv = RE_REVIEW.find(rest)
            if (rv != null) review.getOrPut(tag) { mutableListOf() } += rv.groupValues[1].trim()
            else process.getOrPut(tag) { mutableListOf() } += r.stamp to rest
        } else {
            out += MilestoneEntry.Note(r.stamp, if (tagged != null) "${tag.orEmpty()} · ${tagged.groupValues[2].trim()}" else r.body)
        }
    }
    // 同一个成果可能完成过不止一次（重新打开再完成）：合并成一张卡，取最新的完成时间；复盘和过程按正文去重
    val dones = LinkedHashMap<String, Pair<String, String?>>()
    for (r in rows) {
        val done = RE_DONE.find(r.body) ?: continue
        val title = done.groupValues[1].trim().ifEmpty { "已完成" }
        val url = done.groupValues[2].takeIf { it.isNotEmpty() }
        val old = dones[title]
        dones[title] = if (old == null) r.stamp to url else maxOf(old.first, r.stamp) to (url ?: old.second)
    }
    for ((title, v) in dones) {
        out += MilestoneEntry.Done(
            stamp = v.first,
            title = title,
            url = v.second,
            review = review[title].orEmpty().map { it.trim() }.filter { it.isNotBlank() }.distinct(),
            process = process[title].orEmpty().filter { it.second.isNotBlank() }.distinctBy { it.second.trim() },
        )
    }
    return out.sortedByDescending { it.stamp }
}

private fun shortStamp(stamp: String): String = if (stamp.length >= 10) stamp.substring(5) else stamp

/** 一个完成的成果：对勾 + 成果名 + 完成日期，下面是复盘总结（点一下展开 / 收起），再下面是折叠的过程记录 */
@Composable
private fun MilestoneCard(e: MilestoneEntry.Done, onOpenNote: (String) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    var open by remember(e.stamp, e.title) { mutableStateOf(false) }
    var showProcess by remember(e.stamp, e.title) { mutableStateOf(false) }
    val summary = e.review.joinToString("\n")
    val expandable = summary.length > 70 || e.review.size > 1 || e.process.isNotEmpty()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (expandable) Modifier.clickable { open = !open } else Modifier),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            Modifier.padding(top = 1.dp).size(22.dp).clip(CircleShape).background(Brand.Orange),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.Check, contentDescription = null, tint = Brand.Brown, modifier = Modifier.size(14.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    plain(e.title),
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Bold,
                    maxLines = if (open) Int.MAX_VALUE else 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    shortStamp(e.stamp).substringBefore(' '),
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = scheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 8.dp),
                )
            }
            if (summary.isNotEmpty()) {
                Text(
                    summary,
                    style = MaterialTheme.typography.bodyMedium,
                    color = scheme.onSurfaceVariant,
                    maxLines = if (open) Int.MAX_VALUE else 3,
                    overflow = TextOverflow.Ellipsis,
                )
            } else {
                Text("还没有复盘总结", style = MaterialTheme.typography.bodySmall, color = scheme.onSurfaceVariant.copy(alpha = 0.7f))
            }
            if (open) {
                if (e.process.isNotEmpty()) {
                    Text(
                        if (showProcess) "收起过程记录" else "过程记录 ${e.process.size} 条 ›",
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.Bold,
                        color = scheme.primary,
                        modifier = Modifier.clickable { showProcess = !showProcess }.padding(vertical = 2.dp),
                    )
                    if (showProcess) {
                        e.process.forEach { (stamp, body) ->
                            Text(
                                (if (stamp.isNotEmpty()) "${shortStamp(stamp)}  " else "") + plain(body),
                                style = MaterialTheme.typography.bodySmall,
                                color = scheme.onSurfaceVariant,
                            )
                        }
                    }
                }
                if (e.url != null) {
                    val openNote = openLink(e.url, onOpenNote)
                    Text(
                        "查看任务笔记 ›",
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.Bold,
                        color = scheme.primary,
                        modifier = Modifier.clickable(onClick = openNote).padding(vertical = 2.dp),
                    )
                }
            }
        }
    }
}

/** 一句单独的记录：日期在前、文字接在后面，整行铺满；太长时收起成 [FOLD_LINES] 行，点一下展开 / 收起 */
@Composable
private fun NoteLine(e: MilestoneEntry.Note) {
    val scheme = MaterialTheme.colorScheme
    var open by remember(e.stamp, e.text) { mutableStateOf(false) }
    var overflow by remember(e.stamp, e.text) { mutableStateOf(false) }
    val foldable = overflow || open
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (foldable) Modifier.clickable { open = !open } else Modifier),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            buildAnnotatedString {
                if (e.stamp.isNotEmpty()) {
                    withStyle(SpanStyle(color = scheme.primary, fontWeight = FontWeight.ExtraBold, fontSize = 12.sp)) { append(shortStamp(e.stamp)) }
                    append("  ")
                }
                append(plain(e.text))
            },
            style = MaterialTheme.typography.bodyMedium,
            color = scheme.onSurface,
            maxLines = if (open) Int.MAX_VALUE else FOLD_LINES,
            overflow = TextOverflow.Ellipsis,
            // 只在收起状态下判断是不是被截断；展开后保持「可收起」
            onTextLayout = { if (!open) overflow = it.hasVisualOverflow },
            modifier = Modifier.fillMaxWidth(),
        )
        if (foldable) {
            Text(
                if (open) "收起" else "展开",
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.Bold,
                color = scheme.primary,
            )
        }
    }
}

/** 长内容收起时显示的行数 */
private const val FOLD_LINES = 3

@Composable
private fun LinkRow(line: String, onOpenNote: (String) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val url = firstUrl(line)
    val open = if (url != null) openLink(url, onOpenNote) else null
    Row(
        modifier = Modifier.fillMaxWidth().then(if (open != null) Modifier.clickable(onClick = open) else Modifier),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            plain(line),
            style = MaterialTheme.typography.bodyMedium,
            color = if (open != null) scheme.primary else scheme.onSurface,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (open != null) Text("↗", style = MaterialTheme.typography.labelLarge, color = scheme.primary)
    }
}

@Composable
private fun ReviewBlock(para: String) {
    val scheme = MaterialTheme.colorScheme
    val m = STAMPED.find(para)
    val bodyText = m?.groupValues?.get(4)?.ifEmpty { para } ?: para
    // 太长的复盘：收起时只显示开头几行（纯文字），点一下展开成完整的 Markdown
    val long = bodyText.length > 120 || bodyText.count { it == '\n' } >= FOLD_LINES
    var open by remember(para) { mutableStateOf(false) }
    Column(
        modifier = if (long) Modifier.clickable { open = !open } else Modifier,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        if (m != null) {
            Text(
                "${m.groupValues[1]}-${m.groupValues[2]}" + m.groupValues[3].takeIf { it.isNotEmpty() }?.let { " $it" }.orEmpty(),
                fontSize = 12.sp,
                fontWeight = FontWeight.ExtraBold,
                color = scheme.primary,
            )
        }
        if (long && !open) {
            Text(
                plain(bodyText).replace(Regex("\\s*\\n\\s*"), " "),
                style = MaterialTheme.typography.bodyLarge,
                maxLines = FOLD_LINES,
                overflow = TextOverflow.Ellipsis,
            )
        } else {
            MarkdownText(bodyText)
        }
        if (long) {
            Text(
                if (open) "收起" else "展开",
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.Bold,
                color = scheme.primary,
            )
        }
    }
}
