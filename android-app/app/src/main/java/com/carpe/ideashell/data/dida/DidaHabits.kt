package com.carpe.ideashell.data.dida

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import java.time.LocalDate

/** 滴答习惯 + 专注记录的宽松解析（接口返回没有公开样例，规则与桌面 `dida-habits.ts` / `dida-focus.ts` 一致） */

/** 一个习惯在一段日期里：应打卡 [due] 天，完成 [done] 天 */
data class HabitStat(val name: String, val due: Int, val done: Int)

data class Habit(
    val id: String,
    val name: String,
    /** 每天的目标值（打卡一次写入这个值）；没有则为 1 */
    val goal: Double,
    val unit: String,
    /** 重复规则（RRULE），用来判断今天是否需要打卡 */
    val repeat: String,
    /** 今天已有的打卡记录 id（有的话更新它而不是新建） */
    val checkinId: String? = null,
    val doneToday: Boolean = false,
) {
    val label: String
        get() = if (goal > 1) "${if (goal % 1.0 == 0.0) goal.toLong().toString() else goal.toString()}$unit" else ""
}

object HabitParser {
    private val WEEKDAYS = listOf("SU", "MO", "TU", "WE", "TH", "FR", "SA")
    private val BYDAY = Regex("BYDAY=([A-Z,]+)")

    fun stampOf(d: LocalDate): Int = d.year * 10000 + d.monthValue * 100 + d.dayOfMonth

    /** 今天是否需要打卡：只识别「每周几」（BYDAY=MO,WE）；其他规则一律当作每天 */
    fun isDue(repeat: String, day: LocalDate): Boolean {
        val m = BYDAY.find(repeat) ?: return true
        // java DayOfWeek: MONDAY=1..SUNDAY=7 → WEEKDAYS 以 SU 为 0
        return m.groupValues[1].split(",").contains(WEEKDAYS[day.dayOfWeek.value % 7])
    }

    fun parseHabits(text: String): List<Habit> {
        val found = mutableListOf<JsonObject>()
        DidaParser.parseAny(text).forEach { DidaParser.collectObjects(it, { o -> o.str("id") != null && o.str("name") != null }, found) }
        val out = mutableListOf<Habit>()
        for (o in found) {
            // 已归档 / 已停用的不显示（正常习惯 status 为 0）
            val status = o.num("status")
            if (status != null && status != 0.0) continue
            val goal = o.num("goal")?.takeIf { it > 0 } ?: 1.0
            out += Habit(
                id = o.str("id")!!,
                name = o.str("name")!!.trim(),
                goal = goal,
                unit = o.str("unit").orEmpty(),
                repeat = o.str("repeatRule").orEmpty(),
            )
        }
        return out
    }

    class Checkin(val id: String?, val done: Boolean)

    /** 一段日期内的打卡：习惯 id → 完成了打卡的 stamp 集合（判断「完成」的规则与 [parseCheckins] 一致） */
    fun parseCheckinDays(text: String, habitIds: Set<String>): Map<String, Set<Int>> {
        val out = HashMap<String, MutableSet<Int>>()
        fun walk(v: JsonElement, cur: String) {
            when (v) {
                is JsonArray -> v.forEach { walk(it, cur) }
                is JsonObject -> {
                    val hid = v.str("habitId") ?: cur
                    val st = v.num("stamp")
                    if (st != null && hid.isNotEmpty() && hid in habitIds) {
                        val value = v.num("value") ?: 0.0
                        val goal = v.num("goal") ?: 1.0
                        val status = v.num("status")
                        val done = status == 2.0 || (status == null && value > 0 && value >= goal)
                        if (done) out.getOrPut(hid) { HashSet() }.add(st.toInt())
                    }
                    for ((k, child) in v) walk(child, if (k in habitIds) k else hid)
                }
                else -> Unit
            }
        }
        DidaParser.parseAny(text).forEach { walk(it, "") }
        return out
    }

    /** 在返回内容里找出当天的打卡记录：对象带 stamp，所属习惯来自 habitId 字段或外层的键 */
    fun parseCheckins(text: String, habitIds: Set<String>, stamp: Int): Map<String, Checkin> {
        val out = HashMap<String, Checkin>()
        fun walk(v: JsonElement, cur: String) {
            when (v) {
                is JsonArray -> v.forEach { walk(it, cur) }
                is JsonObject -> {
                    val hid = v.str("habitId") ?: cur
                    val st = v.num("stamp")
                    if (st != null && st.toInt() == stamp && hid.isNotEmpty() && hid in habitIds) {
                        val value = v.num("value") ?: 0.0
                        val goal = v.num("goal") ?: 1.0
                        val status = v.num("status")
                        val done = status == 2.0 || (status == null && value > 0 && value >= goal)
                        val prev = out[hid]
                        out[hid] = Checkin(v.str("id") ?: prev?.id, done || prev?.done == true)
                    }
                    for ((k, child) in v) walk(child, if (k in habitIds) k else hid)
                }
                else -> Unit
            }
        }
        DidaParser.parseAny(text).forEach { walk(it, "") }
        return out
    }

    private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
    private fun JsonObject.num(key: String): Double? = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
}

// ───────────── 专注 ─────────────

data class TaskFocus(val todayMin: Int = 0, val todayCount: Int = 0, val weekMin: Int = 0, val weekCount: Int = 0)

/** 一次专注：起止时刻（毫秒时间戳）；回顾用它画专注趋势、时间线和最佳时段 */
data class FocusSession(val startMs: Long, val endMs: Long)

data class FocusSummary(
    val todayMin: Int = 0,
    val todayPomos: Int = 0,
    val weekMin: Int = 0,
    val weekPomos: Int = 0,
    val byTask: Map<String, TaskFocus> = emptyMap(),
    val titles: Map<String, String> = emptyMap(),
    /** 范围内每一次专注，按开始时间从早到晚 */
    val sessions: List<FocusSession> = emptyList(),
)

object FocusParser {
    /** [texts]：(是否番茄钟, 返回文本) */
    fun summarize(texts: List<Pair<Boolean, String>>, today: LocalDate, zone: java.time.ZoneId): FocusSummary {
        val todayStart = today.atStartOfDay(zone).toInstant().toEpochMilli()
        val seen = HashSet<String>()
        val byTask = HashMap<String, TaskFocus>()
        val titles = HashMap<String, String>()
        val sessions = ArrayList<FocusSession>()
        var todayMin = 0
        var todayPomos = 0
        var weekMin = 0
        var weekPomos = 0
        for ((isPomo, text) in texts) {
            val found = mutableListOf<JsonObject>()
            DidaParser.parseAny(text).forEach {
                DidaParser.collectObjects(it, { o -> o.str("startTime") != null && o.str("endTime") != null }, found)
            }
            for (o in found) {
                val start = DidaParser.parseMs(o.str("startTime")) ?: continue
                val end = DidaParser.parseMs(o.str("endTime")) ?: continue
                if (end <= start) continue
                val id = o.str("id") ?: "${if (isPomo) "pomo" else "timing"}-$start"
                if (!seen.add(id)) continue
                val minutes = Math.round((end - start) / 60000.0).toInt()
                sessions += FocusSession(start, end)
                val isToday = start >= todayStart
                weekMin += minutes
                if (isPomo) weekPomos++
                if (isToday) {
                    todayMin += minutes
                    if (isPomo) todayPomos++
                }
                val ids = LinkedHashSet<String>()
                o.str("taskId")?.takeIf { it.isNotEmpty() }?.let(ids::add)
                (o["tasks"] as? JsonArray)?.forEach { t ->
                    val b = t as? JsonObject ?: return@forEach
                    val tid = b.str("taskId") ?: b.str("id") ?: return@forEach
                    if (tid.isEmpty()) return@forEach
                    ids += tid
                    b.str("title")?.takeIf { it.isNotEmpty() }?.let { titles[tid] = it }
                }
                for (tid in ids) {
                    val f = byTask[tid] ?: TaskFocus()
                    byTask[tid] = TaskFocus(
                        todayMin = f.todayMin + if (isToday) minutes else 0,
                        todayCount = f.todayCount + if (isToday) 1 else 0,
                        weekMin = f.weekMin + minutes,
                        weekCount = f.weekCount + 1,
                    )
                }
            }
        }
        return FocusSummary(todayMin, todayPomos, weekMin, weekPomos, byTask, titles, sessions.sortedBy { it.startMs })
    }

    fun formatMinutes(min: Int): String = when {
        min < 60 -> "$min 分钟"
        min % 60 == 0 -> "${min / 60} 小时"
        else -> "${min / 60} 小时 ${min % 60} 分钟"
    }

    private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
}
