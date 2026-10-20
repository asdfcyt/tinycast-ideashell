package com.carpe.ideashell.data.asr

import android.content.Context
import android.os.Build
import com.k2fsa.sherpa.onnx.SpeakerEmbeddingExtractor
import com.k2fsa.sherpa.onnx.SpeakerEmbeddingExtractorConfig
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
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.TimeUnit
import kotlin.math.sqrt

/** 声纹模型的状态（设置页显示用） */
sealed interface VoiceprintModelState {
    data object Unsupported : VoiceprintModelState
    data object Missing : VoiceprintModelState
    data class Downloading(val percent: Int) : VoiceprintModelState
    data class Ready(val sizeMb: Int) : VoiceprintModelState
    data class Failed(val message: String) : VoiceprintModelState
}

/** 一次比对的结果：[score] 是和你录入的声音的相似度（余弦，越大越像），不小于 [threshold] 算本人 */
data class VoiceprintCheck(val score: Float, val threshold: Float) {
    val passed: Boolean get() = score >= threshold
    val text: String get() = "相似度 ${"%.2f".format(score)}，门槛 ${"%.2f".format(threshold)}"
}

/**
 * 本机声纹（只让「你自己的声音」进入识别）：sherpa-onnx + 3D-Speaker CAM++（中文，约 27 MB，192 维向量）。
 *
 * - 模型不随应用安装，在设置里打开开关时下载一次；全程在手机上算，录音不会上传；
 * - 「录入」把几段你的录音各算一个向量，取平均后只存这个向量（不存录音）；
 * - 「比对」把一整段录音算成一个向量，和你的向量算余弦相似度；
 * - 它只能判断「这一整段像不像你」，分不开混在一起的两个人，也不能把旁人的声音从录音里去掉。
 * - 任何一步出错都当作没有声纹（放行），不会因为声纹出问题就记不了东西。
 */
class VoicePrint(
    context: Context,
    http: OkHttpClient,
    private val scope: CoroutineScope,
) {
    private val appContext = context.applicationContext
    private val client = http.newBuilder()
        .callTimeout(0, TimeUnit.MILLISECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()
    private val dir = File(appContext.filesDir, "asr/voiceprint")
    private val modelFile get() = File(dir, MODEL_NAME)
    private val profileFile get() = File(dir, PROFILE_NAME)

    private val supported: Boolean = Build.SUPPORTED_ABIS.any { it == "arm64-v8a" }

    private val _state = MutableStateFlow(initialState())
    val state: StateFlow<VoiceprintModelState> = _state.asStateFlow()

    private val _enrolled = MutableStateFlow(profileFile.length() > 0)

    /** 已经录入了你的声音 */
    val enrolled: StateFlow<Boolean> = _enrolled.asStateFlow()

    /** 模型和录入的声音都齐了，可以比对 */
    val usable: Boolean get() = _state.value is VoiceprintModelState.Ready && _enrolled.value

    private val lock = Mutex()
    private var extractor: SpeakerEmbeddingExtractor? = null
    private var idleJob: Job? = null
    private var downloadJob: Job? = null

    init {
        // 上一版的「AI 降噪」模型已经去掉，顺手清理
        scope.launch(Dispatchers.IO) { File(appContext.filesDir, "asr/denoise").deleteRecursively() }
    }

    private fun initialState(): VoiceprintModelState = when {
        !supported -> VoiceprintModelState.Unsupported
        modelFile.length() >= MODEL_MIN_BYTES -> VoiceprintModelState.Ready((modelFile.length() / (1024 * 1024)).toInt())
        else -> VoiceprintModelState.Missing
    }

    // ───────────────────────── 模型管理 ─────────────────────────

    fun download() {
        if (!supported || downloadJob?.isActive == true || _state.value is VoiceprintModelState.Ready) return
        _state.value = VoiceprintModelState.Downloading(0)
        downloadJob = scope.launch(Dispatchers.IO) {
            try {
                dir.mkdirs()
                val part = File(dir, "$MODEL_NAME.part")
                client.newCall(Request.Builder().url(MODEL_URL).build()).execute().use { resp ->
                    if (!resp.isSuccessful) throw IOException("服务器返回 ${resp.code}")
                    val body = resp.body ?: throw IOException("服务器没有返回内容")
                    val total = body.contentLength()
                    var read = 0L
                    var last = -1
                    part.outputStream().buffered().use { out ->
                        body.byteStream().use { input ->
                            val buf = ByteArray(1 shl 16)
                            while (true) {
                                val n = input.read(buf)
                                if (n < 0) break
                                out.write(buf, 0, n)
                                read += n
                                val percent = if (total > 0) (read * 100 / total).toInt().coerceIn(0, 99) else -1
                                if (percent != last) {
                                    last = percent
                                    _state.value = VoiceprintModelState.Downloading(percent)
                                }
                            }
                        }
                    }
                }
                if (part.length() < MODEL_MIN_BYTES) throw IOException("模型文件不完整")
                modelFile.delete()
                if (!part.renameTo(modelFile)) throw IOException("无法保存模型文件")
                _state.value = initialState()
            } catch (e: CancellationException) {
                File(dir, "$MODEL_NAME.part").delete()
                _state.value = initialState()
                throw e
            } catch (e: Exception) {
                File(dir, "$MODEL_NAME.part").delete()
                _state.value = VoiceprintModelState.Failed(
                    if (e is java.net.UnknownHostException || e is java.net.SocketTimeoutException || e is java.net.ConnectException) "网络连接失败，请检查网络后重试"
                    else e.message ?: "下载失败",
                )
            }
        }
    }

    fun cancelDownload() {
        downloadJob?.cancel()
        downloadJob = null
    }

    /** 删除模型（已录入的声音保留，再下载模型即可继续用） */
    fun deleteModel() {
        cancelDownload()
        scope.launch(Dispatchers.IO) {
            lock.withLock { releaseLocked() }
            modelFile.delete()
            _state.value = initialState()
        }
    }

    /** 删除录入的声音 */
    fun clearProfile() {
        scope.launch(Dispatchers.IO) {
            profileFile.delete()
            _enrolled.value = false
        }
    }

    // ───────────────────────── 录入与比对 ─────────────────────────

    /**
     * 用几段你的录音（16kHz / 单声道 / 16 位 PCM）录入声音。成功返回 null，失败返回原因。
     * 每段至少约 2 秒有效说话，太短的会被拒绝。
     */
    suspend fun enroll(samples: List<ByteArray>): String? = withContext(Dispatchers.Default) {
        if (_state.value !is VoiceprintModelState.Ready) return@withContext "声纹模型还没有下载"
        if (samples.isEmpty()) return@withContext "没有录到声音"
        lock.withLock {
            idleJob?.cancel()
            try {
                val engine = extractor ?: create().also { extractor = it }
                val vectors = samples.map { pcm ->
                    if (pcm.size / 32 < ENROLL_MIN_MS) return@withContext "有一段太短了，每段请说满约 5 秒"
                    embed(engine, pcm)?.let(::normalize) ?: return@withContext "有一段没有检测到足够的说话声，请在安静处重录"
                }
                val dim = vectors.first().size
                val mean = FloatArray(dim)
                for (v in vectors) for (i in 0 until dim) mean[i] += v[i] / vectors.size
                saveProfile(normalize(mean), vectors.size)
                _enrolled.value = true
                null
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                releaseLocked()
                "录入失败：${e.message ?: e.javaClass.simpleName}"
            } finally {
                scheduleIdleRelease()
            }
        }
    }

    /**
     * 比对一整段录音和你录入的声音。模型 / 声音没准备好、录音太短、或任何一步出错，都返回 null（表示不拦截）。
     * [level] 0 宽松 / 1 标准 / 2 严格。
     */
    suspend fun check(pcm: ByteArray, level: Int): VoiceprintCheck? = withContext(Dispatchers.Default) {
        if (!usable || pcm.size / 32 < CHECK_MIN_MS) return@withContext null
        lock.withLock {
            idleJob?.cancel()
            try {
                val mine = loadProfile() ?: return@withContext null
                val engine = extractor ?: create().also { extractor = it }
                val vec = embed(engine, pcm)?.let(::normalize) ?: return@withContext null
                if (vec.size != mine.size) return@withContext null
                var dot = 0f
                for (i in vec.indices) dot += vec[i] * mine[i]
                VoiceprintCheck(dot, THRESHOLDS[level.coerceIn(0, THRESHOLDS.lastIndex)])
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                releaseLocked()
                null
            } finally {
                scheduleIdleRelease()
            }
        }
    }

    private fun embed(engine: SpeakerEmbeddingExtractor, pcm: ByteArray): FloatArray? {
        val shorts = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val n = minOf(shorts.remaining(), MAX_SAMPLES)
        val samples = FloatArray(n) { shorts.get(it) / 32768f }
        val stream = engine.createStream()
        try {
            stream.acceptWaveform(samples, SAMPLE_RATE)
            stream.inputFinished()
            if (!engine.isReady(stream)) return null
            return engine.compute(stream)
        } finally {
            stream.release()
        }
    }

    private fun normalize(v: FloatArray): FloatArray {
        var sum = 0.0
        for (x in v) sum += x * x
        val norm = sqrt(sum).toFloat().takeIf { it > 1e-6f } ?: return v
        return FloatArray(v.size) { v[it] / norm }
    }

    private fun saveProfile(vec: FloatArray, count: Int) {
        dir.mkdirs()
        DataOutputStream(File(dir, "$PROFILE_NAME.tmp").outputStream().buffered()).use { out ->
            out.writeInt(vec.size)
            out.writeInt(count)
            for (x in vec) out.writeFloat(x)
        }
        val tmp = File(dir, "$PROFILE_NAME.tmp")
        profileFile.delete()
        if (!tmp.renameTo(profileFile)) throw IOException("无法保存声纹")
    }

    private fun loadProfile(): FloatArray? = try {
        DataInputStream(profileFile.inputStream().buffered()).use { input ->
            val dim = input.readInt()
            input.readInt()
            if (dim <= 0 || dim > 4096) null else FloatArray(dim) { input.readFloat() }
        }
    } catch (_: Exception) {
        null
    }

    private fun create(): SpeakerEmbeddingExtractor = SpeakerEmbeddingExtractor(
        config = SpeakerEmbeddingExtractorConfig(
            model = modelFile.absolutePath,
            numThreads = 2,
            debug = false,
            provider = "cpu",
        ),
    )

    private fun scheduleIdleRelease() {
        idleJob = scope.launch {
            delay(IDLE_RELEASE_MS)
            lock.withLock { releaseLocked() }
        }
    }

    private fun releaseLocked() {
        runCatching { extractor?.release() }
        extractor = null
    }

    companion object {
        private const val SAMPLE_RATE = 16_000
        private const val MODEL_NAME = "3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx"
        private const val PROFILE_NAME = "me.vec"
        private const val MODEL_URL =
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/$MODEL_NAME"

        /** 完整的模型约 28.3 MB，小于这个数说明没下完 */
        private const val MODEL_MIN_BYTES = 27_000_000L
        private const val IDLE_RELEASE_MS = 2 * 60_000L

        /** 录入每段至少这么久（毫秒）；比对时更短的录音不比对（声纹在 1 秒多的录音上不可靠） */
        private const val ENROLL_MIN_MS = 2_500
        private const val CHECK_MIN_MS = 1_500

        /** 只取前 30 秒算向量 */
        private const val MAX_SAMPLES = SAMPLE_RATE * 30

        /** 宽松 / 标准 / 严格 的余弦相似度门槛；没有官方推荐值，设置里会显示每次的分数，方便你按自己的声音和手机调 */
        val THRESHOLDS = floatArrayOf(0.35f, 0.45f, 0.55f)

        /** 录入时每段念的句子，约 5 秒 */
        val ENROLL_PROMPTS = listOf(
            "今天下午三点开会，记得带上电脑和笔记本。",
            "明天早上先去买牛奶，再把周报发给同事。",
            "我想把刚才的想法记下来，晚上回家再整理一遍。",
        )
    }
}
