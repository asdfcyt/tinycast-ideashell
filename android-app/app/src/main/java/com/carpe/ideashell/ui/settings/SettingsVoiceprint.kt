package com.carpe.ideashell.ui.settings

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.carpe.ideashell.AppContainer
import com.carpe.ideashell.data.asr.VoicePrint
import com.carpe.ideashell.system.VoiceRecorder
import com.carpe.ideashell.ui.glass.GlassAlertDialog as AlertDialog
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** 录入声纹：依次读 3 句话，每句约 5 秒；录完算出声音特征保存，不保存录音 */
@Composable
internal fun VoiceprintEnrollDialog(container: AppContainer, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val recorder = remember { VoiceRecorder() }
    val samples = remember { mutableStateListOf<ByteArray>() }
    var recording by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var level by remember { mutableFloatStateOf(0f) }
    var elapsedMs by remember { mutableLongStateOf(0L) }
    var message by remember { mutableStateOf<String?>(null) }
    val prompts = VoicePrint.ENROLL_PROMPTS
    val step = samples.size.coerceAtMost(prompts.lastIndex)

    DisposableEffect(Unit) {
        onDispose { if (recorder.isRecording) recorder.cancel() }
    }
    LaunchedEffect(recording) {
        while (recording) {
            delay(100)
            elapsedMs += 100
        }
    }

    fun begin() {
        message = null
        elapsedMs = 0
        level = 0f
        val ok = recorder.start(scope, onLevel = { level = it }, onLimit = {})
        if (ok) recording = true else message = "无法打开麦克风，请检查权限或是否被其他应用占用"
    }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) begin() else message = "需要录音权限才能录入声音"
    }

    fun finishOne() {
        scope.launch {
            val pcm = recorder.stop()
            recording = false
            level = 0f
            if (pcm.size / 32 < 2_500) {
                message = "太短了，请把整句读完再点「停止」"
                return@launch
            }
            samples += pcm
            if (samples.size < prompts.size) return@launch
            saving = true
            val error = container.voicePrint.enroll(samples.toList())
            saving = false
            if (error == null) {
                settingsToast(context, "已录入你的声音")
                onDismiss()
            } else {
                samples.clear()
                message = "$error，请重新录入"
            }
        }
    }

    AlertDialog(
        onDismissRequest = { if (!saving) onDismiss() },
        title = { Text("录入我的声音（${(samples.size + 1).coerceAtMost(prompts.size)}/${prompts.size}）") },
        text = {
            Column {
                Text("在安静的地方，用平时说话的音量和语速读下面这句：", style = MaterialTheme.typography.bodySmall)
                Text(
                    prompts[step],
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.padding(vertical = 12.dp),
                )
                when {
                    saving -> {
                        Text("正在录入…", style = MaterialTheme.typography.bodySmall)
                        LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 8.dp))
                    }
                    recording -> {
                        Text("录音中 ${"%.1f".format(elapsedMs / 1000f)} 秒 · 读完点「停止」", style = MaterialTheme.typography.bodySmall)
                        LinearProgressIndicator(progress = { level }, modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
                    }
                    else -> Text(
                        if (samples.isEmpty()) "点「开始录音」，读完点「停止」；共 ${prompts.size} 句。"
                        else "已录 ${samples.size} 句，继续下一句。",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                message?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !saving,
                onClick = {
                    when {
                        recording -> finishOne()
                        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED -> begin()
                        else -> permission.launch(Manifest.permission.RECORD_AUDIO)
                    }
                },
            ) { Text(if (recording) "停止" else "开始录音") }
        },
        dismissButton = { TextButton(enabled = !saving, onClick = onDismiss) { Text("取消") } },
    )
}
