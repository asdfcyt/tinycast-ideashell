package com.carpe.ideashell.data.capture

import com.carpe.ideashell.core.capture.ClipInput
import com.carpe.ideashell.core.capture.truncate
import com.carpe.ideashell.data.ideashell.IdeashellApi
import com.carpe.ideashell.data.settings.SettingsStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * 摘录模式的笔记：
 * - 同一个 App、同一个来源（书 / 文章 / 站点）下，隔得不太久的摘录追加进同一篇笔记，每段摘录带上自己的想法；
 * - 来源和标签在同一个 App 里延续（[SESSION_MS] 内），下一次摘录时自动填好，用户可以改；
 * - 来源改成另一个，就另起一篇。
 */
class ExcerptNotes(
    private val api: IdeashellApi,
    private val settings: SettingsStore,
    private val captures: () -> CaptureRepository,
) {
    private val lock = Mutex()
    private var session: Session? = null

    /** 每个 App 最近一次用的来源和标签（仅内存） */
    private val lastUsed = HashMap<String, Last>()

    private data class Session(val key: String, val noteId: String, val title: String, val updatedAt: Long)
    private data class Last(val source: String, val tags: List<String>, val at: Long)

    /** 打开抽屉时预填的来源和标签 */
    data class Suggestion(val source: String, val tags: List<String>)

    /** 一次摘录：[source] 是来源（书名 / 文章 / 站点），[thought] 是用户写的想法（可为空） */
    data class Entry(
        val pkg: String,
        val appName: String,
        val source: String,
        val tags: List<String>,
        val quote: String,
        val thought: String,
    )

    sealed interface Result {
        /** 新建了一篇摘录笔记 */
        data class Created(val title: String) : Result

        /** 追加到了已有的这一篇 */
        data class Appended(val title: String) : Result

        /** 没写进去（断网等），已放进离线队列，稍后同步 */
        data class Queued(val title: String) : Result
    }

    /** 这个 App 里上一次用的来源 / 标签（[SESSION_MS] 内）；没有就用识别到的标题，再没有就用 App 名 */
    fun suggest(pkg: String, docTitle: String?, appName: String): Suggestion {
        val last = synchronized(lastUsed) { lastUsed[pkg] }
        if (last != null && System.currentTimeMillis() - last.at < SESSION_MS) return Suggestion(last.source, last.tags)
        return Suggestion(docTitle?.takeIf { it.isNotBlank() } ?: appName, emptyList())
    }

    /** 写入一段摘录；写不进去时退回离线队列（另存一篇），不会丢 */
    suspend fun write(e: Entry): Result = lock.withLock {
        val now = System.currentTimeMillis()
        val source = e.source.trim().ifEmpty { e.appName }
        val tags = e.tags.map(::cleanTag).filter { it.isNotEmpty() }.distinct()
        synchronized(lastUsed) { lastUsed[e.pkg] = Last(source, tags, now) }
        val title = truncate(source, 30)
        try {
            val key = "${e.pkg}|$source"
            val current = session?.takeIf { it.key == key && now - it.updatedAt < SESSION_MS }
            if (current != null) {
                try {
                    val detail = api.noteDetail(current.noteId)
                    if (detail.content.isNotBlank()) {
                        api.updateNoteBody(current.noteId, insertBlock(detail.content, block(e.quote, e.thought), tags))
                        session = current.copy(updatedAt = now)
                        return@withLock Result.Appended(current.title)
                    }
                } catch (c: CancellationException) {
                    throw c
                } catch (_: Exception) {
                    // 读不到 / 笔记被删了：往下重新建一篇
                }
            }
            val sourceLine = "来源：" + if (source == e.appName) source else "$source（${e.appName}）"
            val created = api.createNote(
                title = title,
                body = "$sourceLine\n\n${block(e.quote, e.thought)}",
                tags = (settings.current.defaultTags + "摘录" + tags).distinct(),
            )
            val id = (RE_JSON.find(created) ?: RE_TEXT.find(created) ?: RE_HEX.find(created))?.groupValues?.get(1)
            session = id?.let { Session(key, it, title, now) }
            Result.Created(title)
        } catch (c: CancellationException) {
            throw c
        } catch (_: Exception) {
            val annotation = (listOf(e.thought.trim()) + tags.map { "#$it" }).filter { it.isNotEmpty() }.joinToString("\n")
            captures().submitClip(ClipInput(quote = e.quote, pageTitle = title, url = null, appName = e.appName), annotation, "excerpt")
            Result.Queued(title)
        }
    }

    /** 一段摘录：引用块 + 想法（想法为空就只有引用） */
    private fun block(quote: String, thought: String): String {
        val quoted = quote.trim().lines().joinToString("\n") { if (it.isBlank()) ">" else "> $it" }
        val t = thought.trim()
        return if (t.isEmpty()) quoted else "$quoted\n\n$t"
    }

    /** 新的一段放在正文末尾、结尾的 `#标签` 行之前；新标签并进标签行 */
    private fun insertBlock(content: String, block: String, tags: List<String>): String {
        val lines = content.trimEnd().lines()
        val last = lines.lastOrNull()?.trim().orEmpty()
        val isTagLine = last.isNotEmpty() && last.split(Regex("\\s+")).all { it.startsWith("#") && it.length > 1 }
        val body = if (isTagLine) lines.dropLast(1).joinToString("\n").trimEnd() else content.trimEnd()
        val existing = if (isTagLine) last.split(Regex("\\s+")).map { it.removePrefix("#") } else emptyList()
        val merged = (existing + tags).distinct()
        val tagLine = merged.joinToString(" ") { "#$it" }
        return buildString {
            append(body).append("\n\n").append(block)
            if (tagLine.isNotEmpty()) append("\n\n").append(tagLine)
        }
    }

    private fun cleanTag(t: String): String = t.trim().removePrefix("#").replace(Regex("\\s+"), "")

    companion object {
        const val SESSION_MS = 3 * 60 * 60 * 1000L
        private val RE_JSON = Regex("\"note_id\"\\s*:\\s*\"([^\"]+)\"")
        private val RE_TEXT = Regex("note_id[:\\s]+([0-9a-f]{16,})", RegexOption.IGNORE_CASE)
        private val RE_HEX = Regex("([a-f0-9]{32})", RegexOption.IGNORE_CASE)

        /** 把输入框里的「#a #b，c」拆成标签列表 */
        fun parseTags(text: String): List<String> =
            text.split(Regex("[\\s,，、]+")).map { it.trim().removePrefix("#") }.filter { it.isNotEmpty() }.distinct()
    }
}
