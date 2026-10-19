package com.carpe.ideashell.ui.components

import android.Manifest
import android.content.pm.PackageManager
import android.os.SystemClock
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.heightIn
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.AwaitPointerEventScope
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.carpe.ideashell.R
import com.carpe.ideashell.core.capture.CaptureSchedule
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.core.voice.SpeechCleaner
import com.carpe.ideashell.core.voice.VoiceIntent
import com.carpe.ideashell.core.voice.VoiceIntents
import com.carpe.ideashell.core.voice.VoiceResult
import com.carpe.ideashell.data.asr.AsrException
import com.carpe.ideashell.data.asr.CODE_NETWORK
import com.carpe.ideashell.data.asr.LocalSenseVoice
import com.carpe.ideashell.data.asr.Lexicon
import com.carpe.ideashell.data.asr.TencentAsr
import com.carpe.ideashell.data.llm.LlmClient
import com.carpe.ideashell.data.llm.LlmException
import com.carpe.ideashell.data.settings.SettingsStore
import com.carpe.ideashell.data.settings.VoiceEngine
import com.carpe.ideashell.system.VoiceRecorder
import com.carpe.ideashell.ui.theme.Brand
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.LocalDateTime
import kotlin.math.abs

enum class VoicePhase { IDLE, RECORDING, LOCKED, PROCESSING }

/** 语音整理应用到输入框之前的状态：点「还原」时退回原话（并撤销大模型设的类型 / 日期） */
class VoiceUndo(
    val raw: String,
    val prevText: String,
    val prevOverride: CaptureKind?,
    val prevSchedule: CaptureSchedule?,
    /** 经过大模型整理才有「还原」；没整理（本地规则）只显示原话和「纠错」 */
    val polished: Boolean = true,
)

/**
 * 按住说话的流程：录音 → 腾讯云一句话识别 →（可选）大模型整理并推算日期时间 → [onResult]。
 * 界面只读 [phase] / [level] / [elapsedMs] / [cancelHint]，手势里调用 [start] / [lock] / [finish] / [cancel]。
 * 任何一步失败都不丢话：识别成功后总会交出转写原文，大模型失败就只带 [VoiceResult.polishError]。
 */
class VoiceInputController(
    private val scope: CoroutineScope,
    private val settings: SettingsStore,
    private val asr: TencentAsr,
    /** 本地 SenseVoice：没网 / 云端识别失败 / 没填腾讯云密钥时兜底（设置里开启并下载了模型才会用） */
    private val local: LocalSenseVoice,
    private val llm: LlmClient,
    private val lexicon: Lexicon,
    /** 额外的热词来源（闪念贝壳文件夹 / 项目名） */
    private val extraHotwords: () -> List<String>,
    /** 用户目前未完成的待办（「任务名｜日期 时间」）：给大模型判断「改 / 完成 / 删除哪一条」，也帮它修正人名项目名 */
    private val todoContext: () -> List<String> = { emptyList() },
    private val onError: (String) -> Unit,
    private val onResult: (VoiceResult) -> Unit,
) {
    private val recorder = VoiceRecorder()
    private var ticker: Job? = null
    private var processing: Job? = null
    private var startedAt = 0L

    var phase by mutableStateOf(VoicePhase.IDLE)
        private set
    var level by mutableFloatStateOf(0f)
        private set
    var elapsedMs by mutableLongStateOf(0L)
        private set

    /** 手指拖到了「松手取消」的区域 */
    var cancelHint by mutableStateOf(false)

    /** 设置里的总开关 */
    val enabled: Boolean get() = settings.current.voiceEnabled

    private val engine: VoiceEngine get() = settings.current.voiceEngine

    /** 本地模型已下载好 */
    private val localReady: Boolean get() = local.ready

    /** 当前选的识别方式有没有条件用：云端要密钥，本地要模型已下载，自动二者有一即可 */
    private fun engineUsable(): Boolean = when (engine) {
        VoiceEngine.CLOUD -> asr.configured
        VoiceEngine.LOCAL -> localReady
        VoiceEngine.AUTO -> asr.configured || localReady
    }

    /** 语音输入开着、并且选的识别方式能用 */
    val available: Boolean get() = settings.current.voiceEnabled && engineUsable()

    /** 开始录音；没开 / 没配密钥 / 打不开麦克风时通过 [onError] 说明原因并返回 false。调用前要先拿到录音权限。 */
    fun start(): Boolean {
        if (phase != VoicePhase.IDLE) return false
        if (!settings.current.voiceEnabled) {
            onError("语音输入已关闭，可在 设置 → 语音输入 里打开")
            return false
        }
        if (!engineUsable()) {
            onError(
                when (engine) {
                    VoiceEngine.CLOUD -> "云端识别需要腾讯云密钥（和文字识别共用，并开通「语音识别」）：设置 → 语音输入"
                    VoiceEngine.LOCAL -> "本地识别需要先下载模型：设置 → 语音输入 → 本地模型"
                    VoiceEngine.AUTO -> "语音输入需要腾讯云密钥（和文字识别共用，并开通「语音识别」），或下载本地模型：设置 → 语音输入"
                },
            )
            return false
        }
        val ok = recorder.start(scope, onLevel = { level = it }, onLimit = { scope.launch { finish() } })
        if (!ok) {
            onError("无法打开麦克风，请检查权限或是否被其他应用占用")
            return false
        }
        startedAt = SystemClock.elapsedRealtime()
        elapsedMs = 0
        cancelHint = false
        phase = VoicePhase.RECORDING
        ticker = scope.launch {
            while (phase == VoicePhase.RECORDING || phase == VoicePhase.LOCKED) {
                elapsedMs = SystemClock.elapsedRealtime() - startedAt
                delay(100)
            }
        }
        return true
    }

    /** 下拖锁定：松手后继续录，点「完成」才结束 */
    fun lock() {
        if (phase == VoicePhase.RECORDING) {
            cancelHint = false
            phase = VoicePhase.LOCKED
        }
    }

    /** 结束录音并开始识别 */
    fun finish() {
        if (phase != VoicePhase.RECORDING && phase != VoicePhase.LOCKED) return
        phase = VoicePhase.PROCESSING
        cancelHint = false
        level = 0f
        ticker?.cancel()
        processing = scope.launch {
            val pcm = recorder.stop()
            process(pcm)
        }
    }

    /** 丢弃：录音中直接丢；识别中则放弃结果 */
    fun cancel() {
        when (phase) {
            VoicePhase.RECORDING, VoicePhase.LOCKED -> {
                ticker?.cancel()
                recorder.cancel()
            }
            VoicePhase.PROCESSING -> processing?.cancel()
            VoicePhase.IDLE -> Unit
        }
        phase = VoicePhase.IDLE
        cancelHint = false
        level = 0f
    }

    /** 页面销毁时释放麦克风 */
    fun release() {
        if (phase == VoicePhase.RECORDING || phase == VoicePhase.LOCKED) recorder.cancel()
        ticker?.cancel()
        processing?.cancel()
        phase = VoicePhase.IDLE
    }

    private suspend fun process(pcm: ByteArray) {
        try {
            val durationMs = pcm.size / 32L // 16kHz × 16 位 = 每毫秒 32 字节
            if (durationMs < MIN_MS) {
                onError("说话时间太短，按住说完再松手")
                return
            }
            val hot = lexicon.hotwordsFor(extraHotwords())
            // 词库里的替换规则先改一遍：总是听错的词不用每次都纠
            val heard = recognize(pcm, hot)
            val raw = lexicon.apply(heard.text)
            if (raw.isBlank()) {
                onError("没有听清，再说一次试试")
                return
            }
            val cleaned = SpeechCleaner.clean(raw)

            var intents: List<VoiceIntent> = emptyList()
            var polishError: String? = null
            // 没填大模型 Key 就静默用本地规则；填了但失败，提示一句并退回原始转写
            if (settings.current.voicePolish && llm.configured) {
                try {
                    val now = LocalDateTime.now()
                    val reply = llm.chatJson(VoiceIntents.systemPrompt(now, vocabulary = hot, todos = todoContext()), VoiceIntents.userPrompt(raw))
                    // 「半小时后」这类相对时间，本地再精确算一遍
                    intents = VoiceIntents.fixRelativeTime(raw, VoiceIntents.parse(reply), now)
                    if (intents.isEmpty()) polishError = "AI 整理的结果无法解析，已使用原始转写"
                } catch (e: LlmException) {
                    polishError = (e.message ?: "AI 整理失败") + "，已使用原始转写"
                }
            }
            val note = listOfNotNull(heard.note, polishError).joinToString("；").ifBlank { null }
            // 没有大模型整理时，本地规则听「追加到上一条笔记」
            val appendText = if (intents.isEmpty()) VoiceIntents.stripAppendCommand(raw) else null
            onResult(
                if (appendText != null) VoiceResult(raw, SpeechCleaner.clean(appendText), intents, note, appendToLast = true)
                else VoiceResult(raw, cleaned, intents, note),
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: AsrException) {
            onError(e.message ?: "识别失败")
        } catch (e: Exception) {
            onError("语音处理出错：${e.message ?: e.javaClass.simpleName}")
        } finally {
            phase = VoicePhase.IDLE
        }
    }

    /** 一次识别的结果；[note] 是走了本地识别时给用户的一句说明 */
    private class Heard(val text: String, val note: String? = null)

    /**
     * 按设置里的识别方式识别：
     * - 本地：只用本地模型；
     * - 云端：只用腾讯云，出错就报错；
     * - 自动：云端优先；没网、云端出错或没填密钥时，本地模型可用就改用本地。
     * 本地识别没有热词，识别后词库里的替换规则仍然会生效。
     */
    private suspend fun recognize(pcm: ByteArray, hot: List<String>): Heard {
        when (engine) {
            VoiceEngine.LOCAL -> return Heard(local.recognize(pcm))
            VoiceEngine.CLOUD -> return Heard(asr.recognize(pcm, hot))
            VoiceEngine.AUTO -> Unit
        }
        if (!asr.configured) return Heard(local.recognize(pcm))
        if (localReady && local.offline) return Heard(local.recognize(pcm), "当前没有网络，已用本地识别")
        return try {
            Heard(asr.recognize(pcm, hot))
        } catch (e: AsrException) {
            if (localReady) {
                val reason = if (e.code == CODE_NETWORK) "网络不可用" else (e.message ?: "云端识别失败")
                Heard(local.recognize(pcm), "$reason，已用本地识别")
            } else if (e.code == CODE_NETWORK && local.supported) {
                throw AsrException((e.message ?: "网络不可用") + "（设置 → 语音输入 里下载本地模型后，断网也能用）", e.code)
            } else {
                throw e
            }
        }
    }

    private companion object {
        const val MIN_MS = 600L
    }
}

private fun hasMicPermission(context: android.content.Context): Boolean =
    ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

/**
 * 「按住说话」手势（工具栏按钮和输入框共用）：
 * - 按住 → 开始录音，松手 → 识别；
 * - 按住后向下拖 → 锁定（松手继续录，点状态条上的「完成」结束）；
 * - 按住后向上拖远 → 松手取消。
 *
 * [inField] 为 true 时挂在输入框外面，在 Initial 阶段先于输入框看到触摸：
 * 没按够时间就抬手 / 拖动，一律不管，输入框照常点击、滚动、双击选词；按够时间才接管，录音期间吞掉触摸，
 * 输入框不会再弹出选词菜单。语音输入关掉时这里什么都不做，长按仍是系统自带的行为。
 * 为 false 时是工具栏上的按钮：轻点只提示用法。
 */
@Composable
fun Modifier.voiceHoldGesture(voice: VoiceInputController, inField: Boolean): Modifier {
    val context = LocalContext.current
    val haptic = LocalHapticFeedback.current
    val density = LocalDensity.current
    val lockPx = with(density) { 56.dp.toPx() }
    val cancelPx = with(density) { 72.dp.toPx() }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (!granted) Toast.makeText(context, "没有麦克风权限，无法语音输入", Toast.LENGTH_SHORT).show()
    }
    val latestVoice by rememberUpdatedState(voice)
    val pass = if (inField) PointerEventPass.Initial else PointerEventPass.Main

    return this.pointerInput(inField) {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false, pass = pass)
            if (inField && !latestVoice.enabled) return@awaitEachGesture
            // 正在录音 / 识别时不再接手新的触摸（点「完成」「取消」交给按钮自己）
            if (latestVoice.phase != VoicePhase.IDLE) return@awaitEachGesture

            // 等长按成立；期间抬手 / 被别人消费 / 拖动超过阈值，都不算长按
            var tapped = false
            val aborted = withTimeoutOrNull(if (inField) FIELD_HOLD_MS else viewConfiguration.longPressTimeoutMillis) {
                var abort = false
                while (!abort) {
                    val event = awaitPointerEvent(pass)
                    val c = event.changes.firstOrNull { it.id == down.id }
                    when {
                        c == null -> abort = true
                        !c.pressed -> {
                            tapped = true
                            abort = true
                        }
                        c.isConsumed || (c.position - down.position).getDistance() > viewConfiguration.touchSlop -> abort = true
                    }
                }
                true
            }
            if (aborted != null) {
                if (tapped && !inField) {
                    Toast.makeText(
                        context,
                        if (latestVoice.available) "按住说话，松手识别；下滑锁定，上滑取消" else "语音输入需要先在 设置 → 语音输入 里填腾讯云密钥",
                        Toast.LENGTH_SHORT,
                    ).show()
                }
                return@awaitEachGesture
            }

            // 长按成立
            if (!hasMicPermission(context)) {
                permission.launch(Manifest.permission.RECORD_AUDIO)
                drainUntilUp(down.id, pass)
                return@awaitEachGesture
            }
            val v = latestVoice
            if (!v.start()) {
                drainUntilUp(down.id, pass)
                return@awaitEachGesture
            }
            haptic.performHapticFeedback(HapticFeedbackType.LongPress)

            var locked = false
            while (true) {
                val event = awaitPointerEvent(pass)
                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                if (!change.pressed) {
                    change.consume()
                    if (!locked) {
                        if (v.cancelHint) v.cancel() else v.finish()
                    }
                    break
                }
                change.consume()
                if (!locked) {
                    val dy = change.position.y - down.position.y
                    val dx = change.position.x - down.position.x
                    if (dy > lockPx) {
                        locked = true
                        v.lock()
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    } else {
                        v.cancelHint = dy < -cancelPx || abs(dx) > cancelPx * 2
                    }
                }
            }
        }
    }
}

/** 输入框里长按比系统的长按（约 400–500ms）略早一点接管，抢在输入框弹出选词菜单之前 */
private const val FIELD_HOLD_MS = 350L

/** 吞掉这根手指剩下的触摸，直到抬起（没能开始录音时，避免输入框再响应这次长按） */
private suspend fun AwaitPointerEventScope.drainUntilUp(id: PointerId, pass: PointerEventPass) {
    while (true) {
        val event = awaitPointerEvent(pass)
        val change = event.changes.firstOrNull { it.id == id } ?: return
        change.consume()
        if (!change.pressed) return
    }
}

/** 工具栏上的「按住说话」按钮（对标 Typefree 的鼠标长按说话） */
@Composable
fun VoiceHoldButton(voice: VoiceInputController, modifier: Modifier = Modifier) {
    val busy = voice.phase != VoicePhase.IDLE
    val tint = if (busy) Brand.Brown else MaterialTheme.colorScheme.onSurface

    Box(
        modifier = modifier
            .height(40.dp)
            .widthIn(min = 40.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(if (busy) Brand.Orange else androidx.compose.ui.graphics.Color.Transparent)
            .semantics { contentDescription = "按住说话，识别成待办、日记或笔记" }
            .voiceHoldGesture(voice, inField = false),
        contentAlignment = Alignment.Center,
    ) {
        Icon(painterResource(R.drawable.ic_voice_input), contentDescription = null, tint = tint, modifier = Modifier.size(24.dp))
    }
}

/**
 * 录音 / 识别时盖在输入区上的面板（输入框此时隐藏，占位文字也让位给它）：
 * 左边是时长，中间是随音量跳动的波形，下面一行是手势提示；锁定后右边有「取消 / 完成」，识别中显示转圈和「放弃」。
 */
@Composable
fun VoiceWavePanel(voice: VoiceInputController, modifier: Modifier = Modifier) {
    val phase = voice.phase
    if (phase == VoicePhase.IDLE) return
    val scheme = MaterialTheme.colorScheme
    val cancelling = voice.cancelHint && phase == VoicePhase.RECORDING
    val seconds = (voice.elapsedMs / 1000).toInt()
    val barColor = if (cancelling) scheme.error else Brand.Orange

    // 最近一小段音量，从右往左滚动
    val bars = remember { mutableStateListOf<Float>() }
    LaunchedEffect(Unit) {
        while (true) {
            bars.add(voice.level)
            if (bars.size > WAVE_BARS) bars.removeAt(0)
            delay(60)
        }
    }

    Column(
        modifier = modifier.padding(start = 16.dp, end = 52.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (phase == VoicePhase.PROCESSING) {
                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                Text("正在识别…", style = MaterialTheme.typography.bodyLarge, color = scheme.onSurfaceVariant)
            } else {
                Text(
                    "%d:%02d".format(seconds / 60, seconds % 60),
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = if (cancelling) scheme.error else scheme.onSurface,
                )
                Canvas(Modifier.weight(1f).height(36.dp)) {
                    val slot = size.width / WAVE_BARS
                    val barW = 3.dp.toPx()
                    val minH = 4.dp.toPx()
                    val offset = WAVE_BARS - bars.size
                    bars.forEachIndexed { i, raw ->
                        // 开方让小声也看得出起伏
                        val h = (minH + (size.height - minH) * Math.sqrt(raw.toDouble()).toFloat()).coerceAtMost(size.height)
                        val x = (offset + i) * slot + slot / 2
                        drawLine(
                            color = barColor,
                            start = Offset(x, (size.height - h) / 2),
                            end = Offset(x, (size.height + h) / 2),
                            strokeWidth = barW,
                            cap = StrokeCap.Round,
                        )
                    }
                }
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth().heightIn(min = 32.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                when {
                    phase == VoicePhase.PROCESSING -> "整理成待办、日记或笔记"
                    cancelling -> "松手取消"
                    phase == VoicePhase.LOCKED -> "录音中，说完点「完成」"
                    else -> "松手完成 · 下滑锁定 · 上滑取消"
                },
                style = MaterialTheme.typography.bodyMedium,
                color = if (cancelling) scheme.error else scheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            when (phase) {
                VoicePhase.LOCKED -> {
                    TextButton(onClick = voice::cancel) { Text("取消") }
                    Box(
                        modifier = Modifier
                            .height(30.dp)
                            .clip(CircleShape)
                            .background(Brand.Orange)
                            .clickable(role = Role.Button, onClick = voice::finish)
                            .padding(horizontal = 14.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text("完成", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, color = Brand.Brown)
                    }
                }
                VoicePhase.PROCESSING -> TextButton(onClick = voice::cancel) { Text("放弃") }
                else -> Unit
            }
        }
    }
}

private const val WAVE_BARS = 32

/**
 * 语音结果下面的提示条：显示整理前的原话（最多两行）；整理过的可「还原」，识别错字可「纠错」（记进词库，下次自动改对）。
 */
@Composable
fun VoiceUndoBar(
    undo: VoiceUndo,
    onRevert: () -> Unit,
    onCorrect: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    Row(
        modifier = modifier
            .padding(horizontal = 12.dp, vertical = 2.dp)
            .fillMaxWidth()
            .padding(start = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(painterResource(R.drawable.ic_sparkle), contentDescription = null, tint = scheme.primary, modifier = Modifier.size(16.dp))
        Text(
            (if (undo.polished) "整理前：" else "原话：") + undo.raw,
            fontSize = 12.sp,
            color = scheme.onSurfaceVariant,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f).padding(start = 4.dp),
        )
        Text(
            "纠错",
            fontSize = 12.sp,
            fontWeight = FontWeight.ExtraBold,
            color = scheme.primary,
            modifier = Modifier
                .clip(CircleShape)
                .clickable(role = Role.Button, onClick = onCorrect)
                .padding(horizontal = 8.dp, vertical = 6.dp),
        )
        if (undo.polished) {
            Text(
                "还原",
                fontSize = 12.sp,
                fontWeight = FontWeight.ExtraBold,
                color = scheme.primary,
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable(role = Role.Button, onClick = onRevert)
                    .padding(horizontal = 8.dp, vertical = 6.dp),
            )
        }
        Icon(
            Icons.Filled.Close,
            contentDescription = "关闭提示",
            tint = scheme.onSurfaceVariant,
            modifier = Modifier
                .size(28.dp)
                .clip(CircleShape)
                .clickable(role = Role.Button, onClick = onDismiss)
                .padding(6.dp),
        )
    }
}

/**
 * 一句话里拆出多件事时的预览：每项一行（类型 + 正文 + 日期时间 / 重复），可以去掉某一项；
 * 点面板右上角的确认键后，每项各存一条。
 */
@Composable
fun VoiceItemsPreview(items: List<VoiceIntent>, onRemove: (Int) -> Unit, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    Column(
        modifier = modifier
            .padding(horizontal = 12.dp, vertical = 4.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(scheme.surfaceContainerLow)
            .padding(vertical = 6.dp),
    ) {
        Text(
            "听出 ${items.size} 件事 · 点右上角确认，分别保存",
            style = MaterialTheme.typography.labelMedium,
            color = scheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 14.dp, end = 14.dp, top = 2.dp, bottom = 4.dp),
        )
        items.forEachIndexed { index, item ->
            Row(
                modifier = Modifier.fillMaxWidth().padding(start = 12.dp, end = 4.dp, top = 3.dp, bottom = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val colors = kindColors(item.type)
                InfoPill(
                    text = when (item.type) {
                        CaptureKind.TODO -> "待办"
                        CaptureKind.DAILY -> "日记"
                        CaptureKind.NOTE -> "笔记"
                    },
                    icon = kindIcon(item.type),
                    container = colors.container,
                    content = colors.onContainer,
                )
                Column(Modifier.weight(1f)) {
                    Text(item.content, style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    val whenText = scheduleLabel(item)
                    if (whenText.isNotEmpty()) {
                        Text(whenText, style = MaterialTheme.typography.labelMedium, color = scheme.primary)
                    }
                }
                Icon(
                    Icons.Filled.Close,
                    contentDescription = "去掉这一项",
                    tint = scheme.onSurfaceVariant,
                    modifier = Modifier
                        .size(32.dp)
                        .clip(CircleShape)
                        .clickable(role = Role.Button) { onRemove(index) }
                        .padding(7.dp),
                )
            }
        }
    }
}

/** 「明天 09:00 · 每周五」这样的一行；不是待办或没有日期时间时为空 */
private fun scheduleLabel(item: VoiceIntent): String {
    if (item.type != CaptureKind.TODO) return ""
    val parts = mutableListOf<String>()
    item.date?.let { date ->
        val today = java.time.LocalDate.now()
        parts += when (date) {
            today -> "今天"
            today.plusDays(1) -> "明天"
            today.plusDays(2) -> "后天"
            else -> "${date.monthValue}月${date.dayOfMonth}日 ${date.dayOfWeek.getDisplayName(java.time.format.TextStyle.SHORT, java.util.Locale.CHINA)}"
        }
    }
    item.time?.let { parts += "%02d:%02d".format(it.hour, it.minute) }
    item.repeat?.let { parts += it }
    return parts.joinToString(" ")
}

/** 纠错：告诉我识别成了什么、应该是什么；记进词库，下次说到自动改对，当前文字也立刻改掉 */
@Composable
fun VoiceCorrectDialog(raw: String, onConfirm: (String, String) -> Unit, onDismiss: () -> Unit) {
    var from by remember { mutableStateOf("") }
    var to by remember { mutableStateOf("") }
    com.carpe.ideashell.ui.glass.GlassAlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("纠正识别错误") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "原话：$raw",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                androidx.compose.material3.OutlinedTextField(
                    value = from,
                    onValueChange = { from = it },
                    label = { Text("识别成了（从原话里复制）") },
                    singleLine = true,
                )
                androidx.compose.material3.OutlinedTextField(
                    value = to,
                    onValueChange = { to = it },
                    label = { Text("应该是") },
                    singleLine = true,
                )
                Text(
                    "会记进「设置 → 语音输入 → 词库」，以后自动改对。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = from.isNotBlank() && to.isNotBlank() && from.trim() != to.trim(),
                onClick = {
                    onConfirm(from.trim(), to.trim())
                    onDismiss()
                },
            ) { Text("记住并改正") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}
