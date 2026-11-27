package com.carpe.ideashell.data.voice

import com.carpe.ideashell.AppContainer
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.core.voice.VoiceIntent
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.ideashell.NoteInfo
import android.util.Log
import java.time.LocalDate
import java.time.ZoneId

/**
 * 语音「找一下…」：不调 AI，直接在本机待办 + 闪念贝壳笔记（MCP 语义搜索）里查，返回几行能直接看 / 通知里显示的文字。
 */
object VoiceSearch {
    private const val TAG = "VoiceSearch"
    const val MAX_LINES = 6

    /** 一条结果：笔记或待办，点开能跳到对应页面 */
    class Hit(val isNote: Boolean, val id: String, val title: String, val sub: String)

    /** [text] 是几行能直接看 / 放通知里的文字；[hits] 是可以点开的条目；[keyword] 用来跳到拾忆的搜索页看全部 */
    class Result(val text: String, val hits: List<Hit>, val keyword: String, val isAnswer: Boolean = false)

    fun merge(list: List<Result>): Result = Result(
        text = list.joinToString("\n") { it.text },
        hits = list.flatMap { it.hits },
        keyword = list.firstOrNull { it.keyword.isNotBlank() }?.keyword.orEmpty(),
        isAnswer = list.any { it.isAnswer },
    )

    /** 待办查询（「今天还有什么没做」）的结果也做成可点开的条目 */
    fun taskHits(tasks: List<DidaTask>): List<Hit> = tasks.map { t ->
        val whenText = listOfNotNull(t.date?.take(10)?.drop(5), t.time).joinToString(" ")
        Hit(false, t.id, TodoMeta.cleanTitle(t.title).trim(), whenText)
    }

    /** 按 AI 整理出的搜索意图查：[VoiceIntent.target] 关键词、[VoiceIntent.searchScope] 范围、[VoiceIntent.date] ~ [VoiceIntent.until] 时间 */
    suspend fun find(container: AppContainer, intent: VoiceIntent): Result {
        val k = intent.target.orEmpty().trim()
        val scope = intent.searchScope
        val since = intent.date
        val until = intent.until
        if (k.isEmpty() && since == null && until == null) return Result("没听清要找什么", emptyList(), "")
        Log.i(TAG, "search scope=$scope keyword=$k since=$since until=$until")
        val todoHits = if (scope != "note") todos(container, k, since, until) else emptyList()
        val (noteHits, noteError) = if (scope != "todo") notes(container, k, since, until) else emptyList<Hit>() to null
        val hits = todoHits + noteHits
        val range = rangeText(since, until)
        val text = when {
            hits.isNotEmpty() -> buildString {
                append(if (k.isEmpty()) "${range}共 ${hits.size} 条" else "$range「$k」共 ${hits.size} 条")
                if (noteError != null) append("（$noteError）")
            }
            noteError != null -> noteError
            scope != "todo" && !container.credentials.ideashellConnected.value -> "还没连接闪念贝壳，没法搜索笔记"
            else -> "没找到$range" + (if (k.isEmpty()) "" else "「$k」相关") + when (scope) { "note" -> "的笔记"; "todo" -> "的待办"; else -> "的内容" }
        }
        return Result(text, hits, k)
    }

    private fun rangeText(since: LocalDate?, until: LocalDate?): String = when {
        since == null && until == null -> ""
        since != null && until != null -> "${since.monthValue}/${since.dayOfMonth}~${until.monthValue}/${until.dayOfMonth} "
        since != null -> "${since.monthValue}/${since.dayOfMonth} 起 "
        else -> "${until!!.monthValue}/${until.dayOfMonth} 前 "
    }

    private fun inRange(d: LocalDate?, since: LocalDate?, until: LocalDate?): Boolean {
        if (since == null && until == null) return true
        if (d == null) return false
        return (since == null || !d.isBefore(since)) && (until == null || !d.isAfter(until))
    }

    private suspend fun todos(container: AppContainer, k: String, since: LocalDate?, until: LocalDate?): List<Hit> {
        val hits = findTodos(container, k, since, until)
        Log.i(TAG, "todo hits=${hits.size}")
        return taskHits(hits).mapIndexed { i, h -> if (hits[i].done) Hit(false, h.id, "✓ " + h.title, h.sub) else h }
    }

    /** 待办（含已完成）里按计划日期范围 + 关键词查；未完成的排前面 */
    suspend fun findTodos(container: AppContainer, k: String, since: LocalDate?, until: LocalDate?): List<DidaTask> {
        runCatching { container.todos.refreshNow() }
        val o = container.todos.peek() ?: return emptyList()
        val key = k.lowercase()
        return (o.overdue + o.upcoming + o.undated + o.done)
            .filter { t ->
                inRange(t.date?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() }, since, until) &&
                    (key.isEmpty() || TodoMeta.cleanTitle(t.title).lowercase().contains(key) ||
                        t.content.lowercase().contains(key) ||
                        t.tags.any { it.lowercase().contains(key) })
            }
            .distinctBy { it.id }
            .sortedBy { it.done }
    }

    /** 返回（结果, 错误提示）：搜索失败时结果为空、提示里写原因 */
    private suspend fun notes(container: AppContainer, k: String, since: LocalDate?, until: LocalDate?): Pair<List<Hit>, String?> {
        val (list, error) = findNotes(container, k, since, until)
        return list.map(::noteHit) to error
    }

    fun noteHit(n: NoteInfo): Hit {
        val d = n.localDate?.let { "${it.monthValue}/${it.dayOfMonth}" }.orEmpty()
        return Hit(true, n.id, n.title.trim().ifEmpty { (n.summary ?: "").trim().take(24) }.ifEmpty { "（无标题）" }, d)
    }

    /** 笔记：语义搜索 ∪ 时间范围内字面匹配，新的在前；返回（笔记, 错误提示） */
    suspend fun findNotes(container: AppContainer, k: String, since: LocalDate?, until: LocalDate?): Pair<List<NoteInfo>, String?> {
        if (!container.credentials.ideashellConnected.value) return emptyList<NoteInfo>() to null
        val zone = ZoneId.systemDefault()
        val found = LinkedHashMap<String, NoteInfo>()
        try {
            // 语义搜索（不带时间）：先拿候选，再按时间范围筛
            if (k.isNotEmpty()) container.notes.search(k).filter { inRange(it.localDate, since, until) }.forEach { found.putIfAbsent(it.id, it) }
            // 说了时间范围：再把这段时间内所有笔记拉出来，按关键词字面匹配补漏（语义搜索只返回前 20 条，可能漏掉范围内的）
            if (since != null || until != null) {
                val from = (since ?: until!!.minusYears(1)).atStartOfDay(zone).toInstant()
                val to = (until ?: LocalDate.now()).plusDays(1).atStartOfDay(zone).toInstant()
                val key = k.lowercase()
                container.notes.rangeNotes(from, to)
                    .filter { n ->
                        key.isEmpty() || n.title.lowercase().contains(key) || (n.summary ?: "").lowercase().contains(key) ||
                            (n.text ?: "").lowercase().contains(key) || n.tags.any { it.lowercase().contains(key) }
                    }
                    .forEach { found.putIfAbsent(it.id, it) }
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "note search failed", e)
            return emptyList<NoteInfo>() to ("笔记搜索失败：" + (e.message ?: "未知错误"))
        }
        val hits = found.values.sortedByDescending { it.createdAt.orEmpty() }
        Log.i(TAG, "note hits=${hits.size}")
        return hits to null
    }
}
