package com.carpe.ideashell.data.ideashell

import com.carpe.ideashell.core.parse.FolderInfo
import com.carpe.ideashell.data.settings.SettingsStore
import java.time.LocalDate
import java.time.LocalDateTime

/**
 * 追加到 Daily Note。规则与桌面插件 `daily.ts` 保持一致：
 * - 标题为日期（`YYYY-MM-DD`），存放在 Daily Note 文件夹，带 `daily-note` 标签；
 * - 每次追加一条列表项 `- **YYYY-MM-DD HH:mm** 内容`，多行用缩进；
 * - 追加时顺手把旧格式（挤在一行、带秒、无列表符号）整理成列表。
 * 条目的时间用「记录时间」而不是同步时间，所以离线记的内容也会落在正确的那一天、正确的时刻。
 */
class DailyNoteService(
    private val api: IdeashellApi,
    private val settings: SettingsStore,
) {
    suspend fun append(text: String, recordedAt: LocalDateTime) {
        val date = recordedAt.toLocalDate().toString()
        val stamp = "$date ${"%02d:%02d".format(recordedAt.hour, recordedAt.minute)}"

        val existing = findNote(date)
        if (existing != null) {
            api.updateNoteBody(existing.id, DailyFormat.appendEntry(existing.content, text, stamp))
            return
        }

        val folderId = getOrCreateFolderId()
        val result = api.createNote(
            title = date,
            body = DailyFormat.formatEntry(text, stamp),
            tags = listOf("daily-note"),
            folderId = folderId.ifEmpty { null },
            inlineTags = false,
        )
        RE_ID.find(result)?.value?.let { settings.setDailyNoteId(date, it) }
    }

    /**
     * 把一段内容块插到今天 Daily Note 的最前面（不存在则创建）。
     * 开头已有带同一标记的引用块就替换掉，所以重复生成不会堆叠。返回今天 Daily Note 的 id（拿不到时为 null）。
     */
    suspend fun prependBlockToToday(block: String, marker: String, today: LocalDate = LocalDate.now()): String? {
        val date = today.toString()
        val text = block.trim()
        val existing = findNote(date)
        if (existing != null) {
            val rest = DailyFormat.normalize(DailyFormat.stripLeadingQuote(existing.content, marker)).trim()
            api.updateNoteBody(existing.id, if (rest.isNotEmpty()) "$text\n\n$rest" else text)
            return existing.id
        }
        val folderId = getOrCreateFolderId()
        val result = api.createNote(
            title = date,
            body = text,
            tags = listOf("daily-note"),
            folderId = folderId.ifEmpty { null },
            inlineTags = false,
        )
        val id = RE_ID.find(result)?.value
        if (id != null) settings.setDailyNoteId(date, id)
        return id
    }

    /** Daily Note 文件夹里的全部笔记，按标题里的日期倒序；文件夹不存在时为空 */
    suspend fun list(): List<NoteBrief> {
        val folder = findFolder() ?: return emptyList()
        return api.notesInFolder(folder.id).sortedByDescending { RE_DATE.find(it.title)?.value.orEmpty() }
    }

    /**
     * 找到指定日期的 Daily Note：
     * 1. 本机缓存的 note_id（只需 1 次读取）；
     * 2. 在 Daily Note 文件夹里按标题日期查找（换设备 / 清缓存也不会重复创建）。
     */
    private suspend fun findNote(date: String): NoteContent? {
        settings.dailyNoteId(date)?.let { cached ->
            try {
                return api.noteDetail(cached)
            } catch (_: Exception) {
                settings.clearDailyNoteId(date)
            }
        }

        val folder = findFolder() ?: return null
        val brief = try {
            api.notesInFolder(folder.id).firstOrNull { RE_DATE.find(it.title)?.value == date }
        } catch (_: Exception) {
            null
        } ?: return null

        return try {
            api.noteDetail(brief.id).also { settings.setDailyNoteId(date, brief.id) }
        } catch (_: Exception) {
            null
        }
    }

    private suspend fun findFolder(): FolderInfo? {
        val wanted = settings.current.dailyFolder
        val wantedNorm = normalize(wanted)
        val folders = api.listFolders()
        return folders.firstOrNull { it.name.trim().equals(wanted, ignoreCase = true) }
            ?: folders.firstOrNull { normalize(it.name) == wantedNorm }
            ?: folders.firstOrNull { normalize(it.name) == "dailynote" }
    }

    private suspend fun getOrCreateFolderId(): String {
        findFolder()?.let { return it.id }
        val result = api.createFolder(settings.current.dailyFolder)
        return RE_FOLDER_ID.find(result)?.groupValues?.get(1)
            ?: RE_ID.find(result)?.value
            ?: ""
    }

    /** "Daily Notes" / "Dailynotes" / "daily-note" 都视为同一个 */
    private fun normalize(name: String): String =
        name.lowercase().replace(RE_SEPARATORS, "").replace(RE_TRAILING_S, "")

    private companion object {
        val RE_ID = Regex("[a-f0-9]{32}", RegexOption.IGNORE_CASE)
        val RE_DATE = Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}")
        val RE_FOLDER_ID = Regex("folder_id[:\\s\"]*([a-f0-9]+)", RegexOption.IGNORE_CASE)
        val RE_SEPARATORS = Regex("[\\s_\\-·]+")
        val RE_TRAILING_S = Regex("s\$")
    }
}

/** Daily Note 的排版（纯函数） */
object DailyFormat {
    /** 时间戳行："**2026-10-08 11:37:40** xxx" / "2026-10-08 11:37 xxx" / "- **2026-10-08 11:37** xxx" */
    private val ENTRY_RE = Regex(
        "^\\s*(?:[-*+]\\s+)?(?:\\*\\*)?([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2})(?::[0-9]{2})?(?:\\*\\*)?[ \\t]*(.*)\$",
    )

    /** 生成一条列表条目：`- **时间** 内容`，多行内容用缩进保持在同一条目内 */
    fun formatEntry(text: String, stamp: String): String {
        val lines = text.trim().lines()
        val first = lines.firstOrNull().orEmpty()
        val rest = lines.drop(1).map { if (it.isNotBlank()) "  $it" else "" }
        return (listOf("- **$stamp** $first") + rest).joinToString("\n")
    }

    /** 把旧格式的条目统一整理为列表格式；其余内容原样保留 */
    fun normalize(content: String): String =
        content.lines().joinToString("\n") { line ->
            ENTRY_RE.find(line)?.let { m -> "- **${m.groupValues[1]}** ${m.groupValues[2]}".trimEnd() } ?: line
        }.trim()

    /** 去掉开头已有的、带指定标记的引用块（连续以 ">" 开头的行），以及它后面的空行 */
    fun stripLeadingQuote(content: String, marker: String): String {
        val lines = content.lines()
        val first = lines.firstOrNull() ?: return content
        if (!(first.trim().startsWith(">") && first.contains(marker))) return content
        var i = 0
        while (i < lines.size && lines[i].trim().startsWith(">")) i++
        while (i < lines.size && lines[i].isBlank()) i++
        return lines.drop(i).joinToString("\n")
    }

    fun appendEntry(oldContent: String, text: String, stamp: String): String {
        val entry = formatEntry(text, stamp)
        val normalized = normalize(oldContent)
        return if (normalized.isNotEmpty()) "$normalized\n$entry" else entry
    }
}
