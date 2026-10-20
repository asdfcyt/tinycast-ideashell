package com.carpe.ideashell.data.asr

import android.content.Context
import android.os.Build
import com.k2fsa.sherpa.onnx.OfflineSpeechDenoiser
import com.k2fsa.sherpa.onnx.OfflineSpeechDenoiserConfig
import com.k2fsa.sherpa.onnx.OfflineSpeechDenoiserGtcrnModelConfig
import com.k2fsa.sherpa.onnx.OfflineSpeechDenoiserModelConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder

sealed interface DenoiserState {
    data object Unsupported : DenoiserState
    data object Missing : DenoiserState
    data object Downloading : DenoiserState
    data class Ready(val sizeKb: Int) : DenoiserState
    data class Failed(val message: String) : DenoiserState
}

/**
 * 本机 AI 降噪（sherpa-onnx 的 GTCRN 语音增强模型，约 0.5 MB）：识别前把 16kHz / 单声道 / 16 位的 PCM 过一遍。
 * - 模型不随应用安装，在设置里打开开关时下载一次；全程在手机上处理，录音不会上传；
 * - 任何一步出错都退回原录音，不影响识别；
 * - 降噪不一定让云端识别更准（云端模型本来就是带噪数据训练的），所以做成开关，可用「语音历史 → 重新识别」对比。
 */
class VoiceDenoiser(
    context: Context,
    http: OkHttpClient,
    private val scope: CoroutineScope,
) {
    private val appContext = context.applicationContext
    private val client = http
    private val dir = File(appContext.filesDir, "asr/denoise")
    private val modelFile get() = File(dir, MODEL_NAME)

    private val supported: Boolean = Build.SUPPORTED_ABIS.any { it == "arm64-v8a" }

    private val _state = MutableStateFlow(initialState())
    val state: StateFlow<DenoiserState> = _state.asStateFlow()

    val ready: Boolean get() = _state.value is DenoiserState.Ready

    private val lock = Mutex()
    private var engine: OfflineSpeechDenoiser? = null
    private var idleJob: Job? = null
    private var downloadJob: Job? = null

    private fun initialState(): DenoiserState = when {
        !supported -> DenoiserState.Unsupported
        modelFile.length() >= MODEL_MIN_BYTES -> DenoiserState.Ready((modelFile.length() / 1024).toInt())
        else -> DenoiserState.Missing
    }

    fun download() {
        if (!supported || downloadJob?.isActive == true || ready) return
        _state.value = DenoiserState.Downloading
        downloadJob = scope.launch(Dispatchers.IO) {
            try {
                dir.mkdirs()
                val part = File(dir, "$MODEL_NAME.part")
                client.newCall(Request.Builder().url(MODEL_URL).build()).execute().use { resp ->
                    if (!resp.isSuccessful) throw IOException("服务器返回 ${resp.code}")
                    val body = resp.body ?: throw IOException("服务器没有返回内容")
                    part.outputStream().use { out -> body.byteStream().copyTo(out) }
                }
                if (part.length() < MODEL_MIN_BYTES) throw IOException("模型文件不完整")
                modelFile.delete()
                if (!part.renameTo(modelFile)) throw IOException("无法保存模型文件")
                _state.value = DenoiserState.Ready((modelFile.length() / 1024).toInt())
            } catch (e: CancellationException) {
                File(dir, "$MODEL_NAME.part").delete()
                _state.value = initialState()
                throw e
            } catch (e: Exception) {
                File(dir, "$MODEL_NAME.part").delete()
                _state.value = DenoiserState.Failed(
                    if (e is java.net.UnknownHostException || e is java.net.SocketTimeoutException || e is java.net.ConnectException) "网络连接失败，请检查网络后重试"
                    else e.message ?: "下载失败",
                )
            }
        }
    }

    fun delete() {
        downloadJob?.cancel()
        scope.launch(Dispatchers.IO) {
            lock.withLock { releaseLocked() }
            dir.deleteRecursively()
            _state.value = initialState()
        }
    }

    /** 降噪；模型没下载 / 出任何错都原样返回 [pcm] */
    suspend fun denoise(pcm: ByteArray): ByteArray {
        if (!ready || pcm.isEmpty()) return pcm
        return withContext(Dispatchers.Default) {
            lock.withLock {
                idleJob?.cancel()
                try {
                    val denoiser = engine ?: create().also { engine = it }
                    val shorts = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                    val samples = FloatArray(shorts.remaining()) { shorts.get(it) / 32768f }
                    val out = denoiser.run(samples, SAMPLE_RATE)
                    val buf = ByteBuffer.allocate(out.samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
                    for (v in out.samples) buf.putShort((v * 32767f).toInt().coerceIn(-32768, 32767).toShort())
                    // 输出的采样率应该和输入一致；对不上说明模型 / 库不匹配，宁可不用
                    if (out.sampleRate != SAMPLE_RATE || out.samples.isEmpty()) pcm else buf.array()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    releaseLocked()
                    pcm
                } finally {
                    scheduleIdleRelease()
                }
            }
        }
    }

    private fun create(): OfflineSpeechDenoiser = OfflineSpeechDenoiser(
        config = OfflineSpeechDenoiserConfig(
            model = OfflineSpeechDenoiserModelConfig(
                gtcrn = OfflineSpeechDenoiserGtcrnModelConfig(model = modelFile.absolutePath),
                numThreads = 2,
            ),
        ),
    )

    private fun scheduleIdleRelease() {
        idleJob = scope.launch {
            delay(IDLE_RELEASE_MS)
            lock.withLock { releaseLocked() }
        }
    }

    private fun releaseLocked() {
        runCatching { engine?.release() }
        engine = null
    }

    private companion object {
        const val SAMPLE_RATE = 16_000
        const val MODEL_NAME = "gtcrn_simple.onnx"
        const val MODEL_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speech-enhancement-models/gtcrn_simple.onnx"

        /** 完整的模型约 523 KB，小于这个数说明没下完 */
        const val MODEL_MIN_BYTES = 400L * 1024
        const val IDLE_RELEASE_MS = 2 * 60_000L
    }
}
