package com.carpe.ideashell.data.mcp

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * 通用 MCP（Streamable HTTP）客户端，闪念贝壳与滴答清单共用。
 *
 * 协议要点（与桌面插件 api.ts / dida.ts 保持一致）：
 * - 每次都是 POST JSON-RPC，Accept 同时声明 `application/json, text/event-stream`；
 * - 响应可能是 JSON，也可能是 SSE（`data:` 行），两种都要能解析；
 * - 握手：initialize → 记录响应头 `Mcp-Session-Id` → 发送 `notifications/initialized`；
 * - 之后每个请求都带上 `Mcp-Session-Id`；会话过期（404）时自动重建一次。
 */
class McpClient(
    private val endpoint: String,
    private val http: OkHttpClient,
    private val tokenProvider: () -> String?,
    private val clientName: String = "ideashell-android",
    private val clientVersion: String = "0.1.0",
) {
    private val initLock = Mutex()
    private val idGen = AtomicInteger(0)

    @Volatile
    private var sessionId: String? = null

    @Volatile
    private var initialized = false

    /** 最近一次响应使用的传输格式："json" 或 "sse"（诊断用） */
    @Volatile
    var lastTransport: String = "-"
        private set

    val hasSession: Boolean get() = sessionId != null

    /** 丢弃当前会话，下次调用时重新握手（凭证变更后调用） */
    suspend fun reset() {
        initLock.withLock {
            sessionId = null
            initialized = false
        }
    }

    /** 确保已握手；重复调用无副作用 */
    suspend fun initialize() = ensureInitialized()

    suspend fun listTools(): List<McpTool> {
        val tools = mutableListOf<McpTool>()
        var cursor: String? = null
        repeat(MAX_TOOL_PAGES) {
            val params = if (cursor == null) null else buildJsonObject { put("cursor", cursor) }
            val result = request("tools/list", params)
            (result["tools"] as? JsonArray).orEmpty().filterIsInstance<JsonObject>().forEach { t ->
                val name = t.string("name") ?: return@forEach
                tools += McpTool(name, t.string("description"), t["inputSchema"] as? JsonObject)
            }
            cursor = result.string("nextCursor")
            if (cursor.isNullOrEmpty()) return tools
        }
        return tools
    }

    suspend fun callTool(name: String, arguments: JsonObject = JsonObject(emptyMap())): McpToolResult {
        val result = request(
            "tools/call",
            buildJsonObject {
                put("name", name)
                put("arguments", arguments)
            },
        )
        val text = (result["content"] as? JsonArray).orEmpty()
            .filterIsInstance<JsonObject>()
            .filter { it.string("type") == "text" }
            .mapNotNull { it.string("text") }
            .joinToString("\n")
        val isError = (result["isError"] as? JsonPrimitive)?.booleanOrNull == true
        return McpToolResult(text = text, isError = isError, raw = result)
    }

    // ── 内部实现 ──

    private suspend fun ensureInitialized() {
        if (initialized) return
        initLock.withLock {
            if (initialized) return
            requestOnce(
                "initialize",
                buildJsonObject {
                    put("protocolVersion", PROTOCOL_VERSION)
                    putJsonObject("capabilities") {}
                    putJsonObject("clientInfo") {
                        put("name", clientName)
                        put("version", clientVersion)
                    }
                },
            )
            // 通知没有返回内容；失败不影响后续调用，但鉴权错误已经在 initialize 时暴露了
            try {
                post(buildJsonObject {
                    put("jsonrpc", "2.0")
                    put("method", "notifications/initialized")
                })
            } catch (_: McpHttpException) {
            } catch (_: IOException) {
            }
            initialized = true
        }
    }

    /** 带自动重建会话的请求：会话过期时重置并重试一次 */
    private suspend fun request(method: String, params: JsonObject?): JsonObject {
        for (attempt in 0..1) {
            ensureInitialized()
            try {
                return requestOnce(method, params)
            } catch (e: McpSessionExpiredException) {
                if (attempt == 1) throw McpProtocolException("MCP 会话反复过期，请稍后再试")
                reset()
            }
        }
        throw McpProtocolException("MCP 请求失败")
    }

    private suspend fun requestOnce(method: String, params: JsonObject?): JsonObject {
        val id = idGen.incrementAndGet()
        val reply = post(
            buildJsonObject {
                put("jsonrpc", "2.0")
                put("id", id)
                put("method", method)
                if (params != null) put("params", params)
            },
        )
        // 优先按 id 匹配（SSE 里可能夹带通知），否则取最后一条带 result / error 的消息
        val message = reply.messages.firstOrNull { (it["id"] as? JsonPrimitive)?.intOrNull == id }
            ?: reply.messages.lastOrNull { it.containsKey("result") || it.containsKey("error") }
            ?: throw McpProtocolException("响应中没有 JSON-RPC 结果（${reply.transport}）：${reply.snippet}")

        (message["error"] as? JsonObject)?.let { err ->
            val code = (err["code"] as? JsonPrimitive)?.intOrNull ?: 0
            throw McpRpcException(code, err.string("message") ?: "未知错误")
        }
        return message["result"] as? JsonObject ?: JsonObject(emptyMap())
    }

    private class RawReply(val messages: List<JsonObject>, val transport: String, val snippet: String)

    private suspend fun post(body: JsonObject): RawReply {
        val token = tokenProvider()?.trim()?.removePrefix("Bearer ")?.trim().orEmpty()
        if (token.isEmpty()) throw McpAuthException(null, "还没有填写凭证")

        val sentSession = sessionId
        val request = Request.Builder()
            .url(endpoint)
            .header("Authorization", "Bearer $token")
            .header("Accept", "application/json, text/event-stream")
            .apply { if (sentSession != null) header("Mcp-Session-Id", sentSession) }
            .post(body.toString().toRequestBody(JSON_MEDIA_TYPE))
            .build()

        val response = http.newCall(request).await()
        return withContext(Dispatchers.IO) {
            response.use { resp ->
                val text = resp.body?.string().orEmpty()
                resp.header("Mcp-Session-Id")?.let { sessionId = it }

                if (resp.code == 401 || resp.code == 403) throw McpAuthException(resp.code)
                if (resp.code == 404 && sentSession != null) throw McpSessionExpiredException()
                if (!resp.isSuccessful) throw McpHttpException(resp.code, text.take(200))

                val isSse = resp.header("Content-Type").orEmpty().contains("text/event-stream", ignoreCase = true)
                val transport = if (isSse) "sse" else "json"
                lastTransport = transport

                val payloads = if (isSse) parseSse(text) else if (text.isBlank()) emptyList() else listOf(text)
                val messages = payloads.flatMap { payload ->
                    val element = try {
                        McpJson.parseToJsonElement(payload)
                    } catch (_: SerializationException) {
                        return@flatMap emptyList()
                    }
                    when (element) {
                        is JsonObject -> listOf(element)
                        is JsonArray -> element.filterIsInstance<JsonObject>()
                        else -> emptyList()
                    }
                }
                RawReply(messages, transport, text.take(160).replace('\n', ' '))
            }
        }
    }

    companion object {
        private const val PROTOCOL_VERSION = "2025-03-26"
        private const val MAX_TOOL_PAGES = 10
        private val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()

        /** 解析 SSE 文本：按空行分隔事件，同一事件内多行 data 用换行拼接 */
        internal fun parseSse(text: String): List<String> {
            val events = mutableListOf<String>()
            val data = StringBuilder()
            for (raw in text.lineSequence()) {
                val line = raw.trimEnd('\r')
                if (line.isEmpty()) {
                    if (data.isNotEmpty()) {
                        events += data.toString()
                        data.setLength(0)
                    }
                } else if (line.startsWith("data:")) {
                    if (data.isNotEmpty()) data.append('\n')
                    data.append(line.removePrefix("data:").removePrefix(" "))
                }
            }
            if (data.isNotEmpty()) events += data.toString()
            return events
        }
    }
}

private suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    enqueue(
        object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (!cont.isCancelled) cont.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                cont.resume(response)
            }
        },
    )
    cont.invokeOnCancellation { cancel() }
}
