package com.carpe.ideashell.data.ideashell

import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId

/** 笔记摘要（列表 / 搜索结果）。[text] 是接口返回的原始文本块，note_search 的结果里含完整正文。 */
data class NoteInfo(
    val id: String,
    val title: String,
    val summary: String? = null,
    val tags: List<String> = emptyList(),
    /** 接口返回的创建时间（ISO 字符串） */
    val createdAt: String? = null,
    val text: String? = null,
) {
    val createdInstant: Instant? get() = NoteTime.parse(createdAt)
    val localDate: LocalDate? get() = NoteTime.localDate(createdAt)
    val localClock: String? get() = NoteTime.clock(createdAt)
}

/** 笔记全文 */
data class NoteDetail(
    val id: String,
    val title: String,
    val createdAt: String?,
    val tags: List<String>,
    val summary: String?,
    /** Markdown 正文（已去掉 memo 标题行与重复的 summary 行） */
    val content: String,
    val raw: String,
) {
    val localDate: LocalDate? get() = NoteTime.localDate(createdAt)
    val localClock: String? get() = NoteTime.clock(createdAt)
}

data class Speaker(val id: String, val name: String, val self: Boolean = false)

/** 闪念贝壳自己的待办（档案里的「相关待办」用，与滴答并列） */
data class TodoBrief(
    val title: String,
    val date: String?,
    val time: String?,
    val done: Boolean,
)

/** 区间内的全部笔记；[truncated] 表示某个 1 小时的小段里仍超过单次上限，结果不完整 */
data class NotesInRange(val notes: List<NoteInfo>, val truncated: Boolean)

object NoteTime {
    /** 接口时间多为 ISO-8601（带 Z / 偏移）；兜底支持无时区的本地时间与纯日期 */
    fun parse(iso: String?, zone: ZoneId = ZoneId.systemDefault()): Instant? {
        val s = iso?.trim().orEmpty()
        if (s.isEmpty()) return null
        runCatching { return OffsetDateTime.parse(s).toInstant() }
        runCatching { return LocalDateTime.parse(s.replace(' ', 'T')).atZone(zone).toInstant() }
        runCatching { return LocalDate.parse(s.take(10)).atStartOfDay(zone).toInstant() }
        return null
    }

    fun localDate(iso: String?, zone: ZoneId = ZoneId.systemDefault()): LocalDate? =
        parse(iso, zone)?.atZone(zone)?.toLocalDate()

    /** HH:mm（本地时区） */
    fun clock(iso: String?, zone: ZoneId = ZoneId.systemDefault()): String? =
        parse(iso, zone)?.atZone(zone)?.let { "%02d:%02d".format(it.hour, it.minute) }
}

/** 解析 note_search / recent_notes / search_by_speaker 返回的纯文本 */
object NoteParser {
    private val RE_HEADER = Regex("^# (.+)\\nnote_id:\\s*([a-f0-9]+)", RegexOption.MULTILINE)
    private val RE_TITLE_TIME = Regex("^(.*?)\\s@\\s(\\d{4}-\\d{2}-\\d{2}T\\S+)$")
    private val RE_TIME = Regex("^time:\\s*(\\S+)", RegexOption.MULTILINE)
    private val RE_TAGS = Regex("^tags:\\s*(.+)$", RegexOption.MULTILINE)
    private val RE_SUMMARY = Regex("^summary:\\s*(.+)$", RegexOption.MULTILINE)
    private val RE_META_LINE = Regex("^(time|tags|summary):", RegexOption.IGNORE_CASE)
    private val RE_NO_TEXT = Regex("^\\[No text content\\]", RegexOption.IGNORE_CASE)
    private val RE_TOTAL = Regex("Total notes[^:]*:\\s*(\\d+)", RegexOption.IGNORE_CASE)

    private val RE_DETAIL_TITLE = Regex("^#\\s+(.+)", RegexOption.MULTILINE)
    private val RE_DETAIL_ID = Regex("^note_id:\\s*([a-f0-9]+)", setOf(RegexOption.MULTILINE, RegexOption.IGNORE_CASE))
    private val RE_MEMO_HEAD = Regex("^\\*\\*Memo \\d+:[^*]*\\*\\*[ \\t]*$", RegexOption.MULTILINE)
    private val RE_LEADING_SUMMARY = Regex("^[ \\t]*summary:[ \\t]*", RegexOption.IGNORE_CASE)
    private val RE_BLANKS = Regex("\\n{3,}")
    private val RE_WS = Regex("\\s+")

    /**
     * `## Memos` 之后的正文 → 干净的笔记内容。
     * - 按 `**Memo N: …**` 切成若干条 memo；长文 / 语音笔记的接口输出里，同一份内容常常以多条 memo 原样重复，
     *   按「去空白后的文本」去重，被另一条完整包含的也丢掉；
     * - memo 开头的 `summary:` 前缀只去掉前缀：它可能是重复的摘要（正文里已有同样文字则整行丢弃），
     *   也可能就是正文的第一行（长文的标题行），不能连内容一起删。
     */
    fun memoContent(body: String): String {
        val heads = RE_MEMO_HEAD.findAll(body).toList()
        val raw: List<String> = if (heads.isEmpty()) {
            listOf(body)
        } else {
            heads.mapIndexed { i, m ->
                body.substring(m.range.last + 1, if (i + 1 < heads.size) heads[i + 1].range.first else body.length)
            }
        }
        val cleaned = raw.map(::stripLeadingSummary).filter { it.isNotBlank() }
        val keys = cleaned.map { it.replace(RE_WS, "") }
        val kept = cleaned.filterIndexed { i, _ ->
            keys.indices.none { j ->
                j != i && (keys[j].length > keys[i].length && keys[j].contains(keys[i]) ||
                    keys[j] == keys[i] && j < i)
            }
        }
        return kept.joinToString("\n\n").replace(RE_BLANKS, "\n\n").trim()
    }

    private fun stripLeadingSummary(memo: String): String {
        val text = memo.trim('\n', '\r')
        val first = text.lineSequence().firstOrNull { it.isNotBlank() } ?: return ""
        if (!RE_LEADING_SUMMARY.containsMatchIn(first)) return collapseRepeatedPrefix(text)
        val firstEnd = text.indexOf(first) + first.length
        val rest = text.substring(firstEnd)
        val summary = first.replace(RE_LEADING_SUMMARY, "").trim()
        if (summary.isEmpty()) return rest.trim()
        // 先按「开头一整段在后面又原样出现」折叠（长文：summary 回显 + 正文 + 正文再来一遍）
        val joined = (summary + rest).trim()
        val collapsed = collapseRepeatedPrefix(joined)
        if (collapsed != joined) return collapsed
        val duplicated = rest.replace(RE_WS, "").contains(summary.replace(RE_WS, ""))
        return (if (duplicated) rest else joined).trim()
    }

    /**
     * 文本开头那一段（到第一行再次出现之前）如果被后面的内容完整重复，就只保留后面那份（后一份通常更完整，
     * 比如多出末尾的标签行）；可连续折叠多层。
     */
    private fun collapseRepeatedPrefix(text: String): String {
        var cur = text.trim()
        repeat(4) {
            val lines = cur.split('\n')
            val firstLine = lines.firstOrNull { it.isNotBlank() }?.trim() ?: return cur
            var offset = 0
            var cut = -1
            for (line in lines) {
                if (offset > 0 && line.trim() == firstLine) { cut = offset; break }
                offset += line.length + 1
            }
            if (cut <= 0) return cur
            val head = cur.substring(0, cut).replace(RE_WS, "")
            val tail = cur.substring(cut)
            // 太短的重复多半是正常内容（如两行相同的短句），只处理整段长文重复
            if (head.length < 80 || !tail.replace(RE_WS, "").startsWith(head)) return cur
            cur = tail.trim()
        }
        return cur
    }

    /** 解析 note_detail（scope=full）：头部是元信息，`## Memos` 之后是正文 */
    fun parseDetail(noteId: String, text: String): NoteDetail {
        val source = text.replace("\r\n", "\n")
        val memosIdx = source.indexOf("## Memos")
        val head = if (memosIdx >= 0) source.substring(0, memosIdx) else source
        val body = if (memosIdx >= 0) source.substring(memosIdx + "## Memos".length) else ""
        val content = memoContent(body)
        return NoteDetail(
            id = RE_DETAIL_ID.find(head)?.groupValues?.get(1) ?: noteId,
            title = RE_DETAIL_TITLE.find(head)?.groupValues?.get(1)?.trim().orEmpty(),
            createdAt = RE_TIME.find(head)?.groupValues?.get(1),
            tags = RE_TAGS.find(head)?.groupValues?.get(1)
                ?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }.orEmpty(),
            summary = RE_SUMMARY.find(head)?.groupValues?.get(1)?.takeIf { it.isNotBlank() },
            content = content,
            raw = source,
        )
    }

    /** "Total notes in this time range: N"；没有这一行返回 null */
    fun totalOf(text: String): Int? = RE_TOTAL.find(text)?.groupValues?.get(1)?.toIntOrNull()

    /**
     * - note_search : "# Title\nnote_id: xxx\ntime: ...\nsummary: ..."
     * - recent_notes: "# Title @ 2026-10-08T03:37:43.156Z\nnote_id: xxx\n<摘要或预览>"
     */
    fun parseNotes(text: String): List<NoteInfo> {
        val source = text.replace("\r\n", "\n")
        val heads = RE_HEADER.findAll(source).toList()
        return heads.mapIndexed { i, m ->
            val start = m.range.first
            val end = if (i + 1 < heads.size) heads[i + 1].range.first else source.length
            val block = source.substring(start, end)

            var title = m.groupValues[1].trim()
            var time: String? = null
            RE_TITLE_TIME.matchEntire(title)?.let {
                title = it.groupValues[1].trim()
                time = it.groupValues[2]
            }
            if (time == null) time = RE_TIME.find(block)?.groupValues?.get(1)

            val tags = RE_TAGS.find(block)?.groupValues?.get(1)
                ?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }.orEmpty()

            val summary: String = RE_SUMMARY.find(block)?.groupValues?.get(1) ?: run {
                // recent_notes：note_id 之后直接跟摘要文本（没有 "summary:" 前缀）
                val idLine = block.indexOf('\n', block.indexOf("note_id:"))
                val after = if (idLine >= 0) block.substring(idLine + 1) else ""
                after.lines().map { it.trim() }
                    .filter { it.isNotEmpty() && !RE_META_LINE.containsMatchIn(it) && !it.startsWith("#") }
                    .joinToString(" ")
            }
            // 纯语音笔记没有文字摘要，接口返回占位文案，不当作摘要
            val cleanSummary = summary.takeIf { it.isNotBlank() && !RE_NO_TEXT.containsMatchIn(it) }

            NoteInfo(
                id = m.groupValues[2],
                title = title.ifEmpty { "无标题" },
                summary = cleanSummary,
                tags = tags,
                createdAt = time,
                text = block,
            )
        }
    }
}
