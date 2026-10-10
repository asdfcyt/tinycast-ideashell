package com.carpe.ideashell.data.dida

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * 滴答任务（只保留界面要用的字段）。日期 / 时间用字符串存，方便直接序列化成本地缓存：
 * date = yyyy-MM-dd（本地日期，无截止日期为 null）；time = HH:mm（全天任务为 null）。
 */
@Serializable
data class DidaTask(
    val id: String,
    val projectId: String,
    val title: String,
    val content: String = "",
    val date: String? = null,
    val time: String? = null,
    /** 0 无 / 1 低 / 3 中 / 5 高 */
    val priority: Int = 0,
    val tags: List<String> = emptyList(),
    val done: Boolean = false,
    val completedAt: Long? = null,
    val createdAt: Long? = null,
)

@Serializable
data class DidaOverview(
    val overdue: List<DidaTask> = emptyList(),
    /** 今天起 7 天内有日期的未完成任务 */
    val upcoming: List<DidaTask> = emptyList(),
    /** 收集箱里没有日期的未完成任务（最新在前，最多 100 条） */
    val undated: List<DidaTask> = emptyList(),
    /** 最近 3 天完成的任务 */
    val done: List<DidaTask> = emptyList(),
    val projects: Map<String, String> = emptyMap(),
    /** 部分请求失败时的说明 */
    val warning: String? = null,
) {
    fun withoutTask(id: String): DidaOverview = copy(
        overdue = overdue.filterNot { it.id == id },
        upcoming = upcoming.filterNot { it.id == id },
        undated = undated.filterNot { it.id == id },
    )

    fun findOpen(id: String): DidaTask? =
        (overdue + upcoming + undated).firstOrNull { it.id == id }
}

/** 解析滴答 MCP 返回的文本：可能是单个 JSON、数组，或多个 JSON 对象首尾相接 */
object DidaParser {
    private val json = Json { isLenient = true; ignoreUnknownKeys = true }

    private val DATE_RE = Regex(
        "^(\\d{4})-(\\d{2})-(\\d{2})(?:[T ](\\d{2}):(\\d{2})(?::(\\d{2}))?(?:\\.\\d+)?)?\\s*(Z|[+-]\\d{2}:?\\d{2})?$",
    )

    /** 把文本里所有顶层 JSON 值依次解析出来（跳过无法解析的片段） */
    fun parseAny(text: String): List<JsonElement> {
        val values = mutableListOf<JsonElement>()
        var i = 0
        while (i < text.length) {
            val c = text[i]
            if (c != '{' && c != '[') {
                i++
                continue
            }
            var depth = 0
            var inStr = false
            var esc = false
            var end = -1
            var j = i
            while (j < text.length) {
                val ch = text[j]
                if (inStr) {
                    if (esc) esc = false else if (ch == '\\') esc = true else if (ch == '"') inStr = false
                } else if (ch == '"') {
                    inStr = true
                } else if (ch == '{' || ch == '[') {
                    depth++
                } else if (ch == '}' || ch == ']') {
                    depth--
                    if (depth == 0) {
                        end = j
                        break
                    }
                }
                j++
            }
            if (end < 0) break
            runCatching { json.parseToJsonElement(text.substring(i, end + 1)) }.getOrNull()?.let(values::add)
            i = end + 1
        }
        return values
    }

    /** 深度优先收集满足条件的对象（命中后不再往里找） */
    fun collectObjects(value: JsonElement, pred: (JsonObject) -> Boolean, out: MutableList<JsonObject>) {
        when (value) {
            is JsonArray -> value.forEach { collectObjects(it, pred, out) }
            is JsonObject -> if (pred(value)) out.add(value) else value.values.forEach { collectObjects(it, pred, out) }
            else -> Unit
        }
    }

    fun extractTasks(text: String, zone: ZoneId = ZoneId.systemDefault()): List<DidaTask> {
        val found = mutableListOf<JsonObject>()
        parseAny(text).forEach { collectObjects(it, { o -> o.str("id") != null && o.str("title") != null }, found) }
        val seen = HashSet<String>()
        val tasks = mutableListOf<DidaTask>()
        for (o in found) {
            val id = o.str("id") ?: continue
            if (!seen.add(id)) continue
            val allDay = (o["isAllDay"] as? JsonPrimitive)?.booleanOrNull == true
            val due = parseDate(o.str("dueDate") ?: o.str("startDate"), allDay, zone)
            val status = (o["status"] as? JsonPrimitive)?.intOrNull
            tasks.add(
                DidaTask(
                    id = id,
                    projectId = o.str("projectId").orEmpty(),
                    title = o.str("title").orEmpty(),
                    content = o.str("content") ?: o.str("desc") ?: "",
                    date = due.first,
                    time = due.second,
                    priority = (o["priority"] as? JsonPrimitive)?.intOrNull ?: 0,
                    tags = (o["tags"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty(),
                    // 重复任务完成一次后仍是未完成，但 completedTime 会保留，所以以 status 为准
                    done = status == 2 || (status == null && o.str("completedTime") != null),
                    completedAt = parseMs(o.str("completedTime")),
                    createdAt = parseMs(o.str("createdTime")),
                ),
            )
        }
        return tasks
    }

    /** 项目列表：id → 名称；收集箱 id 形如 inbox1011888736 */
    fun extractProjects(text: String): Map<String, String> {
        val found = mutableListOf<JsonObject>()
        parseAny(text).forEach { collectObjects(it, { o -> o.str("id") != null && o.str("name") != null }, found) }
        val names = LinkedHashMap<String, String>()
        for (o in found) names[o.str("id")!!] = o.str("name")!!
        for ((id, name) in names.entries.toList()) {
            if (id.startsWith("inbox", ignoreCase = true) && name.contains("inbox", ignoreCase = true)) names[id] = "收集箱"
        }
        return names
    }

    /** 滴答返回的日期可能是 UTC，也可能带 +0800 / +08:00，统一换算成本地日期 / 时间 */
    fun parseDate(value: String?, isAllDay: Boolean, zone: ZoneId): Pair<String?, String?> {
        if (value == null) return null to null
        val m = DATE_RE.matchEntire(value.trim()) ?: return null to null
        val g = m.groupValues
        if (g[4].isEmpty()) return "${g[1]}-${g[2]}-${g[3]}" to null

        var offsetMin = 0
        val off = g[7]
        if (off.isNotEmpty() && off != "Z") {
            val sign = if (off[0] == '-') -1 else 1
            val digits = off.drop(1).replace(":", "")
            offsetMin = sign * (digits.take(2).toInt() * 60 + digits.drop(2).take(2).toInt())
        }
        val utc = java.time.LocalDateTime
            .of(g[1].toInt(), g[2].toInt(), g[3].toInt(), g[4].toInt(), g[5].toInt(), g[6].ifEmpty { "0" }.toInt())
            .toEpochSecond(java.time.ZoneOffset.UTC) * 1000 - offsetMin * 60_000L
        val local = Instant.ofEpochMilli(utc).atZone(zone)
        val date = local.toLocalDate().toString()
        val time = if (isAllDay) null else "%02d:%02d".format(local.hour, local.minute)
        return date to time
    }

    fun parseMs(v: String?): Long? {
        if (v == null) return null
        // 2026-10-09T10:00:00+0800 → 补冒号后交给 java.time
        val fixed = v.replace(Regex("([+-]\\d{2})(\\d{2})$"), "$1:$2")
        return runCatching { java.time.OffsetDateTime.parse(fixed).toInstant().toEpochMilli() }.getOrNull()
    }

    private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull

    fun today(zone: ZoneId = ZoneId.systemDefault()): LocalDate = LocalDate.now(zone)
}
