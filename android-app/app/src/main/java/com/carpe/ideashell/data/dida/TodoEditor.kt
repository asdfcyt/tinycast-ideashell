package com.carpe.ideashell.data.dida

import java.time.LocalDate
import java.time.LocalTime

/**
 * 用语音修改「之前建好的待办」：找到要改的那一条，再改时间 / 往备注里追加说明 / 改优先级。
 *
 * 能改多久之前的：就是待办页里本来就有的那批未完成待办——逾期（最近 13 天）、今天起 7 天内、收集箱里最新的无日期任务。
 * - 说了待办名里的关键词（「开会那个」）：在这批里按名字匹配，匹配上了就改，不看建了多久；
 * - 只说「刚才那个」没说名字：只改最近 24 小时内建的最新一条，更早的不敢猜，宁可告诉你没找到。
 * 已经完成的待办不改；还在离线队列里没发到滴答的待办也不改（等同步完再说一次）。
 */
class TodoEditor(
    private val todos: TodoRepository,
    private val hasCredential: () -> Boolean,
) {
    /** 要改什么：没说要改的字段保持 null / 空 */
    data class Edit(
        val date: LocalDate? = null,
        val time: LocalTime? = null,
        /** 追加到备注末尾的说明 */
        val addNote: String? = null,
        /** 0 = 不改优先级 */
        val priority: Int = 0,
    ) {
        val isEmpty get() = date == null && time == null && addNote.isNullOrBlank() && priority == 0
    }

    /** 找到 [hint] 对应的未完成待办；找不到返回 null。会先刷新一次，免得刚建的那条还没进缓存 */
    suspend fun find(hint: String?): DidaTask? {
        if (!hasCredential()) return null
        todos.refreshNow()
        val o = todos.peek() ?: return null
        val all = (o.overdue + o.upcoming + o.undated).filterNot { it.done }.distinctBy { it.id }
        val key = normalize(hint.orEmpty())
        val now = System.currentTimeMillis()
        if (key.isEmpty()) {
            return all.filter { (it.createdAt ?: 0L) > now - DAY_MS }.maxByOrNull { it.createdAt ?: 0L }
        }
        return all
            .map { it to score(it, key, now) }
            .filter { it.second >= MIN_SCORE }
            .maxWithOrNull(compareBy({ it.second }, { it.first.createdAt ?: 0L }))
            ?.first
    }

    private fun score(task: DidaTask, key: String, now: Long): Int {
        val title = normalize(task.title)
        if (title.isEmpty()) return 0
        var s = when {
            title.contains(key) -> 100
            key.contains(title) -> 80
            else -> (bigramOverlap(title, key) * 60).toInt()
        }
        if (s == 0) return 0
        // 同样像的，越是刚建的越优先
        val age = now - (task.createdAt ?: 0L)
        s += when {
            task.createdAt == null -> 0
            age < 6 * HOUR_MS -> 30
            age < DAY_MS -> 15
            age < 3 * DAY_MS -> 5
            else -> 0
        }
        return s
    }

    private fun bigramOverlap(a: String, b: String): Float {
        if (a.length < 2 || b.length < 2) return if (a.contains(b) || b.contains(a)) 1f else 0f
        val ga = a.windowed(2).toSet()
        val gb = b.windowed(2).toSet()
        return ga.intersect(gb).size.toFloat() / minOf(ga.size, gb.size)
    }

    private fun normalize(text: String) = text.lowercase().filter { it.isLetterOrDigit() }

    /** 给界面看的一句话：「开会」改到 14:40，备注加「带上办公电脑」 */
    fun describe(task: DidaTask, edit: Edit): String {
        val parts = mutableListOf<String>()
        if (edit.date != null || edit.time != null) {
            val date = edit.date?.toString() ?: task.date
            val time = edit.time?.let { "%02d:%02d".format(it.hour, it.minute) } ?: task.time
            parts += "改到 " + listOfNotNull(date?.let { dayLabel(it) }, time).joinToString(" ")
        }
        if (!edit.addNote.isNullOrBlank()) parts += "备注加「${edit.addNote.trim().take(30)}」"
        if (edit.priority > 0) parts += "优先级改为" + when (edit.priority) { 5 -> "高"; 3 -> "中"; else -> "低" }
        return "「${task.title.take(24)}」" + parts.joinToString("，")
    }

    private fun dayLabel(date: String): String {
        val today = LocalDate.now()
        val d = runCatching { LocalDate.parse(date) }.getOrNull() ?: return date
        return when (d) {
            today -> "今天"
            today.plusDays(1) -> "明天"
            today.plusDays(2) -> "后天"
            else -> "${d.monthValue}月${d.dayOfMonth}日"
        }
    }

    /** 提交修改；成功返回 [describe] 的那句话 */
    suspend fun apply(task: DidaTask, edit: Edit): Result<String> {
        var cur = task
        if (edit.date != null || edit.time != null) {
            // 只说了时间：日期沿用原来的（原来没日期就算今天）；只说了日期：时间沿用原来的
            val date = edit.date?.toString() ?: task.date ?: LocalDate.now().toString()
            val time = edit.time?.let { "%02d:%02d".format(it.hour, it.minute) } ?: task.time
            val r = todos.reschedule(cur, date, time)
            if (r.isFailure) return Result.failure(r.exceptionOrNull() ?: IllegalStateException("改时间失败"))
            cur = cur.copy(date = date, time = time)
        }
        if (!edit.addNote.isNullOrBlank()) {
            val note = edit.addNote.trim()
            val content = if (cur.content.isBlank()) note else cur.content.trimEnd() + "\n" + note
            val r = todos.setContent(cur, content)
            if (r.isFailure) return Result.failure(r.exceptionOrNull() ?: IllegalStateException("改备注失败"))
            cur = cur.copy(content = content)
        }
        if (edit.priority > 0) {
            val r = todos.setPriority(cur, edit.priority)
            if (r.isFailure) return Result.failure(r.exceptionOrNull() ?: IllegalStateException("改优先级失败"))
        }
        return Result.success(describe(task, edit))
    }

    private companion object {
        const val HOUR_MS = 3_600_000L
        const val DAY_MS = 24 * HOUR_MS
        const val MIN_SCORE = 30
    }
}
