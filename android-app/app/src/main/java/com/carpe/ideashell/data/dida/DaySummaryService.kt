package com.carpe.ideashell.data.dida

import com.carpe.ideashell.data.ideashell.DailyNoteService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import java.time.LocalDate
import java.time.ZoneId

data class FocusItem(val title: String, val min: Int)

data class DaySummary(
    val tasks: List<String>,
    val focusMin: Int,
    val focusPomos: Int,
    val focusByTask: List<FocusItem>,
) {
    val hasContent: Boolean get() = tasks.isNotEmpty() || focusMin > 0
}

/**
 * 今日小结：把今天完成的任务、专注时长（按任务拆分）以引用格式插到今天 Daily Note 的最前面。
 * 全部是滴答里的精确数据，不推测、不需要打字。重复生成会替换开头那一块，不会堆叠。
 * 滴答 MCP 只能读 / 写专注记录，不能启动计时：计时在滴答里进行，这里读回来显示。
 */
class DaySummaryService(
    private val api: DidaApi,
    private val dailyNotes: DailyNoteService,
    private val hasDida: () -> Boolean,
) {
    /** 近 7 天（含今天）的专注记录汇总；番茄钟与正计时两种都读，都失败才抛异常 */
    suspend fun focus(today: LocalDate = LocalDate.now()): FocusSummary = coroutineScope {
        val zone = ZoneId.systemDefault()
        val from = today.minusDays(6)
        val to = today.plusDays(1)
        val pomo = async { attempt { api.focusRaw(from, to, 0) } }
        val timing = async { attempt { api.focusRaw(from, to, 1) } }
        val a = pomo.await()
        val b = timing.await()
        if (a.isFailure && b.isFailure) throw a.exceptionOrNull()!!
        FocusParser.summarize(
            listOf(true to a.getOrDefault(""), false to b.getOrDefault("")),
            today,
            zone,
        )
    }

    suspend fun collect(today: LocalDate = LocalDate.now()): DaySummary = coroutineScope {
        if (!hasDida()) throw IllegalStateException("还没有连接滴答清单，无法汇总今天完成的任务和专注")
        val doneJob = async { api.completedOn(today) }
        val focusJob = async { attempt { focus(today) }.getOrNull() }
        val done = doneJob.await()
        val focus = focusJob.await()

        val titles = HashMap<String, String>(focus?.titles.orEmpty())
        for (t in done) titles.putIfAbsent(t.id, t.title)

        val byTask = focus?.byTask.orEmpty()
            .filterValues { it.todayMin > 0 }
            .map { (id, f) -> FocusItem(titles[id] ?: "（未关联任务）", f.todayMin) }
            .sortedByDescending { it.min }

        DaySummary(
            tasks = done.map { it.title },
            focusMin = focus?.todayMin ?: 0,
            focusPomos = focus?.todayPomos ?: 0,
            focusByTask = byTask,
        )
    }

    /** 引用格式：整块每行以 `> ` 开头，细项缩进成子列表，不带时间戳 */
    fun format(s: DaySummary): String {
        val lines = mutableListOf("**$MARKER**")
        if (s.tasks.isNotEmpty()) {
            lines += "- 完成 ${s.tasks.size} 项任务"
            s.tasks.take(MAX_TASKS).forEach { lines += "  - $it" }
            if (s.tasks.size > MAX_TASKS) lines += "  - ……还有 ${s.tasks.size - MAX_TASKS} 项"
        }
        if (s.focusMin > 0) {
            val pomo = if (s.focusPomos > 0) "（${s.focusPomos} 个番茄）" else ""
            lines += "- 专注 ${FocusParser.formatMinutes(s.focusMin)}$pomo"
            s.focusByTask.take(MAX_FOCUS_TASKS).forEach { lines += "  - ${it.title}：${FocusParser.formatMinutes(it.min)}" }
        }
        return lines.joinToString("\n") { "> $it" }
    }

    /** 汇总并插到今天 Daily Note 的最前面；今天什么都没有时返回 null，不写入 */
    suspend fun write(): DaySummary? {
        val s = collect()
        if (!s.hasContent) return null
        dailyNotes.prependBlockToToday(format(s), MARKER)
        return s
    }

    fun hud(s: DaySummary?): String =
        if (s != null) "今日小结已插到 Daily Note 最前面：完成 ${s.tasks.size} 项 · 专注 ${FocusParser.formatMinutes(s.focusMin)}"
        else "今天还没有完成的任务或专注记录"

    private inline fun <T> attempt(block: () -> T): Result<T> = try {
        Result.success(block())
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        Result.failure(e)
    }

    private companion object {
        const val MAX_TASKS = 20
        const val MAX_FOCUS_TASKS = 10

        /** 开头引用块的标记：重复生成时靠它识别并替换 */
        const val MARKER = "今日小结"
    }
}
