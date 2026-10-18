package com.carpe.ideashell.data.asr

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
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

/**
 * 腾讯云 API 3.0 的通用调用：TC3-HMAC-SHA256 签名 + OkHttp，不引入腾讯云 SDK。
 * 文档：https://cloud.tencent.com/document/api/1093/35646（签名见 https://cloud.tencent.com/document/api/1093/35641）
 */
internal object TencentCloudApi {
    /** 发一次请求，返回响应体原文；网络不通抛 [IOException] */
    suspend fun call(
        http: OkHttpClient,
        host: String,
        service: String,
        action: String,
        version: String,
        secretId: String,
        secretKey: String,
        payload: String,
        region: String? = null,
    ): String {
        val request = signedRequest(host, service, action, version, region, secretId, secretKey, payload)
        return withContext(Dispatchers.IO) { http.newCall(request).await() }
    }

    private fun signedRequest(
        host: String,
        service: String,
        action: String,
        version: String,
        region: String?,
        secretId: String,
        secretKey: String,
        payload: String,
    ): Request {
        val timestamp = System.currentTimeMillis() / 1000
        val date = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
            .format(Date(timestamp * 1000))

        val contentType = "application/json; charset=utf-8"
        val signedHeaders = "content-type;host;x-tc-action"
        val canonicalRequest = listOf(
            "POST",
            "/",
            "",
            "content-type:$contentType\nhost:$host\nx-tc-action:${action.lowercase()}\n",
            signedHeaders,
            sha256Hex(payload),
        ).joinToString("\n")

        val scope = "$date/$service/tc3_request"
        val stringToSign = listOf("TC3-HMAC-SHA256", timestamp.toString(), scope, sha256Hex(canonicalRequest)).joinToString("\n")

        val secretDate = hmac("TC3$secretKey".toByteArray(), date)
        val secretService = hmac(secretDate, service)
        val secretSigning = hmac(secretService, "tc3_request")
        val signature = hmac(secretSigning, stringToSign).joinToString("") { "%02x".format(it) }

        val authorization = "TC3-HMAC-SHA256 Credential=$secretId/$scope, SignedHeaders=$signedHeaders, Signature=$signature"

        return Request.Builder()
            .url("https://$host/")
            .header("Authorization", authorization)
            .header("X-TC-Action", action)
            .header("X-TC-Version", version)
            .header("X-TC-Timestamp", timestamp.toString())
            .apply { if (!region.isNullOrBlank()) header("X-TC-Region", region) }
            .post(payload.toRequestBody(contentType.toMediaType()))
            .build()
    }

    private fun sha256Hex(text: String): String =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }

    private fun hmac(key: ByteArray, message: String): ByteArray =
        Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }.doFinal(message.toByteArray())
}

private suspend fun Call.await(): String = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (cont.isActive) cont.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            response.use {
                val text = it.body?.string().orEmpty()
                if (cont.isActive) cont.resume(text)
            }
        }
    })
}
