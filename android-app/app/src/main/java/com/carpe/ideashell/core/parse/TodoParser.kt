package com.carpe.ideashell.core.parse

import java.time.LocalDate
import java.time.LocalDateTime

data class ParsedTodo(
    val content: String,
    /** yyyy-MM-dd */
    val date: String? = null,
    /** HH:mm */
    val time: String? = null,
)

/**
 * 待办自然语言日期 / 时间解析，行为与桌面插件 `todo-parse.ts` 保持一致：
 * 「明天 15:00 开会」「下周五下午3点半 交周报」「10月9日 买票」。
 * 识别到的日期 / 时间会从内容里移除；只有时间没有日期时默认今天。
 */
object TodoParser {
    private val WEEKDAY_INDEX = mapOf('一' to 0, '二' to 1, '三' to 2, '四' to 3, '五' to 4, '六' to 5, '日' to 6, '天' to 6)

    private val RE_ISO = Regex("([0-9]{4})[-/.]([0-9]{1,2})[-/.]([0-9]{1,2})")
    private val RE_MONTH_DAY = Regex("([0-9]{1,2})月([0-9]{1,2})[日号]?")
    private val RE_RELATIVE = Regex("大后天|后天|明天|明日|今天|今日")
    private val RE_WEEKDAY = Regex("(下下|下)?(?:周|星期|礼拜)([一二三四五六日天])")

    private const val PERIOD = "(凌晨|早上|早晨|上午|中午|下午|晚上|傍晚)?\\s*"
    private val RE_TIME_COLON = Regex("$PERIOD([0-9]{1,2})[:：]([0-9]{2})")
    private val RE_TIME_DIAN = Regex("$PERIOD([0-9]{1,2})\\s*[点時时](?:\\s*(半)|\\s*([0-9]{1,2})\\s*分?)?")

    private val RE_SPACES = Regex("\\s+")
    private val RE_EDGE_PUNCT = Regex("^[\\s,，、:：;；\\-—]+|[\\s,，、:：;；\\-—]+\$")
    private val RE_LEADING_PREP = Regex("^(?:在|于|到)\\s*")

    fun parse(input: String, now: LocalDateTime = LocalDateTime.now()): ParsedTodo {
        val today = now.toLocalDate()
        var text = input.trim()
        var date: String? = null
        var time: String? = null

        matchDate(text, today)?.let { (d, hit) ->
            date = d
            text = text.replaceFirst(hit, " ")
        }
        matchTime(text)?.let { (t, hit) ->
            time = t
            text = text.replaceFirst(hit, " ")
        }
        if (time != null && date == null) date = today.toString()

        val content = text
            .replace(RE_SPACES, " ")
            .replace(RE_EDGE_PUNCT, "")
            .replace(RE_LEADING_PREP, "")
            .trim()

        return ParsedTodo(content.ifEmpty { input.trim() }, date, time)
    }

    /** 依次尝试识别日期，返回 (yyyy-MM-dd, 命中的原文)；识别不到返回 null */
    private fun matchDate(text: String, today: LocalDate): Pair<String, String>? {
        RE_ISO.find(text)?.let { m ->
            val date = safeDate(m.groupValues[1].toInt(), m.groupValues[2].toInt(), m.groupValues[3].toInt())
            if (date != null) return date.toString() to m.value
        }

        // 10月9日 / 10月9号：已过则按明年
        RE_MONTH_DAY.find(text)?.let { m ->
            val month = m.groupValues[1].toInt()
            val day = m.groupValues[2].toInt()
            var date = safeDate(today.year, month, day)
            if (date != null && date.isBefore(today)) date = safeDate(today.year + 1, month, day)
            if (date != null) return date.toString() to m.value
        }

        RE_RELATIVE.find(text)?.let { m ->
            val offset = when (m.value) {
                "今天", "今日" -> 0L
                "明天", "明日" -> 1L
                "后天" -> 2L
                else -> 3L // 大后天
            }
            return today.plusDays(offset).toString() to m.value
        }

        // 周X / 下周X / 下下周X
        RE_WEEKDAY.find(text)?.let { m ->
            val weeks = when (m.groups[1]?.value) {
                "下下" -> 2L
                "下" -> 1L
                else -> 0L
            }
            val weekdayIdx = WEEKDAY_INDEX[m.groupValues[2][0]] ?: return@let
            val todayIdx = today.dayOfWeek.value - 1 // 周一 = 0
            val monday = today.minusDays(todayIdx.toLong())
            var target = monday.plusDays(weekdayIdx + weeks * 7)
            if (weeks == 0L && target.isBefore(today)) target = target.plusDays(7) // 本周已过 → 下一次
            return target.toString() to m.value
        }
        return null
    }

    /** 识别时间：15:30 / 下午3点 / 3点半 / 晚上8点15分，返回 (HH:mm, 命中的原文) */
    private fun matchTime(text: String): Pair<String, String>? {
        val period: String?
        var hour: Int
        val minute: Int
        val hit: String

        val colon = RE_TIME_COLON.find(text)
        if (colon != null) {
            period = colon.groups[1]?.value
            hour = colon.groupValues[2].toInt()
            minute = colon.groupValues[3].toInt()
            hit = colon.value
        } else {
            val dian = RE_TIME_DIAN.find(text) ?: return null
            period = dian.groups[1]?.value
            hour = dian.groupValues[2].toInt()
            minute = when {
                dian.groups[3] != null -> 30
                dian.groups[4] != null -> dian.groupValues[4].toInt()
                else -> 0
            }
            hit = dian.value
        }

        if ((period == "下午" || period == "晚上" || period == "傍晚") && hour < 12) hour += 12
        if (period == "中午" && hour < 11) hour += 12
        if (hour > 23 || minute > 59) return null

        return "%02d:%02d".format(hour, minute) to hit
    }

    private fun safeDate(year: Int, month: Int, day: Int): LocalDate? =
        try {
            LocalDate.of(year, month, day)
        } catch (_: Exception) {
            null
        }
}
