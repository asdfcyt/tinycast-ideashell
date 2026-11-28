package com.carpe.ideashell.data.llm

import com.carpe.ideashell.data.secure.CredentialStore
import com.carpe.ideashell.data.settings.SettingsStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlin.coroutines.coroutineContext
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

    /** 提前建好到大模型服务的连接（后台线程调用） */
    fun prewarm() {
        if (configured) com.carpe.ideashell.data.net.Prewarm.warm(client, settings.current.llmBaseUrl.trimEnd('/') + "/")
    }

    /** 发一轮「系统提示 + 用户内容」，返回模型回复的文字；要求回复是 JSON 对象 */
    suspend fun chatJson(system: String, user: String, timeoutSec: Long? = null): String {
        val key = credentials.llmKey
        if (key.isNullOrBlank()) throw LlmException("还没有填写大模型 API Key")
        val s = settings.current
        val url = s.llmBaseUrl.trimEnd('/') + "/chat/completions"

        // 先带 response_format=json_object；个别服务不认这个参数（返回 400）就去掉再试一次
        val first = send(url, key, s.llmModel, system, user, jsonMode = true, timeoutSec)
        val reply = if (first.code == 400) send(url, key, s.llmModel, system, user, jsonMode = false, timeoutSec) else first
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

    /**
     * 带工具的一轮对话（OpenAI function calling）：[messages] 是完整的对话（system / user / assistant / tool），
     * 返回模型这一轮的 message（可能带 `tool_calls`，也可能直接是 `content`）。[tools] 为空就不带工具（用来逼它直接作答）。
     */
    suspend fun chatWithTools(messages: JsonArray, tools: JsonArray, timeoutSec: Long = 30): JsonObject {
        val key = credentials.llmKey
        if (key.isNullOrBlank()) throw LlmException("还没有填写大模型 API Key")
        val s = settings.current
        val url = s.llmBaseUrl.trimEnd('/') + "/chat/completions"
        val payload = buildJsonObject {
            put("model", s.llmModel)
            put("temperature", 0.2)
            put("stream", false)
            put("messages", messages)
            if (tools.isNotEmpty()) {
                put("tools", tools)
                put("tool_choice", "auto")
            }
        }.toString()
        val reply = post(url, key, payload, timeoutSec)
        if (reply.code == 400 && tools.isNotEmpty()) throw LlmException("当前大模型不支持工具调用（400）" + reply.body.take(80).let { if (it.isBlank()) "" else "：$it" })
        if (reply.code !in 200..299) throw LlmException(describeHttpError(reply.code, reply.body))
        val root = try {
            Json.parseToJsonElement(reply.body).jsonObject
        } catch (_: Exception) {
            throw LlmException("大模型返回了无法解析的内容")
        }
        return ((root["choices"] as? JsonArray)?.firstOrNull() as? JsonObject)?.get("message") as? JsonObject
            ?: throw LlmException("大模型没有返回内容")
    }

    /**
     * 流式版 [chatWithTools]：一边收一边把「到目前为止的回答文字」交给 [onContent]（在后台线程回调），
     * 收完拼成和 [chatWithTools] 一样的 message（含 tool_calls）返回，调用方的循环不用改。
     * 第一个字大约在 1 秒内就出来，不用等整段生成完。
     */
    suspend fun chatStream(messages: JsonArray, tools: JsonArray, timeoutSec: Long = 40, onContent: (String) -> Unit): JsonObject {
        val key = credentials.llmKey
        if (key.isNullOrBlank()) throw LlmException("还没有填写大模型 API Key")
        val s = settings.current
        val url = s.llmBaseUrl.trimEnd('/') + "/chat/completions"
        val payload = buildJsonObject {
            put("model", s.llmModel)
            put("temperature", 0.2)
            put("stream", true)
            put("messages", messages)
            if (tools.isNotEmpty()) {
                put("tools", tools)
                put("tool_choice", "auto")
            }
        }.toString()
        val request = try {
            Request.Builder()
                .url(url)
                .header("Authorization", "Bearer $key")
                .header("Accept", "text/event-stream")
                .post(payload.toRequestBody("application/json; charset=utf-8".toMediaType()))
                .build()
        } catch (_: IllegalArgumentException) {
            throw LlmException("大模型接口地址不正确，请检查设置")
        }
        val c = client.newBuilder().readTimeout(20, TimeUnit.SECONDS).callTimeout(timeoutSec, TimeUnit.SECONDS).build()
        return withContext(Dispatchers.IO) {
            val call = c.newCall(request)
            val handle = coroutineContext[kotlinx.coroutines.Job]?.invokeOnCompletion { if (it != null) call.cancel() }
            try {
                call.execute().use { resp ->
                    if (resp.code !in 200..299) {
                        val body = resp.body?.string().orEmpty()
                        if (resp.code == 400 && tools.isNotEmpty()) throw LlmException("当前大模型不支持工具调用（400）" + body.take(80).let { if (it.isBlank()) "" else "：$it" })
                        throw LlmException(describeHttpError(resp.code, body))
                    }
                    val source = resp.body?.source() ?: throw LlmException("大模型没有返回内容")
                    val content = StringBuilder()
                    val calls = java.util.TreeMap<Int, StreamCall>()
                    while (true) {
                        val line = source.readUtf8Line() ?: break
                        if (!line.startsWith("data:")) continue
                        val data = line.removePrefix("data:").trim()
                        if (data == "[DONE]") break
                        val delta = runCatching {
                            ((Json.parseToJsonElement(data).jsonObject["choices"] as? JsonArray)?.firstOrNull() as? JsonObject)?.get("delta") as? JsonObject
                        }.getOrNull() ?: continue
                        (delta["content"] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotEmpty() }?.let {
                            content.append(it)
                            onContent(content.toString())
                        }
                        (delta["tool_calls"] as? JsonArray)?.forEach { el ->
                            val tc = el as? JsonObject ?: return@forEach
                            val index = (tc["index"] as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: 0
                            val acc = calls.getOrPut(index) { StreamCall() }
                            (tc["id"] as? JsonPrimitive)?.contentOrNull?.let { acc.id = it }
                            (tc["function"] as? JsonObject)?.let { fn ->
                                (fn["name"] as? JsonPrimitive)?.contentOrNull?.let { acc.name += it }
                                (fn["arguments"] as? JsonPrimitive)?.contentOrNull?.let { acc.args.append(it) }
                            }
                        }
                    }
                    buildJsonObject {
                        put("role", "assistant")
                        put("content", content.toString())
                        if (calls.isNotEmpty()) {
                            put("tool_calls", buildJsonArray {
                                calls.values.forEachIndexed { i, tc ->
                                    add(buildJsonObject {
                                        put("id", tc.id.ifBlank { "call_$i" })
                                        put("type", "function")
                                        put("function", buildJsonObject {
                                            put("name", tc.name)
                                            put("arguments", tc.args.toString().ifBlank { "{}" })
                                        })
                                    })
                                }
                            })
                        }
                    }
                }
            } catch (e: IOException) {
                coroutineContext.ensureActive()
                throw LlmException("网络不可用或大模型响应超时")
            } finally {
                handle?.dispose()
            }
        }
    }

    private class StreamCall {
        var id: String = ""
        var name: String = ""
        val args = StringBuilder()
    }

    private suspend fun send(url: String, key: String, model: String, system: String, user: String, jsonMode: Boolean, timeoutSec: Long?): LlmReply {
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
        return post(url, key, payload, timeoutSec)
    }

    private suspend fun post(url: String, key: String, payload: String, timeoutSec: Long?): LlmReply {
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
            // 语音整理要快（默认 8 秒）；排期 / 梳理今天这类较长的请求由调用方放宽超时
            val c = if (timeoutSec == null) client else client.newBuilder()
                .readTimeout(timeoutSec, TimeUnit.SECONDS)
                .callTimeout(timeoutSec, TimeUnit.SECONDS)
                .build()
            withContext(Dispatchers.IO) { c.newCall(request).await() }
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

/** 从大模型回复里取出 JSON 对象（兼容 ```json 代码块 / 前后多余文字）；取不到为 null */
fun extractJsonObject(text: String): JsonObject? {
    val t = text.trim()
    val start = t.indexOf('{')
    val end = t.lastIndexOf('}')
    if (start < 0 || end <= start) return null
    return try {
        Json.parseToJsonElement(t.substring(start, end + 1)) as? JsonObject
    } catch (_: Exception) {
        null
    }
}
