package com.carpe.ideashell.data.voice

import android.content.Context
import com.carpe.ideashell.AppContainer
import com.carpe.ideashell.core.voice.VoiceIntents
import com.carpe.ideashell.data.llm.LlmException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.time.LocalDateTime

/**
 * 意图回归集的一条样本：一句话 [raw] 应该被整理成哪几类 [expect]（[VoiceIntents.signature] 的格式，如 `todo,todo`、`edit:query`）。
 * 测多轮指代的样本带 [ctxRaw] / [ctxResult]：「前一句说了什么 → 做了什么」。
 */
@Serializable
data class IntentCase(
    val raw: String,
    val expect: String,
    val ctxRaw: String? = null,
    val ctxResult: String? = null,
)

/** 自己攒的样本（语音历史里点「加入回归集」）：存在应用私有目录，可以复制出来合进代码里的内置样本 */
class IntentCases(context: Context) {
    private val file = File(context.filesDir, "intent_cases.json")
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true }
    private val _state = MutableStateFlow(load())
    val state: StateFlow<List<IntentCase>> = _state.asStateFlow()

    /** 同一句话只留最新一条 */
    @Synchronized
    fun add(raw: String, expect: String) {
        val next = _state.value.filterNot { it.raw == raw } + IntentCase(raw, expect)
        publish(next)
    }

    @Synchronized
    fun remove(raw: String) = publish(_state.value.filterNot { it.raw == raw })

    @Synchronized
    fun clear() = publish(emptyList())

    fun exportJson(): String = json.encodeToString(_state.value)

    /** 内置样本 + 自己攒的（同一句话以自己的为准） */
    fun all(): List<IntentCase> {
        val mine = _state.value
        return IntentSeeds.cases.filterNot { s -> mine.any { it.raw == s.raw } } + mine
    }

    private fun publish(list: List<IntentCase>) {
        _state.value = list
        runCatching { file.writeText(json.encodeToString(list)) }
    }

    private fun load(): List<IntentCase> = runCatching {
        if (!file.isFile) emptyList() else json.decodeFromString<List<IntentCase>>(file.readText())
    }.getOrDefault(emptyList())
}

/** 类型记号 → 给人看的名字（挑选 / 显示结果用） */
object IntentKinds {
    val ALL: List<Pair<String, String>> = listOf(
        "todo" to "新建待办",
        "daily" to "记日记",
        "note" to "记笔记",
        "append" to "追加到上一条笔记",
        "ask" to "问闪念贝壳 AI",
        "answer" to "语音助手（查询 / 操作）",
        "search" to "找记录（清单）",
        "edit:query" to "查待办",
        "edit:edit" to "改待办",
        "edit:complete" to "完成待办",
        "edit:delete" to "删除待办",
        "cmd:long_record" to "指令·长录音",
        "cmd:new_note" to "指令·新建笔记",
        "cmd:open_ai" to "指令·打开 AI",
    )

    fun label(token: String): String = ALL.firstOrNull { it.first == token }?.second ?: token

    fun labels(signature: String): String =
        if (signature.isBlank()) "（没有）" else signature.split(',').joinToString("、") { label(it) }
}

/** 内置样本：说过的真实问题 + 提示词里的典型说法。改了提示词就跑一遍，看有没有改好一个坏一个 */
object IntentSeeds {
    private fun c(raw: String, expect: String) = IntentCase(raw, expect)

    val cases: List<IntentCase> = listOf(
        c("嗯那个今晚八点半提醒我给张三回电话", "todo"),
        c("今天下午和客户开了会，感觉对方挺有兴趣的", "daily"),
        c("突然想到可以把每周复盘放到周日晚上", "daily"),
        c("今天心情不错，中午吃了牛肉面", "daily"),
        c("昨天的长录音还没整理完，有点焦虑", "daily"),
        c("记个笔记，复利就是利滚利，时间越长差距越大", "note"),
        c("追加到上一条笔记，复利的关键是时间和不中断", "append"),
        c("半小时后提醒我关火", "todo"),
        c("提醒我明天去查一下报销流程", "todo"),
        c("明天上午九点开周会，然后下午三点去取快递，还有每周五要交周报", "todo,todo,todo"),
        c("周五前把报告交了，另外帮我查一下报告模板", "ask,todo"),
        c("帮我查一下格雷厄姆的安全边际是什么意思", "ask"),
        c("帮我分析一下我这三个月的笔记，我最近在关注什么", "ask"),
        c("帮我把接下来的内容记录为长录音", "cmd:long_record"),
        c("开个长录音", "cmd:long_record"),
        c("我想新建一个文字笔记", "cmd:new_note"),
        c("打开 AI", "cmd:open_ai"),
        c("找一下我之前记的关于招聘的笔记", "search"),
        c("帮我找一下最近一周关于书法的笔记", "search"),
        c("把昨天记的笔记列出来", "search"),
        c("我昨天做了哪些事情", "answer"),
        c("这周我专注了多久", "answer"),
        c("今天完成了几个待办", "answer"),
        c("开始对今天的第一个任务进行专注", "answer"),
        c("开始专注二十五分钟", "answer"),
        c("结束专注", "answer"),
        c("记住我周三不开会", "answer"),
        c("每天早上八点告诉我今天有哪些待办", "answer"),
        c("有逾期的待办超过三个就提醒我", "answer"),
        c("帮我定一个明天早上七点的闹钟", "answer"),
        c("倒计时十分钟", "answer"),
        c("给老张打电话", "answer"),
        c("导航到杭州东站", "answer"),
        c("暂停音乐", "answer"),
        c("把这页的要点记成笔记", "answer"),
        c("把这段翻译成英文", "answer"),
        c("总结一下这一页", "answer"),
        c("这篇文章讲了什么", "answer"),
        c("这页内容里关于伽利略的描述，书中这样写对不对？另外帮我介绍一下伽利略的生平", "answer"),
        c("开启勿扰模式", "answer"),
        c("勿扰一个小时", "answer"),
        c("把手机调成静音", "answer"),
        c("音量调到一半", "answer"),
        c("打开手电筒", "answer"),
        c("把客厅的灯打开", "answer"),
        c("空调调到二十六度", "answer"),
        c("关掉卧室所有的灯", "answer"),
        c("打开微信", "answer"),
        c("回到桌面", "answer"),
        c("每周五提醒我交周报", "todo"),
        c("明天早上九点提醒我开会", "todo"),
        c("今天还有什么没做", "edit:query"),
        c("刚才那个开会的待办，改到两点四十，还要带上办公电脑", "edit:edit"),
        c("把交周报那个推迟到周五", "edit:edit"),
        c("开会那个待办已经做完了", "edit:complete"),
        c("把取快递那个待办删掉", "edit:delete"),
        // 多轮指代：前一句 → 这一句
        IntentCase("哪个最花时间", "answer", "我昨天做了哪些事情", "回答：昨天完成 3 项待办（写方案、整理笔记、回邮件），专注 2 小时"),
        IntentCase("再推迟一天", "edit:edit", "把交周报那个推迟到周五", "改待办「周报」（2026-11-27）"),
        IntentCase("那个也完成", "edit:complete", "开会那个待办已经做完了", "完成待办「开会」"),
    )
}

/** 跑回归：把每条样本交给当前配置的大模型整理一遍，比对类型签名 */
object IntentRegression {
    class Outcome(val case: IntentCase, val actual: String?, val error: String?) {
        val ok: Boolean get() = error == null && actual == case.expect
    }

    /** 固定的待办上下文（改 / 完成 / 删除类的样本需要它才有意义） */
    private val FIXTURE_TODOS = listOf("开周会｜明天 09:00", "交周报｜周五", "取快递｜今天 18:00", "整理报销单｜已逾期")

    suspend fun run(container: AppContainer, cases: List<IntentCase>, onProgress: (done: Int, total: Int) -> Unit): List<Outcome> {
        val gate = Semaphore(4)
        var finished = 0
        return coroutineScope {
            cases.map { case ->
                async(Dispatchers.IO) {
                    val out = gate.withPermit { runOne(container, case) }
                    val n = synchronized(gate) { ++finished }
                    onProgress(n, cases.size)
                    out
                }
            }.awaitAll()
        }
    }

    private suspend fun runOne(container: AppContainer, case: IntentCase): Outcome {
        // 和真实流程一样：整句就是「长录音」口令时不经过大模型
        if (VoiceIntents.isLongRecordCommand(case.raw)) return Outcome(case, "cmd:long_record", null)
        return try {
            val now = LocalDateTime.now()
            val ctx = if (case.ctxRaw == null) null
            else VoiceSession.format(listOf(VoiceSession.Turn(System.currentTimeMillis(), case.ctxRaw, case.ctxResult.orEmpty())))
            val reply = container.llm.chatJson(
                VoiceIntents.systemPrompt(now, vocabulary = emptyList(), todos = FIXTURE_TODOS),
                VoiceIntents.userPrompt(case.raw, ctx),
                20,
            )
            val intents = VoiceIntents.fixRelativeTime(case.raw, VoiceIntents.parse(reply), now)
            Outcome(case, VoiceIntents.signature(intents), if (intents.isEmpty()) "没能解析：" + reply.take(60) else null)
        } catch (e: CancellationException) {
            throw e
        } catch (e: LlmException) {
            Outcome(case, null, e.message ?: "大模型失败")
        } catch (e: Exception) {
            withContext(Dispatchers.Default) { Outcome(case, null, e.message ?: e.javaClass.simpleName) }
        }
    }
}
