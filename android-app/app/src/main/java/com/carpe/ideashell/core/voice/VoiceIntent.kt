package com.carpe.ideashell.core.voice

import com.carpe.ideashell.core.parse.CaptureKind
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.TextStyle
import java.util.Locale

/** 大模型对一句语音的整理结果。日期 / 时间由模型按「当前时间 + 日历」推算，本地只做格式校验。 */
data class VoiceIntent(
    val type: CaptureKind,
    /** 去口语后的正文；待办里已经不含日期、时间、重复周期的说法 */
    val content: String,
    val date: LocalDate?,
    val time: LocalTime?,
    /** 重复说法原文（「每周一」），交给 RepeatParser 转成规则；不重复为 null */
    val repeat: String?,
    val tags: List<String>,
    /** 0 无 / 1 低 / 3 中 / 5 高（与滴答一致） */
    val priority: Int,
    /** 这是一句要问闪念贝壳 AI 的话（「帮我查一下…」）：[content] 是整理好的问题，不存成记录 */
    val ask: Boolean = false,
)

/** 一次语音输入的完整结果 */
data class VoiceResult(
    /** 语音识别出的原文 */
    val raw: String,
    /** 只做了本地规则清洗的文字（没有大模型 / 大模型失败时用它） */
    val cleaned: String,
    /** 大模型整理结果：一句话里说了几件事就有几项；没开 / 失败为空 */
    val intents: List<VoiceIntent>,
    /** 大模型整理失败的原因（给用户一句提示）；没失败为 null */
    val polishError: String? = null,
)

object VoiceIntents {
    private val WEEKDAY = Locale.CHINA

    /** 系统提示：当前时间 + 未来三周日历（模型算星期几容易错，直接给表） + 输出格式 */
    fun systemPrompt(now: LocalDateTime, vocabulary: List<String> = emptyList(), zone: ZoneId = ZoneId.systemDefault()): String {
        val today = now.toLocalDate()
        val calendar = (0..20).joinToString("；") { i ->
            val d = today.plusDays(i.toLong())
            val tag = when (i) {
                0 -> "今天"
                1 -> "明天"
                2 -> "后天"
                else -> ""
            }
            "${d}（${d.dayOfWeek.getDisplayName(TextStyle.SHORT, WEEKDAY)}${if (tag.isEmpty()) "" else "，$tag"}）"
        }
        val vocab = if (vocabulary.isEmpty()) "" else
            "\n用户的常用词（项目名、专有名词）：${vocabulary.take(60).joinToString("、")}。转写里读音相近的错字请改成这些词，原本就对的不要乱改。\n"
        return """
你是语音记事助手。用户用语音说了一句话，下面会给出语音转写文字（可能有同音错字、口语、重复）。请判断用户的意图、整理，并只输出一个 JSON 对象，不要输出任何别的文字。

现在是 ${today} ${today.dayOfWeek.getDisplayName(TextStyle.FULL, WEEKDAY)} ${"%02d:%02d".format(now.hour, now.minute)}（时区 ${zone.id}，按中国日历）。
未来三周日历：$calendar。$vocab
推算日期以这份日历为准（「下周三」= 下一个周一所在那周的周三；「周五」= 本周还没到的最近一个周五，本周已过则取下周）。月底、节日、「N 天后」请自行推算。

输出格式：{"items":[{...},{...}]}。items 是数组，一句话里有几个互相独立的意图就输出几项，每项按下面的字段整理：
- 拆分规则：只有明显是「不同的事」才拆，例如「明天上午开会，下午交周报」是两个待办；同一件事的补充说明、同一段想法 / 心情不要拆，仍然是一项。每项要自成一句、能单独看懂（必要时把共同的人名 / 地点补进去）；每项各自推算 date / time；不同类型可以混在一起。最多 8 项。

每一项的字段：
- type："todo" | "daily" | "note" | "ask"，四种意图要分清：
  - ask（问 AI）：用户是在让 AI 查资料、回答问题、分析、解释、总结、翻译、出主意，常见说法「帮我查一下 / 搜一下 / 问一下 AI / 帮我看看 / X 是什么 / 怎么 X / 为什么 / 帮我分析 / 帮我总结」。content 写成整理后的完整问题。注意「提醒我去查…」「记得查…」是 todo，不是 ask。
  - todo（待办）：用户要去做的一件具体的事——需要在将来做，或明确说了「提醒我 / 待办 / 记得 / 别忘了 / 要去 / 得去」。已经做完的事不是 todo。带不带时间都行。
  - note（笔记）：只有用户明确说了「记成笔记 / 记个笔记 / 做个笔记 / 笔记：/ 存为笔记 / 摘录」之类的话才用。没有这类明确说法时，绝对不要用 note，哪怕内容像知识、想法、摘抄也选 daily。这句口令本身不要写进正文。
  - daily（日记）：除上面三种以外的一切，也是默认选项——今天发生的事、心情、感想、流水账、已经做完的事、随口的一个想法、没头没尾的一句话。用户说了「记个日记 / 写进日记」也是 daily。
  拿不准时选 daily。
- content：整理后的正文。去掉「嗯、呃、那个、就是」这类语气词和重复；自我纠正取最后说的（「明天，不对，后天」→ 后天）；修正明显的同音错字；加合适的标点。保留原意和人称，不要扩写、不要总结、不要回答问题（ask 除外：ask 只整理问题本身，不要自己回答）。
- 待办的任务逻辑（type 为 todo 时）：
  - content 是一句简短的任务名，动词开头（「给张三回电话」「交周报」），去掉日期、时间、重复周期、「提醒我」这些说法（它们放进 date / time / repeat）。
  - 只说了「X 前 / 之前 / 截止」是截止日期：date 填那一天；说了「下午五点前」time 填 17:00；不要自己再减去提前量。
  - 只说了「先 A 再 B」「A 之后 B」：拆成两个待办，保持先后顺序，没有说具体时间就不要编造时间。
  - 一个目标下的几个小步骤如果是同一个人连续做的（如「整理资料写进报告」）合成一条；彼此独立、时间不同的才拆开。
  - 完全没说时间的待办，date 和 time 都是 null，不要默认填今天。
  - 说了重要 / 紧急才填优先级，别自己猜。
- date：todo 的日期，格式 yyyy-MM-dd。没说日期但说了具体时间点：取最近一个还没到的那一刻所在的日期（今天这个点已经过了就是明天）。日期和时间都没说为 null。其他类型一律 null。
- time：todo 的时间，24 小时制 HH:mm；没说具体几点为 null。只说了时段时：凌晨 03:00、早上 07:00、上午 09:00、中午 12:00、下午 14:30、傍晚 17:00、晚上 20:00（「今晚」= 今天晚上）。「八点半」这类没说上午下午的，按生活常理判断，说了「晚」「夜」一定是晚上。
- repeat：重复说法原文，如 "每周一"、"每天"、"每月1号"、"每两周"；不重复为 null。有重复说法时，date 填第一次发生的日期。
- tags：用户明确说了「标签 xxx」「井号 xxx」时的标签数组（不带 #）；否则 []。
- priority：说了「重要 / 紧急 / 高优先级」填 5；「中优先级」填 3；「低优先级」填 1；否则 0。

示例（假设今天是 2026-10-18 周日 10:58）：
输入：嗯那个今晚八点半提醒我给张三回电话
输出：{"items":[{"type":"todo","content":"给张三回电话","date":"2026-10-18","time":"20:30","repeat":null,"tags":[],"priority":0}]}
输入：今天下午和客户开了会，感觉对方挺有兴趣的
输出：{"items":[{"type":"daily","content":"今天下午和客户开了会，感觉对方挺有兴趣的。","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：突然想到可以把每周复盘放到周日晚上
输出：{"items":[{"type":"daily","content":"突然想到可以把每周复盘放到周日晚上。","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：记个笔记，复利就是利滚利，时间越长差距越大
输出：{"items":[{"type":"note","content":"复利就是利滚利，时间越长差距越大。","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：帮我查一下格雷厄姆的安全边际是什么意思
输出：{"items":[{"type":"ask","content":"格雷厄姆说的「安全边际」是什么意思？","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：明天上午九点开周会，然后下午三点去取快递，还有每周五要交周报
输出：{"items":[{"type":"todo","content":"开周会","date":"2026-10-19","time":"09:00","repeat":null,"tags":[],"priority":0},{"type":"todo","content":"去取快递","date":"2026-10-19","time":"15:00","repeat":null,"tags":[],"priority":0},{"type":"todo","content":"交周报","date":"2026-10-23","time":null,"repeat":"每周五","tags":[],"priority":0}]}
输入：周五前把报告交了，另外帮我查一下报告模板
输出：{"items":[{"type":"todo","content":"交报告","date":"2026-10-23","time":null,"repeat":null,"tags":[],"priority":0},{"type":"ask","content":"有哪些常用的报告模板？","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
        """.trimIndent()
    }

    /** 用户消息：就是转写原文 */
    fun userPrompt(raw: String): String = "语音转写：$raw"

    private val RE_TIME = Regex("^\\s*(\\d{1,2})[:：](\\d{2})")

    /**
     * 解析模型回复，得到一项或多项；不是合法 JSON / 没有可用的项返回空列表。
     * 兼容两种格式：`{"items":[…]}` 和单个对象 `{…}`。
     */
    fun parse(reply: String): List<VoiceIntent> {
        val start = reply.indexOf('{')
        val end = reply.lastIndexOf('}')
        if (start < 0 || end <= start) return emptyList()
        val root = try {
            Json.parseToJsonElement(reply.substring(start, end + 1)).jsonObject
        } catch (_: Exception) {
            return emptyList()
        }
        val items = (root["items"] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: listOf(root)
        return items.take(MAX_ITEMS).mapNotNull(::parseOne)
    }

    private const val MAX_ITEMS = 8

    private fun parseOne(obj: JsonObject): VoiceIntent? {
        val content = obj.string("content")?.trim().orEmpty()
        if (content.isEmpty()) return null
        val rawType = obj.string("type")?.trim()?.lowercase()
        // 问 AI：不是记录，type 随便占个位（DAILY），靠 ask 标志区分
        val ask = rawType == "ask"
        val type = when (rawType) {
            "todo" -> CaptureKind.TODO
            "daily", "ask" -> CaptureKind.DAILY
            "note" -> CaptureKind.NOTE
            else -> return null
        }

        val todo = type == CaptureKind.TODO
        val date = if (todo) obj.string("date")?.trim()?.let { runCatching { LocalDate.parse(it) }.getOrNull() } else null
        val time = if (todo) {
            obj.string("time")?.let { RE_TIME.find(it) }?.let { m ->
                runCatching { LocalTime.of(m.groupValues[1].toInt(), m.groupValues[2].toInt()) }.getOrNull()
            }
        } else null
        val repeat = if (todo) obj.string("repeat")?.trim()?.takeIf { it.isNotEmpty() && !it.equals("null", true) } else null
        val tags = (obj["tags"] as? JsonArray).orEmpty()
            .mapNotNull { (it as? JsonPrimitive)?.contentOrNull?.trim()?.removePrefix("#") }
            .filter { it.isNotEmpty() && it.none(Char::isWhitespace) }
            .take(5)
        val priority = when ((obj["priority"] as? JsonPrimitive)?.intOrNull ?: 0) {
            in 5..Int.MAX_VALUE -> 5
            in 3..4 -> 3
            in 1..2 -> 1
            else -> 0
        }
        return VoiceIntent(type, content, date, time, repeat, tags, if (todo) priority else 0, ask)
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
}
