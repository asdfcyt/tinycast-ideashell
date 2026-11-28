package com.carpe.ideashell.data.tts

import android.util.Base64
import com.carpe.ideashell.data.asr.TencentCloudApi
import com.carpe.ideashell.data.secure.CredentialStore
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient

class TtsException(message: String) : Exception(message)

/** 腾讯云音色：[id] 是接口里的 VoiceType */
data class TtsVoice(val id: Int, val label: String)

/**
 * 腾讯云语音合成（TextToVoice）：一次最多 150 个汉字，返回 16kHz 单声道 16 位的 PCM。
 * 和文字识别 / 语音识别共用同一份腾讯云密钥，不引入 SDK。
 * 文档：https://cloud.tencent.com/document/api/1073/37995
 */
class TencentTts(private val http: OkHttpClient, private val credentials: CredentialStore) {
    val configured: Boolean
        get() = !credentials.tencentSecretId.isNullOrBlank() && !credentials.tencentSecretKey.isNullOrBlank()

    /** 合成一小段文字（不超过 [MAX_CHARS] 个字）；返回 PCM 数据 */
    suspend fun synthesize(text: String, voice: Int, speed: Int): ByteArray {
        val secretId = credentials.tencentSecretId
        val secretKey = credentials.tencentSecretKey
        if (secretId.isNullOrBlank() || secretKey.isNullOrBlank()) throw TtsException("还没有配置腾讯云密钥")
        val payload = buildJsonObject {
            put("Text", text)
            put("SessionId", "shiyi-" + System.nanoTime())
            put("ModelType", 1)
            put("VoiceType", voice)
            put("Speed", speed.coerceIn(-2, 2))
            put("Volume", 5)
            put("Codec", "pcm")
            put("SampleRate", SAMPLE_RATE)
            put("PrimaryLanguage", 1)
        }.toString()
        val body = try {
            TencentCloudApi.call(
                http = http,
                host = "tts.tencentcloudapi.com",
                service = "tts",
                action = "TextToVoice",
                version = "2019-08-23",
                secretId = secretId,
                secretKey = secretKey,
                payload = payload,
            )
        } catch (e: java.io.IOException) {
            throw TtsException("网络不通：" + (e.message ?: ""))
        }
        val root = try {
            Json.parseToJsonElement(body).jsonObject["Response"] as? JsonObject
        } catch (_: Exception) {
            null
        } ?: throw TtsException("语音合成返回了看不懂的内容")
        (root["Error"] as? JsonObject)?.let { error ->
            val code = (error["Code"] as? JsonPrimitive)?.contentOrNull.orEmpty()
            val message = (error["Message"] as? JsonPrimitive)?.contentOrNull.orEmpty()
            throw TtsException(describe(code, message))
        }
        val audio = (root["Audio"] as? JsonPrimitive)?.contentOrNull
        if (audio.isNullOrEmpty()) throw TtsException("没有合成出声音")
        return Base64.decode(audio, Base64.DEFAULT)
    }

    private fun describe(code: String, message: String): String = when {
        code.startsWith("AuthFailure") -> "腾讯云密钥不对或已失效（$code）"
        code.contains("ServiceIsolate") || code.contains("ArrearsError") || code.contains("Arrears") -> "腾讯云欠费 / 服务被停用，请到腾讯云控制台查看（$code）"
        code.contains("NotOpen") || code.contains("ServiceNotActivated") || message.contains("开通") -> "还没有开通腾讯云「语音合成」服务，请到腾讯云控制台开通"
        code.contains("VoiceType") || message.contains("VoiceType") || message.contains("音色") -> "这个音色没有开通或不支持，换一个音色试试（$code）"
        code.contains("LimitExceeded") || code.contains("RequestLimit") -> "腾讯云语音合成请求太频繁或额度用完（$code）"
        else -> "语音合成出错：$message（$code）"
    }

    companion object {
        const val SAMPLE_RATE = 16000

        /** 一次请求的字数上限（接口限 150 个汉字，留一点余量） */
        const val MAX_CHARS = 120

        /** 常用音色（编号以腾讯云文档为准；标注「大模型」的要在控制台另外开通） */
        val VOICES: List<TtsVoice> = listOf(
            TtsVoice(101006, "智言 · 助手女声"),
            TtsVoice(101004, "智云 · 通用男声"),
            TtsVoice(1002, "智聆 · 通用女声（精品）"),
            TtsVoice(501004, "月华 · 聊天女声（大模型，最自然）"),
            TtsVoice(501005, "飞镜 · 聊天男声（大模型）"),
            TtsVoice(501002, "智菊 · 阅读女声（大模型）"),
        )

        fun voiceLabel(id: Int): String = VOICES.firstOrNull { it.id == id }?.label ?: "音色 $id"

        /** 把一大段话按句号 / 换行切成不超过 [MAX_CHARS] 字的小段，一段一段合成、边合成边播 */
        fun split(text: String): List<String> {
            val parts = mutableListOf<String>()
            val sb = StringBuilder()
            fun flush() {
                val t = sb.toString().trim()
                if (t.isNotEmpty()) parts += t
                sb.clear()
            }
            for (ch in text) {
                sb.append(ch)
                val end = ch in "。！？!?；;\n"
                if ((end && sb.length >= 12) || sb.length >= MAX_CHARS) flush()
            }
            flush()
            return parts
        }
    }
}
