package com.carpe.ideashell.data.asr

import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.dida.TodoRepository
import com.carpe.ideashell.data.project.Project
import java.time.LocalDate

/**
 * 语音整理用的「上下文」：只取拾忆本地已经有的数据（不读屏幕、不额外请求网络）。
 * - [hotwords]：闪念贝壳文件夹、项目关键词和标签、滴答清单的清单名和任务标签、较短的待办标题——
 *   给云端识别当热词，也告诉大模型「读音相近就改成这些词」；
 * - [todoLines]：目前未完成的待办（任务名｜日期 时间），给大模型判断「改 / 完成 / 删除 / 推迟 / 查询」指的是哪一条。
 */
class VoiceContext(
    private val folders: () -> List<String>,
    private val projects: () -> List<Project>,
    private val todos: TodoRepository,
) {
    /** 自动热词按来源分组（设置里「语音词库」展示用）；每组已去掉不适合当热词的 */
    fun hotwordSources(): List<Pair<String, List<String>>> {
        val overview = todos.peek()
        val open = openTasks()
        fun clean(list: List<String>) = list.map { it.trim().removePrefix("#") }.filter(Lexicon::isValidHotword).distinct()
        return listOf(
            "闪念贝壳文件夹" to clean(folders()),
            "项目关键词与标签" to clean(projects().flatMap { it.terms }),
            "滴答清单与任务标签" to clean(overview?.projects?.values.orEmpty().toList() + open.flatMap { it.tags }),
            "待办标题" to clean(open.map { it.title }),
        ).filter { it.second.isNotEmpty() }
    }

    fun hotwords(): List<String> = hotwordSources().flatMap { it.second }.distinct()

    fun todoLines(): List<String> {
        val today = LocalDate.now()
        return openTasks().take(MAX_LINES).map { t ->
            val whenText = listOfNotNull(t.date?.let { dayLabel(it, today) }, t.time).joinToString(" ")
            t.title.trim().take(24) + if (whenText.isEmpty()) "" else "｜$whenText"
        }
    }

    /** 未完成的待办：已逾期和近 7 天的按时间排，再接上收集箱最新的几条无日期任务 */
    private fun openTasks(): List<DidaTask> {
        val o = todos.peek() ?: return emptyList()
        val dated = (o.overdue + o.upcoming).filterNot { it.done }.sortedWith(compareBy({ it.date ?: "9999" }, { it.time ?: "99:99" }))
        val undated = o.undated.filterNot { it.done }.take(UNDATED_LINES)
        return (dated + undated).distinctBy { it.id }
    }

    private fun dayLabel(date: String, today: LocalDate): String {
        val d = runCatching { LocalDate.parse(date) }.getOrNull() ?: return date
        return when (d) {
            today -> "今天"
            today.plusDays(1) -> "明天"
            today.plusDays(2) -> "后天"
            else -> "${d.monthValue}月${d.dayOfMonth}日"
        }
    }

    private companion object {
        const val MAX_LINES = 40
        const val UNDATED_LINES = 10
    }
}
