package com.carpe.ideashell.ui.settings

import android.content.Intent
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
import com.carpe.ideashell.data.asr.DenoiserState
import com.carpe.ideashell.data.asr.LocalAsrState
import com.carpe.ideashell.data.asr.VoiceHistory
import com.carpe.ideashell.data.settings.VoiceEngine
import com.carpe.ideashell.data.settings.VoiceKey
import com.carpe.ideashell.system.ExcerptService
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

private enum class VoiceDialog { Engine, Key, Silence }

/** 首页「语音输入」那一行的状态摘要 */
internal fun SettingsEnv.voiceSummary(localReady: Boolean): String = when {
    !settings.voiceEnabled -> "已关闭"
    !ocrConfigured && !localReady -> "未配置 · 需要腾讯云密钥并开通「语音识别」，或下载本地模型"
    settings.voicePolish && llmConfigured -> "按住说话 · AI 整理并推算日期时间（${settings.llmModel}）"
    else -> "按住说话 · 本地规则识别日期时间（配置大模型可让 AI 整理）"
}

@Composable
internal fun VoiceSection(env: SettingsEnv) {
    val context = env.context
    val container = env.container
    val settings = env.settings
    val localAsr by container.localAsr.state.collectAsStateWithLifecycle()
    val aiDenoiser by container.denoiser.state.collectAsStateWithLifecycle()
    val lexicon by container.lexicon.state.collectAsStateWithLifecycle()
    var dialog by remember { mutableStateOf<VoiceDialog?>(null) }
    var confirmDeleteLocalAsr by remember { mutableStateOf(false) }

    Group("怎么开始说") {
        SettingsSwitchItem(
            iconRes = R.drawable.ic_mic,
            title = "按住说话",
            summary = if (settings.voiceEnabled) "记一条里按住输入框说话，松手识别；上滑取消、下滑锁定" else "已关闭",
            checked = settings.voiceEnabled,
            onChange = { container.settings.setVoiceEnabled(it) },
        )
        // 「语音记一条」磁贴 / 快捷方式的悬浮胶囊要「显示在其他应用上层」权限
        SettingsItem(
            iconRes = R.drawable.ic_tile_voice,
            title = "语音记一条 · 悬浮胶囊",
            summary = if (env.overlayOn) "已开启 · 点磁贴 / 桌面快捷方式「语音记一条」会浮出录音胶囊，不打开面板，说完点「完成」直接保存"
            else "未开启 · 需要允许「显示在其他应用上层」；没开时「语音记一条」会打开快记面板录音 · 点一下去开启",
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
                settings.voiceKey == VoiceKey.OFF -> "关闭 · 选一个音量键，长按开始录音、松手结束（不用点胶囊）"
                !env.excerptServiceOn -> "${settings.voiceKey.label} · 还没开启无障碍里的「拾忆」，点一下去开启"
                else -> "${settings.voiceKey.label} · 长按录音，松手结束；轻按照常调音量"
            },
            onClick = {
                if (settings.voiceKey != VoiceKey.OFF && !env.excerptServiceOn) ExcerptService.openAccessibilitySettings(context)
                else dialog = VoiceDialog.Key
            },
        )
        SettingsSwitchItem(
            icon = Icons.Filled.Done,
            title = "说完自动停止",
            summary = if (settings.voiceAutoStop) "已开启 · 说完停顿 ${"%.1f".format(settings.voiceSilenceMs / 1000f)} 秒就自动结束并开始处理；一直没人说话约 6 秒后放弃"
            else "已关闭 · 需要手动点胶囊上的停止键",
            checked = settings.voiceAutoStop,
            onChange = { container.settings.setVoiceAutoStop(it) },
        )
    }

    Group("语音识别") {
        SettingsItem(
            icon = Icons.Filled.Search,
            title = "腾讯云密钥",
            summary = if (env.ocrConfigured) "已配置 · 云端识别需在腾讯云开通「语音识别」（每月免费 5000 次）· 在「账号与连接」里修改"
            else "未配置 · 点这里去「账号与连接」填写（本地模型不需要）",
            onClick = { env.go(SEC_ACCOUNTS) },
            trailing = { Chevron() },
        )
        // 本地模型：不随应用安装，在这里下载 / 删除
        SettingsItem(
            icon = Icons.Filled.Info,
            title = "本地模型（SenseVoice）",
            summary = when (val s = localAsr) {
                LocalAsrState.Unsupported -> "这台设备不支持（仅支持 64 位 ARM 手机）"
                LocalAsrState.Missing -> "未下载 · 约 160 MB，建议连 Wi-Fi；识别在手机上完成，支持中 / 英 / 日 / 韩 / 粤 · 点一下下载"
                is LocalAsrState.Downloading ->
                    if (s.unpacking) "正在保存模型…"
                    else "正在下载" + (if (s.percent >= 0) " ${s.percent}%" else "") + "，请先别关掉应用 · 点一下取消"
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
            summary = if (settings.voiceSystemDenoise) "已开启 · 录音用语音识别专用录音源，并打开系统的降噪 / 自动增益（效果因手机而异，说话很轻时可能被削掉）"
            else "已关闭 · 开启后在嘈杂环境里识别更稳；不下载任何东西",
            checked = settings.voiceSystemDenoise,
            onChange = { container.settings.setVoiceSystemDenoise(it) },
        )
        val effectSupport = remember {
            val ns = runCatching { NoiseSuppressor.isAvailable() }.getOrDefault(false)
            val agc = runCatching { AutomaticGainControl.isAvailable() }.getOrDefault(false)
            fun mark(ok: Boolean) = if (ok) "可用" else "不可用"
            "降噪（NS）${mark(ns)} · 自动增益（AGC）${mark(agc)}" +
                if (!ns && !agc) "，这台手机开「系统降噪」不会有任何效果" else ""
        }
        SettingsItem(
            icon = Icons.Filled.Info,
            title = "本机系统降噪支持情况",
            summary = effectSupport,
            onClick = null,
        )
        SettingsSwitchItem(
            icon = Icons.Filled.Star,
            title = "AI 降噪（本机）",
            summary = when {
                !settings.voiceAiDenoise -> "已关闭 · 识别前用手机上的 AI 模型再降一次噪，约 0.5 MB，录音不会上传"
                aiDenoiser is DenoiserState.Downloading -> "正在下载模型…"
                aiDenoiser is DenoiserState.Failed -> "模型下载失败：${(aiDenoiser as DenoiserState.Failed).message} · 关掉再打开重试"
                aiDenoiser is DenoiserState.Unsupported -> "这台设备不支持（仅支持 64 位 ARM 手机）"
                aiDenoiser is DenoiserState.Ready -> "已开启 · 识别前先降噪；效果不一定更好，可在「语音历史」里重新识别对比（历史里留的仍是原始录音）"
                else -> "已开启 · 模型还没下载"
            },
            checked = settings.voiceAiDenoise,
            onChange = { on ->
                container.settings.setVoiceAiDenoise(on)
                if (on) container.denoiser.download()
            },
        )
    }

    Group("整理与词库") {
        SettingsSwitchItem(
            icon = Icons.Filled.Star,
            title = "AI 整理口语",
            summary = if (settings.voicePolish) "去掉嗯啊重复，判断是待办 / 日记 / 笔记，并由大模型推算日期、时间、重复；失败时退回本地规则"
            else "已关闭 · 只做简单清洗，日期时间由本地规则识别",
            checked = settings.voicePolish,
            onChange = { container.settings.setVoicePolish(it) },
        )
        SettingsItem(
            iconRes = R.drawable.ic_sparkle,
            title = "大模型接口",
            summary = (if (env.llmConfigured) "已配置" else "未配置 · 需要 API Key") + " · ${settings.llmModel} · 在「账号与连接」里设置",
            onClick = { env.go(SEC_ACCOUNTS) },
            trailing = { Chevron() },
        )
        SettingsItem(
            icon = Icons.Filled.Create,
            title = "语音词库",
            summary = "${lexicon.hotwords.size} 个热词 · ${lexicon.replacements.size} 条替换规则 · 另有来自文件夹、项目、待办的自动热词；改对的同音错字会自动学到这里",
            onClick = { env.go(SEC_LEXICON) },
            trailing = { Chevron() },
        )
    }

    Group("保存") {
        SettingsSwitchItem(
            icon = Icons.Filled.Send,
            title = "松手直接保存",
            summary = if (settings.voiceAutoSend) "识别完不弹确认卡片，只显示一条小提示，几秒后自动保存；点它可以改字、放弃，已完成 / 已修改的待办还能点「撤销」（删除待办仍会先确认）"
            else "识别完先放进输入框 / 弹出确认卡片，确认后再保存",
            checked = settings.voiceAutoSend,
            onChange = { container.settings.setVoiceAutoSend(it) },
        )
        SettingsItem(
            icon = Icons.Filled.Refresh,
            title = "语音历史",
            summary = if (settings.voiceHistory) "保留最近 ${VoiceHistory.MAX_RECORDS} 条原话和录音（只在本机）· 识别错了可重新识别 / 整理"
            else "已关闭 · 点进去可以开启，或清空已有的",
            onClick = { env.go(SEC_VOICE_HISTORY) },
            trailing = { Chevron() },
        )
    }

    AdvancedGroup(key = "voice", summary = "识别方式 · 停顿多久算说完 · 删除本地模型") {
        SettingsItem(
            icon = Icons.Filled.Info,
            title = "识别方式",
            summary = settings.voiceEngine.label + " · " + settings.voiceEngine.summary,
            onClick = { dialog = VoiceDialog.Engine },
        )
        SettingsItem(
            icon = Icons.Filled.DateRange,
            title = "停顿多久算说完",
            summary = if (settings.voiceAutoStop) "${"%.1f".format(settings.voiceSilenceMs / 1000f)} 秒 · 说话慢、爱停顿就调长一点"
            else "只在开启「说完自动停止」后生效",
            onClick = { dialog = VoiceDialog.Silence },
        )
        val ready = localAsr as? LocalAsrState.Ready
        if (ready != null) {
            SettingsItem(
                icon = Icons.Filled.Delete,
                title = "删除本地模型",
                summary = "释放 ${ready.sizeMb} MB 空间，需要时可以重新下载",
                onClick = { confirmDeleteLocalAsr = true },
            )
        }
    }

    SettingsNote("你说的话会发给腾讯云识别（或在本机识别），再把文字发给所选大模型整理，不经过其他服务器。")

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

        null -> Unit
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
    !ocrConfigured -> "未配置 · 填入腾讯云密钥后，可拍照识别文字录入"
    settings.ocrEnabled -> "已开启 · 记一条里点相机，拍完自动识别文字"
    else -> "已配置 · 在相机页点「识别文字」开启"
}

@Composable
internal fun OcrSection(env: SettingsEnv) {
    val settings = env.settings
    val container = env.container

    Group(null) {
        SettingsItem(
            icon = Icons.Filled.Search,
            title = "腾讯云密钥",
            summary = if (env.ocrConfigured) "已配置 · 云端识别需在腾讯云开通「文字识别」· 在「账号与连接」里修改"
            else "未配置 · 点这里去「账号与连接」填写",
            onClick = { env.go(SEC_ACCOUNTS) },
            trailing = { Chevron() },
        )
        SettingsItem(
            iconRes = R.drawable.ic_ocr,
            title = "识别文字",
            summary = when {
                !env.ocrConfigured -> "需要先填入腾讯云密钥"
                settings.ocrEnabled -> "已开启 · 记一条里点相机，拍照或选图后自动识别，挑出要的文字录入"
                else -> "已关闭 · 拍的照片直接当图片附件；也可以在相机页右下角随时开启"
            },
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
            title = "选择方式",
            summary = if (settings.ocrFrameMode) "选择框 · 先框出要识别的区域，只识别框里的文字" else "划选识别 · 整张图识别，再点选 / 划选要的文字",
            checked = settings.ocrFrameMode,
            onChange = { container.settings.setOcrFrameMode(it) },
        )
    }
    SettingsNote("识别在腾讯云完成：图片先缩放压缩再发送，不经过其他服务器。图片转文字之后，和其他输入一样按平常的方式保存。")
}
