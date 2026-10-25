package com.carpe.ideashell.data.llm

import com.carpe.ideashell.core.plan.cleanTitle
import com.carpe.ideashell.core.plan.parseDay
import com.carpe.ideashell.data.dida.DidaOverview
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.ideashell.DailyDay
import com.carpe.ideashell.data.ideashell.NoteInfo
import com.carpe.ideashell.data.project.Project
import com.carpe.ideashell.data.project.ProjectStatus
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.temporal.ChronoUnit

/**
 * 快速启动（与 Mac 端 `QuickStartPlanner` 一致）：把今天的待办、逾期、最近的笔记和 Daily Note 交给 AI，
 * 梳理出「今天做什么 / 留意什么 / 怎么无压力地开始」。
 */
class QuickStartPlan(
    val greeting: String,
    val focus: List<Focus>,
    val watch: List<String>,
    val later: List<Later>,
    /** 无压启动：从哪件事、用多少分钟、第一步做什么 */
    val startTask: DidaTask?,
    val startTitle: String,
    val startMinutes: Int,
    val startStep: String,
    val tip: String,
    val madeAt: Long = System.currentTimeMillis(),
) {
    class Focus(val title: String, val why: String, val task: DidaTask?)

    /** 可以先放一放的事；如果对应某个待办，就能直接延期 */
    class Later(val text: String, val task: DidaTask?)
}

/** 梳理今天要用到的全部素材（由界面层从各个仓库取好再传进来） */
class QuickStartInput(
    val overview: DidaOverview?,
    val recentNotes: List<NoteInfo>,
    val dailyDays: Map<LocalDate, DailyDay>,
    val projects: List<Project>,
    val focusMinutesToday: Int,
    val focusGoalMinutes: Int,
)

object QuickStartPlanner {
    private const val TIMEOUT_SEC = 90L

    private const val SYSTEM = """你是用户的私人晨间助理，帮他「无压力地开始今天」。你会拿到：今天的待办、逾期的待办、最近的笔记、最近几天的 Daily Note（随手记）、进行中的项目和今天已有的专注时长。

请梳理出：
1. focus：今天真正值得做的 1~3 件事（不是把所有待办罗列一遍）。优先考虑：今天到期的、高优先级的、逾期很久的、笔记 / Daily Note 里反复出现或写着「要做 / 别忘了 / 卡住了」的事。每件给一句不超过 30 字的理由或做法。如果是某个待办，带上它的 id（t1、t2…），不是待办就不带。
2. watch：需要留意的事项（0~3 条），比如笔记里提到的担心、没有收尾的想法、逾期很久的、时间冲突、今天很满等。每条不超过 40 字。
3. later：可以放心先放一放的（0~3 条，每条 {"text":"不超过 20 字","taskId":"t3"}），帮用户减压。如果这件事就是某个待办，务必带上它的 id（t1、t2…），用户可以一键把它延期；不是待办就不带 taskId。
4. start：「无压启动」——从 focus 里挑最容易开头的一件，给出 10~25 分钟的小目标：taskId（待办 id，可为空）、title（这一步的名称）、minutes（10~25 的整数）、step（第一步具体做什么，足够小、马上能动手，不超过 40 字）、tip（一句不超过 30 字、让人放松的话）。
5. greeting：一句温和、不说教的开场白，不超过 30 字，可以结合时间段（现在几点会告诉你）。

原则：语气温和，不责备，不制造焦虑；逾期不要用「拖延」这种词；信息不足时宁可少说，不要编造用户没写过的内容。

只输出一个 JSON 对象，不要其他文字：
{"greeting":"","focus":[{"title":"","why":"","taskId":"t1"}],"watch":[""],"later":[{"text":"","taskId":"t3"}],"start":{"taskId":"t1","title":"","minutes":15,"step":"","tip":""}}"""

    suspend fun plan(llm: LlmClient, input: QuickStartInput): QuickStartPlan {
        if (!llm.configured) throw LlmException("还没配置 AI 模型，请先到「设置」里填写大模型接口地址和 Key。")
        val today = LocalDate.now()
        val todayStr = today.toString()
        val ov = input.overview
        val zone = ZoneId.systemDefault()

        // 待办：今天 + 逾期（最久的 10 条）+ 收集箱（5 条），用 t1、t2… 的短 id
        val todayTasks = ov?.upcoming.orEmpty().filter { it.date?.take(10) == todayStr && !it.isCalendar }.sortedBy { it.time ?: "99:99" }
        val overdue = ov?.overdue.orEmpty().filter { !it.isCalendar }.sortedBy { it.date.orEmpty() }.take(10)
        val inbox = ov?.undated.orEmpty().filter { !it.isCalendar }.take(5)
        val idMap = HashMap<String, DidaTask>()
        var n = 0
        fun encode(t: DidaTask, kind: String): JsonObject {
            n++
            val sid = "t$n"
            idMap[sid] = t
            return buildJsonObject {
                put("id", sid)
                put("title", cleanTitle(t.title))
                put("kind", kind)
                t.time?.let { put("time", it) }
                if (t.priority > 0) put("priority", if (t.priority >= 5) "高" else if (t.priority >= 3) "中" else "低")
                val d = parseDay(t.date)
                if (d != null && d.isBefore(today)) put("overdueDays", maxOf(1L, ChronoUnit.DAYS.between(d, today)))
                ov?.projects?.get(t.projectId)?.let { put("list", it) }
                val note = t.content.trim().replace("\n", " ")
                if (note.isNotEmpty()) put("note", note.take(60))
            }
        }
        val todayJson = todayTasks.map { encode(it, "今天") }
        val overdueJson = overdue.map { encode(it, "逾期") }
        val inboxJson = inbox.map { encode(it, "无日期") }
        val doneToday = ov?.done.orEmpty().filter { t ->
            t.completedAt?.let { java.time.Instant.ofEpochMilli(it).atZone(zone).toLocalDate() == today } ?: false
        }.map { cleanTitle(it.title) }

        // 最近的笔记（最多 8 条）
        val notes = input.recentNotes.take(8).map { nt ->
            buildJsonObject {
                put("title", nt.title)
                nt.localDate?.let { put("day", it.toString()) }
                val body = (nt.summary ?: nt.text ?: "").trim().replace("\n", " ")
                if (body.isNotEmpty()) put("summary", body.take(120))
                if (nt.tags.isNotEmpty()) put("tags", buildJsonArray { nt.tags.forEach { add(JsonPrimitive(it)) } })
            }
        }

        // 最近 3 天的 Daily Note
        val daily = buildJsonArray {
            for (d in input.dailyDays.keys.sorted()) {
                val entries = input.dailyDays[d]?.entries.orEmpty().filter { !it.struck }.takeLast(12)
                if (entries.isEmpty()) continue
                add(
                    buildJsonObject {
                        put("day", d.toString())
                        put("entries", buildJsonArray { entries.forEach { add(JsonPrimitive("${it.time} ${it.text}".replace("\n", " ").take(120))) } })
                    },
                )
            }
        }

        // 进行中的项目和它的下一步
        val projects = input.projects.filter { it.status != ProjectStatus.PAUSED }.take(8).map { p ->
            buildJsonObject {
                put("name", p.keyword)
                put("status", p.status.label)
                if (p.next.isNotBlank()) put("next", p.next.trim().take(60))
            }
        }

        val now = LocalTime.now()
        val wk = listOf("一", "二", "三", "四", "五", "六", "日")
        val payload = buildJsonObject {
            put("now", "%02d:%02d".format(now.hour, now.minute))
            put("today", todayStr)
            put("weekday", "周" + wk[today.dayOfWeek.value - 1])
            put("todayTasks", JsonArray(todayJson))
            put("overdueTasks", JsonArray(overdueJson))
            put("inboxTasks", JsonArray(inboxJson))
            put("doneToday", buildJsonArray { doneToday.take(8).forEach { add(JsonPrimitive(it)) } })
            put("focusMinutesToday", input.focusMinutesToday)
            put("focusGoalMinutes", input.focusGoalMinutes)
            put("recentNotes", JsonArray(notes))
            put("dailyNotes", daily)
            put("projects", JsonArray(projects))
        }.toString()

        val reply = llm.chatJson(SYSTEM, payload, TIMEOUT_SEC)
        val obj = extractJsonObject(reply) ?: throw LlmException("AI 返回的内容格式不对，请重试")

        fun str(o: JsonObject, k: String): String? = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull?.trim()
        fun strings(k: String): List<String> =
            (obj[k] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull?.trim() }.filter { it.isNotEmpty() }

        val focus = (obj["focus"] as? JsonArray).orEmpty().take(3).mapNotNull { e ->
            val f = e as? JsonObject ?: return@mapNotNull null
            val title = str(f, "title")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            QuickStartPlan.Focus(title, str(f, "why").orEmpty(), str(f, "taskId")?.let { idMap[it] })
        }
        val later = (obj["later"] as? JsonArray).orEmpty().take(3).mapNotNull { e ->
            when (e) {
                is JsonPrimitive -> e.contentOrNull?.trim()?.takeIf { it.isNotEmpty() }?.let { QuickStartPlan.Later(it, null) }
                is JsonObject -> str(e, "text")?.takeIf { it.isNotEmpty() }?.let { QuickStartPlan.Later(it, str(e, "taskId")?.let { id -> idMap[id] }) }
                else -> null
            }
        }
        if (focus.isEmpty()) throw LlmException("AI 没有梳理出内容，请重试")
        val st = obj["start"] as? JsonObject
        val startTask = st?.let { str(it, "taskId") }?.let { idMap[it] } ?: focus.first().task
        val minutes = ((st?.get("minutes") as? JsonPrimitive)?.doubleOrNull ?: 15.0).toInt()
        return QuickStartPlan(
            greeting = str(obj, "greeting").orEmpty(),
            focus = focus,
            watch = strings("watch"),
            later = later,
            startTask = startTask,
            startTitle = st?.let { str(it, "title") }?.takeIf { it.isNotEmpty() } ?: focus.first().title,
            startMinutes = minutes.coerceIn(5, 30),
            startStep = st?.let { str(it, "step") }.orEmpty(),
            tip = st?.let { str(it, "tip") }.orEmpty(),
        )
    }
}
