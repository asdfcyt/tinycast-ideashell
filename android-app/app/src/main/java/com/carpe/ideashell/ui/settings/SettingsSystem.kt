package com.carpe.ideashell.ui.settings

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.RadioButton
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.data.backup.BackupFile
import com.carpe.ideashell.data.settings.ThemeMode
import com.carpe.ideashell.ui.glass.GlassAlertDialog as AlertDialog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// ───────────────────────── 后台同步 ─────────────────────────

/** 首页「后台同步」那一行的状态摘要 */
internal fun SettingsEnv.backgroundSummary(): String =
    if (batteryIgnored) "电池优化已忽略" else "建议开启，离线记下的内容才能及时同步"

@Composable
internal fun BackgroundSection(env: SettingsEnv) {
    val context = env.context
    Group(null) {
        SettingsItem(
            icon = Icons.Filled.Notifications,
            title = "忽略电池优化",
            summary = if (env.batteryIgnored) "已允许" else "未允许 · 建议开启，离线记下的内容和待办修改才能及时同步",
            onClick = { if (!env.batteryIgnored) requestIgnoreBattery(context) },
        )
        SettingsItem(
            icon = Icons.Filled.Info,
            title = "应用启动管理",
            summary = "打开系统的应用信息页。在「应用启动管理」里把「拾忆」改为手动管理，打开「自启动」「关联启动」「后台活动」；再到多任务界面锁定「拾忆」卡片。不同系统版本入口略有差异。",
            onClick = { openAppDetails(context) },
        )
    }
}

// ───────────────────────── 备份与迁移 ─────────────────────────

/** 首页「备份与迁移」那一行的状态摘要 */
internal fun backupSummary(cloudBackupAt: Long): String =
    if (cloudBackupAt > 0) "上次备份到闪念贝壳：${formatDateTime(cloudBackupAt)}"
    else "导出 / 导入文件，或备份到闪念贝壳，换手机不丢数据"

@Composable
internal fun BackupSection(env: SettingsEnv) {
    val context = env.context
    val container = env.container
    val settings = env.settings
    val scope = rememberCoroutineScope()
    var backupBusy by remember { mutableStateOf(false) }
    var pendingRestore by remember { mutableStateOf<BackupFile?>(null) }
    var cloudBackupAt by remember { mutableStateOf(container.backup.lastCloudBackupAt()) }

    val exportLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        if (uri != null) {
            scope.launch {
                backupBusy = true
                runCatching {
                    val text = container.backup.encode(container.backup.build())
                    withContext(Dispatchers.IO) {
                        context.contentResolver.openOutputStream(uri)?.use { it.write(text.toByteArray()) }
                            ?: error("无法写入所选位置")
                    }
                }.onSuccess { settingsToast(context, "已导出备份文件") }
                    .onFailure { settingsToast(context, "导出失败：${it.message ?: "未知错误"}") }
                backupBusy = false
            }
        }
    }
    val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            scope.launch {
                backupBusy = true
                runCatching {
                    val text = withContext(Dispatchers.IO) {
                        context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
                            ?: error("无法读取所选文件")
                    }
                    container.backup.decode(text)
                }.onSuccess { pendingRestore = it }
                    .onFailure { settingsToast(context, it.message ?: "读取失败") }
                backupBusy = false
            }
        }
    }
    fun backupToIdeashell() {
        if (backupBusy) return
        scope.launch {
            backupBusy = true
            runCatching { container.backup.pushToIdeashell() }
                .onSuccess {
                    cloudBackupAt = container.backup.lastCloudBackupAt()
                    settingsToast(context, "已备份到闪念贝壳")
                }
                .onFailure { settingsToast(context, "备份失败：${it.message ?: "网络异常"}") }
            backupBusy = false
        }
    }
    fun restoreFromIdeashell() {
        if (backupBusy) return
        scope.launch {
            backupBusy = true
            runCatching { container.backup.pullFromIdeashell() }
                .onSuccess { pendingRestore = it }
                .onFailure { settingsToast(context, it.message ?: "读取失败") }
            backupBusy = false
        }
    }

    Group(null) {
        SettingsItem(
            icon = Icons.Filled.Share,
            title = "导出到文件",
            summary = "项目、任务笔记、模板、专注记录、设置、重温库，保存成一个 JSON 文件",
            onClick = { if (!backupBusy) exportLauncher.launch("拾忆备份-${java.time.LocalDate.now()}.json") },
        )
        SettingsItem(
            icon = Icons.Filled.Add,
            title = "从文件导入",
            summary = "选择之前导出的备份文件，合并进当前数据",
            onClick = { if (!backupBusy) importLauncher.launch(arrayOf("application/json", "text/plain", "*/*")) },
        )
    }
    Group("闪念贝壳（可选）") {
        SettingsItem(
            icon = Icons.Filled.Send,
            title = "备份到闪念贝壳",
            summary = if (!env.ideashellConnected) "请先连接闪念贝壳"
            else if (cloudBackupAt > 0) "存成一篇备份笔记（回顾里不显示）· 上次：${formatDateTime(cloudBackupAt)}"
            else "存成一篇备份笔记（回顾里不显示），换机时一键恢复",
            onClick = { if (env.ideashellConnected) backupToIdeashell() else env.onOpenConnection() },
        )
        SettingsItem(
            icon = Icons.Filled.Refresh,
            title = "每周自动备份",
            summary = autoBackupSummary(
                connected = env.ideashellConnected,
                enabled = settings.autoCloudBackup,
                lastAt = cloudBackupAt,
                error = container.settings.autoBackupError(),
            ),
            onClick = {
                if (!env.ideashellConnected) env.onOpenConnection()
                else container.settings.setAutoCloudBackup(!settings.autoCloudBackup)
            },
            trailing = {
                androidx.compose.material3.Switch(
                    checked = settings.autoCloudBackup && env.ideashellConnected,
                    onCheckedChange = {
                        if (env.ideashellConnected) container.settings.setAutoCloudBackup(it) else env.onOpenConnection()
                    },
                )
            },
        )
        SettingsItem(
            icon = Icons.Filled.Refresh,
            title = "从闪念贝壳恢复",
            summary = if (env.ideashellConnected) "读取备份笔记并合并进当前数据" else "请先连接闪念贝壳",
            onClick = { if (env.ideashellConnected) restoreFromIdeashell() else env.onOpenConnection() },
        )
    }
    SettingsNote(
        "备份不含 API Key、口令等凭证，换机后需要在「账号与连接」里重新填写。恢复是合并：同名项目 / 模板以备份为准，本机多出来的内容不会被删除。",
    )
    if (backupBusy) LinearProgressIndicator(Modifier.fillMaxWidth())

    pendingRestore?.let { file ->
        AlertDialog(
            onDismissRequest = { pendingRestore = null },
            title = { Text("恢复这份备份？") },
            text = { Text(file.summary() + "\n\n同名项目 / 模板以备份为准，本机多出来的内容不会被删除。") },
            confirmButton = {
                TextButton(onClick = {
                    pendingRestore = null
                    scope.launch {
                        runCatching { container.backup.restore(file) }
                            .onSuccess { settingsToast(context, it.text()) }
                            .onFailure { settingsToast(context, "恢复失败：${it.message ?: "未知错误"}") }
                    }
                }) { Text("恢复") }
            },
            dismissButton = { TextButton(onClick = { pendingRestore = null }) { Text("取消") } },
        )
    }
}

/** 「每周自动备份」那一行的说明：没连接 / 已开启（带上次时间与最近的失败原因）/ 未开启 */
private fun autoBackupSummary(connected: Boolean, enabled: Boolean, lastAt: Long, error: String?): String = when {
    !connected -> "请先连接闪念贝壳"
    !enabled -> "每 7 天在有网络时自动更新那篇备份笔记，不用再手动点"
    error != null -> "已开启 · 最近一次自动备份失败：$error（系统会稍后重试）"
    lastAt > 0 -> "已开启 · 每 7 天一次 · 上次：${formatDateTime(lastAt)}"
    else -> "已开启 · 每 7 天一次，马上会先备份一次"
}

// ───────────────────────── 主题 ─────────────────────────

@Composable
internal fun ThemeDialog(current: ThemeMode, onSelect: (ThemeMode) -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("主题") },
        text = {
            Column {
                ThemeMode.entries.forEach { mode ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .selectable(
                                selected = mode == current,
                                role = Role.RadioButton,
                                onClick = {
                                    onSelect(mode)
                                    onDismiss()
                                },
                            )
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = mode == current, onClick = null)
                        Text(mode.label, modifier = Modifier.padding(start = 12.dp))
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}
