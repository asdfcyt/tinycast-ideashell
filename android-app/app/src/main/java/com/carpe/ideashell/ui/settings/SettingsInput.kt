package com.carpe.ideashell.ui.settings

import android.content.Intent
import android.content.pm.PackageManager
import android.widget.Toast
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.net.Uri
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Create
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Done
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.R
import com.carpe.ideashell.data.asr.LocalAsrState
import com.carpe.ideashell.data.asr.VoiceHistory
import com.carpe.ideashell.data.asr.VoiceprintModelState
import com.carpe.ideashell.data.settings.VoiceEngine
import com.carpe.ideashell.data.settings.VoiceKey
import com.carpe.ideashell.system.ExcerptService
import com.carpe.ideashell.system.VoiceCapsuleService
import com.carpe.ideashell.ui.glass.GlassAlertDialog as AlertDialog

// ───────────────────────── 文字记录 ─────────────────────────

private enum class RecordDialog { Tags, DailyFolder }

@Composable
internal fun RecordSection(env: SettingsEnv) {
    val settings = env.settings
    val container = env.container
    var dialog by remember { mutableStateOf<RecordDialog?>(null) }

    Group(null) {
        SettingsItem(
            iconRes = R.drawable.ic_tag,
            title = "默认标签",
            summary = settings.defaultTagsText.ifEmpty { "无（创建笔记时自动附加，逗号分隔）" },
            onClick = { dialog = RecordDialog.Tags },
        )
        SettingsItem(
            icon = Icons.Filled.DateRange,
            title = "Daily Note 文件夹",
            summary = settings.dailyFolder,
            onClick = { dialog = RecordDialog.DailyFolder },
        )
    }

    when (dialog) {
        RecordDialog.Tags -> TextInputDialog(
            title = "默认标签",
            label = "标签（逗号分隔）",
            initial = settings.defaultTagsText,
            onConfirm = { container.settings.setDefaultTags(it) },
            onDismiss = { dialog = null },
        )

        RecordDialog.DailyFolder -> TextInputDialog(
            title = "Daily Note 文件夹",
            label = "文件夹名",
            initial = settings.dailyFolder,
            onConfirm = { container.settings.setDailyFolder(it) },
            onDismiss = { dialog = null },
        )

        null -> Unit
    }
}

// ───────────────────────── 语音输入 ─────────────────────────

private enum class VoiceDialog { Engine, Key, LockedKey, Silence, Enroll, VoiceprintLevel }

/** 首页「语音输入」那一行的状态摘要 */
internal fun SettingsEnv.voiceSummary(localReady: Boolean): String = when {
    !settings.voiceEnabled -> "已关闭"
    !ocrConfigured && !localReady -> "未配置识别"
    else -> ""
}

@Composable
internal fun VoiceSection(env: SettingsEnv) {
    val context = env.context
    val container = env.container
    val settings = env.settings
    val localAsr by container.localAsr.state.collectAsStateWithLifecycle()
    val vpModel by container.voicePrint.state.collectAsStateWithLifecycle()
    val vpEnrolled by container.voicePrint.enrolled.collectAsStateWithLifecycle()
    var confirmClearVoiceprint by remember { mutableStateOf(false) }
    val lexicon by container.lexicon.state.collectAsStateWithLifecycle()
    var dialog by remember { mutableStateOf<VoiceDialog?>(null) }
    var confirmDeleteLocalAsr by remember { mutableStateOf(false) }

    Group("怎么开始说") {
        SettingsSwitchItem(
            iconRes = R.drawable.ic_mic,
            title = "按住说话",
            summary = "",
            checked = settings.voiceEnabled,
            onChange = { container.settings.setVoiceEnabled(it) },
        )
        // 「语音记一条」磁贴 / 快捷方式的悬浮胶囊要「显示在其他应用上层」权限
        SettingsItem(
            iconRes = R.drawable.ic_tile_voice,
            title = "语音记一条 · 悬浮胶囊",
            summary = if (env.overlayOn) "" else "未开启",
            onClick = {
                if (!env.overlayOn) {
                    context.startActivity(
                        Intent(
                            android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:" + context.packageName),
                        ),
                    )
                }
            },
        )
        SettingsItem(
            icon = Icons.Filled.PlayArrow,
            title = "音量键按住说话",
            summary = when {
                settings.voiceKey == VoiceKey.OFF -> "关闭"
                !env.excerptServiceOn -> "${settings.voiceKey.label} · 需要开启无障碍「拾忆」"
                else -> settings.voiceKey.label
            },
            onClick = {
                if (settings.voiceKey != VoiceKey.OFF && !env.excerptServiceOn) ExcerptService.openAccessibilitySettings(context)
                else dialog = VoiceDialog.Key
            },
        )
        SettingsSwitchItem(
            iconRes = R.drawable.ic_mic,
            title = "熄屏也能用",
            summary = "",
            checked = settings.voiceKeyScreenOff,
            onChange = { on ->
                when {
                    !on -> {
                        container.settings.setVoiceKeyScreenOff(false)
                        VoiceCapsuleService.disarm(context)
                    }
                    settings.voiceKey == VoiceKey.OFF ->
                        Toast.makeText(context, "先在上面选一个音量键", Toast.LENGTH_SHORT).show()
                    context.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED ->
                        Toast.makeText(context, "先在拾忆里开一次语音输入，授予麦克风权限", Toast.LENGTH_LONG).show()
                    else -> {
                        container.settings.setVoiceKeyScreenOff(true)
                        VoiceCapsuleService.arm(context)
                    }
                }
            },
        )
        if (settings.voiceKeyScreenOff) {
            SettingsItem(
                icon = Icons.Filled.PlayArrow,
                title = "熄屏 / 锁屏时用的键",
                summary = settings.voiceKeyLocked.label,
                onClick = { dialog = VoiceDialog.LockedKey },
            )
            SettingsSwitchItem(
                icon = Icons.Filled.Star,
                title = "耳机键也能录音",
                summary = "",
                checked = settings.voiceHeadsetKey,
                onChange = { container.settings.setVoiceHeadsetKey(it) },
            )
        }
        SettingsSwitchItem(
            icon = Icons.Filled.Done,
            title = "说完自动停止",
            summary = "",
            checked = settings.voiceAutoStop,
            onChange = { container.settings.setVoiceAutoStop(it) },
        )
    }

    Group("语音识别") {
        SettingsItem(
            icon = Icons.Filled.Search,
            title = "腾讯云密钥",
            summary = if (env.ocrConfigured) "" else "未配置",
            onClick = { env.go(SEC_ACCOUNTS) },
            trailing = { Chevron() },
        )
        // 本地模型：不随应用安装，在这里下载 / 删除
        SettingsItem(
            icon = Icons.Filled.Info,
            title = "本地模型（SenseVoice）",
            summary = when (val s = localAsr) {
                LocalAsrState.Unsupported -> "这台设备不支持（仅支持 64 位 ARM 手机）"
                LocalAsrState.Missing -> "未下载 · 约 160 MB"
                is LocalAsrState.Downloading ->
                    if (s.unpacking) "正在保存模型…"
                    else "正在下载" + (if (s.percent >= 0) " ${s.percent}%" else "") + " · 点一下取消"
                is LocalAsrState.Ready -> "已下载（${s.sizeMb} MB）"
                is LocalAsrState.Failed -> "下载失败：${s.message} · 点一下重试"
            },
            onClick = {
                when (localAsr) {
                    LocalAsrState.Unsupported -> settingsToast(context, "这台设备不支持本地识别")
                    is LocalAsrState.Downloading -> container.localAsr.cancelDownload()
                    LocalAsrState.Missing, is LocalAsrState.Failed -> container.localAsr.download()
                    is LocalAsrState.Ready -> Unit
                }
            },
        )
    }
    if (localAsr is LocalAsrState.Downloading) LinearProgressIndicator(Modifier.fillMaxWidth())

    Group("降噪") {
        SettingsSwitchItem(
            icon = Icons.Filled.Info,
            title = "系统降噪",
            summary = "",
            checked = settings.voiceSystemDenoise,
            onChange = { container.settings.setVoiceSystemDenoise(it) },
        )
        val effectSupport = remember {
            val ns = runCatching { NoiseSuppressor.isAvailable() }.getOrDefault(false)
            val agc = runCatching { AutomaticGainControl.isAvailable() }.getOrDefault(false)
            fun mark(ok: Boolean) = if (ok) "可用" else "不可用"
            "降噪 ${mark(ns)} · 自动增益 ${mark(agc)}"
        }
        SettingsItem(
            icon = Icons.Filled.Info,
            title = "本机系统降噪支持情况",
            summary = effectSupport,
            onClick = null,
        )
    }

    Group("声纹 · 只识别我的声音") {
        SettingsSwitchItem(
            icon = Icons.Filled.Star,
            title = "只识别我的声音",
            summary = when {
                !settings.voiceprintEnabled -> ""
                vpModel is VoiceprintModelState.Unsupported -> "这台设备不支持（仅支持 64 位 ARM 手机）"
                vpModel is VoiceprintModelState.Downloading -> "正在下载声纹模型（约 27 MB）" + (vpModel as VoiceprintModelState.Downloading).percent.takeIf { it >= 0 }?.let { " $it%" }.orEmpty()
                vpModel is VoiceprintModelState.Failed -> "模型下载失败：${(vpModel as VoiceprintModelState.Failed).message}"
                vpModel !is VoiceprintModelState.Ready -> "已开启 · 声纹模型还没下载"
                !vpEnrolled -> "已开启 · 还没录入声音"
                else -> ""
            },
            checked = settings.voiceprintEnabled,
            onChange = { on ->
                container.settings.setVoiceprintEnabled(on)
                if (on) container.voicePrint.download()
            },
        )
        if (settings.voiceprintEnabled) {
            if (vpModel !is VoiceprintModelState.Ready && vpModel !is VoiceprintModelState.Unsupported) {
                SettingsItem(
                    icon = Icons.Filled.Info,
                    title = "声纹模型（CAM++）",
                    summary = when (val s = vpModel) {
                        is VoiceprintModelState.Downloading -> "正在下载" + (if (s.percent >= 0) " ${s.percent}%" else "") + " · 点一下取消"
                        is VoiceprintModelState.Failed -> "下载失败：${s.message} · 点一下重试"
                        else -> "未下载 · 约 27 MB"
                    },
                    onClick = {
                        if (vpModel is VoiceprintModelState.Downloading) container.voicePrint.cancelDownload()
                        else container.voicePrint.download()
                    },
                )
            }
            if (vpModel is VoiceprintModelState.Downloading) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (vpModel is VoiceprintModelState.Ready) {
                SettingsItem(
                    icon = Icons.Filled.Create,
                    title = "录入我的声音",
                    summary = if (vpEnrolled) "" else "未录入",
                    onClick = { dialog = VoiceDialog.Enroll },
                )
                SettingsItem(
                    icon = Icons.Filled.Search,
                    title = "严格程度",
                    summary = voiceprintLevelLabel(settings.voiceprintLevel),
                    onClick = { dialog = VoiceDialog.VoiceprintLevel },
                )
                if (vpEnrolled) {
                    SettingsItem(
                        icon = Icons.Filled.Delete,
                        title = "删除我的声纹",
                        summary = "",
                        onClick = { confirmClearVoiceprint = true },
                    )
                }
            }
        }
    }

    Group("整理与词库") {
        SettingsSwitchItem(
            icon = Icons.Filled.Star,
            title = "AI 整理口语",
            summary = "",
            checked = settings.voicePolish,
            onChange = { container.settings.setVoicePolish(it) },
        )
        SettingsItem(
            iconRes = R.drawable.ic_sparkle,
            title = "大模型接口",
            summary = if (env.llmConfigured) "" else "未配置",
            onClick = { env.go(SEC_ACCOUNTS) },
            trailing = { Chevron() },
        )
        SettingsItem(
            icon = Icons.Filled.Create,
            title = "语音词库",
            summary = "${lexicon.hotwords.size} 个热词 · ${lexicon.replacements.size} 条替换",
            onClick = { env.go(SEC_LEXICON) },
            trailing = { Chevron() },
        )
    }

    Group("保存") {
        SettingsSwitchItem(
            icon = Icons.Filled.Send,
            title = "松手直接保存",
            summary = "",
            checked = settings.voiceAutoSend,
            onChange = { container.settings.setVoiceAutoSend(it) },
        )
        SettingsItem(
            icon = Icons.Filled.Refresh,
            title = "语音历史",
            summary = if (settings.voiceHistory) "" else "已关闭",
            onClick = { env.go(SEC_VOICE_HISTORY) },
            trailing = { Chevron() },
        )
    }

    AdvancedGroup(key = "voice", summary = "识别方式 · 停顿时长") {
        SettingsItem(
            icon = Icons.Filled.Info,
            title = "识别方式",
            summary = settings.voiceEngine.label,
            onClick = { dialog = VoiceDialog.Engine },
        )
        SettingsItem(
            icon = Icons.Filled.DateRange,
            title = "停顿多久算说完",
            summary = if (settings.voiceAutoStop) "${"%.1f".format(settings.voiceSilenceMs / 1000f)} 秒" else "需先开启「说完自动停止」",
            onClick = { dialog = VoiceDialog.Silence },
        )
        val ready = localAsr as? LocalAsrState.Ready
        if (ready != null) {
            SettingsItem(
                icon = Icons.Filled.Delete,
                title = "删除本地模型",
                summary = "${ready.sizeMb} MB",
                onClick = { confirmDeleteLocalAsr = true },
            )
        }
        (vpModel as? VoiceprintModelState.Ready)?.let { vp ->
            SettingsItem(
                icon = Icons.Filled.Delete,
                title = "删除声纹模型",
                summary = "${vp.sizeMb} MB",
                onClick = { container.voicePrint.deleteModel() },
            )
        }
    }


    when (dialog) {
        VoiceDialog.Engine -> VoiceEngineDialog(
            current = settings.voiceEngine,
            onSelect = { engine ->
                container.settings.setVoiceEngine(engine)
                if (engine != VoiceEngine.CLOUD) {
                    when (localAsr) {
                        LocalAsrState.Missing, is LocalAsrState.Failed -> {
                            container.localAsr.download()
                            settingsToast(context, "开始下载本地模型（约 160 MB），下载完成前仍用云端")
                        }
                        LocalAsrState.Unsupported -> settingsToast(context, "这台设备不支持本地识别")
                        else -> Unit
                    }
                }
            },
            onDismiss = { dialog = null },
        )

        VoiceDialog.Silence -> ChoiceDialog(
            title = "停顿多久算说完",
            options = listOf(1000, 1500, 2000, 3000),
            current = settings.voiceSilenceMs,
            label = { "${"%.1f".format(it / 1000f)} 秒" + if (it == 1500) "（默认）" else "" },
            onSelect = { container.settings.setVoiceSilenceMs(it) },
            onDismiss = { dialog = null },
        )

        VoiceDialog.Key -> ChoiceDialog(
            title = "音量键按住说话",
            options = VoiceKey.entries,
            current = settings.voiceKey,
            label = { it.label },
            onSelect = { key ->
                container.settings.setVoiceKey(key)
                if (key != VoiceKey.OFF && !env.excerptServiceOn) ExcerptService.openAccessibilitySettings(context)
            },
            onDismiss = { dialog = null },
        )

        VoiceDialog.LockedKey -> ChoiceDialog(
            title = "熄屏 / 锁屏时用的键",
            options = listOf(VoiceKey.VOLUME_UP, VoiceKey.VOLUME_DOWN),
            current = settings.voiceKeyLocked,
            label = { it.label + if (it == VoiceKey.VOLUME_UP) "（推荐，荣耀熄屏也能按住说话）" else "" },
            onSelect = { container.settings.setVoiceKeyLocked(it) },
            onDismiss = { dialog = null },
        )

        VoiceDialog.Enroll -> VoiceprintEnrollDialog(container = container, onDismiss = { dialog = null })

        VoiceDialog.VoiceprintLevel -> ChoiceDialog(
            title = "声纹严格程度",
            options = listOf(0, 1, 2),
            current = settings.voiceprintLevel,
            label = { voiceprintLevelLabel(it) },
            onSelect = { container.settings.setVoiceprintLevel(it) },
            onDismiss = { dialog = null },
        )

        null -> Unit
    }

    if (confirmClearVoiceprint) {
        AlertDialog(
            onDismissRequest = { confirmClearVoiceprint = false },
            title = { Text("删除我的声纹？") },
            text = { Text("删除后声纹不再拦截任何录音，想继续用要重新录入。") },
            confirmButton = {
                TextButton(onClick = {
                    confirmClearVoiceprint = false
                    container.voicePrint.clearProfile()
                }) { Text("删除") }
            },
            dismissButton = { TextButton(onClick = { confirmClearVoiceprint = false }) { Text("取消") } },
        )
    }

    if (confirmDeleteLocalAsr) {
        AlertDialog(
            onDismissRequest = { confirmDeleteLocalAsr = false },
            title = { Text("删除本地模型？") },
            text = { Text("删除后之后想用本地识别要重新下载（约 160 MB）。如果当前选的是「本地模型」，会改回「自动」。") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDeleteLocalAsr = false
                    if (settings.voiceEngine == VoiceEngine.LOCAL) container.settings.setVoiceEngine(VoiceEngine.AUTO)
                    container.localAsr.delete()
                }) { Text("删除") }
            },
            dismissButton = { TextButton(onClick = { confirmDeleteLocalAsr = false }) { Text("取消") } },
        )
    }
}

internal fun voiceprintLevelLabel(level: Int): String = when (level) {
    0 -> "宽松"
    2 -> "严格"
    else -> "标准"
}

@Composable
private fun VoiceEngineDialog(current: VoiceEngine, onSelect: (VoiceEngine) -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("识别方式") },
        text = {
            Column {
                VoiceEngine.entries.forEach { engine ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .selectable(
                                selected = engine == current,
                                role = Role.RadioButton,
                                onClick = {
                                    onSelect(engine)
                                    onDismiss()
                                },
                            )
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = engine == current, onClick = null)
                        Column(Modifier.padding(start = 12.dp)) {
                            Text(engine.label)
                            Text(
                                engine.summary,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

// ───────────────────────── OCR 输入 ─────────────────────────

/** 首页「OCR 输入」那一行的状态摘要 */
internal fun SettingsEnv.ocrSummary(): String = when {
    !ocrConfigured -> "未配置"
    else -> ""
}

@Composable
internal fun OcrSection(env: SettingsEnv) {
    val settings = env.settings
    val container = env.container

    Group(null) {
        SettingsItem(
            icon = Icons.Filled.Search,
            title = "腾讯云密钥",
            summary = if (env.ocrConfigured) "" else "未配置",
            onClick = { env.go(SEC_ACCOUNTS) },
            trailing = { Chevron() },
        )
        SettingsItem(
            iconRes = R.drawable.ic_ocr,
            title = "识别文字",
            summary = if (!env.ocrConfigured) "需要先填入腾讯云密钥" else "",
            onClick = {
                if (!env.ocrConfigured) env.go(SEC_ACCOUNTS) else container.settings.setOcrEnabled(!settings.ocrEnabled)
            },
            trailing = {
                Switch(
                    checked = settings.ocrEnabled && env.ocrConfigured,
                    onCheckedChange = { if (!env.ocrConfigured) env.go(SEC_ACCOUNTS) else container.settings.setOcrEnabled(it) },
                )
            },
        )
        SettingsSwitchItem(
            icon = Icons.Filled.Create,
            title = "选择框",
            summary = "",
            checked = settings.ocrFrameMode,
            onChange = { container.settings.setOcrFrameMode(it) },
        )
    }
}
