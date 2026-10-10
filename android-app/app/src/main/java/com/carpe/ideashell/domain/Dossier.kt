package com.carpe.ideashell.domain

import com.carpe.ideashell.data.ideashell.NoteInfo
import com.carpe.ideashell.data.ideashell.Speaker
import java.time.LocalDate
import java.time.temporal.ChronoUnit

data class DossierNote(
    val note: NoteInfo,
    /** 正文 / 标题里出现关键词的次数（说话人命中的笔记可能为 0） */
    val mentions: Int,
    /** 直接提及：文字里出现关键词，或有该说话人发言 */
    val direct: Boolean,
    val viaSpeaker: Boolean,
    val snippet: String,
    val tags: List<String>,
    val day: LocalDate?,
)

data class DossierTodo(
    val title: String,
    val date: String?,
    val time: String?,
    val done: Boolean,
)

/** 提及的时间分布 */
data class DossierStats(
    val firstDay: LocalDate,
    val firstTitle: String,
    val lastDay: LocalDate,
    val lastTitle: String,
    val totalMentions: Int,
    val distinctDays: Int,
    /** 近 12 个月（含本月），形如 2026-10 */
    val monthLabels: List<String>,
    val monthCounts: List<Int>,
    /** 距上次提及的天数 */
    val gapDays: Int,
)

data class DossierData(
    val query: String,
    /** 时间倒序 */
    val notes: List<DossierNote>,
    val directCount: Int,
    val todos: List<DossierTodo>,
    val speakers: List<Speaker>,
    val voiceCount: Int,
    val stats: DossierStats?,
    /** 高频同现标签（标签 → 次数） */
    val topTags: List<Pair<String, Int>>,
    /** 完整 Markdown 简报（用于复制） */
    val brief: String,
) {
    val direct: List<DossierNote> get() = notes.filter { it.direct }
    val related: List<DossierNote> get() = notes.filterNot { it.direct }
}

/**
 * 人物 / 主题档案：围绕一个名字或关键词，聚合提及过的笔记（多路语义检索 + 字面校验）、
 * 相关待办、该说话人的录音笔记，并统计首次 / 最近提及、近 12 个月频率、高频同现标签。
 * 规则与桌面 `dossier.ts` 一致。
 */
object Dossier {
    private val BARS = listOf('▁', '▂', '▃', '▄', '▅', '▆', '▇', '█')

    /** 多种问法各检索一次再合并，扩大覆盖面（接口单次最多返回 20 条） */
    fun searchVariants(q: String): List<String> =
        listOf(q, "关于$q", "$q 计划 待办", "$q 沟通 讨论").distinct()

    /** 名字里含关键词（或关键词里含 2 字以上的名字）的说话人 */
    fun matchSpeakers(q: String, all: List<Speaker>): List<Speaker> {
        val lq = q.lowercase()
        return all.filter { s ->
            val n = s.name.lowercase()
            n.isNotEmpty() && (n.contains(lq) || (n.length >= 2 && lq.contains(n)))
        }
    }

    fun build(
        query: String,
        searchResults: List<NoteInfo>,
        speakerNotes: List<NoteInfo>,
        speakers: List<Speaker>,
        todos: List<DossierTodo>,
        today: LocalDate = LocalDate.now(),
    ): DossierData {
        val q = query.trim()
        val lq = q.lowercase()
        val speakerIds = speakerNotes.map { it.id }.toSet()

        // 合并去重：同一条笔记优先保留带正文文本的那份
        val byId = LinkedHashMap<String, NoteInfo>()
        for (n in searchResults + speakerNotes) {
            if (n.id.isEmpty()) continue
            val old = byId[n.id]
            if (old == null || (old.text == null && n.text != null)) byId[n.id] = n
        }

        val notes = byId.values.map { note ->
            val body = NoteText.memoText(note.text.orEmpty())
            val mentions = countOf("${note.title}\n$body".lowercase(), lq)
            val viaSpeaker = note.id in speakerIds
            DossierNote(
                note = note,
                mentions = mentions,
                direct = mentions > 0 || viaSpeaker,
                viaSpeaker = viaSpeaker,
                snippet = makeSnippet(body, q, note.summary ?: note.title),
                tags = NoteText.extractTags(note, body),
                day = note.localDate,
            )
        }.sortedByDescending { it.note.createdAt.orEmpty() }

        val direct = notes.filter { it.direct }
        val sortedTodos = todos.sortedWith(
            compareBy<DossierTodo>({ it.done }).thenByDescending { it.date.orEmpty() },
        )
        val dated = direct.filter { it.day != null }
        val stats = if (dated.isEmpty()) null else buildStats(dated, today)

        val tagCount = LinkedHashMap<String, Int>()
        direct.forEach { n -> n.tags.forEach { tagCount[it] = (tagCount[it] ?: 0) + 1 } }
        tagCount.remove(q)
        val topTags = tagCount.entries.sortedByDescending { it.value }.take(8).map { it.key to it.value }

        val data = DossierData(
            query = q,
            notes = notes,
            directCount = direct.size,
            todos = sortedTodos,
            speakers = speakers,
            voiceCount = direct.count { it.viaSpeaker },
            stats = stats,
            topTags = topTags,
            brief = "",
        )
        return data.copy(brief = brief(data, today))
    }

    private fun buildStats(dated: List<DossierNote>, today: LocalDate): DossierStats {
        val newest = dated.first()
        val oldest = dated.last()
        val (labels, counts) = monthlySeries(dated.mapNotNull { it.day }, today)
        return DossierStats(
            firstDay = oldest.day!!,
            firstTitle = oldest.note.title,
            lastDay = newest.day!!,
            lastTitle = newest.note.title,
            totalMentions = dated.sumOf { it.mentions },
            distinctDays = dated.mapNotNull { it.day }.toSet().size,
            monthLabels = labels,
            monthCounts = counts,
            gapDays = daysBetween(newest.day!!, today),
        )
    }

    // ── 纯函数 ──

    private fun countOf(hay: String, needle: String): Int {
        if (needle.isEmpty()) return 0
        var count = 0
        var i = hay.indexOf(needle)
        while (i >= 0) {
            count++
            i = hay.indexOf(needle, i + needle.length)
        }
        return count
    }

    private fun makeSnippet(body: String, q: String, fallback: String): String {
        val i = body.lowercase().indexOf(q.lowercase())
        if (i < 0) return NoteText.truncate(fallback, 70)
        val from = maxOf(0, i - 28)
        val to = minOf(body.length, i + q.length + 56)
        val s = body.substring(from, to).replace("**", "").replace("__", "").replace(Regex("\\s+"), " ").trim()
        return "${if (from > 0) "…" else ""}$s${if (to < body.length) "…" else ""}"
    }

    fun daysBetween(from: LocalDate, to: LocalDate): Int = ChronoUnit.DAYS.between(from, to).toInt()

    fun ago(days: Int): String = when {
        days <= 0 -> "今天"
        days == 1 -> "昨天"
        days < 30 -> "$days 天前"
        days < 365 -> "约 ${Math.round(days / 30.0)} 个月前"
        else -> "约 ${"%.1f".format(days / 365.0)} 年前"
    }

    /** 近 12 个月（含本月）每月直接提及的笔记数 */
    fun monthlySeries(days: List<LocalDate>, today: LocalDate): Pair<List<String>, List<Int>> {
        val labels = (11 downTo 0).map { i ->
            val d = today.withDayOfMonth(1).minusMonths(i.toLong())
            "%04d-%02d".format(d.year, d.monthValue)
        }
        val counts = labels.map { label -> days.count { "%04d-%02d".format(it.year, it.monthValue) == label } }
        return labels to counts
    }

    fun sparkline(counts: List<Int>): String {
        val max = counts.maxOrNull() ?: 0
        return counts.joinToString("") { c ->
            if (c == 0) "·" else BARS[minOf(BARS.size - 1, Math.ceil(c.toDouble() / max * BARS.size).toInt() - 1)].toString()
        }
    }

    /** 可复制的 Markdown 简报 */
    private fun brief(d: DossierData, today: LocalDate): String {
        val direct = d.direct
        val out = mutableListOf("# 「${d.query}」档案", "", "> 直接提及 ${direct.size} 条笔记，另有 ${d.notes.size - direct.size} 条语义相关")
        if (direct.isEmpty() && d.todos.isEmpty()) {
            out += listOf("", "没有找到直接提及的记录。「可能相关」是语义相近的笔记，换个叫法（全名 / 昵称 / 项目代号）再试试。")
            return out.joinToString("\n")
        }

        out += ""
        d.stats?.let { s ->
            out += "- **首次提及**：${s.firstDay}，${ago(daysBetween(s.firstDay, today))}（${NoteText.truncate(s.firstTitle, 16)}）"
            out += "- **最近提及**：${s.lastDay}，${ago(s.gapDays)}（${NoteText.truncate(s.lastTitle, 16)}）"
            out += "- **累计提及**：${s.totalMentions} 次，分布在 ${s.distinctDays} 个日期"
            if (s.monthCounts.any { it > 0 }) {
                out += "- **近 12 个月**：${sparkline(s.monthCounts)}　${s.monthLabels.first().drop(2)} 至 ${s.monthLabels.last().drop(2)}"
            }
        }
        val open = d.todos.count { !it.done }
        out += "- **待办**：$open 未完成，${d.todos.size - open} 已完成"
        if (d.speakers.isNotEmpty()) {
            out += "- **说话人**：${d.speakers.joinToString("、") { it.name }}，有其发言的笔记 ${d.voiceCount} 条"
        }
        if (d.topTags.isNotEmpty()) {
            out += "- **常伴随的标签**：${d.topTags.joinToString("　") { "#${it.first}  ${it.second}" }}"
        }

        val recent = direct.filter { it.snippet.isNotEmpty() }.take(4)
        if (recent.isNotEmpty()) {
            out += listOf("", "## 最近的提及", "")
            recent.forEach { n ->
                out += "> ${n.snippet}"
                out += "> — ${NoteText.truncate(n.note.title, 24)}　${n.day ?: ""}"
                out += ""
            }
        }

        if (d.todos.isNotEmpty()) {
            out += listOf("## 相关待办", "")
            d.todos.take(12).forEach { t ->
                val whenText = listOfNotNull(t.date, t.time).joinToString(" ")
                out += "- [${if (t.done) "x" else " "}] ${t.title}${if (whenText.isNotEmpty()) "（$whenText）" else ""}"
            }
            if (d.todos.size > 12) out += "- 另有 ${d.todos.size - 12} 条"
            out += ""
        }

        d.stats?.takeIf { it.gapDays >= 30 }?.let {
            out += "> 距上次提及已 ${it.gapDays} 天，见面 / 推进前也许值得先补一条近况。"
            out += ""
        }
        out += "*基于对「${d.query}」的多路语义检索（每路最多 20 条）并做字面校验，可能不是全部记录。*"
        return out.joinToString("\n")
    }
}
