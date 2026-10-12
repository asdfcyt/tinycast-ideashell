package com.carpe.ideashell.domain

import com.carpe.ideashell.data.dida.FocusSummary
import com.carpe.ideashell.data.project.Project
import com.carpe.ideashell.data.project.ProjectStats
import com.carpe.ideashell.data.project.ProjectStatus
import com.carpe.ideashell.data.project.firstMatching
import java.time.LocalDate

/** 一个项目在回顾范围里占的份额 */
data class ProjectSlice(
    val project: Project,
    /** 范围内归在这个项目名下的专注分钟（没有专注数据时为 0） */
    val focusMin: Int,
    /** 范围内提到它的记录条数：笔记 + 日记 + 完成的待办 */
    val activity: Int,
    /** 距上次提及的天数；项目统计还没算出来为 null */
    val gapDays: Int?,
    /** 超过提醒天数没提及（搁置的项目不算） */
    val stale: Boolean,
)

/**
 * 回顾顶部的「时间去哪了」：把范围内的专注时长按项目拆开；
 * 滴答没有专注记录（或没连接）时，退而按记录条数拆，由 [byFocus] 告诉界面用哪种单位。
 */
data class ProjectFlow(
    /** 份额从大到小；久没提及的项目即使这段时间没动静也会在末尾，用来提醒 */
    val slices: List<ProjectSlice>,
    /** 没有归到任何项目的专注分钟 */
    val otherMin: Int,
    val totalMin: Int,
    val byFocus: Boolean,
) {
    val isEmpty: Boolean get() = slices.isEmpty() && otherMin == 0

    /** 堆叠条里每一段的权重（和 [slices] 一一对应） */
    fun weightOf(s: ProjectSlice): Int = if (byFocus) s.focusMin else s.activity

    companion object {
        val Empty = ProjectFlow(emptyList(), 0, 0, false)

        fun build(
            projects: List<Project>,
            data: TimelineData,
            focus: FocusSummary?,
            stats: Map<String, ProjectStats>,
            today: LocalDate = LocalDate.now(),
        ): ProjectFlow {
            if (projects.isEmpty()) return Empty

            // 记录条数：每条记录只算给第一个命中的项目（与待办归属的规则一致）
            val activity = HashMap<String, Int>()
            fun hit(text: String, tags: List<String> = emptyList()) {
                projects.firstMatching(text, tags)?.let { activity.merge(it.keyword, 1, Int::plus) }
            }
            // 任务 id → 任务，用来把专注记录对回项目
            val tasks = HashMap<String, com.carpe.ideashell.data.dida.DidaTask>()
            for (day in data.days) {
                day.notes.forEach { n -> hit("${n.title} ${n.summary.orEmpty()}", n.tags) }
                day.daily.forEach { e -> hit(e.text) }
                day.todos.forEach { t ->
                    tasks[t.id] = t
                    if (t.done) hit(t.title, t.tags)
                }
            }

            val focusMin = HashMap<String, Int>()
            var otherMin = 0
            var totalMin = 0
            if (focus != null) {
                for ((id, f) in focus.byTask) {
                    val min = f.weekMin
                    if (min <= 0) continue
                    totalMin += min
                    val task = tasks[id]
                    val title = task?.title ?: focus.titles[id]
                    val project = title?.let { projects.firstMatching(it, task?.tags.orEmpty()) }
                    if (project != null) focusMin.merge(project.keyword, min, Int::plus) else otherMin += min
                }
            }
            val byFocus = totalMin > 0

            val slices = projects.map { p ->
                val gap = stats[p.keyword]?.lastDay?.let { Dossier.daysBetween(it, today) }
                ProjectSlice(
                    project = p,
                    focusMin = focusMin[p.keyword] ?: 0,
                    activity = activity[p.keyword] ?: 0,
                    gapDays = gap,
                    stale = p.status != ProjectStatus.PAUSED && gap != null && gap >= p.staleDays,
                )
            }.filter { s -> s.focusMin > 0 || s.activity > 0 || s.stale }
                .sortedWith(
                    compareByDescending<ProjectSlice> { if (byFocus) it.focusMin else it.activity }
                        .thenByDescending { it.stale }
                        .thenBy { it.project.keyword.lowercase() },
                )
            return ProjectFlow(slices, otherMin, totalMin, byFocus)
        }
    }
}
