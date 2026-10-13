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

    /** 阿拉伯数字或中文数字（一 ~ 九十九） */
    private const val N = "(?:[0-9]{1,2}|[零〇一二三四五六七八九十两]{1,3})"

    private val RE_ISO = Regex("([0-9]{4})[-/.]([0-9]{1,2})[-/.]([0-9]{1,2})")
    // 3/6、03/06、3-6、03-06
    private val RE_SLASH_DATE = Regex("(?<![0-9/\\-.:：])([0-9]{1,2})[/\\-]([0-9]{1,2})(?![0-9/\\-.:：])")
    // 3月6日、三月六日（中文数字的日必须带「日 / 号」，免得「三月一起去」被当成 3 月 1 日）
    private val RE_MONTH_DAY = Regex("($N)月\\s*($N)[日号]")
    // 3月6（没写「日」，只认阿拉伯数字）
    private val RE_MONTH_DAY_BARE = Regex("([0-9]{1,2})月\\s*([0-9]{1,2})(?![0-9点時时:：])")
    // 3月 / 三月 / 3月份：当月 1 号
    private val RE_MONTH = Regex("($N)月份?")
    private val RE_RELATIVE = Regex("大后天|后天|明天|明日|今天|今日")
    private val RE_WEEKDAY = Regex("(下下|下)?(?:周|星期|礼拜)([一二三四五六日天])")

    private const val PERIOD = "(凌晨|早上|早晨|上午|中午|下午|晚上|傍晚)?\\s*"
    private val RE_TIME_COLON = Regex("$PERIOD([0-9]{1,2})[:：]([0-9]{2})")
    // 3点 / 九点 / 3点半 / 3点15分 / 九点十五分
    private val RE_TIME_DIAN = Regex("$PERIOD($N)\\s*[点時时](?:\\s*(半)|\\s*([0-9]{1,2})\\s*分?|\\s*([零〇一二三四五六七八九十]{1,3})分)?")
    // 只说了时段：早上 / 上午 / 中午 / 下午 / 傍晚 / 晚上
    private val RE_PERIOD_ONLY = Regex("(凌晨|早上|早晨|上午|中午|下午|晚上|傍晚)(?![茶饭餐])")

    /** 只说时段时的默认时间 */
    private val PERIOD_DEFAULT = mapOf(
        "凌晨" to "03:00",
        "早上" to "07:00",
        "早晨" to "07:00",
        "上午" to "09:00",
        "中午" to "12:00",
        "下午" to "14:30",
        "傍晚" to "17:00",
        "晚上" to "20:00",
    )

    private val CN_DIGIT = mapOf(
        '零' to 0, '〇' to 0, '一' to 1, '二' to 2, '两' to 2, '三' to 3, '四' to 4,
        '五' to 5, '六' to 6, '七' to 7, '八' to 8, '九' to 9,
    )

    /** 「12」「九」「十二」「二十三」→ 数字；认不出返回 null */
    private fun num(s: String): Int? {
        s.toIntOrNull()?.let { return it }
        if (s.isEmpty()) return null
        val ten = s.indexOf('十')
        if (ten < 0) return if (s.length == 1) CN_DIGIT[s[0]] else null
        val head = s.substring(0, ten)
        val tail = s.substring(ten + 1)
        val tens = when {
            head.isEmpty() -> 1
            head.length == 1 -> CN_DIGIT[head[0]] ?: return null
            else -> return null
        }
        val ones = when {
            tail.isEmpty() -> 0
            tail.length == 1 -> CN_DIGIT[tail[0]] ?: return null
            else -> return null
        }
        return tens * 10 + ones
    }

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
        // 只有时间没有日期：取最近有效的那一刻——今天这个点还没到就是今天，已过就是明天
        if (time != null && date == null) {
            val t = java.time.LocalTime.parse(time)
            date = (if (t.isAfter(now.toLocalTime())) today else today.plusDays(1)).toString()
        }

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

        // 10月9日 / 十月九日 / 10月9：已过则按明年（最近有效的那一天）
        for (re in listOf(RE_MONTH_DAY, RE_MONTH_DAY_BARE)) {
            re.find(text)?.let { m ->
                val month = num(m.groupValues[1])
                val day = num(m.groupValues[2])
                if (month != null && day != null) {
                    val date = nearestDate(today, month, day)
                    if (date != null) return date.toString() to m.value
                }
            }
        }

        // 3/6、03/06、3-6、03-06
        RE_SLASH_DATE.find(text)?.let { m ->
            val date = nearestDate(today, m.groupValues[1].toInt(), m.groupValues[2].toInt())
            if (date != null) return date.toString() to m.value
        }

        // 3月 / 三月：最近一个 3 月的第一天
        RE_MONTH.find(text)?.let { m ->
            val month = num(m.groupValues[1])
            if (month != null) {
                val date = nearestDate(today, month, 1)
                if (date != null) return date.toString() to m.value
            }
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
            val dian = RE_TIME_DIAN.find(text)
            if (dian == null) {
                // 只说了时段（「下午」「晚上」…）：用该时段的默认时间
                val only = RE_PERIOD_ONLY.find(text) ?: return null
                return (PERIOD_DEFAULT[only.groupValues[1]] ?: return null) to only.value
            }
            period = dian.groups[1]?.value
            hour = num(dian.groupValues[2]) ?: return null
            minute = when {
                dian.groups[3] != null -> 30
                dian.groups[4] != null -> dian.groupValues[4].toInt()
                dian.groups[5] != null -> num(dian.groupValues[5]) ?: return null
                else -> 0
            }
            hit = dian.value
            // 「一点东西」「买一点」不是 1 点：中文的「一点」没有时段、也没有半 / 分时不当作时间
            val chinese = dian.groupValues[2].toIntOrNull() == null
            if (chinese && period == null && hour == 1 && dian.groups[3] == null && dian.groups[4] == null && dian.groups[5] == null) {
                return null
            }
        }

        if ((period == "下午" || period == "晚上" || period == "傍晚") && hour < 12) hour += 12
        if (period == "中午" && hour < 11) hour += 12
        if (hour > 23 || minute > 59) return null

        return "%02d:%02d".format(hour, minute) to hit
    }

    /** 今年的 month 月 day 日；已经过去就取明年的（最近有效） */
    private fun nearestDate(today: LocalDate, month: Int, day: Int): LocalDate? {
        val date = safeDate(today.year, month, day) ?: return null
        return if (date.isBefore(today)) safeDate(today.year + 1, month, day) else date
    }

    private fun safeDate(year: Int, month: Int, day: Int): LocalDate? =
        try {
            LocalDate.of(year, month, day)
        } catch (_: Exception) {
            null
        }
}
