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
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Settings as SettingsIcon
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.data.assistant.DeviceControl
import com.carpe.ideashell.data.settings.SpeakEngine
import com.carpe.ideashell.data.tts.SpeechOut
import com.carpe.ideashell.data.tts.TencentTts
import com.carpe.ideashell.system.ExcerptService
import com.carpe.ideashell.ui.components.AppTextField
import com.carpe.ideashell.ui.components.RowDivider
import com.carpe.ideashell.ui.glass.GlassAlertDialog as AlertDialog

private fun isAssistantHeld(context: Context): Boolean =
    runCatching { context.getSystemService(RoleManager::class.java).isRoleHeld(RoleManager.ROLE_ASSISTANT) }.getOrDefault(false)

/** 首页「语音助手」那一行的状态摘要 */
internal fun SettingsEnv.assistantSummary(): String = if (isAssistantHeld(context)) "" else "未设为默认助手"

private fun toast(context: Context, text: String) = Toast.makeText(context, text, Toast.LENGTH_SHORT).show()

/**
 * 设置 → 语音助手：入口（默认助手 / 通讯录）、语音回答（念出来）、系统权限（勿扰 / 亮度 / 无障碍）、快捷指令、
 * 复杂问题转闪念贝壳 AI 的方式、助手记忆（说「记住……」添加）。定时任务在独立的「定时任务」页。
 */
@Composable
internal fun AssistantSection(env: SettingsEnv) {
    val context = env.context
    val container = env.container
    val memory by container.assistantMemory.state.collectAsStateWithLifecycle()
    val skills by container.assistantSkills.state.collectAsStateWithLifecycle()

    var held by remember { mutableStateOf(isAssistantHeld(context)) }
    var contactsOn by remember { mutableStateOf(context.checkSelfPermission(Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED) }
    var placeLevel by remember { mutableStateOf(container.place.level()) }
    var dndOn by remember { mutableStateOf(DeviceControl.dndAccessGranted(context)) }
    var writeOn by remember { mutableStateOf(DeviceControl.writeSettingsGranted(context)) }
    LifecycleResumeEffect(Unit) {
        held = isAssistantHeld(context)
        contactsOn = context.checkSelfPermission(Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED
        placeLevel = container.place.level()
        dndOn = DeviceControl.dndAccessGranted(context)
        writeOn = DeviceControl.writeSettingsGranted(context)
        onPauseOrDispose { }
    }
    val roleLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { held = isAssistantHeld(context) }
    val contactsLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { contactsOn = it }
    val placeLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { placeLevel = container.place.level() }
    val placeAlwaysLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { placeLevel = container.place.level() }
    var addMemory by remember { mutableStateOf(false) }
    var addSkill by remember { mutableStateOf(false) }
    var speakDialog by remember { mutableStateOf<SpeakDialog?>(null) }
    var previewing by remember { mutableStateOf(false) }
    var confirmClearMemory by remember { mutableStateOf(false) }

    Group("入口") {
        SettingsItem(
            icon = Icons.Filled.Star,
            title = "设为默认助手",
            summary = if (held) "已设置" else "未设置",
            onClick = {
                // 系统的「默认数字助理应用」列表：在里面选「拾忆」。（角色申请弹窗在部分系统上会直接关掉，所以直接打开列表）
                runCatching {
                    context.startActivity(Intent(Settings.ACTION_VOICE_INPUT_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }.onSuccess {
                    toast(context, "在列表里选「拾忆」，再打开「使用屏幕和应用数据」")
                }.onFailure {
                    val rm = context.getSystemService(RoleManager::class.java)
                    if (rm != null && rm.isRoleAvailable(RoleManager.ROLE_ASSISTANT)) roleLauncher.launch(rm.createRequestRoleIntent(RoleManager.ROLE_ASSISTANT))
                    else toast(context, "打不开系统的助手设置，请到 系统设置 → 应用 → 默认应用 里选")
                }
            },
            trailing = { Chevron() },
        )
        RowDivider()
        SettingsItem(
            icon = Icons.Filled.Info,
            title = "通讯录",
            summary = if (contactsOn) "已允许" else "未允许",
            onClick = { if (!contactsOn) contactsLauncher.launch(Manifest.permission.READ_CONTACTS) },
        )
        RowDivider()
        SettingsItem(
            icon = Icons.Filled.Info,
            title = "位置",
            summary = when (placeLevel) { 0 -> "未允许"; 1 -> "仅使用时允许"; else -> "始终允许" },
            onClick = {
                when (placeLevel) {
                    0 -> placeLauncher.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
                    1 -> {
                        // 熄屏说话 / 定时任务要「始终允许」：系统会跳到应用的位置权限页，选「始终允许」
                        toast(context, "选「始终允许」")
                        placeAlwaysLauncher.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                    }
                    else -> toast(context, "已是始终允许")
                }
            },
        )
    }

    Group("语音回答") {
        SettingsSwitchItem(
            icon = Icons.Filled.Notifications,
            title = "把回答念出来",
            summary = if (env.settings.speakReply) "开启" else "关闭",
            checked = env.settings.speakReply,
            onChange = { container.settings.setSpeakReply(it) },
        )
        RowDivider()
        SettingsItem(
            icon = Icons.Filled.Star,
            title = "声音来源",
            summary = env.settings.speakEngine.label,
            onClick = { speakDialog = SpeakDialog.Engine },
            trailing = { Chevron() },
        )
        RowDivider()
        if (env.settings.speakEngine == SpeakEngine.TENCENT) {
            SettingsItem(
                icon = Icons.Filled.Info,
                title = "腾讯云音色",
                summary = TencentTts.voiceLabel(env.settings.speakTencentVoice),
                onClick = { speakDialog = SpeakDialog.Voice },
                trailing = { Chevron() },
            )
        } else {
            SettingsItem(
                icon = Icons.Filled.Info,
                title = "系统语音引擎",
                summary = systemEngineLabel(context, env.settings.speakSystemEngine),
                onClick = { speakDialog = SpeakDialog.SystemEngine },
                trailing = { Chevron() },
            )
            RowDivider()
            SettingsItem(
                icon = Icons.Filled.SettingsIcon,
                title = "系统语音设置",
                summary = "",
                onClick = { SpeechOut.openSystemTtsSettings(context) },
                trailing = { Chevron() },
            )
        }
        RowDivider()
        SettingsItem(
            icon = Icons.Filled.Build,
            title = "语速",
            summary = speedLabel(env.settings.speakSpeed),
            onClick = { speakDialog = SpeakDialog.Speed },
            trailing = { Chevron() },
        )
        RowDivider()
        SettingsItem(
            icon = Icons.Filled.PlayArrow,
            title = if (previewing) "正在念……（点一下停止）" else "试听",
            summary = "",
            onClick = {
                if (previewing) {
                    container.speech.stop()
                    previewing = false
                } else {
                    previewing = true
                    container.speech.preview("你好，我是拾忆的语音助手。今天有三件待办，最要紧的是下午两点的周会。") { previewing = false }
                }
            },
        )
    }

    Group("系统权限") {
        SettingsItem(
            icon = Icons.Filled.Lock,
            title = "勿扰模式",
            summary = if (dndOn) "已允许" else "未允许",
            onClick = { if (!dndOn) DeviceControl.openDndAccess(context) else toast(context, "已经允许了") },
            trailing = { Chevron() },
        )
        RowDivider()
        SettingsItem(
            icon = Icons.Filled.Build,
            title = "修改系统设置",
            summary = if (writeOn) "已允许" else "未允许",
            onClick = { if (!writeOn) DeviceControl.openWriteSettings(context) else toast(context, "已经允许了") },
            trailing = { Chevron() },
        )
        RowDivider()
        SettingsItem(
            icon = Icons.Filled.SettingsIcon,
            title = "无障碍服务",
            summary = if (!env.excerptServiceOn) "未开启" else if (ExcerptService.instance == null) "已开启 · 未运行，关掉再打开一次" else "已开启",
            onClick = { ExcerptService.openAccessibilitySettings(context) },
            trailing = { Chevron() },
        )
    }

    Group("快捷指令") {
        SettingsItem(icon = Icons.Filled.Add, title = "添加一个", summary = "", onClick = { addSkill = true })
        skills.reversed().forEach { sk ->
            RowDivider()
            Row(
                Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp),
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            ) {
                androidx.compose.foundation.layout.Column(Modifier.weight(1f).padding(vertical = 12.dp)) {
                    Text("「${sk.name}」" + if (sk.uses > 0) " · 用过 ${sk.uses} 次" else "", style = MaterialTheme.typography.titleMedium)
                    Text(sk.steps, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 4)
                }
                TextButton(onClick = { container.assistantSkills.remove(sk.id) }) { Text("删除") }
            }
        }
    }

    Group("复杂问题") {
        SettingsSwitchItem(
            icon = Icons.Filled.Send,
            title = "转给闪念贝壳 AI 后自动发送",
            summary = if (env.settings.aiAutoSend && !env.excerptServiceOn) "还差无障碍服务 · 点此前往" else "",
            checked = env.settings.aiAutoSend,
            onChange = {
                container.settings.setAiAutoSend(it)
                if (it && !env.excerptServiceOn) ExcerptService.openAccessibilitySettings(context)
            },
        )
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

    when (speakDialog) {
        SpeakDialog.Engine -> ChoiceDialog(
            title = "声音来源",
            options = SpeakEngine.entries.toList(),
            current = env.settings.speakEngine,
            label = { it.label + "\n" + it.summary },
            onSelect = { container.settings.setSpeakEngine(it) },
            onDismiss = { speakDialog = null },
        )
        SpeakDialog.Voice -> ChoiceDialog(
            title = "腾讯云音色",
            options = TencentTts.VOICES.map { it.id },
            current = env.settings.speakTencentVoice,
            label = { TencentTts.voiceLabel(it) },
            onSelect = { container.settings.setSpeakTencentVoice(it) },
            onDismiss = { speakDialog = null },
        )
        SpeakDialog.SystemEngine -> {
            val engines = remember { SpeechOut.installedEngines(context) }
            ChoiceDialog(
                title = "系统语音引擎",
                options = listOf("") + engines.map { it.pkg },
                current = env.settings.speakSystemEngine,
                label = { pkg -> if (pkg.isEmpty()) "系统默认" else engines.firstOrNull { it.pkg == pkg }?.label ?: pkg },
                onSelect = { container.settings.setSpeakSystemEngine(it) },
                onDismiss = { speakDialog = null },
            )
        }
        SpeakDialog.Speed -> ChoiceDialog(
            title = "语速",
            options = listOf(-2, -1, 0, 1, 2),
            current = env.settings.speakSpeed,
            label = { speedLabel(it) },
            onSelect = { container.settings.setSpeakSpeed(it) },
            onDismiss = { speakDialog = null },
        )
        null -> Unit
    }
    if (addSkill) {
        var name by remember { mutableStateOf("") }
        var steps by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { addSkill = false },
            title = { Text("添加快捷指令") },
            text = {
                androidx.compose.foundation.layout.Column(verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(10.dp)) {
                    AppTextField(value = name, onValueChange = { name = it }, placeholder = "口令，例如：开会模式")
                    AppTextField(value = steps, onValueChange = { steps = it }, placeholder = "要办的事，一行一步，例如：开启勿扰一小时\n调成静音\n倒计时 25 分钟")
                }
            },
            confirmButton = {
                TextButton(enabled = name.isNotBlank() && steps.isNotBlank(), onClick = {
                    container.assistantSkills.save(name, steps).onFailure { toast(context, it.message ?: "没存成") }
                    addSkill = false
                }) { Text("保存") }
            },
            dismissButton = { TextButton(onClick = { addSkill = false }) { Text("取消") } },
        )
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

private enum class SpeakDialog { Engine, Voice, SystemEngine, Speed }

private fun speedLabel(speed: Int): String = when (speed) {
    -2 -> "慢"
    -1 -> "稍慢"
    1 -> "稍快"
    2 -> "快"
    else -> "正常"
}

private fun systemEngineLabel(context: Context, pkg: String): String =
    if (pkg.isEmpty()) "系统默认" else SpeechOut.installedEngines(context).firstOrNull { it.pkg == pkg }?.label ?: pkg
