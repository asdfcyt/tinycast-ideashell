package com.carpe.ideashell.data.voice

import android.util.Log
import com.carpe.ideashell.AppContainer
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.data.dida.FocusParser
import com.carpe.ideashell.data.llm.LlmException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.format.TextStyle
import java.util.Locale

/**
 * 语音助手的「大脑」：用你配置的大模型（OpenAI 兼容的函数调用）基于你自己的待办 / 笔记 / 专注记录回答问题。
 * 模型自己决定要查什么（工具都是只读的），查完用几句话作答；最多几轮，超了就让它凭手头的信息直接答。
 */
object VoiceAgent {
    private const val TAG = "VoiceAgent"
    private const val MAX_ROUNDS = 4
    private const val MAX_HITS = 12

    /** [text] 是回答；[hits] 是查数据时碰到的待办 / 笔记，卡片上可点开 */
    class Answer(val text: String, val hits: List<VoiceSearch.Hit>)

    /** [scheduled]：助手任务到点自动运行（没人在场）：不给读屏幕 / 打开别的应用 / 改任务的工具 */
    /**
     * [onPartial]：不为空时用流式请求，回答文字边生成边交给它（已去掉 Markdown 标记；在后台线程回调）。
     */
    suspend fun answer(
        container: AppContainer,
        question: String,
        context: String? = null,
        scheduled: Boolean = false,
        onPartial: ((String) -> Unit)? = null,
    ): Answer {
        if (!container.llm.configured) throw LlmException("还没有填写大模型 API Key")
        val hits = LinkedHashMap<String, VoiceSearch.Hit>()
        val messages = mutableListOf<JsonObject>()
        messages += msg("system", systemPrompt(LocalDateTime.now(), container.assistantMemory.promptBlock(), container.assistantSkills.promptBlock(), scheduled))
        val tools = toolsFor(scheduled)
        messages += msg("user", if (context.isNullOrBlank()) question else "$context\n\n我现在问：$question")

        for (round in 1..MAX_ROUNDS + 1) {
            val last = round > MAX_ROUNDS
            val toolsNow = if (last) JsonArray(emptyList()) else tools
            val reply = if (onPartial != null) {
                container.llm.chatStream(JsonArray(messages), toolsNow) { onPartial(clean(it)) }
            } else {
                container.llm.chatWithTools(JsonArray(messages), toolsNow)
            }
            val calls = (reply["tool_calls"] as? JsonArray)?.mapNotNull { it as? JsonObject }.orEmpty()
            val content = (reply["content"] as? JsonPrimitive)?.contentOrNull?.trim().orEmpty()
            if (calls.isEmpty() || last) {
                if (content.isEmpty()) throw LlmException("没有得到回答")
                return Answer(clean(content), hits.values.take(MAX_HITS))
            }
            // 把这一轮（带 tool_calls）原样放回对话，再逐个执行工具、把结果按 tool_call_id 放回去
            messages += reply
            val results = coroutineScope {
                calls.map { call ->
                    async {
                        val id = (call["id"] as? JsonPrimitive)?.contentOrNull.orEmpty()
                        val fn = call["function"] as? JsonObject
                        val name = (fn?.get("name") as? JsonPrimitive)?.contentOrNull.orEmpty()
                        val args = parseArgs((fn?.get("arguments") as? JsonPrimitive)?.contentOrNull)
                        id to runTool(container, name, args, hits)
                    }
                }.awaitAll()
            }
            for ((id, out) in results) {
                messages += buildJsonObject {
                    put("role", "tool")
                    put("tool_call_id", id)
                    put("content", out.take(6000))
                }
            }
        }
        throw LlmException("没有得到回答")
    }

    private fun msg(role: String, content: String) = buildJsonObject {
        put("role", role)
        put("content", content)
    }

    /** 回复是给人看的纯文字：去掉模型偶尔带上的 Markdown 标记 */
    private fun clean(text: String): String = text
        .replace(Regex("\\*\\*|__|`"), "")
        .replace(Regex("(?m)^#{1,6}\\s*"), "")
        .replace(Regex("(?m)^\\s*[-*]\\s+"), "· ")
        .trim()

    private fun parseArgs(raw: String?): JsonObject = try {
        if (raw.isNullOrBlank()) JsonObject(emptyMap()) else Json.parseToJsonElement(raw).jsonObject
    } catch (_: Exception) {
        JsonObject(emptyMap())
    }

    private fun weekday(d: LocalDate) = "周" + d.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.CHINA).removePrefix("周")

    private fun toolsFor(scheduled: Boolean): JsonArray = JsonArray(
        (TOOLS + AssistantTools.defs).filter { t ->
            !scheduled || ((t as JsonObject)["function"] as? JsonObject)?.get("name")?.let { (it as? JsonPrimitive)?.contentOrNull } !in AssistantTools.NOT_FOR_SCHEDULED
        },
    )

    private fun systemPrompt(now: LocalDateTime, memory: String?, skills: String?, scheduled: Boolean): String {
        val today = now.toLocalDate()
        val calendar = (-13..3).joinToString("；") { i ->
            val d = today.plusDays(i.toLong())
            val tag = when (i) { -2 -> "前天"; -1 -> "昨天"; 0 -> "今天"; 1 -> "明天"; 2 -> "后天"; else -> "" }
            "$d ${weekday(d)}" + if (tag.isEmpty()) "" else "（$tag）"
        }
        val memoryText = if (memory == null) "" else "\n\n你记得关于用户的这些事（用户让你记住的，回答和办事时可以参考）：\n$memory"
        val skillsText = if (skills == null) "" else "\n\n用户存了这些快捷指令（一句话叫出名字就要照办）：$skills。用户说出其中一个的名字（或明显是在叫它）时，先调用 run_skill 取步骤，再依次办完，最后用一句话汇报。"
        return """
你是用户的私人语音助手，用户用语音提了一个问题或请求。你通过工具查他的待办 / 笔记 / 专注数据，或替他办事（专注计时、记忆、定时任务、读屏幕、记笔记、闹钟 / 倒计时 / 拨号 / 导航 / 音乐、勿扰 / 音量 / 亮度 / 手电筒 / 打开应用 / 控制中心开关、快捷指令），再用中文回答。$memoryText$skillsText

现在是 $today ${weekday(today)} ${"%02d:%02d".format(now.hour, now.minute)}。日期对照：$calendar。「本周」= 本周一到今天；「上周」= 上一个周一到周日；「最近一周」= 今天往前 6 天到今天。

规则：
- 只根据工具返回的内容回答，查不到就如实说「没查到」，绝对不要编造；数量、时长要和工具结果一致。
- 需要什么查什么，能一次查完的并行调用；不要重复调用同样的工具。
- 回答是给人在手机卡片 / 锁屏通知里看的（有时还会被念出来）：纯文字、不要 Markdown、不要客套，先说结论，最多 5 行、总共 150 字以内（针对屏幕内容的问题例外，见下）；列条目时用「· 」开头，最多列 5 条，多的说「等 N 项」。
- 笔记只引用标题和摘要里有的信息；需要细节再用 read_note 读全文。
- 能办的事：start_focus / focus_control（专注计时）、remember / forget（记忆）、create_task / list_tasks / task_control（定时或条件任务）、save_skill / run_skill / delete_skill（快捷指令）、read_screen、create_note、set_alarm / set_timer / dial / navigate / media_control、set_dnd / set_ringer / set_volume / set_brightness / flashlight / open_app / open_settings / phone_action / toggle_quick_setting（控制手机）、home_list / home_control（控制家里的米家等智能设备）。只有用户明确要求才调用，做完用一句话告诉他结果。
- 控制家里的设备时：先 home_list 找到 entity_id（带房间 / 设备名关键词），再 home_control；「所有灯」这类批量要求把匹配的 id 一次传完；结果如实转述（离线 / 没找到 / 连不上就直说），不要假装办成；门锁、报警、摄像头不能控制。
- 控制手机时：工具返回「还没有……权限」就把原因和去哪里授权如实告诉用户（已经替他打开了授权页）；WLAN / 蓝牙 / 飞行模式 / 移动数据 / NFC / 热点这类开关用 toggle_quick_setting，失败了再建议 open_settings；不要假装已经办成。
- 用户让你把刚才做的 / 常做的一串事「存成快捷指令」时：用 save_skill，name 取用户说的口令（没说就按内容取个 2~4 字的名字），steps 根据用户的描述和最近对话写成按顺序的完整步骤。
- 你没有天气、联网搜索、股价这类工具；条件或请求依赖它们时如实说做不到，不要假装能。
- 创建任务前想清楚：时间（几点、每天 / 哪几天 / 哪一天）、做什么、有没有条件；用户没说几点就问不了他，按最合理的默认（早上 8 点）并在回答里说明。
- 用户说「这页 / 这段 / 这篇 / 屏幕上」时先 read_screen 再处理；要求「记成笔记」时再 create_note，content 写整理好的最终内容。
- 针对屏幕内容的提问（总结 / 解释 / 翻译 / 判断对不对 / 顺带介绍里面提到的人物或概念）：你自己直接答，不要说做不到、也不要建议他去问别的 AI。先 read_screen，依据屏幕内容并结合你自己的知识作答；这类回答可以展开一些：最多 10 行、总共 320 字以内，先说结论。屏幕内容读不到时，把 read_screen 说的原因告诉用户，不要编造页面内容。
- 「今天的第一个任务」= list_todos(today) 里**计划日期是今天**的未完成待办中时间最靠前的一条（没有时间的排在有时间的后面；已逾期的不算今天）；「接下来要做的」同理。要对某个任务开始专注，先 list_todos 找到它，再用它的 id 调 start_focus。
- 你不能新建 / 修改 / 删除待办，也不能改 / 删已有笔记；用户要待办时，告诉他直接说「提醒我……」「把……改到……」即可。
        """.trimIndent()
    }

    // ───────────────────────── 工具 ─────────────────────────

    internal fun tool(name: String, description: String, props: JsonObjectBuilder.() -> Unit = {}, required: List<String> = emptyList()) = buildJsonObject {
        put("type", "function")
        putJsonObject("function") {
            put("name", name)
            put("description", description)
            putJsonObject("parameters") {
                put("type", "object")
                putJsonObject("properties") { props() }
                putJsonArray("required") { required.forEach { add(JsonPrimitive(it)) } }
            }
        }
    }

    private val TOOLS: JsonArray = buildJsonArray {
        add(
            tool(
                "day_summary",
                "查某段时间（最多 7 天）每天完成了哪些待办、记录了哪些笔记（标题）、专注了多久。回答「我昨天 / 这周做了什么」优先用它。",
                props = {
                    putJsonObject("since") { put("type", "string"); put("description", "起始日期 yyyy-MM-dd") }
                    putJsonObject("until") { put("type", "string"); put("description", "结束日期 yyyy-MM-dd（含），不填 = 和 since 同一天") }
                },
                required = listOf("since"),
            ),
        )
        add(
            tool(
                "focus_stats",
                "查某段时间的专注总时长，以及按任务拆分的时长。",
                props = {
                    putJsonObject("since") { put("type", "string"); put("description", "起始日期 yyyy-MM-dd") }
                    putJsonObject("until") { put("type", "string"); put("description", "结束日期 yyyy-MM-dd（含）") }
                },
                required = listOf("since", "until"),
            ),
        )
        add(
            tool(
                "list_todos",
                "列出未完成的待办（滴答清单 + 日历待办）。range：today（今天含已逾期）/ tomorrow / week（今天起 7 天）/ overdue（已逾期）/ all（全部未完成）。",
                props = {
                    putJsonObject("range") { put("type", "string"); put("enum", buildJsonArray { listOf("today", "tomorrow", "week", "overdue", "all").forEach { add(JsonPrimitive(it)) } }) }
                    putJsonObject("keyword") { put("type", "string"); put("description", "只留标题里相关的，可不填") }
                },
                required = listOf("range"),
            ),
        )
        add(
            tool(
                "search_todos",
                "按计划日期范围和关键词查待办，包含已完成的（标题前带 ✓）。用来回答「某段时间安排了 / 完成了什么」「某件事的待办」。",
                props = {
                    putJsonObject("keyword") { put("type", "string"); put("description", "关键词，可不填") }
                    putJsonObject("since") { put("type", "string"); put("description", "起始日期 yyyy-MM-dd，可不填") }
                    putJsonObject("until") { put("type", "string"); put("description", "结束日期 yyyy-MM-dd（含），可不填") }
                },
            ),
        )
        add(
            tool(
                "search_notes",
                "查闪念贝壳里的笔记：关键词语义搜索，可限定创建日期范围；返回 id、日期、标题、摘要。keyword 不填 = 取这段时间内的全部笔记。",
                props = {
                    putJsonObject("keyword") { put("type", "string"); put("description", "主题关键词，可不填") }
                    putJsonObject("since") { put("type", "string"); put("description", "起始日期 yyyy-MM-dd，可不填") }
                    putJsonObject("until") { put("type", "string"); put("description", "结束日期 yyyy-MM-dd（含），可不填") }
                },
            ),
        )
        add(
            tool(
                "start_focus",
                "开始一次专注计时（拾忆自带的计时，结束后记录到滴答）。task_id 来自 list_todos / search_todos 返回的 [id]，不填就是不关联任务的专注。minutes 不填用上次的时长。已经有专注在进行时会失败。",
                props = {
                    putJsonObject("task_id") { put("type", "string"); put("description", "待办 id（方括号里的），可不填") }
                    putJsonObject("minutes") { put("type", "integer"); put("description", "专注分钟数 5~120，可不填") }
                },
            ),
        )
        add(
            tool(
                "focus_control",
                "控制正在进行的专注：pause 暂停、resume 继续、finish 结束并记录（不足 1 分钟不记）。",
                props = {
                    putJsonObject("action") { put("type", "string"); put("enum", buildJsonArray { listOf("pause", "resume", "finish").forEach { add(JsonPrimitive(it)) } }) }
                },
                required = listOf("action"),
            ),
        )
        add(
            tool(
                "read_note",
                "读一篇笔记的全文（前 2000 字）。id 来自 search_notes。",
                props = { putJsonObject("id") { put("type", "string") } },
                required = listOf("id"),
            ),
        )
    }

    internal fun JsonObject.arg(key: String): String? =
        (this[key] as? JsonPrimitive)?.contentOrNull?.trim()?.takeIf { it.isNotEmpty() && !it.equals("null", true) }

    internal fun JsonObject.day(key: String): LocalDate? = arg(key)?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() }

    /** 执行一个工具，返回给模型看的文字；出错也返回文字（让模型自己决定怎么说），不抛异常 */
    private suspend fun runTool(container: AppContainer, name: String, args: JsonObject, hits: MutableMap<String, VoiceSearch.Hit>): String {
        Log.i(TAG, "tool $name $args")
        return try {
            if (name in AssistantTools.names) return AssistantTools.run(container, name, args)
            when (name) {
                "day_summary" -> daySummary(container, args)
                "focus_stats" -> focusStats(container, args)
                "list_todos" -> listTodos(container, args, hits)
                "search_todos" -> searchTodos(container, args, hits)
                "search_notes" -> searchNotes(container, args, hits)
                "read_note" -> readNote(container, args)
                "start_focus" -> startFocus(container, args, hits)
                "focus_control" -> focusControl(container, args)
                else -> "没有这个工具：$name"
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "tool $name failed", e)
            "出错：" + (e.message ?: e.javaClass.simpleName)
        }
    }

    private suspend fun daySummary(container: AppContainer, args: JsonObject): String {
        val since = args.day("since") ?: return "缺少 since（yyyy-MM-dd）"
        val until = (args.day("until") ?: since).let { if (it.isBefore(since)) since else it }
        val days = generateSequence(since) { it.plusDays(1) }.takeWhile { !it.isAfter(until) }.take(7).toList()
        val parts = coroutineScope {
            days.map { d -> async { d to runCatching { container.daySummary.collect(d) } } }.awaitAll()
        }
        return parts.joinToString("\n") { (d, r) ->
            val head = "$d ${weekday(d)}："
            val s = r.getOrNull() ?: return@joinToString head + "读取失败（" + (r.exceptionOrNull()?.message ?: "未知错误") + "）"
            if (!s.hasContent) return@joinToString head + "没有完成的待办、笔记和专注记录"
            buildString {
                append(head)
                append("完成待办 ${s.tasks.size} 项")
                if (s.tasks.isNotEmpty()) append("（" + s.tasks.take(12).joinToString("、") { TodoMeta.cleanTitle(it).trim() } + (if (s.tasks.size > 12) "等" else "") + "）")
                append("；记笔记 ${s.notes.size} 篇")
                if (s.notes.isNotEmpty()) append("（" + s.notes.take(10).joinToString("、") + (if (s.notes.size > 10) "等" else "") + "）")
                append("；专注 " + if (s.focusMin > 0) FocusParser.formatMinutes(s.focusMin) else "0")
                if (s.focusByTask.isNotEmpty()) append("（" + s.focusByTask.take(5).joinToString("、") { "${it.title} ${FocusParser.formatMinutes(it.min)}" } + "）")
            }
        }
    }

    private suspend fun focusStats(container: AppContainer, args: JsonObject): String {
        val since = args.day("since") ?: return "缺少 since（yyyy-MM-dd）"
        val until = (args.day("until") ?: since).let { if (it.isBefore(since)) since else it }
        val f = container.daySummary.focusIn(since, until.plusDays(1))
        if (f.weekMin <= 0) return "$since ~ $until 没有专注记录"
        val top = f.byTask.entries.sortedByDescending { it.value.weekMin }.take(8)
            .joinToString("、") { (id, t) -> "${f.titles[id] ?: "（未关联任务）"} ${FocusParser.formatMinutes(t.weekMin)}" }
        return "$since ~ $until 共专注 ${FocusParser.formatMinutes(f.weekMin)}" + if (top.isEmpty()) "" else "；按任务：$top"
    }

    private fun addHits(hits: MutableMap<String, VoiceSearch.Hit>, list: List<VoiceSearch.Hit>) {
        synchronized(hits) { list.forEach { hits.putIfAbsent((if (it.isNote) "n:" else "t:") + it.id, it) } }
    }

    private fun taskLine(t: com.carpe.ideashell.data.dida.DidaTask): String {
        val whenText = listOfNotNull(t.date?.take(10), t.time).joinToString(" ")
        return (if (t.done) "✓ " else "· ") + "[${t.id}] " + TodoMeta.cleanTitle(t.title).trim() + if (whenText.isEmpty()) "" else "（$whenText）"
    }

    private suspend fun listTodos(container: AppContainer, args: JsonObject, hits: MutableMap<String, VoiceSearch.Hit>): String {
        val tasks = container.todoEditor.query(args.arg("range"), args.arg("keyword"))
        addHits(hits, VoiceSearch.taskHits(tasks))
        if (tasks.isEmpty()) return "没有符合的未完成待办"
        return "共 ${tasks.size} 项：\n" + tasks.take(30).joinToString("\n") { taskLine(it) } + if (tasks.size > 30) "\n…还有 ${tasks.size - 30} 项" else ""
    }

    private suspend fun searchTodos(container: AppContainer, args: JsonObject, hits: MutableMap<String, VoiceSearch.Hit>): String {
        val tasks = VoiceSearch.findTodos(container, args.arg("keyword").orEmpty(), args.day("since"), args.day("until"))
        addHits(hits, VoiceSearch.taskHits(tasks))
        if (tasks.isEmpty()) return "没有符合的待办"
        return "共 ${tasks.size} 项（✓ 为已完成）：\n" + tasks.take(30).joinToString("\n") { taskLine(it) } + if (tasks.size > 30) "\n…还有 ${tasks.size - 30} 项" else ""
    }

    private suspend fun searchNotes(container: AppContainer, args: JsonObject, hits: MutableMap<String, VoiceSearch.Hit>): String {
        val keyword = args.arg("keyword").orEmpty()
        val since = args.day("since")
        val until = args.day("until")
        if (keyword.isEmpty() && since == null && until == null) return "需要给出关键词或日期范围"
        if (!container.credentials.ideashellConnected.value) return "还没连接闪念贝壳，没法查笔记"
        val (notes, error) = VoiceSearch.findNotes(container, keyword, since, until)
        if (error != null) return error
        addHits(hits, notes.map(VoiceSearch::noteHit))
        if (notes.isEmpty()) return "没有符合的笔记"
        return "共 ${notes.size} 篇：\n" + notes.take(20).joinToString("\n") { n ->
            val summary = (n.summary ?: n.text ?: "").replace(Regex("\\s+"), " ").trim().take(80)
            "· [${n.id}] ${n.localDate ?: ""} ${n.title.trim().ifEmpty { "（无标题）" }}" + if (summary.isEmpty()) "" else "：$summary"
        } + if (notes.size > 20) "\n…还有 ${notes.size - 20} 篇" else ""
    }

    private suspend fun startFocus(container: AppContainer, args: JsonObject, hits: MutableMap<String, VoiceSearch.Hit>): String {
        val focus = container.focus
        focus.session.value?.let { return "已经有一个专注在进行（${it.title.ifBlank { "未关联任务" }}），没有重复开始" }
        val id = args.arg("task_id")
        val task = if (id == null) null else {
            runCatching { container.todos.refreshNow() }
            container.todos.peek()?.let { o -> (o.overdue + o.upcoming + o.undated).firstOrNull { it.id == id } }
                ?: return "找不到 id 为 $id 的待办，请先用 list_todos 查"
        }
        val minutes = (args.arg("minutes")?.toDoubleOrNull()?.toInt() ?: focus.lastMinutes).coerceIn(5, 120)
        val title = task?.let { TodoMeta.cleanTitle(it.title).ifBlank { it.title } }.orEmpty()
        val project = task?.let { container.projects.projectOf(it)?.keyword }
        // 日历事件不是滴答任务：专注记录不绑任务 id（否则会往滴答提交一条找不到任务的专注）
        val ok = if (task == null || task.isCalendar) focus.start(null, null, title, minutes, com.carpe.ideashell.data.focus.FocusKind.FOCUS, project)
        else focus.start(task.id, task.projectId, title, minutes, com.carpe.ideashell.data.focus.FocusKind.FOCUS, project)
        if (!ok) return "已经有一个专注在进行，没有重复开始"
        if (task != null) addHits(hits, VoiceSearch.taskHits(listOf(task)))
        return "已开始专注 $minutes 分钟" + if (title.isEmpty()) "（未关联任务）" else "：$title"
    }

    private suspend fun focusControl(container: AppContainer, args: JsonObject): String {
        val focus = container.focus
        val s = focus.session.value ?: return "现在没有正在进行的专注"
        val name = s.title.ifBlank { "专注" }
        return when (args.arg("action")) {
            "pause" -> { focus.pause(); "已暂停：$name" }
            "resume" -> { focus.resume(); "已继续：$name" }
            "finish" -> when (val r = focus.finish()) {
                is com.carpe.ideashell.data.focus.FocusResult.Recorded -> "已结束并记录 ${r.minutes} 分钟：$name" + if (r.synced) "" else "（还没同步到滴答，联网后自动同步）"
                com.carpe.ideashell.data.focus.FocusResult.TooShort -> "已结束，不足 1 分钟没有记录：$name"
                com.carpe.ideashell.data.focus.FocusResult.None -> "现在没有正在进行的专注"
            }
            else -> "action 只能是 pause / resume / finish"
        }
    }

    private suspend fun readNote(container: AppContainer, args: JsonObject): String {
        val id = args.arg("id") ?: return "缺少 id"
        val n = container.notes.note(id)
        return "${n.title}（${n.localDate ?: ""}）\n" + n.content.trim().take(2000)
    }
}
