package com.carpe.ideashell.data.mcp

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import java.io.IOException

/** 暂时性的失败（断网、超时、服务端 5xx / 限流、响应不完整）值得再试一次；凭证无效、服务端明确拒绝的不值得 */
internal fun Throwable.isTransient(): Boolean = when (this) {
    is IOException -> true
    is McpHttpException -> httpCode >= 500 || httpCode == 429 || httpCode == 408
    is McpProtocolException -> true
    else -> false
}

/**
 * 只读请求的重试：遇到暂时性失败最多试 [times] 次，间隔逐次拉长；
 * 取消、凭证问题和其他确定性的错误立刻抛出。写入类请求不要用它（重试可能重复写入）。
 */
internal suspend fun <T> retrying(times: Int = 3, baseDelayMs: Long = 500, block: suspend () -> T): T {
    var attempt = 0
    while (true) {
        try {
            return block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            attempt++
            if (attempt >= times || !e.isTransient()) throw e
            delay(baseDelayMs * attempt)
        }
    }
}
