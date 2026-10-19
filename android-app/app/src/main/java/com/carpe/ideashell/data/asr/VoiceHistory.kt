package com.carpe.ideashell.data.asr

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

/**
 * 一次语音输入的留底：[raw] 是识别出的原话（词库替换规则改过之后）、[summary] 是最后整理成了什么、[error] 是失败原因。
 * 原始录音（16kHz / 单声道 / 16 位 PCM）单独存成文件，只在本机，和原话一样不会上传到任何地方（重新识别 / 整理时才会像平时一样发送）。
 */
@Serializable
data class VoiceRecord(
    val id: String,
    val at: Long,
    val durationMs: Long,
    val raw: String? = null,
    val summary: String? = null,
    val error: String? = null,
)

/**
 * 语音历史：保留最近 [MAX_RECORDS] 条，识别错了可以查看原话、重新识别、重新整理。
 * 存在应用私有目录 `voice_history/`（索引 index.json + 每条一个 .pcm），可以在设置里关闭或清空。
 */
class VoiceHistory(context: Context) {
    private val dir = File(context.filesDir, "voice_history")
    private val indexFile = File(dir, "index.json")
    private val json = Json { ignoreUnknownKeys = true }
    private val lock = Any()
    private val _state = MutableStateFlow(load())
    val state: StateFlow<List<VoiceRecord>> = _state.asStateFlow()

    /** 新开一条：保存录音，返回 id；写文件失败返回 null（不影响正常的语音流程） */
    suspend fun begin(pcm: ByteArray, durationMs: Long): String? = withContext(Dispatchers.IO) {
        runCatching {
            dir.mkdirs()
            val at = System.currentTimeMillis()
            val id = at.toString()
            File(dir, "$id.pcm").writeBytes(pcm)
            synchronized(lock) {
                val next = (listOf(VoiceRecord(id, at, durationMs)) + _state.value)
                val keep = next.take(MAX_RECORDS)
                next.drop(MAX_RECORDS).forEach { File(dir, "${it.id}.pcm").delete() }
                publish(keep)
            }
            id
        }.getOrNull()
    }

    /** 补充这一条的结果：只改传了的字段；[error] 传空串表示清掉旧的失败原因 */
    fun update(id: String, raw: String? = null, summary: String? = null, error: String? = null) {
        synchronized(lock) {
            val list = _state.value
            if (list.none { it.id == id }) return
            publish(
                list.map {
                    if (it.id != id) it
                    else it.copy(
                        raw = raw ?: it.raw,
                        summary = summary ?: it.summary,
                        error = when {
                            error == null -> it.error
                            error.isEmpty() -> null
                            else -> error
                        },
                    )
                },
            )
        }
    }

    fun get(id: String): VoiceRecord? = _state.value.firstOrNull { it.id == id }

    /** 这条的原始录音；文件丢了返回 null */
    suspend fun audio(id: String): ByteArray? = withContext(Dispatchers.IO) {
        File(dir, "$id.pcm").takeIf { it.isFile }?.let { runCatching { it.readBytes() }.getOrNull() }
    }

    fun hasAudio(id: String): Boolean = File(dir, "$id.pcm").isFile

    fun delete(id: String) {
        synchronized(lock) {
            File(dir, "$id.pcm").delete()
            publish(_state.value.filterNot { it.id == id })
        }
    }

    fun clear() {
        synchronized(lock) {
            dir.listFiles()?.forEach { it.delete() }
            publish(emptyList())
        }
    }

    private fun publish(list: List<VoiceRecord>) {
        _state.value = list
        runCatching {
            dir.mkdirs()
            indexFile.writeText(json.encodeToString(list))
        }
    }

    private fun load(): List<VoiceRecord> = runCatching {
        if (!indexFile.isFile) emptyList() else json.decodeFromString<List<VoiceRecord>>(indexFile.readText())
    }.getOrDefault(emptyList())

    companion object {
        const val MAX_RECORDS = 10
    }
}
