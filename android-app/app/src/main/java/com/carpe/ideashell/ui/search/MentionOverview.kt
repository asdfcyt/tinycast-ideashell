package com.carpe.ideashell.ui.search

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.data.project.Project
import com.carpe.ideashell.domain.Dossier
import com.carpe.ideashell.domain.DossierData
import com.carpe.ideashell.domain.DossierStats
import com.carpe.ideashell.ui.components.ListGroup
import com.carpe.ideashell.ui.review.Async
import java.time.LocalDate

/**
 * 搜索结果里的「提及概览」：这个词在笔记里什么时候第一次、最近一次出现、近 12 个月的频率、常一起出现的标签。
 * 原来「回顾」里的人物 / 主题档案搬到了这里：已经成了项目的词，完整的数据在项目页；还不是项目的词，在这里看个大概，
 * 觉得值得长期跟，就一键设为项目。点开才加载，不拖慢搜索本身。
 */
@Composable
fun MentionOverview(
    keyword: String,
    open: Boolean,
    state: Async<DossierData>,
    project: Project?,
    onToggle: () -> Unit,
    onRetry: () -> Unit,
    onMakeProject: () -> Unit,
    onOpenProject: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    ListGroup(modifier) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 52.dp)
                .clickable(onClick = onToggle)
                .padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("「$keyword」提及概览", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
            Icon(
                if (open) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                contentDescription = if (open) "收起" else "展开",
                tint = scheme.onSurfaceVariant,
            )
        }
        if (!open) return@ListGroup

        val data = state.data
        when {
            data == null && state.error != null -> Column(
                Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(state.error, style = MaterialTheme.typography.bodyMedium, color = scheme.onSurfaceVariant)
                TextButton(onClick = onRetry) { Text("重试") }
            }

            data == null -> Box(Modifier.fillMaxWidth().padding(vertical = 24.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }

            else -> OverviewBody(data, project, onMakeProject, onOpenProject)
        }
    }
}

@Composable
private fun OverviewBody(
    data: DossierData,
    project: Project?,
    onMakeProject: () -> Unit,
    onOpenProject: (String) -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val stats = data.stats

    Column(
        Modifier.padding(start = 16.dp, end = 16.dp, bottom = 8.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            "直接提及 ${data.directCount} 条笔记，另有 ${data.related.size} 条语义相关",
            style = MaterialTheme.typography.bodyMedium,
            color = scheme.onSurfaceVariant,
        )
        if (stats == null) {
            Text(
                "没有找到直接提及的记录。换个叫法（全名 / 昵称 / 项目代号）再搜一次。",
                style = MaterialTheme.typography.bodyMedium,
            )
        } else {
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

        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            TextButton(onClick = {
                clipboard.setText(AnnotatedString(data.brief))
                Toast.makeText(context, "简报已复制", Toast.LENGTH_SHORT).show()
            }) { Text("复制简报") }
            if (project != null) {
                TextButton(onClick = { onOpenProject(project.keyword) }) { Text("打开项目页") }
            } else if (data.query.trim().trimStart('#').length >= Project.MIN_TERM_LENGTH) {
                // 太短的词（单个字）会把大量无关任务算进项目，不提供「设为项目」
                TextButton(onClick = {
                    onMakeProject()
                    Toast.makeText(context, "已设为项目「${data.query}」", Toast.LENGTH_SHORT).show()
                }) { Text("设为项目") }
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
