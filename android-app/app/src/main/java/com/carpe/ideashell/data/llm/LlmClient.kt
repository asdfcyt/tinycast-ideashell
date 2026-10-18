package com.carpe.ideashell.data.llm

import com.carpe.ideashell.data.secure.CredentialStore
import com.carpe.ideashell.data.settings.SettingsStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
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
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class LlmException(message: String) : Exception(message)

/**
 * OpenAI 兼容的 Chat Completions 客户端（通义千问 / DeepSeek / OpenAI 等都能用，改设置里的地址和模型名即可）。
 * 只用来整理语音转写：一次请求、不流式；超时较短，慢了就让调用方退回原始转写。
 */
class LlmClient(
    http: OkHttpClient,
    private val credentials: CredentialStore,
    private val settings: SettingsStore,
) {
    private val client: OkHttpClient = http.newBuilder()
        .connectTimeout(4, TimeUnit.SECONDS)
        .readTimeout(7, TimeUnit.SECONDS)
        .callTimeout(8, TimeUnit.SECONDS)
        .build()

    val configured: Boolean
        get() = !credentials.llmKey.isNullOrBlank()

    /** 发一轮「系统提示 + 用户内容」，返回模型回复的文字；要求回复是 JSON 对象 */
    suspend fun chatJson(system: String, user: String): String {
        val key = credentials.llmKey
        if (key.isNullOrBlank()) throw LlmException("还没有填写大模型 API Key")
        val s = settings.current
        val url = s.llmBaseUrl.trimEnd('/') + "/chat/completions"

        // 先带 response_format=json_object；个别服务不认这个参数（返回 400）就去掉再试一次
        val first = send(url, key, s.llmModel, system, user, jsonMode = true)
        val reply = if (first.code == 400) send(url, key, s.llmModel, system, user, jsonMode = false) else first
        if (reply.code !in 200..299) throw LlmException(describeHttpError(reply.code, reply.body))

        val root = try {
            Json.parseToJsonElement(reply.body).jsonObject
        } catch (_: Exception) {
            throw LlmException("大模型返回了无法解析的内容")
        }
        val content = ((root["choices"] as? JsonArray)?.firstOrNull() as? JsonObject)
            ?.get("message")?.let { it as? JsonObject }
            ?.get("content")?.let { it as? JsonPrimitive }
            ?.contentOrNull
        return content?.trim().takeUnless { it.isNullOrEmpty() } ?: throw LlmException("大模型没有返回内容")
    }

    private suspend fun send(url: String, key: String, model: String, system: String, user: String, jsonMode: Boolean): LlmReply {
        val payload = buildJsonObject {
            put("model", model)
            put("temperature", 0.1)
            put("stream", false)
            if (jsonMode) put("response_format", buildJsonObject { put("type", "json_object") })
            put("messages", buildJsonArray {
                add(buildJsonObject { put("role", "system"); put("content", system) })
                add(buildJsonObject { put("role", "user"); put("content", user) })
            })
        }.toString()
        val request = try {
            Request.Builder()
                .url(url)
                .header("Authorization", "Bearer $key")
                .post(payload.toRequestBody("application/json; charset=utf-8".toMediaType()))
                .build()
        } catch (_: IllegalArgumentException) {
            throw LlmException("大模型接口地址不正确，请检查设置")
        }
        return try {
            withContext(Dispatchers.IO) { client.newCall(request).await() }
        } catch (_: IOException) {
            throw LlmException("网络不可用或大模型响应超时")
        }
    }

    private fun describeHttpError(code: Int, body: String): String = when (code) {
        401, 403 -> "大模型 API Key 不正确或没有权限"
        404 -> "大模型接口地址或模型名不对（$code）"
        429 -> "大模型请求太频繁或额度用完"
        else -> "大模型请求失败（$code）" + body.take(80).let { if (it.isBlank()) "" else "：$it" }
    }
}

private suspend fun Call.await(): LlmReply = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (cont.isActive) cont.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            response.use {
                val text = it.body?.string().orEmpty()
                if (cont.isActive) cont.resume(LlmReply(it.code, text))
            }
        }
    })
}

internal class LlmReply(val code: Int, val body: String)
