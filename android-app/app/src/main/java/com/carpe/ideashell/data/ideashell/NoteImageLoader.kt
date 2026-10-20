package com.carpe.ideashell.data.ideashell

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import android.util.LruCache
import com.carpe.ideashell.data.secure.CredentialStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request

/** 从笔记详情文本里找出图片地址（接口怎么写都尽量认：Markdown 图片、带图片后缀的链接、标着「图片 / 附件」的行里的链接） */
object NoteImages {
    private val RE_MD_IMAGE = Regex("!\\[[^\\]]*]\\(\\s*<?([^)\\s>]+)>?[^)]*\\)")
    private val RE_URL = Regex("(?:https?://|data:image/)[^\\s)\\]\">'<]+", RegexOption.IGNORE_CASE)
    private val RE_IMAGE_EXT = Regex("\\.(png|jpe?g|gif|webp|bmp|heic|heif|avif)(\\?|#|$)", RegexOption.IGNORE_CASE)
    private val RE_NOT_IMAGE_EXT = Regex("\\.(mp3|m4a|aac|wav|amr|mp4|mov|pdf|docx?|xlsx?|pptx?|txt|zip)(\\?|#|$)", RegexOption.IGNORE_CASE)
    private val RE_IMAGE_HINT = Regex("image|img|photo|picture|图片|照片|附件|attachment", RegexOption.IGNORE_CASE)

    private fun clean(url: String): String = url.trimEnd('.', ',', ';', '，', '。', '、')

    fun extract(raw: String): List<String> {
        val out = LinkedHashSet<String>()
        for (m in RE_MD_IMAGE.findAll(raw)) out += clean(m.groupValues[1])
        for (line in raw.lineSequence()) {
            for (m in RE_URL.findAll(line)) {
                val url = clean(m.value)
                val image = url.startsWith("data:image/", ignoreCase = true) ||
                    RE_IMAGE_EXT.containsMatchIn(url) ||
                    (RE_IMAGE_HINT.containsMatchIn(line) && !RE_NOT_IMAGE_EXT.containsMatchIn(url))
                if (image) out += url
            }
        }
        return out.take(MAX_IMAGES)
    }

    const val MAX_IMAGES = 30
}

/**
 * 笔记图片的下载 + 内存缓存（按大小淘汰）。图片地址在闪念贝壳自己的域名下时带上 API Key（可能需要鉴权），
 * 别的域名一律不带，免得把凭证发出去。
 */
class NoteImageLoader(
    private val http: OkHttpClient,
    private val credentials: CredentialStore,
) {
    private val cache = object : LruCache<String, Bitmap>((Runtime.getRuntime().maxMemory() / 8).toInt().coerceAtLeast(8 * 1024 * 1024)) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }

    fun cached(url: String): Bitmap? = cache.get(url)

    /** 下载并解码（长边不超过 [maxEdge]）；失败返回 null */
    suspend fun load(url: String, maxEdge: Int = 1800): Bitmap? {
        cache.get(url)?.let { return it }
        val bitmap = withContext(Dispatchers.IO) {
            runCatching {
                val bytes = if (url.startsWith("data:", ignoreCase = true)) {
                    Base64.decode(url.substringAfter("base64,"), Base64.DEFAULT)
                } else {
                    val builder = Request.Builder().url(url)
                    val host = java.net.URI(url).host.orEmpty()
                    if (host == "ideashell.cn" || host.endsWith(".ideashell.cn")) {
                        credentials.ideashellKey?.takeIf { it.isNotBlank() }?.let { builder.header("Authorization", "Bearer $it") }
                    }
                    http.newCall(builder.build()).execute().use { resp ->
                        if (!resp.isSuccessful) error("HTTP ${resp.code}")
                        resp.body?.bytes() ?: error("empty")
                    }
                }
                decode(bytes, maxEdge)
            }.getOrNull()
        }
        if (bitmap != null) cache.put(url, bitmap)
        return bitmap
    }

    private fun decode(bytes: ByteArray, maxEdge: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxEdge) sample *= 2
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
    }
}
