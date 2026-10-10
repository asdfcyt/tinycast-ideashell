package com.carpe.ideashell.data.mcp

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

object McpEndpoints {
    /** 闪念贝壳官方 MCP，Bearer = API Key */
    const val IDEASHELL = "https://api.ideashell.cn/ideashell/mcp"

    /** 滴答清单官方 MCP，Bearer = API 口令 */
    const val DIDA = "https://mcp.dida365.com"
}

internal val McpJson = Json {
    ignoreUnknownKeys = true
    isLenient = true
}

internal fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull

data class McpTool(
    val name: String,
    val description: String?,
    val inputSchema: JsonObject?,
)

data class McpToolResult(
    /** 所有 text 类型内容拼接后的文本 */
    val text: String,
    val isError: Boolean,
    val raw: JsonObject,
)

/** MCP 调用失败的基类，message 可直接展示给用户 */
sealed class McpException(message: String, cause: Throwable? = null) : Exception(message, cause)

/** 401 / 403：凭证无效或已失效 */
class McpAuthException(val httpCode: Int?, message: String = "凭证无效或已失效，请重新填写") : McpException(message)

/** 其他非 2xx 的 HTTP 响应 */
class McpHttpException(val httpCode: Int, val body: String) :
    McpException("HTTP $httpCode${if (body.isNotBlank()) "：$body" else ""}")

/** 服务端返回了 JSON-RPC error */
class McpRpcException(val code: Int, message: String) : McpException("MCP 错误 $code：$message")

/** 工具执行失败（result.isError = true），message 为服务端返回的说明 */
class McpToolException(message: String) : McpException(message)

/** 调用工具并在失败时抛出 [McpToolException]，返回文本内容 */
suspend fun McpClient.callText(name: String, arguments: JsonObject = JsonObject(emptyMap())): String {
    val result = callTool(name, arguments)
    if (result.isError) throw McpToolException(result.text.ifBlank { "$name 调用失败" })
    return result.text
}

/** 响应格式不符合预期 */
class McpProtocolException(message: String) : McpException(message)

/** 会话已过期（带着 Mcp-Session-Id 请求却返回 404），客户端会自动重建会话后重试一次 */
internal class McpSessionExpiredException : McpException("MCP 会话已过期")
