package com.carpe.ideashell.data.asr

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineSenseVoiceModelConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import java.io.BufferedInputStream
import java.io.File
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.TimeUnit

/** 本地识别模型的状态（设置页显示用） */
sealed interface LocalAsrState {
    /** 这台设备跑不了（原生库只带了 arm64） */
    data object Unsupported : LocalAsrState

    /** 还没下载模型 */
    data object Missing : LocalAsrState

    /** 下载并解压中；[percent] 为 -1 表示不知道总大小 */
    data class Downloading(val percent: Int, val unpacking: Boolean) : LocalAsrState

    data class Ready(val sizeMb: Int) : LocalAsrState

    data class Failed(val message: String) : LocalAsrState
}

/**
 * 本地语音识别（断网兜底）：SenseVoice-Small（中 / 英 / 日 / 韩 / 粤，int8 量化），通过 sherpa-onnx 在手机上离线识别。
 *
 * - 模型不随应用安装：用户在设置里打开「本地识别」时才下载（约 160 MB 的压缩包，解压后约 240 MB），存在应用私有目录；
 * - 一句话识别同一套入口：16kHz / 单声道 / 16 位 PCM 进、文字出；SenseVoice 自带标点和逆文本规整（「三点半」→「3:30」之类）；
 * - 模型加载要 1～2 秒、占约 300 MB 内存，所以用完两分钟没再用就释放。
 */
class LocalSenseVoice(
    context: Context,
    http: OkHttpClient,
    private val scope: CoroutineScope,
) {
    private val appContext = context.applicationContext
    private val dir = File(appContext.filesDir, "asr/sensevoice")
    private val modelFile get() = File(dir, MODEL_NAME)
    private val tokensFile get() = File(dir, TOKENS_NAME)

    // 下载 163 MB 的包不能被默认的整体超时（60 秒）掐断，只限制「多久没收到数据」
    private val client = http.newBuilder()
        .callTimeout(0, TimeUnit.MILLISECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    private val _state = MutableStateFlow(initialState())
    val state: StateFlow<LocalAsrState> = _state.asStateFlow()

    /** 模型已就绪，可以直接识别 */
    val ready: Boolean get() = _state.value is LocalAsrState.Ready

    /** 这台设备能不能用本地识别 */
    val supported: Boolean get() = supportsAbi()

    /** 现在有没有网络（没有连接就别等云端超时了，直接走本地） */
    val offline: Boolean
        get() {
            val cm = appContext.getSystemService(ConnectivityManager::class.java) ?: return false
            val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return true) ?: return true
            return !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        }

    private var downloadJob: Job? = null
    private val lock = Mutex()
    private var recognizer: OfflineRecognizer? = null
    private var idleJob: Job? = null

    // ───────────────────────── 模型管理 ─────────────────────────

    private fun initialState(): LocalAsrState = when {
        !supportsAbi() -> LocalAsrState.Unsupported
        modelInstalled() -> LocalAsrState.Ready(sizeMb())
        else -> LocalAsrState.Missing
    }

    private fun modelInstalled() = modelFile.length() >= MODEL_MIN_BYTES && tokensFile.length() > 0

    private fun sizeMb(): Int = ((modelFile.length() + tokensFile.length()) / (1024 * 1024)).toInt()

    /** 开始下载并解压模型；已经在下载或已就绪时什么都不做 */
    fun download() {
        if (!supported || downloadJob?.isActive == true || modelInstalled()) return
        _state.value = LocalAsrState.Downloading(0, unpacking = false)
        downloadJob = scope.launch(Dispatchers.IO) {
            try {
                fetchAndUnpack()
                _state.value = LocalAsrState.Ready(sizeMb())
            } catch (e: CancellationException) {
                cleanPartial()
                _state.value = initialState()
                throw e
            } catch (e: Exception) {
                cleanPartial()
                _state.value = LocalAsrState.Failed(describe(e))
            }
        }
    }

    /** 取消下载 */
    fun cancelDownload() {
        downloadJob?.cancel()
        downloadJob = null
    }

    /** 删除模型，释放空间 */
    fun delete() {
        cancelDownload()
        scope.launch(Dispatchers.IO) {
            lock.withLock { releaseLocked() }
            dir.deleteRecursively()
            _state.value = initialState()
        }
    }

    private fun describe(e: Exception): String = when (e) {
        is java.net.UnknownHostException, is java.net.SocketTimeoutException, is java.net.ConnectException ->
            "网络连接失败，请检查网络后重试"
        is IOException -> e.message?.takeIf { it.isNotBlank() }?.let { "下载中断：$it" } ?: "下载中断，请重试"
        else -> e.message ?: e.javaClass.simpleName
    }

    private fun cleanPartial() {
        dir.listFiles()?.filter { it.name.endsWith(".part") }?.forEach { it.delete() }
    }

    /** 流式：下载的同时 bz2 解压 + 拆 tar，只留 model.int8.onnx 和 tokens.txt，不需要额外的磁盘空间放压缩包 */
    private suspend fun fetchAndUnpack() = withContext(Dispatchers.IO) {
        dir.mkdirs()
        cleanPartial()
        var lastPercent = -2
        val request = Request.Builder().url(MODEL_URL).build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("服务器返回 ${response.code}")
            val body = response.body ?: throw IOException("服务器没有返回内容")
            val total = body.contentLength()
            val counting = CountingInputStream(body.byteStream()) { read ->
                val percent = if (total > 0) (read * 100 / total).toInt().coerceIn(0, 99) else -1
                if (percent != lastPercent) {
                    lastPercent = percent
                    _state.value = LocalAsrState.Downloading(percent, unpacking = false)
                }
            }
            val got = HashSet<String>()
            TarArchiveInputStream(BZip2CompressorInputStream(BufferedInputStream(counting, 1 shl 16))).use { tar ->
                val buffer = ByteArray(1 shl 16)
                while (true) {
                    ensureActive()
                    val entry = tar.nextEntry ?: break
                    if (entry.isDirectory) continue
                    val name = entry.name.substringAfterLast('/')
                    if (name != MODEL_NAME && name != TOKENS_NAME) continue
                    val part = File(dir, "$name.part")
                    part.outputStream().buffered().use { out ->
                        while (true) {
                            ensureActive()
                            val n = tar.read(buffer)
                            if (n < 0) break
                            out.write(buffer, 0, n)
                        }
                    }
                    got += name
                }
            }
            if (got.size < 2) throw IOException("模型包内容不完整")
            _state.value = LocalAsrState.Downloading(100, unpacking = true)
        }
        // 两个文件都完整了才换名，中途失败不会留下半截模型
        for (name in listOf(TOKENS_NAME, MODEL_NAME)) {
            val part = File(dir, "$name.part")
            val target = File(dir, name)
            target.delete()
            if (!part.renameTo(target)) throw IOException("无法保存模型文件")
        }
        if (!modelInstalled()) throw IOException("模型文件不完整")
    }

    // ───────────────────────── 识别 ─────────────────────────

    /** 识别 16kHz / 单声道 / 16 位的 PCM 录音 */
    suspend fun recognize(pcm: ByteArray): String = withContext(Dispatchers.Default) {
        if (!supported) throw AsrException("这台设备不支持本地识别")
        if (!modelInstalled()) throw AsrException("本地识别模型还没有下载")
        lock.withLock {
            idleJob?.cancel()
            try {
                val engine = recognizer ?: createRecognizer().also { recognizer = it }
                val samples = toFloatSamples(pcm)
                val stream = engine.createStream()
                try {
                    stream.acceptWaveform(samples, SAMPLE_RATE)
                    engine.decode(stream)
                    engine.getResult(stream).text.trim()
                } finally {
                    stream.release()
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: UnsatisfiedLinkError) {
                throw AsrException("本地识别库无法加载，这台设备可能不支持")
            } catch (e: AsrException) {
                throw e
            } catch (e: Throwable) {
                // 模型文件损坏之类：丢掉引擎，下次重新加载
                releaseLocked()
                throw AsrException("本地识别失败：${e.message ?: e.javaClass.simpleName}")
            } finally {
                scheduleIdleRelease()
            }
        }
    }

    private fun createRecognizer(): OfflineRecognizer {
        val config = OfflineRecognizerConfig(
            modelConfig = OfflineModelConfig(
                senseVoice = OfflineSenseVoiceModelConfig(
                    model = modelFile.absolutePath,
                    // 主要说中文；中英混着说时，英文单词照样能识别出来
                    language = "zh",
                    useInverseTextNormalization = true,
                ),
                tokens = tokensFile.absolutePath,
                numThreads = 2,
                provider = "cpu",
            ),
        )
        return OfflineRecognizer(config = config)
    }

    private fun toFloatSamples(pcm: ByteArray): FloatArray {
        val shorts = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val out = FloatArray(shorts.remaining())
        for (i in out.indices) out[i] = shorts.get(i) / 32768f
        return out
    }

    private fun scheduleIdleRelease() {
        idleJob = scope.launch {
            delay(IDLE_RELEASE_MS)
            lock.withLock { releaseLocked() }
        }
    }

    private fun releaseLocked() {
        runCatching { recognizer?.release() }
        recognizer = null
    }

    private class CountingInputStream(input: InputStream, private val onRead: (Long) -> Unit) : FilterInputStream(input) {
        private var total = 0L

        override fun read(): Int = super.read().also { if (it >= 0) advance(1) }

        override fun read(b: ByteArray, off: Int, len: Int): Int = super.read(b, off, len).also { if (it > 0) advance(it.toLong()) }

        private fun advance(n: Long) {
            total += n
            onRead(total)
        }
    }

    private companion object {
        const val SAMPLE_RATE = 16_000
        const val MODEL_NAME = "model.int8.onnx"
        const val TOKENS_NAME = "tokens.txt"

        /** 完整的 model.int8.onnx 约 239 MB，小于这个数说明没下完 */
        const val MODEL_MIN_BYTES = 200L * 1024 * 1024
        const val IDLE_RELEASE_MS = 2 * 60_000L

        const val MODEL_URL =
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/" +
                "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2"

        fun supportsAbi(): Boolean = Build.SUPPORTED_ABIS.any { it == "arm64-v8a" }
    }
}
