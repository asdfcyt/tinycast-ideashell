package com.carpe.ideashell.data.asr

import android.util.Base64
import com.carpe.ideashell.data.secure.CredentialStore
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

class AsrException(message: String, val code: String = "") : Exception(message)

/** [AsrException.code]：网络不通（区别于云端返回的错误码） */
const val CODE_NETWORK = "Network"

/**
 * 腾讯云「一句话识别」（SentenceRecognition，60 秒以内的短语音，松手后一次返回）。
 * 和文字识别共用同一对 SecretId / SecretKey，但需要在腾讯云控制台单独开通「语音识别」。
 * 文档：https://cloud.tencent.com/document/api/1093/35646
 */
class TencentAsr(
    private val http: OkHttpClient,
    private val credentials: CredentialStore,
) {
    /** 密钥是否已填（语音输入能不能用的前提） */
    val configured: Boolean
        get() = !credentials.tencentSecretId.isNullOrBlank() && !credentials.tencentSecretKey.isNullOrBlank()

    /**
     * 识别 16kHz / 单声道 / 16 位的 PCM 录音，返回识别出的文字。
     * [hotwords] 是热词（项目名、词库里的专有名词），识别时优先；热词参数被服务拒绝时自动去掉热词重试一次。
     */
    suspend fun recognize(pcm: ByteArray, hotwords: List<String> = emptyList()): String {
        if (hotwords.isEmpty()) return request(pcm, emptyList())
        return try {
            request(pcm, hotwords)
        } catch (e: AsrException) {
            if (e.code.startsWith("InvalidParameter")) request(pcm, emptyList()) else throw e
        }
    }

    private suspend fun request(pcm: ByteArray, hotwords: List<String>): String {
        val secretId = credentials.tencentSecretId
        val secretKey = credentials.tencentSecretKey
        if (secretId.isNullOrBlank() || secretKey.isNullOrBlank()) throw AsrException("还没有配置腾讯云密钥")

        val wav = pcmToWav(pcm)
        val payload = buildJsonObject {
            put("ProjectId", 0)
            put("SubServiceType", 2)
            put("EngSerViceType", "16k_zh")
            put("SourceType", 1)
            put("VoiceFormat", "wav")
            put("UsrAudioKey", UUID.randomUUID().toString())
            put("Data", Base64.encodeToString(wav, Base64.NO_WRAP))
            put("DataLen", wav.size)
            // 数字转阿拉伯数字（「三点半」→「3点半」），方便后面的日期时间识别
            put("ConvertNumMode", 1)
            if (hotwords.isNotEmpty()) put("HotwordList", hotwords.joinToString(",") { "$it|8" })
        }.toString()

        val body = try {
            TencentCloudApi.call(
                http = http,
                host = HOST,
                service = SERVICE,
                action = ACTION,
                version = VERSION,
                secretId = secretId,
                secretKey = secretKey,
                payload = payload,
            )
        } catch (_: IOException) {
            throw AsrException("网络不可用，无法识别语音", CODE_NETWORK)
        }

        val root = try {
            Json.parseToJsonElement(body).jsonObject["Response"]?.jsonObject
        } catch (_: Exception) {
            null
        } ?: throw AsrException("识别服务返回了无法解析的内容")

        (root["Error"] as? JsonObject)?.let { error ->
            val code = (error["Code"] as? JsonPrimitive)?.contentOrNull.orEmpty()
            val message = (error["Message"] as? JsonPrimitive)?.contentOrNull.orEmpty()
            throw AsrException(describeError(code, message), code)
        }

        return (root["Result"] as? JsonPrimitive)?.contentOrNull?.trim().orEmpty()
    }

    private fun describeError(code: String, message: String): String = when {
        code.startsWith("AuthFailure.SecretIdNotFound") -> "SecretId 不存在，请检查设置里的密钥"
        code.startsWith("AuthFailure.SignatureFailure") -> "SecretKey 不正确，请检查设置里的密钥"
        code.startsWith("AuthFailure.SignatureExpire") -> "手机时间与标准时间相差太大，请校准时间后重试"
        code.startsWith("AuthFailure") -> "密钥验证失败（$code）"
        code == "FailedOperation.UserNotRegistered" || code.startsWith("UnauthorizedOperation") ->
            "还没有开通腾讯云「语音识别」，请到腾讯云控制台开通（有每月免费额度）"
        code == "FailedOperation.ServiceIsolate" || code == "ResourceUnavailable.InArrears" -> "腾讯云账号已欠费"
        code.startsWith("FailedOperation.NoFreeAmount") || code.startsWith("ResourceInsufficient") ||
            code == "ResourceUnavailable.ResourcePackageRunOut" -> "语音识别免费额度已用完，请到腾讯云控制台查看"
        code.startsWith("RequestLimitExceeded") || code.startsWith("LimitExceeded") -> "识别请求太频繁，请稍后再试"
        else -> listOf(code, message).filter { it.isNotBlank() }.joinToString("：").ifEmpty { "识别失败" }
    }

    private companion object {
        const val HOST = "asr.tencentcloudapi.com"
        const val SERVICE = "asr"
        const val ACTION = "SentenceRecognition"
        const val VERSION = "2019-06-14"
        const val SAMPLE_RATE = 16_000

        /** 给裸 PCM（16kHz / 单声道 / 16 位）加上 44 字节的 WAV 头 */
        fun pcmToWav(pcm: ByteArray): ByteArray {
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray())
            header.putInt(36 + pcm.size)
            header.put("WAVE".toByteArray())
            header.put("fmt ".toByteArray())
            header.putInt(16)
            header.putShort(1) // PCM
            header.putShort(1) // 单声道
            header.putInt(SAMPLE_RATE)
            header.putInt(SAMPLE_RATE * 2) // 每秒字节数
            header.putShort(2) // 每个采样点字节数
            header.putShort(16) // 位深
            header.put("data".toByteArray())
            header.putInt(pcm.size)
            return header.array() + pcm
        }
    }
}
