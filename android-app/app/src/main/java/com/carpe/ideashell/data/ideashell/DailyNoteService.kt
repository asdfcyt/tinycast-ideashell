package com.carpe.ideashell.data.ideashell

import com.carpe.ideashell.core.parse.FolderInfo
import com.carpe.ideashell.data.mcp.retrying
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

    /**
     * 删掉某一天 Daily Note 里的一条（时间 + 文字都对得上的那一条）。
     * 先重读那天最新的全文再改，避免覆盖别处刚写的内容；找不到这一条（已被改过 / 删过）返回 false。
     */
    suspend fun deleteEntry(date: LocalDate, entry: DailyEntry): Boolean {
        synchronized(pastDays) { pastDays.remove(date) }
        val note = findNote(date.toString()) ?: return false
        val updated = DailyFormat.removeEntry(note.content, entry.time, entry.text) ?: return false
        api.updateNoteBody(note.id, updated)
        return true
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
                        readEntries(e.value).size
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
                        val day = DailyDay(e.value, readEntries(e.value))
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

    /**
     * 读一篇 Daily Note 并拆成条目。和笔记详情页用同一个全文解析（多个 memo 都算、去掉 memo 标题行），
     * 所以时间河里和点进去看到的拆分一致；断网等暂时性失败会自动重试几次。
     */
    private suspend fun readEntries(noteId: String): List<DailyEntry> =
        DailyFormat.entries(retrying { api.noteFull(noteId) }.content)

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

/**
 * Daily Note 里的一条：时间 `HH:mm` + 文字（多行合并成一行，换行变空格）。
 * [struck] 表示这一条整条加了删除线（`~~…~~`）：[text] 里已经去掉了 `~~`，显示时按删除线画。
 */
data class DailyEntry(val time: String, val text: String, val struck: Boolean = false)

/** Daily Note 全文拆开后的两部分：条目以外的内容（Markdown）+ 条目（按写入顺序） */
data class DailySections(val other: String, val entries: List<DailyEntry>)

/** 某一天的 Daily Note：笔记 id + 条目（按写入顺序） */
data class DailyDay(val noteId: String, val entries: List<DailyEntry>)

/** Daily Note 的排版（纯函数） */
object DailyFormat {
    /** 时间戳行："**2026-10-08 11:37:40** xxx" / "2026-10-08 11:37 xxx" / "- **2026-10-08 11:37** xxx"。只用来整理（改写）旧格式，所以保持严格 */
    private val ENTRY_RE = Regex(
        "^\\s*(?:[-*+]\\s+)?(?:\\*\\*)?([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2})(?::[0-9]{2})?(?:\\*\\*)?[ \\t]*(.*)\$",
    )

    /**
     * 读取用的宽松版本：在严格版的基础上容忍时间戳前后的删除线 / 加粗 / 中括号
     * （`- ~~**2026-10-08 11:37** 内容~~`、`- **~~2026-10-08 11:37~~** 内容`、`[2026-10-08 11:37] 内容`），
     * 日期和时间之间可以是空格或 `T`，时间后面可以跟冒号。
     * 分组：1 时间戳前的符号，2 时间 HH:mm，3 时间戳后紧跟的符号，4 正文。
     */
    private val ENTRY_LOOSE_RE = Regex(
        "^\\s*(?:[-*+]\\s+)?((?:[*_~\\[(（]\\s*)*)[0-9]{4}-[0-9]{2}-[0-9]{2}[ T]([0-9]{2}:[0-9]{2})(?::[0-9]{2})?([*_~\\])）]*)[ \\t:：]*(.*)\$",
    )
    private val RE_NUMBERED = Regex("^\\d+[.、)]\\s")

    private class Head(val time: String, val rest: String, val struck: Boolean)

    private fun head(line: String): Head? {
        val m = ENTRY_LOOSE_RE.find(line) ?: return null
        val g = m.groupValues
        val rest = g[4]
        val struck = "~~" in g[1] || "~~" in g[3] || isWholeStruck(rest)
        return Head(g[2], rest, struck)
    }

    /** 正文整句被一对 `~~` 包住（中间没有别的 `~~`） */
    private fun isWholeStruck(rest: String): Boolean {
        val t = rest.trim()
        return t.length > 4 && t.startsWith("~~") && t.endsWith("~~") && !t.substring(2, t.length - 2).contains("~~")
    }

    /** 紧跟在条目后面的、不缩进也不是列表 / 标题 / 引用的文字行，算同一条的后续行（在别处编辑过的多行条目） */
    private fun continues(line: String): Boolean {
        if (line.isBlank()) return false
        val c = line.first()
        if (c.isWhitespace()) return true
        return c !in "#>-*+|" && !RE_NUMBERED.containsMatchIn(line)
    }

    /** 生成一条列表条目：`- **时间** 内容`，多行内容用缩进保持在同一条目内 */
    fun formatEntry(text: String, stamp: String): String {
        val lines = text.trim().lines()
        val first = lines.firstOrNull().orEmpty()
        val rest = lines.drop(1).map { if (it.isNotBlank()) "  $it" else "" }
        return (listOf("- **$stamp** $first") + rest).joinToString("\n")
    }

    /** 逐行扫描：时间戳行开头，后面的续行算同一条；条目以外的行交给 [onOther] */
    private fun scan(content: String, onOther: (String) -> Unit): List<DailyEntry> {
        val out = ArrayList<DailyEntry>()
        var time: String? = null
        var struck = false
        val text = StringBuilder()
        fun flush() {
            val t = time
            if (t != null) {
                val body = if (struck) text.toString().replace("~~", "") else text.toString()
                if (body.isNotBlank()) out += DailyEntry(t, body.trim(), struck)
            }
            time = null
            struck = false
            text.setLength(0)
        }
        for (line in content.lines()) {
            val h = head(line)
            when {
                h != null -> {
                    flush()
                    time = h.time
                    struck = h.struck
                    text.append(h.rest)
                }
                time != null && continues(line) -> text.append(' ').append(line.trim())
                else -> {
                    flush()
                    onOther(line)
                }
            }
        }
        flush()
        return out
    }

    /** 解析出全部条目：引用块（今日简报之类）和其他文字跳过 */
    fun entries(content: String): List<DailyEntry> = scan(content) {}

    /** 全文拆成两部分：时间戳条目，以及条目以外的内容（今日简报的引用块之类），详情页分别渲染 */
    fun sections(content: String): DailySections {
        val other = StringBuilder()
        val entries = scan(content) { other.append(it).append('\n') }
        return DailySections(other.toString().trim(), entries)
    }

    /** 把旧格式的条目统一整理为列表格式；其余内容原样保留 */
    fun normalize(content: String): String =
        content.lines().joinToString("\n") { line ->
            ENTRY_RE.find(line)?.let { m -> "- **${m.groupValues[1]}** ${m.groupValues[2]}".trimEnd() } ?: line
        }.trim()

    /**
     * 去掉一条日记：时间戳行 + 它的续行；时间和文字（按 [entries] 同样的方式合并续行后）都对上才删。
     * 没找到返回 null，其余内容原样保留。
     */
    fun removeEntry(content: String, time: String, text: String): String? {
        val lines = content.lines()
        val wanted = text.trim()
        var i = 0
        while (i < lines.size) {
            val h = head(lines[i])
            if (h == null) {
                i++
                continue
            }
            var j = i + 1
            val body = StringBuilder(h.rest)
            while (j < lines.size && head(lines[j]) == null && continues(lines[j])) {
                body.append(' ').append(lines[j].trim())
                j++
            }
            val merged = (if (h.struck) body.toString().replace("~~", "") else body.toString()).trim()
            if (h.time == time && merged == wanted) {
                return (lines.take(i) + lines.drop(j)).joinToString("\n").trim()
            }
            i = j
        }
        return null
    }

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
