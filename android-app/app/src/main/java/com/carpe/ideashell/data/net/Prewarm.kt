package com.carpe.ideashell.data.net

import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * 提前把到某个服务的连接（DNS + TCP + TLS）建好放进连接池：录音一开始就调用，
 * 等说完要真正请求识别 / 大模型时直接复用，省掉几百毫秒的握手。失败了不影响任何事。
 * 在后台线程调用（会阻塞到响应回来）；同一个主机 [MIN_GAP_MS] 内只预热一次。
 */
object Prewarm {
    private const val MIN_GAP_MS = 20_000L
    private val last = ConcurrentHashMap<String, Long>()

    fun warm(http: OkHttpClient, url: String) {
        val host = runCatching { java.net.URI(url).host }.getOrNull() ?: return
        val now = System.currentTimeMillis()
        val prev = last[host]
        if (prev != null && now - prev < MIN_GAP_MS) return
        last[host] = now
        runCatching {
            val client = http.newBuilder()
                .connectTimeout(3, TimeUnit.SECONDS)
                .readTimeout(3, TimeUnit.SECONDS)
                .callTimeout(4, TimeUnit.SECONDS)
                .build()
            // HEAD 不带内容，对方回 404 / 405 也没关系：要的只是那条连接
            client.newCall(Request.Builder().url(url).head().build()).execute().close()
        }
    }
}
