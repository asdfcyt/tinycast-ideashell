package com.carpe.ideashell.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.data.assistant.AssistantRunner
import com.carpe.ideashell.data.assistant.AssistantTask
import com.carpe.ideashell.data.assistant.TaskTime
import com.carpe.ideashell.system.AssistantScheduler
import com.carpe.ideashell.ui.glass.GlassAlertDialog as AlertDialog
import com.carpe.ideashell.ui.glass.GlassSurface
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** 首页「定时任务」那一行的状态摘要 */
internal fun tasksSummary(tasks: List<AssistantTask>): String {
    if (tasks.isEmpty()) return "对助手说一句话就能创建"
    val now = System.currentTimeMillis()
    val next = tasks.filter { it.enabled }.mapNotNull { TaskTime.next(it, now) }.minOrNull()
    val on = tasks.count { it.enabled }
    return "${tasks.size} 个" + when {
        next != null -> " · 下次 ${nextText(next)}"
        on == 0 -> " · 已全部暂停"
        else -> " · 没有后续执行"
    }
}

/** 「今天 08:00」「明天 08:00」「6月3日 08:00」 */
private fun nextText(at: Long): String {
    val dt = Instant.ofEpochMilli(at).atZone(ZoneId.systemDefault())
    val today = LocalDate.now()
    val day = when (dt.toLocalDate()) {
        today -> "今天"
        today.plusDays(1) -> "明天"
        else -> "${dt.monthValue}月${dt.dayOfMonth}日"
    }
    return "$day %02d:%02d".format(dt.hour, dt.minute)
}

/**
 * 设置 → 定时任务：每个任务一张卡片（标题 + 开关、时间 / 条件标签、要做的事、上次结果、操作）。
 * 任务用语音创建：对助手说「每天早上八点告诉我今天的待办」「有逾期待办超过三个就提醒我」。
 */
@Composable
internal fun TasksSection(env: SettingsEnv) {
    val context = env.context
    val container = env.container
    val scope = rememberCoroutineScope()
    val tasks by container.assistantTasks.state.collectAsStateWithLifecycle()
    var running by remember { mutableStateOf<String?>(null) }
    var deleting by remember { mutableStateOf<AssistantTask?>(null) }

    if (tasks.isEmpty()) {
        EmptyTasks()
    } else {
        tasks.forEach { t ->
            TaskCard(
                task = t,
                running = running == t.id,
                onToggle = {
                    container.assistantTasks.update(t.id) { it.copy(enabled = !it.enabled) }
                    AssistantScheduler.reschedule(context)
                },
                onRun = {
                    running = t.id
                    scope.launch {
                        val r = try {
                            AssistantRunner.run(container, t, System.currentTimeMillis(), manual = true)
                        } finally {
                            running = null
                        }
                        settingsToast(context, (if (r.status == "ok") "已推送通知 · " else "") + r.text.take(40))
                    }
                },
                onDelete = { deleting = t },
            )
        }
        SettingsNote("到点会弹出通知；条件任务不满足时不打扰，一天最多通知一次。想改时间或内容，删掉后重新对助手说一遍。")
    }

    deleting?.let { t ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("删除这个任务？") },
            text = { Text("「${t.title}」") },
            confirmButton = {
                TextButton(onClick = { container.assistantTasks.remove(t.id); deleting = null }) { Text("删除") }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("取消") } },
        )
    }
}

@Composable
private fun EmptyTasks() {
    GlassSurface(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("还没有定时任务", style = MaterialTheme.typography.titleMedium)
            Text(
                "对着语音胶囊（或默认助手）说一句话，助手会帮你建好：",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            listOf(
                "每天早上八点告诉我今天的待办",
                "工作日晚上十点总结一下我今天做了什么",
                "有逾期的待办超过三个就提醒我",
            ).forEach { example ->
                Text("「$example」", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.primary)
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun TaskCard(task: AssistantTask, running: Boolean, onToggle: () -> Unit, onRun: () -> Unit, onDelete: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    GlassSurface(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().padding(start = 18.dp, end = 10.dp, top = 14.dp, bottom = 4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    task.title,
                    style = MaterialTheme.typography.titleMedium,
                    color = if (task.enabled) scheme.onSurface else scheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f).padding(end = 8.dp),
                )
                Switch(checked = task.enabled, onCheckedChange = { onToggle() })
            }
            Spacer(Modifier.height(6.dp))
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.padding(end = 8.dp),
            ) {
                Tag(task.whenText, scheme.primary.copy(alpha = 0.12f), scheme.primary)
                task.condition?.let { Tag("条件：$it", scheme.tertiary.copy(alpha = 0.14f), scheme.tertiary) }
                val next = if (task.enabled) TaskTime.next(task, System.currentTimeMillis()) else null
                when {
                    !task.enabled -> Tag(if (task.onceDate != null) "已执行完" else "已暂停", scheme.surfaceContainerHigh, scheme.onSurfaceVariant)
                    next != null -> Tag("下次 ${nextText(next)}", scheme.surfaceContainerHigh, scheme.onSurfaceVariant)
                }
            }
            Spacer(Modifier.height(10.dp))
            Text(
                task.prompt,
                style = MaterialTheme.typography.bodyMedium,
                color = scheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(end = 8.dp),
            )
            task.runs.firstOrNull()?.let { r ->
                Spacer(Modifier.height(10.dp))
                val (dot, label) = when (r.status) {
                    "ok" -> Color(0xFF1E9E57) to "已通知"
                    "skipped" -> scheme.outline to "条件不满足，已跳过"
                    else -> scheme.error to "没能执行"
                }
                Row(verticalAlignment = Alignment.Top, modifier = Modifier.padding(end = 8.dp)) {
                    Box(Modifier.padding(top = 6.dp).size(7.dp).clip(CircleShape).background(dot))
                    Text(
                        "${formatDateTime(r.at)} · $label" + if (r.status == "ok" || r.status == "failed") "：${r.text.take(60)}" else "",
                        style = MaterialTheme.typography.bodySmall,
                        color = if (r.status == "failed") scheme.error else scheme.onSurfaceVariant,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(start = 8.dp),
                    )
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(enabled = !running, onClick = onRun) { Text(if (running) "执行中…" else "立即执行") }
                TextButton(onClick = onDelete) { Text("删除", color = scheme.error) }
            }
        }
    }
}

@Composable
private fun Tag(text: String, background: Color, content: Color) {
    Text(
        text,
        style = MaterialTheme.typography.labelMedium,
        fontWeight = FontWeight.Medium,
        color = content,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(background)
            .padding(horizontal = 10.dp, vertical = 4.dp),
    )
}
