package com.carpe.ideashell.ui.todos

import androidx.compose.foundation.clickable
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

    // 里程碑与进展：最新在上，默认 5 条
    item(key = "home-milestone") {
        val all = itemsOf(NoteSections.sectionBody(text, SEC_MILESTONE)).asReversed()
        var expanded by remember { mutableStateOf(false) }
        val shown = if (expanded) all else all.take(5)
        SectionCard(
            title = "里程碑与进展",
            count = all.size.takeIf { it > 0 },
            action = "记一条",
            onAction = {
                onEdit(
                    HomeEditTarget(
                        SEC_MILESTONE, "记一条进展 · ${project.keyword}", "进展", "会自动带上当前时间，写进笔记的「里程碑与进展」。", "", HomeEditMode.MILESTONE,
                    ),
                )
            },
        ) {
            if (all.isEmpty()) Hint("还没有记录。完成相关任务时会自动记一行，也可以自己记。")
            shown.forEach { line -> MilestoneRow(line, onOpenNote) }
            if (all.size > 5) {
                TextButton(onClick = { expanded = !expanded }) { Text(if (expanded) "收起" else "还有 ${all.size - 5} 条 ›") }
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

@Composable
private fun MilestoneRow(line: String, onOpenNote: (String) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val m = STAMPED.find(line)
    val date = m?.let { "${it.groupValues[2]}${it.groupValues[3].takeIf { t -> t.isNotEmpty() }?.let { t -> " $t" } ?: ""}" }
    val body = m?.groupValues?.get(4)?.ifEmpty { line } ?: line
    val url = firstUrl(body)
    val open = if (url != null) openLink(url, onOpenNote) else null
    Row(
        modifier = Modifier.fillMaxWidth().then(if (open != null) Modifier.clickable(onClick = open) else Modifier),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            date.orEmpty(),
            fontSize = 12.sp,
            lineHeight = 20.sp,
            fontWeight = FontWeight.ExtraBold,
            color = scheme.primary,
            modifier = Modifier.width(84.dp),
        )
        Text(
            plain(body),
            style = MaterialTheme.typography.bodyMedium,
            color = if (open != null) scheme.primary else scheme.onSurface,
            modifier = Modifier.weight(1f),
        )
    }
}

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
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        if (m != null) {
            Text(
                "${m.groupValues[1]}-${m.groupValues[2]}" + m.groupValues[3].takeIf { it.isNotEmpty() }?.let { " $it" }.orEmpty(),
                fontSize = 12.sp,
                fontWeight = FontWeight.ExtraBold,
                color = scheme.primary,
            )
        }
        MarkdownText(m?.groupValues?.get(4)?.ifEmpty { para } ?: para)
    }
}
