package com.carpe.ideashell.data.ideashell

import com.carpe.ideashell.core.parse.FolderInfo
import com.carpe.ideashell.data.mcp.McpClient
import com.carpe.ideashell.data.mcp.McpJson
import com.carpe.ideashell.data.mcp.callText
import com.carpe.ideashell.data.mcp.string
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import java.time.Instant
import java.time.ZoneId
import java.util.concurrent.atomic.AtomicBoolean

data class NoteBrief(val id: String, val title: String)

data class NoteContent(val id: String, val title: String, val content: String)

/** 随笔记上传的图片：[bytes] 是 JPEG / PNG 原始字节，[name] 含扩展名 */
class ImageUpload(val name: String, val bytes: ByteArray)

data class TodoDraft(val content: String, val date: String? = null, val time: String? = null)

/** 闪念贝壳 MCP 的业务封装（M1 只包含「记录」需要的接口，其余在后续里程碑补充） */
class IdeashellApi(private val mcp: McpClient) {

    suspend fun createNote(
        title: String,
        body: String,
        tags: List<String> = emptyList(),
        folderId: String? = null,
        /** 把标签以 `#标签` 写进正文末尾（闪念贝壳 App 只识别正文里的行内标签），默认开启 */
        inlineTags: Boolean = true,
        images: List<ImageUpload> = emptyList(),
    ): String {
        val content = if (inlineTags) withInlineTags(body, tags) else body
        return mcp.callText(
            "note_create",
            buildJsonObject {
                put("title", title)
                if (content.isNotEmpty()) put("content", content)
                if (tags.isNotEmpty()) putJsonArray("tags") { tags.forEach { add(it) } }
                if (folderId != null) put("folder_id", folderId)
                if (images.isNotEmpty()) {
                    putJsonArray("images") {
                        images.forEach { img ->
                            add(
                                buildJsonObject {
                                    put("data", java.util.Base64.getEncoder().encodeToString(img.bytes))
                                    put("name", img.name)
                                },
                            )
                        }
                    }
                }
            },
        )
    }

    suspend fun updateNoteBody(noteId: String, body: String): String =
        mcp.callText(
            "note_update",
            buildJsonObject {
                put("note_id", noteId)
                put("content", body)
            },
        )

    suspend fun createTodos(items: List<TodoDraft>) {
        mcp.callText(
            "todo_create",
            buildJsonObject {
                putJsonArray("items") {
                    items.forEach { item ->
                        add(
                            buildJsonObject {
                                put("content", item.content)
                                if (item.date != null) put("date", item.date)
                                if (item.time != null) put("time", item.time)
                            },
                        )
                    }
                }
                put("timezone", ZoneId.systemDefault().id)
            },
        )
    }

    suspend fun listFolders(): List<FolderInfo> {
        val text = mcp.callText("folder_list")
        if (text.isBlank()) return emptyList()
        // 文本格式："- 📁 FolderName [folder_id: xxx]"
        return RE_FOLDER.findAll(text).map { m ->
            FolderInfo(
                id = m.groupValues[3],
                name = m.groupValues[2].trim(),
                emoji = m.groupValues[1].ifEmpty { null },
            )
        }.toList()
    }

    suspend fun createFolder(name: String): String =
        mcp.callText("folder_create", buildJsonObject { put("name", name) })

    /** 文件夹里的笔记，返回格式 "- 标题 [note_id: xxx]" */
    suspend fun notesInFolder(folderId: String): List<NoteBrief> {
        val text = mcp.callText("folder_notes", buildJsonObject { put("folder_id", folderId) })
        return RE_FOLDER_NOTE.findAll(text).map { NoteBrief(id = it.groupValues[2], title = it.groupValues[1].trim()) }.toList()
    }

    suspend fun noteDetail(noteId: String): NoteContent {
        val text = mcp.callText(
            "note_detail",
            buildJsonObject {
                put("note_id", noteId)
                put("scope", "full")
            },
        )
        val title = RE_TITLE.find(text)?.groupValues?.get(1).orEmpty()
        var content = ""
        val memosIdx = text.indexOf("## Memos")
        if (memosIdx != -1) {
            val memosText = text.substring(memosIdx + "## Memos".length).trim()
            // note_search / note_detail 会在 memo 开头重复一行 summary，去掉；没有 memo 标题行时整段都算正文，
            // 不能当成空（追加时会拿它覆盖整篇笔记）
            content = (RE_MEMO.find(memosText)?.groupValues?.get(1) ?: memosText).replace(RE_SUMMARY_LINE, "").trim()
        }
        return NoteContent(id = noteId, title = title, content = content)
    }

    // ───────────────────────── M3 回顾：读取接口 ─────────────────────────

    /** 笔记全文（元信息 + Markdown 正文） */
    suspend fun noteFull(noteId: String): NoteDetail {
        val text = mcp.callText(
            "note_detail",
            buildJsonObject {
                put("note_id", noteId)
                put("scope", "full")
            },
        )
        return NoteParser.parseDetail(noteId, text)
    }

    /** 语义搜索；接口单次最多 20 条 */
    suspend fun searchNotes(query: String, limit: Int = 15): List<NoteInfo> {
        val text = mcp.callText(
            "note_search",
            buildJsonObject {
                put("query", query)
                put("limit", limit.coerceIn(1, 20))
            },
        )
        return if (text.isBlank()) emptyList() else NoteParser.parseNotes(text)
    }

    /**
     * 取出 [start, end) 内创建的全部笔记。
     * recent_notes 单次最多 20 条，但会返回区间总数；超过 20 条时把区间对半拆分并行拉取，
     * 直到每段都取全（最小粒度 1 小时，再多就标记为 truncated）。
     */
    suspend fun notesInRange(start: Instant, end: Instant): NotesInRange = coroutineScope {
        val truncated = AtomicBoolean(false)
        val all = walkRange(start.toEpochMilli(), end.toEpochMilli(), truncated)
        val unique = LinkedHashMap<String, NoteInfo>()
        all.forEach { unique.putIfAbsent(it.id, it) }
        NotesInRange(
            notes = unique.values.sortedByDescending { it.createdAt.orEmpty() },
            truncated = truncated.get(),
        )
    }

    private suspend fun walkRange(s: Long, e: Long, truncated: AtomicBoolean): List<NoteInfo> = coroutineScope {
        val text = mcp.callText(
            "recent_notes",
            buildJsonObject {
                put("start_time", Instant.ofEpochMilli(s).toString())
                put("end_time", Instant.ofEpochMilli(e).toString())
                put("limit", 20)
            },
        )
        val notes = if (text.isBlank()) emptyList() else NoteParser.parseNotes(text)
        val total = NoteParser.totalOf(text) ?: notes.size
        when {
            total <= notes.size -> notes
            e - s <= HOUR_MS -> {
                truncated.set(true)
                notes
            }
            else -> {
                val mid = s + (e - s) / 2
                val left = async { walkRange(s, mid, truncated) }
                val right = async { walkRange(mid, e, truncated) }
                left.await() + right.await()
            }
        }
    }

    suspend fun listSpeakers(): List<Speaker> {
        val text = mcp.callText("speaker_list")
        val array = runCatching { McpJson.parseToJsonElement(text) as? JsonArray }.getOrNull() ?: return emptyList()
        return array.mapNotNull { el ->
            val o = el as? JsonObject ?: return@mapNotNull null
            val id = o.string("id") ?: return@mapNotNull null
            Speaker(id = id, name = o.string("name").orEmpty(), self = (o["self"] as? JsonPrimitive)?.booleanOrNull == true)
        }
    }

    /** 说话人出现过的笔记（录音转写里有此人发言），按时间倒序 */
    suspend fun searchBySpeaker(speakerIds: List<String>, limit: Int = 20): List<NoteInfo> {
        val text = mcp.callText(
            "search_by_speaker",
            buildJsonObject {
                putJsonArray("speaker_ids") { speakerIds.forEach { add(it) } }
                put("limit", limit.coerceIn(1, 20))
            },
        )
        return if (text.isBlank()) emptyList() else NoteParser.parseNotes(text)
    }

    /** 闪念贝壳自己的待办，按关键词查（档案的「相关待办」） */
    suspend fun todosByKeyword(keyword: String, completed: Boolean, limit: Int = 50): List<TodoBrief> {
        val text = mcp.callText(
            "todo_list",
            buildJsonObject {
                put("timezone", ZoneId.systemDefault().id)
                put("is_completed", completed)
                put("keyword", keyword)
                put("limit", limit.coerceIn(1, 200))
            },
        )
        val root = runCatching { McpJson.parseToJsonElement(text) }.getOrNull() ?: return emptyList()
        val list: JsonArray = when (root) {
            is JsonArray -> root
            is JsonObject -> (root["todos"] as? JsonArray) ?: (root["updated"] as? JsonArray) ?: return emptyList()
            else -> return emptyList()
        }
        return list.mapNotNull { el ->
            val o = el as? JsonObject ?: return@mapNotNull null
            val content = o.string("content") ?: return@mapNotNull null
            TodoBrief(
                title = content,
                date = o.string("date"),
                time = o.string("time"),
                done = (o["is_completed"] as? JsonPrimitive)?.booleanOrNull == true,
            )
        }
    }

    companion object {
        private const val HOUR_MS = 3_600_000L
        private val RE_FOLDER = Regex("-\\s*(\\S*)\\s*(.+?)\\s*\\[folder_id:\\s*([a-f0-9]+)\\]", RegexOption.IGNORE_CASE)
        private val RE_FOLDER_NOTE = Regex("^-\\s+(.+?)\\s*\\[note_id:\\s*([a-f0-9]+)\\]\\s*\$", RegexOption.MULTILINE)
        private val RE_TITLE = Regex("^#\\s+(.+)", RegexOption.MULTILINE)
        private val RE_MEMO = Regex("\\*\\*Memo [0-9]+:.*?\\*\\*\\n?([\\s\\S]*)")
        private val RE_SUMMARY_LINE = Regex("^summary:.*\\n?", RegexOption.IGNORE_CASE)

        /** 标签名里不能有空白，否则 App 会把它拆成多个 */
        fun cleanTag(tag: String): String = tag.replace(Regex("^#+"), "").replace(Regex("[\\s#]+"), "")

        /** 在正文末尾追加一行 `#标签1 #标签2`（已在正文里出现的标签不重复追加） */
        fun withInlineTags(body: String, tags: List<String>): String {
            val clean = tags.map(::cleanTag).filter { it.isNotEmpty() }.distinct()
            val missing = clean.filterNot { tag ->
                Regex("(^|\\s)#${Regex.escape(tag)}(?=\\s|\$)").containsMatchIn(body)
            }
            if (missing.isEmpty()) return body
            val line = missing.joinToString(" ") { "#$it" }
            return if (body.isNotBlank()) "${body.trimEnd()}\n\n$line" else line
        }
    }
}
