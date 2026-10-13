package com.carpe.ideashell.data.ocr

import android.util.Base64
import com.carpe.ideashell.data.secure.CredentialStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.floatOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** 一行识别结果：文字 + 四个顶点（原图像素坐标，顺序为左上、右上、右下、左下） */
data class OcrLine(
    val text: String,
    val xs: FloatArray,
    val ys: FloatArray,
) {
    val left: Float get() = xs.min()
    val right: Float get() = xs.max()
    val top: Float get() = ys.min()
    val bottom: Float get() = ys.max()
}

class OcrException(message: String) : Exception(message)

/**
 * 腾讯云文字识别（通用印刷体识别 GeneralBasicOCR）。
 * 不引入腾讯云 SDK：直接用 OkHttp 发请求，自己做 TC3-HMAC-SHA256 签名（文档：https://cloud.tencent.com/document/product/866/34681）。
 * 密钥（SecretId / SecretKey）存在本机加密的 [CredentialStore] 里。
 */
class TencentOcr(
    private val http: OkHttpClient,
    private val credentials: CredentialStore,
) {
    /** 识别一张 JPEG / PNG 图片，返回按阅读顺序排列的文字行 */
    suspend fun recognize(image: ByteArray): List<OcrLine> {
        val secretId = credentials.tencentSecretId
        val secretKey = credentials.tencentSecretKey
        if (secretId.isNullOrBlank() || secretKey.isNullOrBlank()) throw OcrException("还没有配置腾讯云文字识别密钥")

        val payload = buildJsonObject {
            put("ImageBase64", Base64.encodeToString(image, Base64.NO_WRAP))
            // zh = 中英文混合；auto 对短文字有时会误判语种
            put("LanguageType", "zh")
        }.toString()

        val request = signedRequest(secretId, secretKey, payload)
        val body = withContext(Dispatchers.IO) { http.newCall(request).await() }

        val root = try {
            Json.parseToJsonElement(body).jsonObject["Response"]?.jsonObject
        } catch (_: Exception) {
            null
        } ?: throw OcrException("识别服务返回了无法解析的内容")

        (root["Error"] as? JsonObject)?.let { error ->
            val code = (error["Code"] as? JsonPrimitive)?.contentOrNull.orEmpty()
            val message = (error["Message"] as? JsonPrimitive)?.contentOrNull.orEmpty()
            throw OcrException(describeError(code, message))
        }

        val detections = root["TextDetections"] as? JsonArray ?: return emptyList()
        return detections.mapNotNull { item ->
            val obj = item as? JsonObject ?: return@mapNotNull null
            val text = (obj["DetectedText"] as? JsonPrimitive)?.contentOrNull?.trim().orEmpty()
            if (text.isEmpty()) return@mapNotNull null
            val polygon = (obj["Polygon"] as? JsonArray).orEmpty().mapNotNull { p ->
                val point = p as? JsonObject ?: return@mapNotNull null
                val x = (point["X"] as? JsonPrimitive)?.floatOrNull ?: return@mapNotNull null
                val y = (point["Y"] as? JsonPrimitive)?.floatOrNull ?: return@mapNotNull null
                x to y
            }
            if (polygon.size < 3) return@mapNotNull null
            OcrLine(text, FloatArray(polygon.size) { polygon[it].first }, FloatArray(polygon.size) { polygon[it].second })
        }
    }

    private fun signedRequest(secretId: String, secretKey: String, payload: String): Request {
        val timestamp = System.currentTimeMillis() / 1000
        val date = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
            .format(Date(timestamp * 1000))

        val contentType = "application/json; charset=utf-8"
        val signedHeaders = "content-type;host;x-tc-action"
        val canonicalRequest = listOf(
            "POST",
            "/",
            "",
            "content-type:$contentType\nhost:$HOST\nx-tc-action:${ACTION.lowercase()}\n",
            signedHeaders,
            sha256Hex(payload),
        ).joinToString("\n")

        val scope = "$date/$SERVICE/tc3_request"
        val stringToSign = listOf("TC3-HMAC-SHA256", timestamp.toString(), scope, sha256Hex(canonicalRequest)).joinToString("\n")

        val secretDate = hmac("TC3$secretKey".toByteArray(), date)
        val secretService = hmac(secretDate, SERVICE)
        val secretSigning = hmac(secretService, "tc3_request")
        val signature = hmac(secretSigning, stringToSign).joinToString("") { "%02x".format(it) }

        val authorization = "TC3-HMAC-SHA256 Credential=$secretId/$scope, SignedHeaders=$signedHeaders, Signature=$signature"

        return Request.Builder()
            .url("https://$HOST/")
            .header("Authorization", authorization)
            .header("X-TC-Action", ACTION)
            .header("X-TC-Version", VERSION)
            .header("X-TC-Region", REGION)
            .header("X-TC-Timestamp", timestamp.toString())
            .post(payload.toRequestBody(contentType.toMediaType()))
            .build()
    }

    private fun describeError(code: String, message: String): String = when {
        code.startsWith("AuthFailure.SecretIdNotFound") -> "SecretId 不存在，请检查设置里的密钥"
        code.startsWith("AuthFailure.SignatureFailure") -> "SecretKey 不正确，请检查设置里的密钥"
        code.startsWith("AuthFailure.SignatureExpire") -> "手机时间与标准时间相差太大，请校准时间后重试"
        code.startsWith("AuthFailure") -> "密钥验证失败（$code）"
        code == "FailedOperation.ImageNoText" -> "图片里没有识别到文字"
        code == "FailedOperation.ImageDecodeFailed" -> "图片无法解码，请换一张"
        code == "FailedOperation.OcrFailed" -> "识别失败，请重试"
        code == "ResourceUnavailable.InArrears" -> "腾讯云账号已欠费"
        code == "ResourceUnavailable.NotExist" || code == "ResourceUnavailable.ResourcePackageRunOut" || code.startsWith("ResourceInsufficient") ->
            "文字识别服务未开通或额度已用完，请到腾讯云控制台查看"
        code == "LimitExceeded" || code.startsWith("RequestLimitExceeded") -> "识别请求太频繁，请稍后再试"
        code.startsWith("UnauthorizedOperation") -> "账号未开通文字识别服务，请到腾讯云控制台开通"
        else -> listOf(code, message).filter { it.isNotBlank() }.joinToString("：").ifEmpty { "识别失败" }
    }

    private companion object {
        const val HOST = "ocr.tencentcloudapi.com"
        const val SERVICE = "ocr"
        const val ACTION = "GeneralBasicOCR"
        const val VERSION = "2018-11-19"
        const val REGION = "ap-guangzhou"

        fun sha256Hex(text: String): String =
            MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }

        fun hmac(key: ByteArray, message: String): ByteArray =
            Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }.doFinal(message.toByteArray())
    }
}

private suspend fun Call.await(): String = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (cont.isActive) cont.resumeWithException(OcrException("网络不可用，无法识别文字"))
        }

        override fun onResponse(call: Call, response: Response) {
            response.use {
                val text = it.body?.string().orEmpty()
                if (cont.isActive) cont.resume(text)
            }
        }
    })
}
