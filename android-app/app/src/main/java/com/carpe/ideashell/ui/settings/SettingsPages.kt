package com.carpe.ideashell.ui.settings

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.provider.Settings
import android.widget.Toast
import androidx.compose.foundation.clickable
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
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.data.asr.VoiceRecord
import com.carpe.ideashell.system.VoiceCapsuleService
import com.carpe.ideashell.ui.capture.QuickCaptureActivity
import com.carpe.ideashell.ui.components.AppTextField
import com.carpe.ideashell.ui.components.InputSheet
import com.carpe.ideashell.ui.components.ListGroup
import com.carpe.ideashell.ui.components.RowDivider
import com.carpe.ideashell.ui.glass.GlassAlertDialog as AlertDialog
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private sealed interface LexiconAdd {
    data object Hotword : LexiconAdd
    data object Rule : LexiconAdd
}

/**
 * 设置 → 语音输入 → 语音词库：
 * - 我加的热词：专有名词，识别时优先、也告诉 AI；
 * - 替换规则：总是被听错的词 → 正确写法（在确认卡片里改对同音错字后会自动学到这里）；
 * - 自动热词：只读，来自拾忆里已有的内容（文件夹、项目、标签、待办标题），不用维护。
 */
@Composable
internal fun LexiconPage() {
    val context = LocalContext.current
    val container = (context.applicationContext as IdeashellApp).container
    val lexicon by container.lexicon.state.collectAsStateWithLifecycle()
    val todoState by container.todos.state.collectAsStateWithLifecycle()
    // 待办 / 文件夹 / 项目一变就重算自动热词
    val auto = remember(lexicon, todoState) { container.voiceContext.hotwordSources() }
    var adding by remember { mutableStateOf<LexiconAdd?>(null) }

    Group("我加的热词") {
        SettingsItem(
            icon = Icons.Filled.Add,
            title = "添加热词",
            summary = "项目名、人名、产品名等专有名词（2–10 个字），识别时优先，也会告诉 AI",
            onClick = { adding = LexiconAdd.Hotword },
        )
        lexicon.hotwords.forEach { word ->
            RowDivider()
            LexiconRow(word) { container.lexicon.save(lexicon.hotwords - word, lexicon.replacements) }
        }
    }

    Group("替换规则") {
        SettingsItem(
            icon = Icons.Filled.Add,
            title = "添加替换规则",
            summary = "总是被听错的词：识别后自动改成正确写法。在悬浮胶囊的确认卡片里把同音错字改对，也会自动记到这里",
            onClick = { adding = LexiconAdd.Rule },
        )
        lexicon.replacements.forEach { (from, to) ->
            RowDivider()
            LexiconRow("$from  →  $to") { container.lexicon.save(lexicon.hotwords, lexicon.replacements.filterNot { it.first == from }) }
        }
    }

    Group("自动热词（只读）") {
        if (auto.isEmpty()) {
            SettingsItem(
                icon = Icons.Filled.Info,
                title = "还没有",
                summary = "有了文件夹、项目、滴答清单的待办之后，这里会自动出现",
                onClick = null,
            )
        } else {
            auto.forEachIndexed { index, (source, words) ->
                if (index > 0) RowDivider()
                SettingsItem(
                    icon = Icons.Filled.Star,
                    title = "$source · ${words.size}",
                    summary = words.take(AUTO_SHOW).joinToString("、") + if (words.size > AUTO_SHOW) " 等" else "",
                    onClick = null,
                )
            }
        }
    }
    Text(
        "自动热词来自拾忆里已有的内容，识别时和上面的热词一起使用（只用本机已有的数据，不读屏幕）；你加的热词和替换规则永远优先。",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 8.dp),
    )

    when (adding) {
        LexiconAdd.Hotword -> {
            var word by remember { mutableStateOf("") }
            InputSheet(
                title = "添加热词",
                hint = "2–10 个字的专有名词；可以一次写多个，用换行或逗号分开。",
                confirmEnabled = word.isNotBlank(),
                onDismiss = { adding = null },
                onConfirm = {
                    val add = com.carpe.ideashell.data.asr.Lexicon.parseHotwords(word)
                    container.lexicon.save((lexicon.hotwords + add).distinct(), lexicon.replacements)
                    adding = null
                },
            ) {
                ListGroup {
                    AppTextField(value = word, onValueChange = { word = it }, placeholder = "拾忆\n闪念贝壳", minLines = 2, autoFocus = true)
                }
            }
        }

        LexiconAdd.Rule -> {
            var from by remember { mutableStateOf("") }
            var to by remember { mutableStateOf("") }
            InputSheet(
                title = "添加替换规则",
                hint = "听错的词 → 正确写法，识别出来后自动改。",
                confirmEnabled = from.isNotBlank() && to.isNotBlank() && from.trim() != to.trim(),
                onDismiss = { adding = null },
                onConfirm = {
                    container.lexicon.addReplacement(from, to)
                    adding = null
                },
            ) {
                ListGroup {
                    AppTextField(value = from, onValueChange = { from = it }, label = "听错的词", placeholder = "是疑", singleLine = true, autoFocus = true)
                    RowDivider()
                    AppTextField(value = to, onValueChange = { to = it }, label = "正确写法", placeholder = "拾忆", singleLine = true)
                }
            }
        }

        null -> Unit
    }
}

private const val AUTO_SHOW = 24

@Composable
private fun LexiconRow(text: String, onDelete: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 2.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        IconButton(onClick = onDelete) {
            Icon(Icons.Filled.Close, contentDescription = "删除", tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

private val TIME_FORMAT = SimpleDateFormat("M月d日 HH:mm", Locale.CHINA)

/**
 * 设置 → 语音输入 → 语音历史：最近 10 条的原话、整理结果和原始录音（只在本机）。
 * 识别错了可以：播放原始录音、重新识别（用录音再识别 + 整理一遍）、重新整理（只重新让 AI 整理原话）、复制原话。
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun VoiceHistoryPage() {
    val context = LocalContext.current
    val container = (context.applicationContext as IdeashellApp).container
    val settings by container.settings.state.collectAsStateWithLifecycle()
    val records by container.voiceHistory.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val player = remember { PcmPlayer() }
    DisposableEffect(Unit) { onDispose { player.stop() } }
    var confirmClear by remember { mutableStateOf(false) }

    Group(null) {
        SettingsItem(
            icon = Icons.Filled.Info,
            title = "保存语音历史",
            summary = if (settings.voiceHistory) "已开启 · 保留最近 ${com.carpe.ideashell.data.asr.VoiceHistory.MAX_RECORDS} 条的原话、整理结果和原始录音，只存在这台手机里"
            else "已关闭 · 不再保留录音和原话（已有的历史还在，可以清空）",
            onClick = { container.settings.setVoiceHistory(!settings.voiceHistory) },
            trailing = { Switch(checked = settings.voiceHistory, onCheckedChange = { container.settings.setVoiceHistory(it) }) },
        )
        if (records.isNotEmpty()) {
            RowDivider()
            SettingsItem(
                icon = Icons.Filled.Close,
                title = "清空历史",
                summary = "删除全部 ${records.size} 条原话和录音",
                onClick = { confirmClear = true },
            )
        }
    }

    if (records.isEmpty()) {
        Text(
            "还没有语音历史。说一条话之后，会出现在这里。",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 8.dp),
        )
    } else {
        Group("最近 ${records.size} 条") {
            records.forEachIndexed { index, record ->
                if (index > 0) RowDivider()
                val hasAudio = container.voiceHistory.hasAudio(record.id)
                Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        TIME_FORMAT.format(Date(record.at)) + " · " + formatDuration(record.durationMs),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        record.raw ?: "（没有识别出文字）",
                        style = MaterialTheme.typography.bodyLarge,
                        color = if (record.raw == null) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                    )
                    record.summary?.let {
                        Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
                    }
                    record.error?.let {
                        Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                    }
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(0.dp)) {
                        if (hasAudio) {
                            TextButton(onClick = {
                                scope.launch {
                                    val pcm = container.voiceHistory.audio(record.id)
                                    if (pcm == null) toast(context, "录音已经不在了") else player.play(pcm)
                                }
                            }) { Text("播放") }
                            TextButton(onClick = { replay(context, record.id, audio = true) }) { Text("重新识别") }
                        }
                        if (!record.raw.isNullOrBlank()) {
                            TextButton(onClick = { replay(context, record.id, audio = false) }) { Text("重新整理") }
                            TextButton(onClick = {
                                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                cm.setPrimaryClip(ClipData.newPlainText("语音原话", record.raw))
                                toast(context, "已复制原话")
                            }) { Text("复制原话") }
                        }
                        TextButton(onClick = { container.voiceHistory.delete(record.id) }) { Text("删除") }
                    }
                }
            }
        }
        Text(
            "「重新识别」用留底的录音再识别并整理一遍，「重新整理」只让 AI 重新整理上面的原话；结果和平时一样先弹出确认卡片，你确认后才保存。",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 8.dp),
        )
    }

    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("清空语音历史？") },
            text = { Text("原话和原始录音都会从手机里删除，不能恢复。") },
            confirmButton = {
                TextButton(onClick = {
                    confirmClear = false
                    player.stop()
                    container.voiceHistory.clear()
                }) { Text("清空") }
            },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("取消") } },
        )
    }
}

private fun formatDuration(ms: Long): String {
    val sec = (ms / 1000).toInt().coerceAtLeast(1)
    return if (sec < 60) "$sec 秒" else "${sec / 60} 分 ${sec % 60} 秒"
}

private fun toast(context: Context, text: String) = Toast.makeText(context, text, Toast.LENGTH_SHORT).show()

/**
 * 重新识别 / 重新整理：有悬浮胶囊权限就用胶囊显示进度和确认卡片；没有就回到快记面板，结果放进输入框。
 */
private fun replay(context: Context, id: String, audio: Boolean) {
    val micOk = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    if (micOk && Settings.canDrawOverlays(context)) {
        VoiceCapsuleService.replay(context, id, audio)
    } else {
        context.startActivity(
            Intent(context, QuickCaptureActivity::class.java).apply {
                action = QuickCaptureActivity.ACTION_QUICK_CAPTURE
                putExtra(QuickCaptureActivity.EXTRA_REPLAY_ID, id)
                putExtra(QuickCaptureActivity.EXTRA_REPLAY_AUDIO, audio)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
        )
    }
}

/** 播放留底的原始录音（16kHz / 单声道 / 16 位 PCM）；同一时间只播一条 */
private class PcmPlayer {
    private var track: AudioTrack? = null

    fun play(pcm: ByteArray) {
        stop()
        if (pcm.isEmpty()) return
        val t = runCatching {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(16_000)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .build(),
                )
                .setBufferSizeInBytes(pcm.size)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()
        }.getOrNull() ?: return
        t.write(pcm, 0, pcm.size)
        // 播到末尾自动释放
        t.notificationMarkerPosition = pcm.size / 2
        t.setPlaybackPositionUpdateListener(object : AudioTrack.OnPlaybackPositionUpdateListener {
            override fun onMarkerReached(track: AudioTrack?) {
                if (this@PcmPlayer.track === track) stop()
            }

            override fun onPeriodicNotification(track: AudioTrack?) = Unit
        })
        t.play()
        track = t
    }

    fun stop() {
        val t = track ?: return
        track = null
        runCatching { t.stop() }
        t.release()
    }
}
