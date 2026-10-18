package com.carpe.ideashell.system

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.ByteArrayOutputStream
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * 按住说话用的录音：16kHz / 单声道 / 16 位 PCM，攒在内存里（60 秒约 1.9MB）。
 * 调用方负责先检查 RECORD_AUDIO 权限。一次只录一段：[start] → [stop] 拿到 PCM，或 [cancel] 丢弃。
 */
class VoiceRecorder {
    private var record: AudioRecord? = null
    private var job: Job? = null
    private var buffer = ByteArrayOutputStream()

    val isRecording: Boolean get() = job?.isActive == true

    /**
     * 开始录音；打不开麦克风返回 false。
     * [onLevel] 在录音线程回调，0..1 的音量；到 [MAX_MS] 自动停止录音并回调 [onLimit]（数据还在，仍要调 [stop] 取走）。
     */
    @SuppressLint("MissingPermission")
    fun start(scope: CoroutineScope, onLevel: (Float) -> Unit, onLimit: () -> Unit): Boolean {
        if (isRecording) return false
        val minSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minSize <= 0) return false
        val bufferSize = maxOf(minSize, SAMPLE_RATE / 5 * 2)
        val rec = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize,
            )
        } catch (_: Exception) {
            return false
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            return false
        }
        try {
            rec.startRecording()
        } catch (_: Exception) {
            rec.release()
            return false
        }
        record = rec
        buffer = ByteArrayOutputStream()
        val out = buffer
        job = scope.launch(Dispatchers.IO) {
            val chunk = ShortArray(bufferSize / 2)
            val bytes = ByteArray(chunk.size * 2)
            var total = 0L
            while (isActive) {
                val n = rec.read(chunk, 0, chunk.size)
                if (n <= 0) break
                var sum = 0.0
                for (i in 0 until n) {
                    val v = chunk[i].toInt()
                    bytes[i * 2] = (v and 0xFF).toByte()
                    bytes[i * 2 + 1] = ((v shr 8) and 0xFF).toByte()
                    sum += abs(v).toDouble() * abs(v)
                }
                synchronized(out) { out.write(bytes, 0, n * 2) }
                total += n
                // 说话的 RMS 大约在 1000–6000，映射到 0..1
                onLevel((sqrt(sum / n) / 6000.0).coerceIn(0.0, 1.0).toFloat())
                if (total * 1000 / SAMPLE_RATE >= MAX_MS) {
                    onLimit()
                    break
                }
            }
        }
        return true
    }

    /** 停止录音，返回 PCM；没在录返回空数组 */
    suspend fun stop(): ByteArray {
        val rec = record ?: return ByteArray(0)
        val running = job
        record = null
        job = null
        runCatching { rec.stop() }
        running?.cancel()
        running?.join()
        rec.release()
        return synchronized(buffer) { buffer.toByteArray() }
    }

    /** 丢弃正在录的内容 */
    fun cancel() {
        val rec = record ?: return
        val running = job
        record = null
        job = null
        running?.cancel()
        runCatching { rec.stop() }
        // 录音线程可能还卡在 read() 上，等它退出后再释放，避免释放中读取
        CoroutineScope(Dispatchers.IO).launch {
            running?.join()
            rec.release()
        }
    }

    companion object {
        const val SAMPLE_RATE = 16_000

        /** 一句话识别的上限是 60 秒，留一点余量 */
        const val MAX_MS = 59_000L
    }
}
