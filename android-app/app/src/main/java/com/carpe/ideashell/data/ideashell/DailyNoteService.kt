package com.carpe.ideashell.data.ideashell

import com.carpe.ideashell.core.parse.FolderInfo
import com.carpe.ideashell.data.settings.SettingsStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
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
    /** 过去日子的 Daily Note 内存缓存：日期 → (读取时间, 内容)。回顾反复进出时不用把每天的全文重读一遍 */
    private val pastDays = HashMap<LocalDate, Pair<Long, DailyDay>>()

    suspend fun append(text: String, recordedAt: LocalDateTime) {
        synchronized(pastDays) { pastDays.remove(recordedAt.toLocalDate()) }
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

    /** 指定日期的 Daily Note 的全部条目（时间 + 文字）；那天没有 Daily Note 时为 null */
    suspend fun entriesOn(date: LocalDate): DailyDay? {
        val note = findNote(date.toString()) ?: return null
        return DailyDay(note.id, DailyFormat.entries(note.content))
    }

    /**
     * [from]..[today] 之间每天的 Daily Note 条目数（没有 Daily Note 的天不在结果里）。
     * 过去的日子读过就缓存在本机，只有今天每次重读；没缓存的天最多 [READ_PARALLEL] 路并发读全文，
     * 每读完 [PROGRESS_BATCH] 天回调一次 [onProgress]。读失败的天跳过（不缓存，下次再试）。
     */
    suspend fun entryCounts(
        from: LocalDate,
        today: LocalDate,
        onProgress: (Map<LocalDate, Int>) -> Unit,
    ): Map<LocalDate, Int> = coroutineScope {
        val ids = LinkedHashMap<LocalDate, String>()
        for (b in list()) {
            val d = RE_DATE.find(b.title)?.value?.let { runCatching { LocalDate.parse(it) }.getOrNull() } ?: continue
            if (!d.isBefore(from) && !d.isAfter(today)) ids.putIfAbsent(d, b.id)
        }
        val counts = HashMap<LocalDate, Int>()
        val missing = ArrayList<Map.Entry<LocalDate, String>>()
        for (e in ids.entries) {
            val cached = if (e.key.isBefore(today)) settings.dailyEntryCount(e.key.toString()) else null
            if (cached != null) counts[e.key] = cached else missing += e
        }
        onProgress(HashMap(counts))

        val gate = Semaphore(READ_PARALLEL)
        val lock = Any()
        var sinceReport = 0
        // 今天排在最前面：最重要的先出来
        missing.sortedByDescending { it.key.toEpochDay() }.map { e ->
            async {
                gate.withPermit {
                    val n = try {
                        DailyFormat.entries(api.noteDetail(e.value).content).size
                    } catch (c: CancellationException) {
                        throw c
                    } catch (_: Exception) {
                        null
                    }
                    if (n != null) {
                        if (e.key.isBefore(today)) settings.setDailyEntryCount(e.key.toString(), n)
                        val snapshot = synchronized(lock) {
                            counts[e.key] = n
                            if (++sinceReport >= PROGRESS_BATCH) {
                                sinceReport = 0
                                HashMap(counts)
                            } else {
                                null
                            }
                        }
                        if (snapshot != null) onProgress(snapshot)
                    }
                }
            }
        }.awaitAll()
        synchronized(lock) { HashMap(counts) }.also(onProgress)
    }

    /**
     * [from]..[toInclusive] 之间每天的 Daily Note（含按时间戳拆开的条目）；没有 Daily Note 的天不在结果里。
     * 全文最多 [READ_PARALLEL] 路并发读，读失败的那一天跳过（不影响其它天）。
     * 「回顾」的时间河用它把每条日记拆成独立的一行。
     */
    suspend fun daysInRange(from: LocalDate, toInclusive: LocalDate): Map<LocalDate, DailyDay> = coroutineScope {
        val ids = LinkedHashMap<LocalDate, String>()
        for (b in list()) {
            val d = RE_DATE.find(b.title)?.value?.let { runCatching { LocalDate.parse(it) }.getOrNull() } ?: continue
            if (!d.isBefore(from) && !d.isAfter(toInclusive)) ids.putIfAbsent(d, b.id)
        }
        val gate = Semaphore(READ_PARALLEL)
        val today = LocalDate.now()
        val now = System.currentTimeMillis()
        ids.entries.map { e ->
            async {
                // 过去的日子很少再变：内存里有（且笔记 id 没变）就直接用，不再读全文
                val hit = if (e.key.isBefore(today)) synchronized(pastDays) { pastDays[e.key] } else null
                if (hit != null && hit.second.noteId == e.value && now - hit.first < PAST_DAY_TTL_MS) {
                    return@async e.key to hit.second
                }
                gate.withPermit {
                    try {
                        val day = DailyDay(e.value, DailyFormat.entries(api.noteDetail(e.value).content))
                        if (e.key.isBefore(today)) synchronized(pastDays) { pastDays[e.key] = System.currentTimeMillis() to day }
                        e.key to day
                    } catch (c: CancellationException) {
                        throw c
                    } catch (_: Exception) {
                        // 读失败：有旧的就先用旧的
                        hit?.let { e.key to it.second }
                    }
                }
            }
        }.awaitAll().filterNotNull().toMap()
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
        const val READ_PARALLEL = 4
        const val PAST_DAY_TTL_MS = 10 * 60_000L
        const val PROGRESS_BATCH = 8
        val RE_ID = Regex("[a-f0-9]{32}", RegexOption.IGNORE_CASE)
        val RE_DATE = Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}")
        val RE_FOLDER_ID = Regex("folder_id[:\\s\"]*([a-f0-9]+)", RegexOption.IGNORE_CASE)
        val RE_SEPARATORS = Regex("[\\s_\\-·]+")
        val RE_TRAILING_S = Regex("s\$")
    }
}

/** Daily Note 里的一条：时间 `HH:mm` + 文字（多行合并成一行，换行变空格） */
data class DailyEntry(val time: String, val text: String)

/** 某一天的 Daily Note：笔记 id + 条目（按写入顺序） */
data class DailyDay(val noteId: String, val entries: List<DailyEntry>)

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

    /** 解析出全部条目：时间戳行开头，后面缩进的行算同一条；引用块（今日简报之类）和其他文字跳过 */
    fun entries(content: String): List<DailyEntry> {
        val out = ArrayList<DailyEntry>()
        var time: String? = null
        val text = StringBuilder()
        fun flush() {
            val t = time
            if (t != null && text.isNotBlank()) out += DailyEntry(t, text.toString().trim())
            time = null
            text.setLength(0)
        }
        for (line in content.lines()) {
            val m = ENTRY_RE.find(line)
            when {
                m != null -> {
                    flush()
                    time = m.groupValues[1].substring(11)
                    text.append(m.groupValues[2])
                }
                time != null && line.isNotBlank() && line.first().isWhitespace() -> text.append(' ').append(line.trim())
                else -> flush()
            }
        }
        flush()
        return out
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
