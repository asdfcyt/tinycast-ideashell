package com.carpe.ideashell.data.llm

import com.carpe.ideashell.core.plan.cleanTitle
import com.carpe.ideashell.core.plan.parseDay
import com.carpe.ideashell.data.dida.DidaOverview
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.project.Project
import com.carpe.ideashell.data.project.ProjectStatus
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.format.TextStyle
import java.util.Locale
import java.util.UUID

/**
 * AI 规划助手，两步走：
 * ① 拆解并分配时间：用户把脑子里还没记下的事一股脑倒出来，AI 拆成具体小任务、估好每个要多久（[AiAssistant.decompose]）；
 * ② 排期：根据今天已有的任务（带时间的、日历事件占着的时段），把拆好的小任务排进空档（[AiAssistant.schedule]）。
 * 只返回方案，不写入滴答；写入前由规划弹层里的「应用」决定。
 *
 * 比 Mac 端多一条：**时间占用**。带时间的任务从开始时刻起占用「预计时长」（标题 / 备注里的「约 2h」），
 * 这段时间里不能再排别的带时间任务；模型排出来的方案会再由 [PlanTime.resolve] 兜一次底，自动错开。
 */

// ───────────────────────── 数据 ─────────────────────────

class PlanConflict(val date: String, val text: String)

/**
 * 第一步从用户写的那段话里识别出来的一件事：
 * - [taskId] 为空：新事，排期时才新建任务；
 * - [taskId] 不为空：就是已有的某条待办（「看书」≈「阅读第 4 章」），不新建，只给它排时间。
 * [from] / [to]：用户说过的时间限制（「晚上才有时间看书」→ from=21:00；「下午 4 点到 6 点吃饭」→ from=16:00、to=18:00），排期时必须遵守。
 */
data class DraftItem(
    val key: String,
    val title: String,
    val minutes: Int,
    val priority: Int,
    /** 从哪件大事拆出来的 */
    val parent: String?,
    val project: String?,
    /** AI 觉得今天排不下，建议放到之后 */
    val later: Boolean,
    val reason: String,
    val taskId: String? = null,
    /** 已有待办现在排在什么时候（「今天 13:00」「无日期」「逾期 2 天」） */
    val current: String? = null,
    val from: String? = null,
    val to: String? = null,
)

class AiMove(val task: DidaTask, val date: String, val time: String?, val reason: String, val mentioned: Boolean = false) {
    val id: String get() = task.id
}

class AiNewTask(
    val key: String,
    val title: String,
    val date: String,
    val time: String?,
    val priority: Int,
    val minutes: Int,
    val reason: String,
    /** 从哪件待办 / 目标拆出来的 */
    val parent: String?,
    /** 属于哪个项目（项目关键词） */
    val project: String?,
)

class AiConflictFix(val text: String, val resolution: String)

class AiDayPlan(
    val summary: String,
    /** 今天最重要的 3 件事（MIT）：标题 to 为什么 */
    val topThree: List<Pair<String, String>>,
    val conflicts: List<AiConflictFix>,
    val moves: List<AiMove>,
    val newTasks: List<AiNewTask>,
    /** 为了避免时间重叠，自动调整了几项 */
    val adjusted: Int,
)

/** 交给 AI 的上下文：待办（短 id）、冲突、项目 */
class PlanContext(
    val today: LocalDate,
    val tasks: List<DidaTask>,
    val idMap: Map<String, DidaTask>,
    val locked: Set<String>,
    val conflicts: List<PlanConflict>,
    val overdueCount: Int,
    val todayCount: Int,
    val undatedCount: Int,
    val payload: JsonObject,
)

// ───────────────────────── 时间 ─────────────────────────

object PlanTime {
    /** 一天里可以排任务的时间范围 */
    const val DAY_START = 6 * 60
    const val DAY_END = 23 * 60 + 30

    /** 用户明确说了「几点以后 / 几点之前」的任务，可以排到午夜 */
    const val DAY_LIMIT = 24 * 60

    /** 任务之间至少留这么久（分钟）；已经紧挨着的不算冲突，只在 AI 自己挑时间时要求留 */
    private const val GAP = 5

    private val ESTIMATE = Regex("(?i)约\\s*([0-9]+(?:\\.[0-9]+)?)\\s*(h|小时|min|分钟|分|m)")

    fun minutes(hhmm: String?): Int? {
        val p = hhmm?.trim()?.split(":") ?: return null
        if (p.size != 2) return null
        val h = p[0].toIntOrNull() ?: return null
        val m = p[1].toIntOrNull() ?: return null
        return if (h in 0..23 && m in 0..59) h * 60 + m else null
    }

    fun fmt(min: Int): String = "%02d:%02d".format(min / 60, min % 60)

    /** 预计要多久：日历事件用它的起止；其余从标题 / 备注里读「约 2h」「1.5 小时」「30 分钟」，没有就按 30 分钟 */
    fun estimate(t: DidaTask): Int {
        if (t.isCalendar) {
            val s = minutes(t.time)
            val e = minutes(t.endTime)
            if (s != null && e != null && e > s) return e - s
        }
        val m = ESTIMATE.find(t.title + " " + t.content) ?: return 30
        val v = m.groupValues[1].toDoubleOrNull() ?: return 30
        val u = m.groupValues[2].lowercase()
        return maxOf(5, (if (u == "h" || u == "小时") v * 60 else v).toInt())
    }

    /** [date] 当天从 [from] 分钟起还空着的时段（每段至少 15 分钟）：已有的带时间任务 / 日历事件按预计时长占用 */
    fun freeSlots(tasks: List<DidaTask>, date: LocalDate, from: Int): List<Pair<Int, Int>> {
        val busy = tasks.filter { !it.done && parseDay(it.date) == date }.mapNotNull { t ->
            val st = minutes(t.time) ?: return@mapNotNull null
            st to (st + maxOf(estimate(t), 15))
        }.sortedBy { it.first }
        var cur = maxOf(from, DAY_START)
        val out = ArrayList<Pair<Int, Int>>()
        for ((st, en) in busy) {
            if (st - cur >= 15) out += cur to st
            cur = maxOf(cur, en)
        }
        if (DAY_END - cur >= 15) out += cur to DAY_END
        return out
    }

    /** 今天还能用的起点：现在往后留 10 分钟缓冲，取整到 5 分钟 */
    fun todayFrom(now: LocalDateTime): Int = ((now.hour * 60 + now.minute + 10) + 4) / 5 * 5

    private class Slot(val start: Int, val end: Int, val label: String)

    /**
     * 兜底：把方案里带时间的任务（改期 + 新任务）按「时间占用」检查一遍。
     * 占用 = 开始时刻起、预计时长内。和当天已有的带时间任务 / 日历事件（没被这次改期挪走的）、以及方案里先排好的任务重叠，
     * 就往后找最近的空档；当天排不下就改成全天（不带时间）。今天已经过去的时段也算被占用。
     * @return 调整后的改期、新任务，以及调整了几项
     */
    fun resolve(
        moves: List<AiMove>,
        news: List<AiNewTask>,
        tasks: List<DidaTask>,
        today: LocalDate,
        now: LocalDateTime,
        /** 用户限定的时间窗：改期任务的 id / 新任务的 key → (最早开始分钟, 最晚结束分钟) */
        windows: Map<String, Pair<Int?, Int?>> = emptyMap(),
    ): Triple<List<AiMove>, List<AiNewTask>, Int> {
        val movedIds = moves.map { it.id }.toSet()
        val occupied = HashMap<String, MutableList<Slot>>()
        fun add(date: String, s: Int, e: Int, label: String) {
            occupied.getOrPut(date) { ArrayList() } += Slot(s, e, label)
        }
        for (t in tasks) {
            if (t.done || t.id in movedIds) continue
            val d = parseDay(t.date)?.toString() ?: continue
            if (d < today.toString()) continue
            val s = minutes(t.time) ?: continue
            add(d, s, s + maxOf(estimate(t), 15), cleanTitle(t.title).take(14))
        }
        // 今天已经过去的时段不能再排；留 10 分钟缓冲
        val nowMin = now.hour * 60 + now.minute
        add(today.toString(), 0, ((nowMin + 10) + 4) / 5 * 5, "现在")

        class Entry(val move: AiMove?, val new: AiNewTask?, val date: String, var time: String?, val minutes: Int, var reason: String, val title: String) {
            val key: String get() = move?.id ?: new!!.key
        }

        val entries = ArrayList<Entry>()
        for (m in moves) entries += Entry(m, null, m.date, m.time, maxOf(estimate(m.task), 15), m.reason, cleanTitle(m.task.title).take(14))
        for (n in news) entries += Entry(null, n, n.date, n.time, maxOf(n.minutes, 15), n.reason, n.title.take(14))
        entries.sortWith(compareBy({ it.date }, { it.time ?: "99:99" }))

        var adjusted = 0
        for (e in entries) {
            val s0 = minutes(e.time) ?: continue
            val list = occupied.getOrPut(e.date) { ArrayList() }
            fun overlap(s: Int): Slot? = list.firstOrNull { s < it.end && it.start < s + e.minutes }
            val win = windows[e.key]
            val limit = if (win != null) minOf(DAY_LIMIT, win.second ?: DAY_LIMIT) else DAY_END
            var cur = maxOf(s0, DAY_START, win?.first ?: 0)
            var blocker = overlap(cur)
            var guard = 0
            while (blocker != null && guard++ < 60) {
                cur = (blocker.end + GAP + 4) / 5 * 5
                if (cur + e.minutes > limit) break
                blocker = overlap(cur)
            }
            if (blocker == null && cur + e.minutes <= limit) {
                if (cur != s0) {
                    adjusted++
                    e.reason = (e.reason + (if (win?.first != null && s0 < win.first!!) "（按你说的时间限制，改到 ${fmt(cur)}）" else "（原时段被占用，改到 ${fmt(cur)}）")).trim()
                    e.time = fmt(cur)
                }
                list += Slot(cur, cur + e.minutes, e.title)
            } else {
                adjusted++
                e.reason = (e.reason + (if (win != null) "（你说的那段时间排不下，改为全天）" else "（当天时段排不下，改为全天）")).trim()
                e.time = null
            }
        }

        val byMove = entries.filter { it.move != null }.associateBy { it.move!!.id }
        val byNew = entries.filter { it.new != null }.associateBy { it.new!!.key }
        val outMoves = moves.map { m -> byMove[m.id]!!.let { AiMove(m.task, m.date, it.time, it.reason, m.mentioned) } }
        val outNews = news.map { n ->
            byNew[n.key]!!.let { AiNewTask(n.key, n.title, n.date, it.time, n.priority, n.minutes, it.reason, n.parent, n.project) }
        }
        return Triple(outMoves, outNews, adjusted)
    }
}

// ───────────────────────── 冲突检测 ─────────────────────────

object ConflictFinder {
    private fun label(d: LocalDate, today: LocalDate): String = when (java.time.temporal.ChronoUnit.DAYS.between(today, d)) {
        0L -> "今天"
        1L -> "明天"
        2L -> "后天"
        else -> "${d.monthValue}月${d.dayOfMonth}日"
    }

    private fun span(h: Int): String = if (h % 60 == 0) "${h / 60}h" else "%.1fh".format(h / 60.0)

    /** 未来 14 天里：时间重叠（带时长）、某天件数偏多、某天预计要做太久 */
    fun find(tasks: List<DidaTask>, today: LocalDate, perDay: Int = 6): List<PlanConflict> {
        val out = ArrayList<PlanConflict>()
        val end = today.plusDays(14)
        val byDay = sortedMapOf<LocalDate, MutableList<DidaTask>>()
        for (t in tasks) {
            if (t.done) continue
            val d = parseDay(t.date) ?: continue
            if (!d.isBefore(today) && !d.isAfter(end)) byDay.getOrPut(d) { ArrayList() } += t
        }
        for ((d, ts) in byDay) {
            val day = label(d, today)
            class Timed(val t: DidaTask, val start: Int, val end: Int)

            val timed = ts.mapNotNull { t ->
                val s = PlanTime.minutes(t.time) ?: return@mapNotNull null
                Timed(t, s, s + maxOf(PlanTime.estimate(t), 15))
            }.sortedBy { it.start }
            // 用「目前为止结束最晚的那件」比较：一件两小时的任务里夹着别的任务，也能查出来
            var latest: Timed? = null
            for (b in timed) {
                val a = latest
                if (a != null && b.start < a.end) {
                    out += PlanConflict(
                        d.toString(),
                        "$day ${PlanTime.fmt(a.start)}–${PlanTime.fmt(a.end)}「${cleanTitle(a.t.title).take(18)}」和 ${PlanTime.fmt(b.start)}「${cleanTitle(b.t.title).take(18)}」时间重叠",
                    )
                }
                if (a == null || b.end > a.end) latest = b
            }
            val total = ts.sumOf { PlanTime.estimate(it) }
            if (ts.size > perDay) {
                out += PlanConflict(d.toString(), "$day 有 ${ts.size} 件待办，偏多")
            } else if (total > 8 * 60) {
                out += PlanConflict(d.toString(), "$day 预计要做约 ${span(total)}，排太满")
            }
        }
        return out
    }
}

// ───────────────────────── 提示词与调用 ─────────────────────────

object AiAssistant {
    /** 每天最多几件（交给 AI 的约束） */
    const val PER_DAY = 6

    private const val DECOMPOSE_SYSTEM = """你是用户的私人日程助理。用户写了一段话，说今天想做什么、什么时候有空 / 没空。这是规划的「第一步：拆解并分配时间」：从这段话里识别出他提到的每一件事，并分清：它是**已有待办里的某一条**，还是**全新的事**；再给每件事估好需要多久、记下他说过的时间限制。这一步不排几点几分，那是第二步的事。

你会拿到：现在的日期时间 now、今天剩下的空闲分钟数 freeMinutes、待办 tasks（逾期 / 近 14 天 / 无日期，每条有 id、标题、date、time、minutes、locked 等）、进行中的项目 projects、用户写的 userText。

规则：
1.【先对照已有待办，不要重复造任务】用户提到的事，只要和 tasks 里某条待办是同一件事（哪怕说法不一样：「看书」≈「阅读第 4 章」，「写周报」≈「周报」，「锻炼」≈「跑步」），就用 existing 填那条的 id，不要再当成新任务。同一系列有好几条（第 4 章、第 5 章…）时，选还没做的、编号最小的那条。locked 的待办（重复任务、日历事件）不能匹配。一条待办最多匹配一次。
2. 只有 tasks 里确实没有的事，才算新事（existing 给空串）：动词开头、标题不超过 25 字，一句话里有好几件事就分开；吃饭、外出这类占时间的事也算，按实际估时。不要编造用户没提到的事。
3. 时长：新事的 minutes 取 5 的倍数，通常 15~90，不超过 120（太大的继续拆），估时诚实、略偏保守；已有待办的 minutes 不用你估（给 0 即可）。
4. 时间限制：用户明确说过的时间要求写进 from / to（HH:mm）。from 是最早几点开始，to 是最晚几点必须结束；没说就给空串。例：「晚上才有时间看书」→ from=21:00（「晚上」没说几点按 19:00 起）；「下午 4 点到 6 点吃饭」→ from=16:00、to=18:00、minutes=120；「下午出去」→ from=13:00、to=18:00；「上午」→ 06:00~12:00；「中午」→ 11:30~13:30；「晚上 9 点以后」→ from=21:00。
5. 估算今天放不下的、不急的事，later 标 true。所有任务加起来超过 freeMinutes 时也照实输出，不要硬压。
6. 有先后顺序的步骤按先后输出；同一件大事拆出的步骤用同一个 parent（不超过 12 字，没有就给空串）。priority 只能是 0 / 1 / 3 / 5；project 只在匹配 projects 里某个 keyword 时才填，否则给空串。最多 12 项；reason 不超过 16 字（已有待办写「就是已有的『xx』」之类）。
7. note：一句不超过 50 字的话，说识别出几件、其中几件是已有待办、几件是新事、总共约多久，语气温和，不制造焦虑。

只输出一个 JSON 对象，不要其他文字：
{"note":"","items":[{"existing":"t5","title":"","minutes":0,"priority":0,"from":"","to":"","parent":"","project":"","later":false,"reason":""}]}"""

    private const val SCHEDULE_SYSTEM = """你是用户的私人日程规划助理。这是规划的「第二步：排期」：用户写的那段话已经被识别成了若干件事（toSchedule），其中有的是**已有待办**（有 existing，只需要给它重新定时间，不新建），有的是**新事**（会新建任务）。现在要根据**已有的日程**把它们安排好。严格遵守下面的规则。

你会拿到：now、today、tasks（逾期 / 近 14 天 / 无日期的待办，每条有 id、日期、time、minutes、locked 等）、scheduled（已排好的任务和时段）、todayFreeSlots（今天从现在起还空着的时段，已扣掉已有任务的占用）、conflicts、projects、toSchedule（每条有 key、title、minutes；已有待办还有 existing、current；可能有 from / to 时间限制、priority、parent、later）。

规则：
1.【每个都要排】toSchedule 里的每一项都必须在 placements 里出现且只出现一次，用它的 key；不要改标题和 minutes。date 只能是 today 或之后，格式 yyyy-MM-dd；time 格式 HH:mm，可以为 null（全天）。有 from / to 的必须给具体 time。later 为 true 的优先放到之后的日子。
2.【用户说的时间限制是硬要求】有 from：time 不能早于 from；有 to：time + minutes 不能晚于 to。例如「晚上才有时间看书」的阅读任务，只能排在晚上，不能排下午。
3.【先看已有的日程】先看 tasks / scheduled 里已有的带时间任务和日历事件，今天再用 todayFreeSlots 里的空档放：一个任务必须整个放进一个空档里，任务之间至少隔 5 分钟，今天的 time 必须晚于 now。没有时间限制的，有精力要求的重活放上午，碎活填缝，午饭晚饭时段尽量留出来。
4.【时间占用，必须遵守】带 time 的任务，从 time 开始一直占用 minutes 分钟（endTime 是结束时刻）。同一天任何两个任务的占用时段都不能重叠，日历事件和 locked 任务占用的时段也不能占；比如 14:00 开始、约 2 小时的任务，14:00~16:00 之间不能再放别的带时间任务。今天放不下就放到之后的日子，不要硬塞；没有 time 的任务视为全天任务，不参与时段冲突，但那天所有任务的 minutes 加起来别超过约 7 小时，件数别超过 perDay。
5. toSchedule 里有先后顺序的（同一个 parent、第 N 章 / 第 N 步）编号小的排前面，同一系列同一天最多一个（都很短除外）。
6.【没提到的待办】reschedule：toSchedule 之外，逾期的、没有日期的待办，今天有空档（且不占用 toSchedule 要用的时段）就放进去，放不下的往后推；和别的任务时段重叠的错开。带 locked 的不能动。toSchedule 里的已有待办只在 placements 里排，不要再放进 reschedule。不需要动的不要动，每条理由不超过 20 字。
7. 优先级高、逾期久的先排；MIT：今天最重要的 1~3 件事放在 topThree，每条 {"ref":"待办 id（如 t5）或 toSchedule 的 key（如 n1）","why":"为什么今天要做（不超过 24 字）"}。
8. conflicts：对输入里 conflicts 的每一条给一句处理方式 {"text":"冲突描述","resolution":"怎么处理的（不超过 40 字）"}；没有就给空数组。
9. summary：2~4 句话（不超过 160 字）：今天几点到几点排了什么、哪些放到了之后、哪里留了缓冲。语气温和，不责备。

只输出一个 JSON 对象，不要其他文字：
{"summary":"","topThree":[{"ref":"n1","why":""}],"conflicts":[{"text":"","resolution":""}],"reschedule":[{"id":"t3","date":"yyyy-MM-dd","time":null,"reason":""}],"placements":[{"key":"n1","date":"yyyy-MM-dd","time":"21:00","reason":""}]}"""

    private fun weekday(d: LocalDate): String = "周" + d.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.CHINA).removePrefix("周")

    private fun priorityText(p: Int) = when {
        p >= 5 -> "高"
        p >= 3 -> "中"
        p >= 1 -> "低"
        else -> "无"
    }

    private fun JsonObject.str(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull?.trim()
    private fun JsonObject.num(k: String): Int? = (this[k] as? JsonPrimitive)?.contentOrNull?.toDoubleOrNull()?.toInt()
    private fun JsonObject.objs(k: String): List<JsonObject> = (this[k] as? JsonArray)?.mapNotNull { it as? JsonObject }.orEmpty()

    /**
     * 汇总上下文。[extra] 是读到的未来 2 周待办（含日历事件，用来看时间占用）。
     * 逾期 / 近 14 天 / 无日期的待办都交给 AI；重复任务和日历事件标记为 locked，不能改期，但它们占用的时段 AI 要避开。
     */
    fun context(
        overview: DidaOverview?,
        extra: List<DidaTask>,
        projects: List<Project>,
        recentTitles: List<String>,
        projectName: (String) -> String?,
        now: LocalDateTime = LocalDateTime.now(),
    ): PlanContext {
        val today = now.toLocalDate()
        val todayStr = today.toString()
        val horizon = today.plusDays(14)
        val seen = HashSet<String>()
        val all = ArrayList<DidaTask>()
        val sources = overview?.overdue.orEmpty() + overview?.upcoming.orEmpty() + extra + overview?.undated.orEmpty()
        for (t in sources) if (!t.done && seen.add(t.id + "|" + (t.date ?: ""))) all += t

        val overdue = all.filter { !it.isCalendar && parseDay(it.date)?.isBefore(today) == true }.sortedBy { it.date.orEmpty() }.take(25)
        val upcoming = all.filter { t -> parseDay(t.date)?.let { !it.isBefore(today) && !it.isAfter(horizon) } == true }
            .sortedWith(compareBy({ it.date.orEmpty() }, { it.time ?: "99" })).take(80)
        val undated = all.filter { !it.isCalendar && it.date == null }.take(20)
        val picked = overdue + upcoming + undated

        val idMap = HashMap<String, DidaTask>()
        val locked = HashSet<String>()
        val list = buildJsonArray {
            picked.forEachIndexed { i, t ->
                val sid = "t${i + 1}"
                idMap[sid] = t
                add(
                    buildJsonObject {
                        put("id", sid)
                        put("title", cleanTitle(t.title))
                        put("priority", priorityText(t.priority))
                        val d = parseDay(t.date)
                        if (d != null) {
                            put("date", d.toString())
                            if (d.isBefore(today)) put("overdueDays", maxOf(1L, java.time.temporal.ChronoUnit.DAYS.between(d, today)))
                        } else {
                            put("date", "无")
                        }
                        val minutes = PlanTime.estimate(t)
                        put("minutes", minutes)
                        PlanTime.minutes(t.time)?.let { s ->
                            put("time", PlanTime.fmt(s))
                            put("endTime", PlanTime.fmt(minOf(s + maxOf(minutes, 15), 24 * 60 - 1)))
                        }
                        projectName(t.projectId)?.let { put("list", it) }
                        val note = t.content.trim().replace("\n", " ")
                        if (note.isNotEmpty()) put("note", note.take(60))
                        if (t.isCalendar) put("calendar", true)
                        if (!t.repeatFlag.isNullOrBlank() || t.isCalendar) {
                            put("locked", true)
                            locked += t.id
                        }
                    },
                )
            }
        }

        val conflicts = ConflictFinder.find(picked, today, PER_DAY)

        // 已排好的任务逐条给标题和时段（最多 120 条），AI 才能看出「第 5 章排在哪天」「哪个时段被占了」
        val scheduled = buildJsonArray {
            for (t in upcoming.take(120)) add(
                buildJsonObject {
                    put("date", parseDay(t.date)?.toString() ?: "")
                    PlanTime.minutes(t.time)?.let { s ->
                        put("time", PlanTime.fmt(s))
                        put("minutes", maxOf(PlanTime.estimate(t), 15))
                    }
                    put("title", cleanTitle(t.title).take(34))
                },
            )
        }

        val projectsJson = buildJsonArray {
            for (p in projects.filter { it.status != ProjectStatus.PAUSED }.take(10)) add(
                buildJsonObject {
                    put("keyword", p.keyword)
                    put("status", p.status.label)
                    p.next.trim().takeIf { it.isNotEmpty() }?.let { put("next", it.take(50)) }
                },
            )
        }

        val payload = buildJsonObject {
            put("today", todayStr)
            put("weekday", weekday(today))
            put("now", "%02d:%02d".format(now.hour, now.minute))
            put("perDay", PER_DAY)
            put("tasks", list)
            put("scheduled", scheduled)
            put("conflicts", buildJsonArray { conflicts.forEach { add(JsonPrimitive(it.text)) } })
            put("projects", projectsJson)
            put("recentNotes", buildJsonArray { recentTitles.take(6).forEach { add(JsonPrimitive(it.take(30))) } })
        }
        return PlanContext(
            today = today,
            tasks = picked,
            idMap = idMap,
            locked = locked,
            conflicts = conflicts,
            overdueCount = overdue.size,
            todayCount = upcoming.count { parseDay(it.date) == today },
            undatedCount = undated.size,
            payload = payload,
        )
    }

    private fun currentText(t: DidaTask, today: LocalDate): String {
        val d = parseDay(t.date)
        val time = PlanTime.minutes(t.time)?.let { " " + PlanTime.fmt(it) }.orEmpty()
        return when {
            d == null -> "无日期"
            d.isBefore(today) -> "逾期 ${java.time.temporal.ChronoUnit.DAYS.between(d, today)} 天"
            d == today -> "今天$time"
            d == today.plusDays(1) -> "明天$time"
            else -> "${d.monthValue}/${d.dayOfMonth}$time"
        }
    }

    /** 用户限定了时间段、AI 却没给具体时刻时，用时间段的起点（只有「之前」就用结束前的一段）：说了「晚上看书」就必须落到具体的晚上 */
    private fun windowStart(d: DraftItem): String? {
        val lo = PlanTime.minutes(d.from)
        val hi = PlanTime.minutes(d.to)
        return when {
            lo != null -> PlanTime.fmt(lo)
            hi != null -> PlanTime.fmt(maxOf(PlanTime.DAY_START, hi - d.minutes))
            else -> null
        }
    }

    /** 第一步：从用户写的话里识别每件事（已有待办 / 新事）、估好时长、记下时间限制（不排几点） */
    suspend fun decompose(
        llm: LlmClient,
        ctx: PlanContext,
        text: String,
        projectKeys: Set<String>,
        now: LocalDateTime = LocalDateTime.now(),
    ): Pair<String, List<DraftItem>> {
        val today = ctx.today
        val free = PlanTime.freeSlots(ctx.tasks, today, PlanTime.todayFrom(now))
        val payload = buildJsonObject {
            put("today", today.toString())
            put("weekday", weekday(today))
            put("now", "%02d:%02d".format(now.hour, now.minute))
            put("freeMinutes", free.sumOf { it.second - it.first })
            ctx.payload["tasks"]?.let { put("tasks", it) }
            ctx.payload["projects"]?.let { put("projects", it) }
            put("userText", text.trim())
        }
        val reply = llm.chatJson(DECOMPOSE_SYSTEM, payload.toString(), 120)
        val obj = extractJsonObject(reply) ?: throw LlmException("AI 返回的内容格式不对，请重试")
        val usedTasks = HashSet<String>()
        val items = ArrayList<DraftItem>()
        for (o in obj.objs("items")) {
            if (items.size >= 12) break
            val pr = o.num("priority") ?: 0
            val from = o.str("from")?.let { PlanTime.minutes(it) }?.let { PlanTime.fmt(it) }
            val to = o.str("to")?.let { PlanTime.minutes(it) }?.let { PlanTime.fmt(it) }
            val existing = o.str("existing")?.takeIf { it.isNotEmpty() }?.let { ctx.idMap[it] }
            val key = "n${items.size + 1}"
            if (existing != null) {
                // 就是已有的某条待办：不新建，只给它排时间；固定的（重复任务 / 日历事件）动不了，跳过
                if (existing.id in ctx.locked || !usedTasks.add(existing.id)) continue
                items += DraftItem(
                    key = key,
                    title = cleanTitle(existing.title).take(40),
                    minutes = maxOf(PlanTime.estimate(existing), 15),
                    priority = existing.priority,
                    parent = null,
                    project = null,
                    later = (o["later"] as? JsonPrimitive)?.contentOrNull == "true",
                    reason = o.str("reason").orEmpty(),
                    taskId = existing.id,
                    current = currentText(existing, today),
                    from = from,
                    to = to,
                )
            } else {
                val title = o.str("title")?.takeIf { it.isNotEmpty() } ?: continue
                items += DraftItem(
                    key = key,
                    title = title.take(40),
                    minutes = ((o.num("minutes") ?: 30).coerceIn(5, 180) + 2) / 5 * 5,
                    priority = if (pr in listOf(0, 1, 3, 5)) pr else 0,
                    parent = o.str("parent")?.takeIf { it.isNotEmpty() },
                    project = o.str("project")?.takeIf { it in projectKeys },
                    later = (o["later"] as? JsonPrimitive)?.contentOrNull == "true",
                    reason = o.str("reason").orEmpty(),
                    from = from,
                    to = to,
                )
            }
        }
        if (items.isEmpty()) throw LlmException("AI 没有从你写的内容里识别出可做的事，换个说法再试试")
        return obj.str("note").orEmpty() to items
    }

    /** 第二步：根据已有的日程排期：已有待办重新定时间，新事新建；同时顾到逾期 / 没排期的待办 */
    suspend fun schedule(
        llm: LlmClient,
        ctx: PlanContext,
        items: List<DraftItem>,
        now: LocalDateTime = LocalDateTime.now(),
    ): AiDayPlan {
        val today = ctx.today
        val free = PlanTime.freeSlots(ctx.tasks, today, PlanTime.todayFrom(now))
        val byTaskId = ctx.tasks.associateBy { it.id }
        // 已有待办这次可能已经完成 / 不在范围里了：找不到的就不排
        val use = items.filter { it.taskId == null || byTaskId.containsKey(it.taskId) }
        val shortId = ctx.idMap.entries.associate { it.value.id to it.key }
        val existingIds = use.mapNotNull { it.taskId }.toSet()

        val payload = buildJsonObject {
            for ((k, v) in ctx.payload) put(k, v)
            put("todayFreeSlots", buildJsonArray { free.forEach { add(JsonPrimitive("${PlanTime.fmt(it.first)}–${PlanTime.fmt(it.second)}")) } })
            put(
                "toSchedule",
                buildJsonArray {
                    for (d in use) add(
                        buildJsonObject {
                            put("key", d.key)
                            put("title", d.title)
                            put("minutes", d.minutes)
                            d.taskId?.let { id ->
                                shortId[id]?.let { put("existing", it) }
                                d.current?.let { put("current", it) }
                            }
                            if (d.priority > 0) put("priority", priorityText(d.priority))
                            d.parent?.let { put("parent", it) }
                            d.from?.let { put("from", it) }
                            d.to?.let { put("to", it) }
                            if (d.later) put("later", true)
                        },
                    )
                },
            )
        }
        val reply = llm.chatJson(SCHEDULE_SYSTEM, payload.toString(), 150)
        val obj = extractJsonObject(reply) ?: throw LlmException("AI 返回的计划格式不对，请重试")

        fun validDate(s: String?): String? = parseDay(s)?.takeIf { !it.isBefore(today) }?.toString()
        fun validTime(s: String?): String? = PlanTime.minutes(s)?.let { PlanTime.fmt(it) }

        val placed = HashMap<String, JsonObject>()
        for (p in obj.objs("placements")) p.str("key")?.let { placed.putIfAbsent(it, p) }

        // 改期：① 已有待办（用户提到的，按 placements 定）② 没提到的逾期 / 没排期的（按 reschedule 定）
        var rescheduled = ArrayList<AiPlanResult.Item>()
        val times = HashMap<String, String>()
        val explicit = HashSet<String>()
        val seen = HashSet<String>()
        for (d in use) {
            val id = d.taskId ?: continue
            val t = byTaskId[id] ?: continue
            val p = placed[d.key]
            val date = validDate(p?.str("date")) ?: continue
            val time = validTime(p?.str("time")) ?: windowStart(d)
            seen += id
            if (parseDay(t.date)?.toString() == date && time == t.time) continue
            rescheduled += AiPlanResult.Item(id, date, p?.str("reason").orEmpty())
            if (time != null) times[id] = time
            explicit += id
        }
        for (r in obj.objs("reschedule")) {
            val t = r.str("id")?.let { ctx.idMap[it] } ?: continue
            if (t.id in ctx.locked || t.id in existingIds) continue
            val date = validDate(r.str("date")) ?: continue
            if (!seen.add(t.id)) continue
            val time = validTime(r.str("time"))
            if (parseDay(t.date)?.toString() == date && (time ?: t.time) == t.time) continue
            rescheduled += AiPlanResult.Item(t.id, date, r.str("reason").orEmpty())
            if (time != null) times[t.id] = time
        }
        val movedTasks = rescheduled.mapNotNull { byTaskId[it.id] }
        val busy = ctx.tasks.filter { t -> t.date != null && rescheduled.none { it.id == t.id } }
        rescheduled = ArrayList(AiPlanner.enforceSeriesOrder(rescheduled, movedTasks, busy))
        var moves = rescheduled.mapNotNull { i ->
            val t = byTaskId[i.id] ?: return@mapNotNull null
            // 用户提到的已有待办：时间以排期为准（没给就是全天）；其余：没给时间的，原来有时间、日期没过期的保留时间点
            val time = if (i.id in explicit) times[t.id] else times[t.id] ?: if ((parseDay(t.date)?.toString() ?: "") >= today.toString()) t.time else null
            AiMove(t, i.date, time, i.reason, mentioned = i.id in explicit)
        }

        // 新事：每一项都要有去处，AI 漏掉的放到今天（全天）
        var news: List<AiNewTask> = use.filter { it.taskId == null }.map { d ->
            val p = placed[d.key]
            AiNewTask(
                key = d.key,
                title = d.title,
                date = validDate(p?.str("date")) ?: today.toString(),
                time = validTime(p?.str("time")) ?: windowStart(d),
                priority = d.priority,
                minutes = d.minutes,
                reason = p?.str("reason").orEmpty(),
                parent = d.parent,
                project = d.project,
            )
        }

        // 用户说过的时间限制：新事按 key、已有待办按任务 id
        val windows = HashMap<String, Pair<Int?, Int?>>()
        for (d in use) {
            val lo = PlanTime.minutes(d.from)
            val hi = PlanTime.minutes(d.to)
            if (lo != null || hi != null) windows[d.taskId ?: d.key] = lo to hi
        }

        // 按「时间占用」兜底：模型给的时间和已有任务（含它的预计时长）重叠、或不在用户说的时间段里，就错开
        val (m2, n2, adjusted) = PlanTime.resolve(moves, news, ctx.tasks, today, now, windows)
        moves = m2
        news = n2

        val fixes = obj.objs("conflicts").mapNotNull { c ->
            val text = c.str("text")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            AiConflictFix(text, c.str("resolution").orEmpty())
        }
        val summary = obj.str("summary").orEmpty()
        val titles = use.associate { it.key to it.title }
        val top = obj.objs("topThree").take(3).mapNotNull { t ->
            var ref = t.str("ref")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            titles[ref]?.let { ref = it } ?: ctx.idMap[ref]?.let { ref = cleanTitle(it.title) }
            ref to t.str("why").orEmpty()
        }
        if (moves.isEmpty() && news.isEmpty() && summary.isEmpty()) throw LlmException("AI 没有给出可用的计划，请重试")
        return AiDayPlan(summary, top, fixes, moves, news, adjusted)
    }
}
