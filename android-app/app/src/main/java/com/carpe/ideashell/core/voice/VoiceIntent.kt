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

/** 对「之前已经建好的待办」能做的几件事 */
enum class TodoOp(val label: String) {
    EDIT("改待办"),
    COMPLETE("完成待办"),
    DELETE("删除待办"),
    QUERY("查待办"),
}

/** 对 App 本身下的指令（不是要记录的内容）：本地直接执行，不存成记录 */
enum class VoiceCmd(val key: String, val label: String) {
    LONG_RECORD("long_record", "长录音"),
    NEW_NOTE("new_note", "新建笔记"),
    OPEN_AI("open_ai", "闪念贝壳 AI"),
}

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
    /** 用户说了「追加到上一条笔记」：[content] 是要追加的内容，保存时接到最近一次快记的笔记后面（类型固定为笔记） */
    val append: Boolean = false,
    /** 修改之前建好的待办：[target] 是找到它的关键词（可为空 = 刚才建的那条），[content] 是要追加到备注的说明（可为空），date / time / priority 是要改成的新值（null / 0 = 不改） */
    val edit: Boolean = false,
    val target: String? = null,
    /** [edit] 为 true 时具体做什么：改 / 完成 / 删除 / 查询（查询没有「目标」，[target] 是可选的关键词，[range] 是范围） */
    val op: TodoOp = TodoOp.EDIT,
    /** 查询范围：today / tomorrow / week / overdue / all（默认 today） */
    val range: String? = null,
    /** 这是一句对 App 的指令（「开始长录音」）：不存成记录，由界面直接执行 */
    val cmd: VoiceCmd? = null,
    /** 这是一句「找一下已有的东西」：note / todo / all；[target] 是关键词。本地查完直接列出来，不调 AI */
    val searchScope: String? = null,
    /** 搜索的时间范围终点（含，yyyy-MM-dd）；起点放在 [date]。都为 null = 不限时间 */
    val until: LocalDate? = null,
    /** 这是一个要用「我自己的记录」回答的问题（「我昨天做了哪些事」）：[content] 是整理好的完整问题，交给语音助手查数据后回答，不存成记录 */
    val answer: Boolean = false,
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
    /** 没经过大模型、但本地规则听出了「追加到上一条笔记」：[cleaned] 已经去掉了这句口令 */
    val appendToLast: Boolean = false,
    /** 说的是对 App 的指令（长录音 / 新建笔记 / 打开 AI）：不整理、不保存，丢掉这段直接执行 */
    val command: VoiceCmd? = null,
)

object VoiceIntents {
    private val WEEKDAY = Locale.CHINA

    /**
     * 整句话就是「长录音」口令（「长录音」「开始长录音」「帮我开个长录音」）。
     * 去掉标点空格后不超过 [LONG_RECORD_MAX_LEN] 个字才算：一条正常笔记里顺带提到「长录音」不会被当成口令。
     */
    fun isLongRecordCommand(raw: String): Boolean {
        val s = raw.filter { it.isLetterOrDigit() }
        return s.length <= LONG_RECORD_MAX_LEN && s.contains("长录音")
    }

    private const val LONG_RECORD_MAX_LEN = 10

    /** 系统提示：当前时间 + 未来三周日历（模型算星期几容易错，直接给表） + 输出格式 */
    fun systemPrompt(
        now: LocalDateTime,
        vocabulary: List<String> = emptyList(),
        todos: List<String> = emptyList(),
        zone: ZoneId = ZoneId.systemDefault(),
        skills: List<String> = emptyList(),
    ): String {
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
        val todoCtx = if (todos.isEmpty()) "" else
            "\n用户目前未完成的待办（每行「任务名｜日期 时间」，供你判断「改 / 完成 / 删除 / 推迟 / 查询」指的是哪一条，并据此推算「推迟一小时」「往后挪两天」这类相对说法；新建待办不要照抄它们；转写里读音相近的人名、项目名可以参考它们修正）：\n" +
                todos.take(40).joinToString("\n") { "· $it" } + "\n"
        val skillCtx = if (skills.isEmpty()) "" else
            "\n快捷指令：用户存了这些快捷指令：${skills.take(30).joinToString("、") { "「$it」" }}。用户说出其中任何一个的名字（或「执行 / 运行 / 开始 X」「X 模式」）就是 answer，content 写成「执行快捷指令「X」」；不要把它当成待办或笔记。另外「把刚才这些存成快捷指令」「以后我说下班就帮我……」这类**保存**快捷指令的话也是 answer，content 保留用户原话。\n"
        return """
你是语音记事助手。用户用语音说了一句话，下面会给出语音转写文字（可能有同音错字、口语、重复）。请判断用户的意图、整理，并只输出一个 JSON 对象，不要输出任何别的文字。

现在是 ${today} ${today.dayOfWeek.getDisplayName(TextStyle.FULL, WEEKDAY)} ${"%02d:%02d".format(now.hour, now.minute)}（时区 ${zone.id}，按中国日历）。
未来三周日历：$calendar。$vocab$todoCtx$skillCtx
推算日期以这份日历为准（「下周三」= 下一个周一所在那周的周三；「周五」= 本周还没到的最近一个周五，本周已过则取下周）。月底、节日、「N 天后」请自行推算。

如果用户消息开头带有「最近对话」，那是这几分钟内的上下文，只用来理解「那个 / 刚才 / 它们 / 再 / 也」这类指代：把指代补成具体名字再填 target / content（例如上一轮改了「交周报」，这一轮说「再推迟一天」，target 就填「周报」）；绝不能把「最近对话」里的内容当成这次要记录的话，也不要重复执行上一轮的事。

输出格式：{"items":[{...},{...}]}。items 是数组，一句话里有几个互相独立的意图就输出几项，每项按下面的字段整理：
- 拆分规则：只有明显是「不同的事」才拆，例如「明天上午开会，下午交周报」是两个待办；同一件事的补充说明、同一段想法 / 心情不要拆，仍然是一项。每项要自成一句、能单独看懂（必要时把共同的人名 / 地点补进去）；每项各自推算 date / time；不同类型可以混在一起。最多 8 项。

每一项的字段：
- type："cmd" | "search" | "answer" | "todo" | "daily" | "note" | "ask"，七种意图要分清（先看是不是 cmd / search / answer，再看后四种）：
  - cmd（指令）：用户是在**命令这个 App 做一个操作**，而不是在说一段要记录的内容。content 填 ""，用 cmd 字段说明做什么：
    - "long_record"：开始长录音 / 「记录为长录音」「帮我把接下来的内容记成长录音」「开个长录音」「我要录一段长的」（用闪念贝壳自己的录音页）。口令后面如果还带了内容，一律丢掉，只执行指令。
    - "new_note"：打开空白笔记编辑器手打一条（「我要手写一条笔记」「新建一个文字笔记」），注意「记个笔记，复利是…」带了正文的是 note，不是 cmd。
    - "open_ai"：只想打开闪念贝壳 AI 对话、没有具体问题（「打开 AI」「我想和 AI 聊聊」）；有具体问题的是 ask。
    句子里出现「长录音」「新建笔记」这类词，要先判断是不是在下指令：是指令就 cmd，只是在叙述一件事（「昨天的长录音还没整理」）才不是。
  - search（找已有的记录，只列清单，不分析）：「找一下关于招聘的笔记」「搜一下预算」「我有没有记过装修的事」「列出和周报相关的待办」。target 填关键词（去掉「相关 / 关于 / 的笔记」和时间说法，只留要找的主题词；没有主题、只问某段时间做了什么 / 记了什么时填 ""，一定要带上时间范围），scope 填 "note"（说了笔记 / 记录）/ "todo"（说了待办 / 任务）/ "all"（没限定）。说了时间范围（「最近一周」「这个月」「昨天」「上周」）就按日历推算成 since / until（yyyy-MM-dd，含首尾；「最近一周」= 今天往前 6 天到今天；没说时间都填 null）。content 填 ""。要 AI 帮忙总结 / 分析 / 回答的是 ask，不是 search；按日期查待办（「今天还有什么没做」）仍然用 edit 的 query。
  - answer（语音助手：查我自己的记录再回答，或做专注计时操作）：问题的答案就在用户自己的待办 / 笔记 / 专注记录里，要查完再用几句话回答或统计；或者要助手替他办一件事：开始 / 暂停 / 继续 / 结束专注计时（「开始对今天的第一个任务进行专注」「结束专注」）；记住 / 忘掉一件事（「记住我周三不开会」「老张是我同事」「忘掉我刚才让你记的」）；设定时 / 条件任务或查看、取消它们（「每天早上八点告诉我今天的待办和日历」「有逾期待办超过三个就提醒我」「把早上那个任务暂停」）；设系统闹钟 / 倒计时（「定个明早七点的闹钟」「倒计时十分钟」，注意没说「闹钟 / 倒计时」的「提醒我明天九点开会」是 todo）；打电话、导航、控制音乐（「给老张打电话」「导航到杭州东站」「暂停音乐」「下一首」）；控制手机（「开启勿扰模式」「勿扰一小时」「调成静音 / 震动」「音量调到一半」「亮度调低一点」「打开手电筒」「打开微信」「打开蓝牙 / WLAN」「回到桌面」「截个屏」）；控制家里的智能设备（米家等：「打开客厅的灯」「空调调到 26 度」「关掉所有灯」「回家模式」「卧室温度多少」）；存下快捷指令（「把刚才这些存成快捷指令，叫下班」「以后我说下班就帮我开勿扰、调静音」，content 保留用户原话）或叫出已存的快捷指令（存了的话会在后面「快捷指令」里列出）；**所有针对屏幕内容的请求**——不管是操作（「这页的要点记成笔记」）还是提问（「总结一下这一页」「这篇文章讲了什么」「这段翻译一下」「这页关于伽利略的描述对不对，再介绍下他的生平」）——都是 answer，助手会自己读屏幕（读不到文字时自动截屏识别）并直接回答，不要转给 ask。注意这些都是对助手的请求，不是 todo / daily；单纯的重复提醒（「每周五提醒我交周报」）仍是 todo + repeat，不是任务。查询类例子：「我昨天做了哪些事情」「今天完成了几个待办」「这周专注了多久」「我最近记了哪些关于书法的内容，帮我总结一下」「哪个任务最花时间」「明天有什么要紧的」。content 写成**完整、能单独看懂的问题 / 请求**（把「那个 / 它 / 刚才」按最近对话补全，时间说法保留原样，如「昨天」「最近一周」）。只想要清单、不要回答（「找一下 / 列出 / 搜一下」）是 search；要外部知识、深度分析、大范围梳理（「帮我分析三个月的笔记」「X 是什么」）是 ask。
  - ask（问 AI）：用户是在让 AI 查资料、回答问题、分析、解释、总结、翻译、出主意，常见说法「帮我查一下 / 搜一下 / 问一下 AI / 帮我看看 / X 是什么 / 怎么 X / 为什么 / 帮我分析 / 帮我总结」。content 写成整理后的完整问题，多个问题合成一条 ask，不要拆开。**但只要问题是针对眼前屏幕内容的（说到「这页 / 这段 / 这篇 / 书中 / 屏幕上 / 这张图」），不是 ask，是 answer。**注意「提醒我去查…」「记得查…」是 todo，不是 ask。
  - todo（待办）：用户要去做的一件具体的事——需要在将来做，或明确说了「提醒我 / 待办 / 记得 / 别忘了 / 要去 / 得去」。已经做完的事不是 todo。带不带时间都行。
  - note（笔记）：只有用户明确说了「记成笔记 / 记个笔记 / 做个笔记 / 笔记：/ 存为笔记 / 摘录」之类的话才用。没有这类明确说法时，绝对不要用 note，哪怕内容像知识、想法、摘抄也选 daily。这句口令本身不要写进正文。
  - daily（日记）：除上面三种以外的一切，也是默认选项——今天发生的事、心情、感想、流水账、已经做完的事、随口的一个想法、没头没尾的一句话。用户说了「记个日记 / 写进日记」也是 daily。
  拿不准时选 daily；但对 App 说的指令、找东西的请求、向我提问的请求绝对不能当成 daily 存起来。
- append：true / false，默认 false。用户说了「追加到上一条笔记 / 上个笔记 / 上一篇 / 刚才那条」「接着上一条写」「补充到上一条」这类话，就是想把这段话接到最近一条笔记后面：append 填 true，type 填 note，content 只写要追加的内容（口令本身不要写进去）。没说这类话一律 false。append 和 ask 不会同时出现。
- edit：true / false，默认 false。用户要对**之前已经建好的待办**做操作（而不是新建）：修改、完成、删除、查询。这时 type 填 todo，edit 填 true，用 op 说明做什么：
  - op = "edit"（改时间 / 补充备注 / 改优先级）：「把刚才的会改到两点四十」「开会那个待办补充一下，带上办公电脑」「把交周报那个推迟到周五」「开会那个往后推一小时」。
    - content：要补充进这条待办**备注**的说明（如「带上办公电脑」），没有补充就填 ""。不是任务名，不要把任务名放这里。
    - date / time：要改成的新日期 / 新时间，**只填用户明确说了要改的**，没说要改的填 null（不要套用「没说日期就取最近一个」的规则）。「推迟一小时 / 往后挪两天」这类相对说法，按上面「未完成的待办」里那条的原日期时间推算出新的 date / time（原来没有时间就从现在算）。priority 同理，没说要改填 0。
  - op = "complete"（标记完成）：「开会那个完成了」「周报我交了」「把买快递那个勾掉」。content 填 ""。
  - op = "delete"（删除）：「把开会那个待办删掉」「取消交周报那个任务」。content 填 ""。只有明确说了删除 / 取消 / 不要了 / 删掉才用 delete，「做完了」是 complete。
  - op = "query"（查询，不改任何东西）：「今天还有什么没做」「明天有哪些待办」「这周还有什么任务」「有没有逾期的」「还有开会相关的待办吗」。range 填 "today"（今天，含已逾期）/ "tomorrow" / "week"（本周起七天内）/ "overdue"（已逾期）/ "all"（全部未完成）之一；说了某个主题（「开会相关的」）时 target 填关键词，否则填 ""。
  - target：用来找到那条待办的关键词（任务名里的核心词，如「开会」「周报」）；只说了「刚才那个 / 上一个」没说是什么就填 ""。
  - 说「再加一个待办 / 新建」是新建，不是 edit。edit 项不要拆分，也不会和 append / ask 同时出现。
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
  相对现在的说法一定按「现在」精确推算：「半小时后」「一个半小时后」「二十分钟后」= 现在加上这段时间，date 和 time 都要填（跨过午夜 date 要变成明天）；「一会儿」「待会儿」没有具体时间，time 填 null。
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
输入：帮我把接下来的内容记录为长录音
输出：{"items":[{"type":"cmd","cmd":"long_record","content":""}]}
输入：找一下我之前记的关于招聘的笔记
输出：{"items":[{"type":"search","scope":"note","target":"招聘","since":null,"until":null,"content":""}]}
输入：把昨天记的笔记列出来
输出：{"items":[{"type":"search","scope":"note","target":"","since":"2026-10-17","until":"2026-10-17","content":""}]}
输入：我昨天做了哪些事情
输出：{"items":[{"type":"answer","content":"我昨天做了哪些事情？"}]}
输入：这周我专注了多久
输出：{"items":[{"type":"answer","content":"这周我专注了多久？"}]}
输入：开始对今天的第一个任务进行专注
输出：{"items":[{"type":"answer","content":"对今天的第一个待办开始专注。"}]}
输入：结束专注
输出：{"items":[{"type":"answer","content":"结束当前的专注。"}]}
输入：记住我周三不开会
输出：{"items":[{"type":"answer","content":"记住：我周三不开会。"}]}
输入：每天早上八点告诉我今天有哪些待办
输出：{"items":[{"type":"answer","content":"创建一个定时任务：每天早上 8 点告诉我今天有哪些待办。"}]}
输入：帮我定一个明天早上七点的闹钟
输出：{"items":[{"type":"answer","content":"设一个明天早上 7 点的闹钟。"}]}
输入：这页内容里关于伽利略的描述，书中这样写对不对？另外帮我介绍一下伽利略的生平
输出：{"items":[{"type":"answer","content":"读一下当前屏幕：这页内容里关于伽利略的描述，书中这样写对不对？另外介绍一下伽利略的生平。"}]}
输入：总结一下这一页
输出：{"items":[{"type":"answer","content":"读一下当前屏幕，总结这一页的内容。"}]}
输入：开启勿扰模式一个小时
输出：{"items":[{"type":"answer","content":"开启勿扰模式，60 分钟后自动关闭。"}]}
输入：打开手电筒
输出：{"items":[{"type":"answer","content":"打开手电筒。"}]}
输入：把这页的要点记成笔记
输出：{"items":[{"type":"answer","content":"读一下当前屏幕，把要点记成笔记。"}]}
输入：每周五提醒我交周报
输出：{"items":[{"type":"todo","content":"交周报","date":"2026-10-23","time":null,"repeat":"每周五","tags":[],"priority":0}]}
输入：帮我找一下最近一周关于书法的笔记
输出：{"items":[{"type":"search","scope":"note","target":"书法","since":"2026-10-12","until":"2026-10-18","content":""}]}
输入：帮我查一下格雷厄姆的安全边际是什么意思
输出：{"items":[{"type":"ask","content":"格雷厄姆说的「安全边际」是什么意思？","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：追加到上一条笔记，复利的关键是时间和不中断
输出：{"items":[{"type":"note","append":true,"content":"复利的关键是时间和不中断。","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：刚才那个开会的待办，改到两点四十，还要带上办公电脑
输出：{"items":[{"type":"todo","edit":true,"op":"edit","target":"开会","content":"带上办公电脑","date":null,"time":"14:40","repeat":null,"tags":[],"priority":0}]}
输入：把交周报那个推迟到周五
输出：{"items":[{"type":"todo","edit":true,"op":"edit","target":"周报","content":"","date":"2026-10-23","time":null,"repeat":null,"tags":[],"priority":0}]}
输入：开会那个待办已经做完了
输出：{"items":[{"type":"todo","edit":true,"op":"complete","target":"开会","content":"","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：把取快递那个待办删掉
输出：{"items":[{"type":"todo","edit":true,"op":"delete","target":"快递","content":"","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：今天还有什么没做
输出：{"items":[{"type":"todo","edit":true,"op":"query","range":"today","target":"","content":"","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：半小时后提醒我关火
输出：{"items":[{"type":"todo","content":"关火","date":"2026-10-18","time":"11:28","repeat":null,"tags":[],"priority":0}]}
输入：明天上午九点开周会，然后下午三点去取快递，还有每周五要交周报
输出：{"items":[{"type":"todo","content":"开周会","date":"2026-10-19","time":"09:00","repeat":null,"tags":[],"priority":0},{"type":"todo","content":"去取快递","date":"2026-10-19","time":"15:00","repeat":null,"tags":[],"priority":0},{"type":"todo","content":"交周报","date":"2026-10-23","time":null,"repeat":"每周五","tags":[],"priority":0}]}
输入：周五前把报告交了，另外帮我查一下报告模板
输出：{"items":[{"type":"todo","content":"交报告","date":"2026-10-23","time":null,"repeat":null,"tags":[],"priority":0},{"type":"ask","content":"有哪些常用的报告模板？","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
        """.trimIndent()
    }

    private val APPEND_HEAD = Regex(
        "^[，,。\\s]*(?:请|麻烦)?(?:帮我)?(?:把(?:下面|这句话|这段话|这个|以下)?)?(?:追加|补充|接着写|续写|加)(?:到|在|进|入)(?:上一条|上一个|上个|上一篇|最近一条|最近的|刚才那条|刚才那个|刚才的|刚刚那条)(?:笔记|记录|日记)?(?:里面|里|中|后面)?[，,：:。\\s]*",
    )
    private val APPEND_TAIL = Regex(
        "[，,。\\s]*(?:请|麻烦)?(?:帮我)?(?:追加|补充|续写)(?:到|在|进|入)(?:上一条|上一个|上个|上一篇|最近一条|最近的|刚才那条|刚才那个|刚才的|刚刚那条)(?:笔记|记录|日记)?(?:里面|里|中|后面)?[。\\s]*$",
    )

    /**
     * 本地规则：转写开头 / 结尾有「追加到上一条笔记」这类口令时，返回去掉口令后的正文；没有口令返回 null。
     * 没开大模型时用它；开了大模型由模型通过 append 字段判断。
     */
    fun stripAppendCommand(raw: String): String? {
        val head = APPEND_HEAD.find(raw)
        val rest = when {
            head != null -> raw.substring(head.range.last + 1)
            else -> APPEND_TAIL.find(raw)?.let { raw.substring(0, it.range.first) } ?: return null
        }.trim()
        return rest.takeIf { it.isNotEmpty() }
    }

    /** 用户消息：就是转写原文 */
    fun userPrompt(raw: String, context: String? = null): String =
        if (context.isNullOrBlank()) "语音转写：$raw" else "$context\n语音转写：$raw"

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
        val kind = obj.string("type")?.trim()?.lowercase()
        if (kind == "cmd") {
            val cmd = VoiceCmd.entries.firstOrNull { it.key == obj.string("cmd")?.trim()?.lowercase() } ?: return null
            return VoiceIntent(CaptureKind.DAILY, "", null, null, null, emptyList(), 0, cmd = cmd)
        }
        if (kind == "answer") {
            if (content.isEmpty()) return null
            return VoiceIntent(CaptureKind.DAILY, content, null, null, null, emptyList(), 0, answer = true)
        }
        if (kind == "search") {
            val scope = obj.string("scope")?.trim()?.lowercase()?.takeIf { it in SEARCH_SCOPES } ?: "all"
            val keyword = obj.string("target")?.trim()?.takeIf { it.isNotEmpty() && !it.equals("null", true) }
            fun day(key: String) = obj.string(key)?.trim()?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
            val since = day("since")
            val until = day("until")
            // 关键词和时间范围至少要有一个（「我昨天做了哪些事情」没有关键词，只有时间）
            if (keyword == null && since == null && until == null) return null
            return VoiceIntent(CaptureKind.DAILY, "", since, null, null, emptyList(), 0, target = keyword, searchScope = scope, until = until)
        }
        val edit = obj.string("type")?.trim()?.lowercase() == "todo" &&
            (obj["edit"] as? JsonPrimitive)?.contentOrNull?.equals("true", ignoreCase = true) == true
        if (edit) return parseEdit(obj, content)
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
        val append = !ask && (obj["append"] as? JsonPrimitive)?.contentOrNull?.equals("true", ignoreCase = true) == true
        return VoiceIntent(if (append) CaptureKind.NOTE else type, content, if (append) null else date, if (append) null else time, if (append) null else repeat, tags, if (todo && !append) priority else 0, ask, append)
    }

    /** 对已有待办的操作：改（什么都没要改就丢掉）/ 完成 / 删除 / 查询 */
    private fun parseEdit(obj: JsonObject, content: String): VoiceIntent? {
        val op = when (obj.string("op")?.trim()?.lowercase()) {
            "complete", "done", "finish" -> TodoOp.COMPLETE
            "delete", "remove" -> TodoOp.DELETE
            "query", "list", "search" -> TodoOp.QUERY
            else -> TodoOp.EDIT
        }
        val target = obj.string("target")?.trim()?.takeIf { it.isNotEmpty() && !it.equals("null", true) }
        if (op == TodoOp.QUERY) {
            val range = obj.string("range")?.trim()?.lowercase()?.takeIf { it in QUERY_RANGES } ?: "today"
            return VoiceIntent(CaptureKind.TODO, "", null, null, null, emptyList(), 0, edit = true, target = target, op = op, range = range)
        }
        if (op != TodoOp.EDIT) {
            return VoiceIntent(CaptureKind.TODO, "", null, null, null, emptyList(), 0, edit = true, target = target, op = op)
        }
        val date = obj.string("date")?.trim()?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
        val time = obj.string("time")?.let { RE_TIME.find(it) }?.let { m ->
            runCatching { LocalTime.of(m.groupValues[1].toInt(), m.groupValues[2].toInt()) }.getOrNull()
        }
        val priority = when ((obj["priority"] as? JsonPrimitive)?.intOrNull ?: 0) {
            in 5..Int.MAX_VALUE -> 5
            in 3..4 -> 3
            in 1..2 -> 1
            else -> 0
        }
        if (content.isEmpty() && date == null && time == null && priority == 0) return null
        return VoiceIntent(CaptureKind.TODO, content, date, time, null, emptyList(), priority, edit = true, target = target)
    }

    /** 一项整理结果的类型记号：todo / daily / note / ask / answer / search / append / cmd:xxx / edit:edit|complete|delete|query */
    fun kindToken(i: VoiceIntent): String = when {
        i.cmd != null -> "cmd:${i.cmd.key}"
        i.searchScope != null -> "search"
        i.answer -> "answer"
        i.edit -> "edit:" + when (i.op) {
            TodoOp.EDIT -> "edit"
            TodoOp.COMPLETE -> "complete"
            TodoOp.DELETE -> "delete"
            TodoOp.QUERY -> "query"
        }
        i.ask -> "ask"
        i.append -> "append"
        else -> when (i.type) {
            CaptureKind.TODO -> "todo"
            CaptureKind.DAILY -> "daily"
            CaptureKind.NOTE -> "note"
        }
    }

    /** 一句话整理结果的「类型签名」（回归集比对用）：各项记号按字母序用逗号连起来 */
    fun signature(intents: List<VoiceIntent>): String = intents.map(::kindToken).sorted().joinToString(",")

    /** 给「最近对话」用的一句话：这句话被整理成了什么 / 做了什么（带具体名字和日期，方便下一句的「那个」能指到） */
    fun contextLine(intents: List<VoiceIntent>, cleaned: String): String {
        if (intents.isEmpty()) return "原话：$cleaned".take(60)
        fun day(d: LocalDate?, t: LocalTime?): String {
            if (d == null && t == null) return ""
            return "（" + listOfNotNull(d?.toString(), t?.let { "%02d:%02d".format(it.hour, it.minute) }).joinToString(" ") + "）"
        }
        return intents.joinToString("；") { i ->
            when {
                i.cmd != null -> "执行指令：${i.cmd.label}"
                i.searchScope != null -> "搜索「${i.target.orEmpty()}」"
                i.answer -> "回答：${i.content.take(40)}"
                i.edit -> "${i.op.label}「${i.target.orEmpty()}」" + day(i.date, i.time)
                i.ask -> "问闪念贝壳 AI：${i.content.take(40)}"
                i.append -> "追加到上一条笔记：${i.content.take(40)}"
                else -> when (i.type) {
                    CaptureKind.TODO -> "新建待办「${i.content.take(30)}」" + day(i.date, i.time)
                    CaptureKind.DAILY -> "记日记：${i.content.take(40)}"
                    CaptureKind.NOTE -> "记笔记：${i.content.take(40)}"
                }
            }
        }.take(200)
    }

    private val QUERY_RANGES = setOf("today", "tomorrow", "week", "overdue", "all")
    private val SEARCH_SCOPES = setOf("note", "todo", "all")

    /**
     * 「半小时后 / 两小时后 / 十分钟后」这类相对现在的说法，本地用规则再精确算一遍，不依赖模型的心算：
     * 转写里恰好有一个这样的说法、而且整理结果里恰好有一条新建待办时，直接把它的日期和时间改成算出来的那一刻。
     */
    fun fixRelativeTime(raw: String, intents: List<VoiceIntent>, now: LocalDateTime = LocalDateTime.now()): List<VoiceIntent> {
        val found = com.carpe.ideashell.core.parse.TodoParser.findAfterDuration(raw, now) ?: return intents
        val fresh = intents.filter { it.type == CaptureKind.TODO && !it.edit && !it.ask && !it.append && it.cmd == null && it.searchScope == null && !it.answer }
        if (fresh.size != 1) return intents
        val at = found.first
        return intents.map {
            if (it === fresh[0]) it.copy(date = at.toLocalDate(), time = LocalTime.of(at.hour, at.minute)) else it
        }
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
}
