package com.carpe.ideashell.data.tts

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import android.widget.Toast
import com.carpe.ideashell.data.settings.SettingsStore
import com.carpe.ideashell.data.settings.SpeakEngine
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.Locale
import kotlin.coroutines.resume

/** 手机上装着的一个语音合成引擎（系统「文字转语音」里能选的那些） */
data class SystemTtsEngine(val pkg: String, val label: String)

/**
 * 语音回答：把助手的回答念出来。
 * - 系统语音：用 Android 的 TextToSpeech，默认走系统里选中的引擎（荣耀手机在「系统设置 → 文字转语音」里选荣耀自带的）；
 * - 腾讯云：按句合成 PCM，边合成边播，声音更拟人。云端出错时自动退回系统语音，并提示原因。
 * 新的一轮录音开始 / 用户点了别的，调用 [stop] 立刻停。
 */
class SpeechOut(
    private val context: Context,
    private val settings: SettingsStore,
    private val tencent: TencentTts,
    private val scope: CoroutineScope,
) {
    private val main = Handler(Looper.getMainLooper())
    private val audio = context.getSystemService(AudioManager::class.java)
    private var job: Job? = null
    private var tts: TextToSpeech? = null
    private var ttsEngine: String? = null
    private var ttsReady = false
    private var pendingSystem: Pair<String, Float>? = null
    private var focus: AudioFocusRequest? = null

    private val attrs = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANT)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    /** 设置里开了「语音回答」才念；念之前先停掉上一段 */
    fun speak(text: String) {
        if (!settings.current.speakReply) return
        speakNow(text, onError = { toast(it) })
    }

    /** 不管开关，用当前设置的声音念一段（设置里的「试听」）；[onDone] 在念完 / 出错后回调（主线程） */
    fun preview(text: String, onDone: () -> Unit = {}) {
        speakNow(text, onError = { toast(it) }, onDone = onDone)
    }

    fun stop() {
        job?.cancel()
        job = null
        main.post {
            runCatching { tts?.stop() }
            abandonFocus()
        }
    }

    fun release() {
        stop()
        main.post {
            runCatching { tts?.shutdown() }
            tts = null
            ttsReady = false
        }
    }

    private fun speakNow(raw: String, onError: (String) -> Unit, onDone: () -> Unit = {}) {
        val text = plain(raw)
        if (text.isEmpty()) {
            onDone()
            return
        }
        stop()
        val s = settings.current
        job = scope.launch(Dispatchers.IO) {
            requestFocus()
            try {
                if (s.speakEngine == SpeakEngine.TENCENT) {
                    try {
                        speakTencent(text, s.speakTencentVoice, s.speakSpeed)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        Log.w(TAG, "tencent tts failed", e)
                        onError("云端语音不可用，已改用系统语音：" + (e.message ?: ""))
                        speakSystem(text, s.speakSystemEngine, rateOf(s.speakSpeed))
                    }
                } else {
                    speakSystem(text, s.speakSystemEngine, rateOf(s.speakSpeed))
                }
            } finally {
                abandonFocus()
                main.post(onDone)
            }
        }
    }

    // ───────────────────────── 腾讯云 ─────────────────────────

    private suspend fun speakTencent(text: String, voice: Int, speed: Int) {
        val parts = TencentTts.split(text)
        if (parts.isEmpty()) return
        val minBuf = AudioTrack.getMinBufferSize(TencentTts.SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val track = AudioTrack.Builder()
            .setAudioAttributes(attrs)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(TencentTts.SAMPLE_RATE)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setBufferSizeInBytes(maxOf(minBuf, TencentTts.SAMPLE_RATE * 2))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        var frames = 0L
        try {
            // 合成和播放并行：合成线程最多领先两段，播放线程一段一段写进 AudioTrack
            val queue = Channel<ByteArray>(2)
            val producer = scope.launch(Dispatchers.IO) {
                try {
                    for (p in parts) queue.send(tencent.synthesize(p, voice, speed))
                    queue.close()
                } catch (e: CancellationException) {
                    queue.close(e)
                    throw e
                } catch (e: Exception) {
                    queue.close(e)
                }
            }
            try {
                track.play()
                var first = true
                for (pcm in queue) {
                    if (!kotlinx.coroutines.currentCoroutineContext().isActive) break
                    track.write(pcm, 0, pcm.size)
                    frames += pcm.size / 2
                    first = false
                }
                if (first) throw TtsException("没有合成出声音")
            } catch (e: TtsException) {
                // 一段都没播出来就失败了：交给上层退回系统语音；播到一半失败就算了，念多少是多少
                if (frames == 0L) throw e
            } finally {
                producer.cancel()
            }
            // 等已经写进去的声音播完
            var waited = 0
            while (kotlinx.coroutines.currentCoroutineContext().isActive && track.playbackHeadPosition < frames && waited < 120_000) {
                delay(60)
                waited += 60
            }
        } finally {
            runCatching { track.pause(); track.flush() }
            runCatching { track.release() }
        }
    }

    // ───────────────────────── 系统语音 ─────────────────────────

    /** 用系统语音引擎念；念完（或被打断 / 出错）才返回 */
    private suspend fun speakSystem(text: String, enginePkg: String, rate: Float) {
        suspendCancellableCoroutine<Unit> { cont ->
            main.post {
                val id = "shiyi-" + System.nanoTime()
                val listener = object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {}
                    override fun onDone(utteranceId: String?) { if (utteranceId == id && cont.isActive) cont.resume(Unit) }
                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) { if (utteranceId == id && cont.isActive) cont.resume(Unit) }
                    override fun onStop(utteranceId: String?, interrupted: Boolean) { if (utteranceId == id && cont.isActive) cont.resume(Unit) }
                }
                cont.invokeOnCancellation { main.post { runCatching { tts?.stop() } } }
                ensureTts(enginePkg) { engine ->
                    engine.setOnUtteranceProgressListener(listener)
                    engine.setSpeechRate(rate)
                    // 超长的话分段排队：系统引擎对单次文字长度有上限（通常 4000 字）
                    val chunks = text.chunked(1500)
                    chunks.forEachIndexed { i, c ->
                        val uid = if (i == chunks.lastIndex) id else "$id-$i"
                        engine.speak(c, if (i == 0) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD, null, uid)
                    }
                }
            }
        }
    }

    /** 在主线程里取得可用的 TextToSpeech（引擎换了就重建）；初始化好后回调 [ready] */
    private fun ensureTts(enginePkg: String, ready: (TextToSpeech) -> Unit) {
        val want = enginePkg.ifBlank { null }
        val cur = tts
        if (cur != null && ttsReady && ttsEngine == want) {
            ready(cur)
            return
        }
        runCatching { cur?.shutdown() }
        ttsReady = false
        ttsEngine = want
        var created: TextToSpeech? = null
        val onInit = TextToSpeech.OnInitListener { status ->
            val engine = created
            if (status == TextToSpeech.SUCCESS && engine != null) {
                val lang = engine.setLanguage(Locale.CHINA)
                if (lang == TextToSpeech.LANG_MISSING_DATA || lang == TextToSpeech.LANG_NOT_SUPPORTED) {
                    toast("这个语音引擎没有中文语音包，请到 系统设置 → 文字转语音 里下载 / 换一个引擎")
                }
                engine.setAudioAttributes(attrs)
                ttsReady = true
                ready(engine)
            } else {
                toast("系统语音引擎启动失败，请到 系统设置 → 文字转语音 里检查")
            }
        }
        created = if (want == null) TextToSpeech(context, onInit) else TextToSpeech(context, onInit, want)
        tts = created
    }

    // ───────────────────────── 音频焦点 / 小工具 ─────────────────────────

    private fun requestFocus() {
        val am = audio ?: return
        val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(attrs)
            .setOnAudioFocusChangeListener { }
            .build()
        focus = req
        runCatching { am.requestAudioFocus(req) }
    }

    private fun abandonFocus() {
        val am = audio ?: return
        focus?.let { runCatching { am.abandonAudioFocusRequest(it) } }
        focus = null
    }

    private fun toast(text: String) {
        main.post { Toast.makeText(context, text, Toast.LENGTH_LONG).show() }
    }

    private fun rateOf(speed: Int): Float = when (speed.coerceIn(-2, 2)) {
        -2 -> 0.7f
        -1 -> 0.85f
        1 -> 1.2f
        2 -> 1.4f
        else -> 1.0f
    }

    companion object {
        private const val TAG = "SpeechOut"

        /** 回答里的「· 」列表符、括号里的说明、网址不念；最多念 [MAX_SPEAK] 字 */
        private const val MAX_SPEAK = 600

        fun plain(raw: String): String = raw
            .replace(Regex("https?://\\S+"), "")
            .replace(Regex("(?m)^\\s*[·•\\-*]\\s*"), "")
            .replace(Regex("[「」『』【】]"), "")
            .replace(Regex("[ \\t]+"), " ")
            .replace(Regex("\\n{2,}"), "\n")
            .trim()
            .take(MAX_SPEAK)

        /** 手机上装着的语音合成引擎 */
        fun installedEngines(context: Context): List<SystemTtsEngine> {
            val pm = context.packageManager
            return runCatching {
                pm.queryIntentServices(Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE), 0)
                    .mapNotNull { it.serviceInfo }
                    .map { SystemTtsEngine(it.packageName, it.loadLabel(pm).toString()) }
                    .distinctBy { it.pkg }
            }.getOrDefault(emptyList())
        }

        /** 系统「文字转语音」设置页（选默认引擎 / 下载语音包） */
        fun openSystemTtsSettings(context: Context) {
            val intents = listOf(
                Intent("com.android.settings.TTS_SETTINGS"),
                Intent("android.settings.TTS_SETTINGS"),
                Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS),
            )
            for (i in intents) {
                val ok = runCatching { context.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }.isSuccess
                if (ok) return
            }
        }
    }
}
