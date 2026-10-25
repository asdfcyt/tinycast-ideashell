package com.carpe.ideashell.core.plan

import com.carpe.ideashell.data.dida.DidaTask
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.LocalDateTime

/** 日期字符串（yyyy-MM-dd，可能带时间）→ LocalDate；解析不了为 null */
internal fun parseDay(s: String?): LocalDate? =
    s?.takeIf { it.length >= 10 }?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() }

/**
 * 重新规划里的「规则排期」（与 Mac 端 `Scheduler.plan` 一致）：
 * 把要排的任务按「优先级高 → 日期早 → 先创建」依次放进「每天不超过 perDay 件」的最近一天；晚上 8 点以后今天不再排。
 */
object Scheduler {
    const val HORIZON_DAYS = 28

    class Item(val task: DidaTask, val date: String)

    class Plan(val items: List<Item>, val leftover: List<DidaTask>)

    fun isWeekend(d: LocalDate): Boolean = d.dayOfWeek == DayOfWeek.SATURDAY || d.dayOfWeek == DayOfWeek.SUNDAY

    /** 今天起第一个周六（今天是周六就是今天） */
    fun nextSaturday(today: LocalDate): LocalDate {
        var d = today
        repeat(7) { if (d.dayOfWeek != DayOfWeek.SATURDAY) d = d.plusDays(1) }
        return d
    }

    /** 明天起第一个周一 */
    fun nextMonday(today: LocalDate): LocalDate {
        var d = today.plusDays(1)
        repeat(7) { if (d.dayOfWeek != DayOfWeek.MONDAY) d = d.plusDays(1) }
        return d
    }

    /**
     * @param tasks 要排的任务
     * @param existing 已经有日期、不在本次排期里的任务，用来算每天已有几件
     */
    fun plan(
        tasks: List<DidaTask>,
        existing: List<DidaTask>,
        perDay: Int,
        skipWeekends: Boolean,
        now: LocalDateTime = LocalDateTime.now(),
    ): Plan {
        val today = now.toLocalDate()
        val first = if (now.hour >= 20) today.plusDays(1) else today
        val planIds = tasks.map { it.id }.toSet()
        val load = HashMap<LocalDate, Int>()
        for (t in existing) {
            if (t.done || t.id in planIds) continue
            val d = parseDay(t.date) ?: continue
            if (!d.isBefore(today)) load[d] = (load[d] ?: 0) + 1
        }
        val sorted = tasks.sortedWith(
            compareByDescending<DidaTask> { it.priority }
                .thenBy { it.date?.take(10) ?: "9999-99-99" }
                .thenBy { it.createdAt ?: 0L },
        )
        val cap = maxOf(perDay, 1)
        val items = ArrayList<Item>()
        val leftover = ArrayList<DidaTask>()
        for (t in sorted) {
            var placed = false
            for (i in 0..HORIZON_DAYS) {
                val d = first.plusDays(i.toLong())
                if (skipWeekends && isWeekend(d)) continue
                if ((load[d] ?: 0) < cap) {
                    load[d] = (load[d] ?: 0) + 1
                    items += Item(t, d.toString())
                    placed = true
                    break
                }
            }
            if (!placed) leftover += t
        }
        return Plan(items, leftover)
    }
}

/** 从标题里认出「第 N 章」这类序号：同一本书 / 课程（标签或项目相同）的同一种单位算一个系列 */
internal object Series {
    private const val UNIT = "章|节|讲|课|篇|回|集|话|部分|单元|周|卷|册|期"
    private val CN = mapOf('零' to 0, '一' to 1, '二' to 2, '两' to 2, '三' to 3, '四' to 4, '五' to 5, '六' to 6, '七' to 7, '八' to 8, '九' to 9)
    private val VERBS = listOf("阅读", "精读", "泛读", "学习", "复习", "预习", "整理", "看", "读", "刷", "做", "完成")
    private val PATTERNS = listOf(
        Regex("(.*?)第\\s*([0-9]+|[零一二两三四五六七八九十百]+)\\s*($UNIT)"),
        Regex("(?i)(.*?)\\b(?:chapter|ch\\.?|lesson|part|day|week|unit|episode|ep\\.?)\\s*([0-9]+)()"),
    )

    class Key(val key: String, val n: Int)

    fun parse(t: DidaTask): Key? {
        val title = cleanTitle(t.title)
        for (re in PATTERNS) {
            val m = re.find(title) ?: continue
            val prefix = m.groupValues[1].trim()
            val unit = m.groupValues[3].ifEmpty { "x" }
            val n = number(m.groupValues[2]) ?: continue
            val scope = if (t.tags.isNotEmpty()) {
                t.tags.sorted().joinToString(",")
            } else {
                // 没有标签：用前缀（去掉「阅读 / 精读 / 学习」这类动词）加清单区分
                var s = prefix
                for (v in VERBS) if (s.startsWith(v)) s = s.removePrefix(v)
                s.trim() + "@" + t.projectId
            }
            return Key("$unit|$scope", n)
        }
        return null
    }

    private fun number(s: String): Int? {
        s.toIntOrNull()?.let { return it }
        var total = 0
        var cur = 0
        for (c in s) {
            val d = CN[c]
            when {
                d != null -> cur = d
                c == '十' -> { total += (if (cur == 0) 1 else cur) * 10; cur = 0 }
                c == '百' -> { total += (if (cur == 0) 1 else cur) * 100; cur = 0 }
            }
        }
        total += cur
        return if (total > 0) total else null
    }
}

/** 旧版本写在标题里的 `!重要` `!紧急` 标记不显示 */
internal fun cleanTitle(title: String): String {
    if (!title.contains('!') && !title.contains('！')) return title
    val c = title.replace(Regex("\\s*[!！]重要"), "").replace(Regex("\\s*[!！]紧急"), "").trim()
    return c.ifEmpty { title }
}
