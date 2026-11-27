package com.carpe.ideashell.ui.settings

import android.Manifest
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.data.assistant.AssistantRunner
import com.carpe.ideashell.data.assistant.AssistantTask
import com.carpe.ideashell.system.AssistantScheduler
import com.carpe.ideashell.system.ExcerptService
import com.carpe.ideashell.ui.components.AppTextField
import com.carpe.ideashell.ui.components.RowDivider
import com.carpe.ideashell.ui.glass.GlassAlertDialog as AlertDialog
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val RUN_TIME = SimpleDateFormat("M/d HH:mm", Locale.CHINA)

private fun isAssistantHeld(context: Context): Boolean =
    runCatching { context.getSystemService(RoleManager::class.java).isRoleHeld(RoleManager.ROLE_ASSISTANT) }.getOrDefault(false)

private fun toast(context: Context, text: String) = Toast.makeText(context, text, Toast.LENGTH_SHORT).show()

/**
 * 设置 → 语音助手：入口（默认助手 / 读屏幕 / 通讯录）、助手任务（定时 / 条件，对助手说「每天早上八点告诉我……」创建）、助手记忆（说「记住……」添加）。
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun AssistantSection(env: SettingsEnv) {
    val context = env.context
    val container = env.container
    val scope = rememberCoroutineScope()
    val tasks by container.assistantTasks.state.collectAsStateWithLifecycle()
    val memory by container.assistantMemory.state.collectAsStateWithLifecycle()

    var held by remember { mutableStateOf(isAssistantHeld(context)) }
    var screenOn by remember { mutableStateOf(ExcerptService.isEnabled(context)) }
    var contactsOn by remember { mutableStateOf(context.checkSelfPermission(Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED) }
    LifecycleResumeEffect(Unit) {
        held = isAssistantHeld(context)
        screenOn = ExcerptService.isEnabled(context)
        contactsOn = context.checkSelfPermission(Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED
        onPauseOrDispose { }
    }
    val roleLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { held = isAssistantHeld(context) }
    val contactsLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { contactsOn = it }
    var addMemory by remember { mutableStateOf(false) }
    var confirmClearMemory by remember { mutableStateOf(false) }
    var running by remember { mutableStateOf<String?>(null) }

    Group("入口") {
        SettingsItem(
            icon = Icons.Filled.Star,
            title = "设为默认助手",
            summary = if (held) "已设置" else "",
            onClick = {
                val rm = context.getSystemService(RoleManager::class.java)
                if (!held && rm != null && rm.isRoleAvailable(RoleManager.ROLE_ASSISTANT)) {
                    roleLauncher.launch(rm.createRequestRoleIntent(RoleManager.ROLE_ASSISTANT))
                } else {
                    runCatching { context.startActivity(Intent(Settings.ACTION_VOICE_INPUT_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                        .onFailure { toast(context, "打不开系统的助手设置") }
                }
            },
            trailing = { Chevron() },
        )
        RowDivider()
        SettingsItem(
            icon = Icons.Filled.Info,
            title = "读取屏幕",
            summary = if (screenOn) "" else "未开启",
            onClick = { ExcerptService.openAccessibilitySettings(context) },
            trailing = { Chevron() },
        )
        RowDivider()
        SettingsItem(
            icon = Icons.Filled.Info,
            title = "通讯录",
            summary = if (contactsOn) "已允许" else "未允许",
            onClick = { if (!contactsOn) contactsLauncher.launch(Manifest.permission.READ_CONTACTS) },
        )
    }

    Group("定时任务") {
        if (tasks.isEmpty()) {
            Text(
                "还没有。对助手说「每天早上八点告诉我今天的待办」。",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 14.dp),
            )
        }
        tasks.forEachIndexed { index, t ->
            if (index > 0) RowDivider()
            TaskRow(
                task = t,
                running = running == t.id,
                onRun = {
                    running = t.id
                    scope.launch {
                        val r = try {
                            AssistantRunner.run(container, t, System.currentTimeMillis(), manual = true)
                        } finally {
                            running = null
                        }
                        toast(context, (if (r.status == "ok") "已推送通知" else "") + r.text.take(40))
                    }
                },
                onToggle = {
                    container.assistantTasks.update(t.id) { it.copy(enabled = !it.enabled) }
                    AssistantScheduler.reschedule(context)
                },
                onDelete = { container.assistantTasks.remove(t.id) },
            )
        }
    }

    Group("记忆") {
        SettingsItem(icon = Icons.Filled.Add, title = "添加一条", summary = "", onClick = { addMemory = true })
        memory.reversed().forEach { m ->
            RowDivider()
            Row(
                Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp),
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            ) {
                Text(m.text, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f).padding(vertical = 12.dp))
                TextButton(onClick = { container.assistantMemory.remove(m.id) }) { Text("删除") }
            }
        }
        if (memory.isNotEmpty()) {
            RowDivider()
            SettingsItem(icon = Icons.Filled.Close, title = "清空记忆", summary = "${memory.size} 条", onClick = { confirmClearMemory = true })
        }
    }

    if (addMemory) {
        var text by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { addMemory = false },
            title = { Text("添加记忆") },
            text = { AppTextField(value = text, onValueChange = { text = it }, placeholder = "例如：我周三不开会") },
            confirmButton = {
                TextButton(enabled = text.isNotBlank(), onClick = {
                    container.assistantMemory.add(text).onFailure { toast(context, it.message ?: "没记成") }
                    addMemory = false
                }) { Text("添加") }
            },
            dismissButton = { TextButton(onClick = { addMemory = false }) { Text("取消") } },
        )
    }
    if (confirmClearMemory) {
        AlertDialog(
            onDismissRequest = { confirmClearMemory = false },
            title = { Text("清空助手记忆？") },
            confirmButton = { TextButton(onClick = { container.assistantMemory.clear(); confirmClearMemory = false }) { Text("清空") } },
            dismissButton = { TextButton(onClick = { confirmClearMemory = false }) { Text("取消") } },
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun TaskRow(task: AssistantTask, running: Boolean, onRun: () -> Unit, onToggle: () -> Unit, onDelete: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(task.title, style = MaterialTheme.typography.bodyLarge, color = if (task.enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
        Text(
            task.whenText + (task.condition?.let { " · 条件：$it" } ?: "") + if (task.enabled) "" else " · 已暂停",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.primary,
        )
        Text(task.prompt, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
        task.runs.firstOrNull()?.let { r ->
            val label = when (r.status) { "ok" -> "已通知"; "skipped" -> "跳过"; else -> "失败" }
            Text(
                "${RUN_TIME.format(Date(r.at))} $label · ${r.text.take(40)}",
                style = MaterialTheme.typography.bodySmall,
                color = if (r.status == "failed") MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
        }
        FlowRow {
            TextButton(enabled = !running, onClick = onRun) { Text(if (running) "执行中…" else "立即执行") }
            TextButton(onClick = onToggle) { Text(if (task.enabled) "暂停" else "恢复") }
            TextButton(onClick = onDelete) { Text("删除") }
        }
    }
}
