package com.carpe.ideashell.ui.todos

import com.carpe.ideashell.data.calendar.CalendarState
import com.carpe.ideashell.data.dida.DidaOverview
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.dida.TodoData
import java.time.LocalDate

/** 日历同步是否在起作用（开了开关并且有权限） */
internal val CalendarState.active: Boolean get() = enabled && permission

/**
 * 把日历事件并进待办概览（只在界面层合并：小部件 / 常驻通知 / 语音修改用的仍然是纯滴答数据）。
 * - 今天起 7 天内、没处理的事件 → 「未来 7 天」；
 * - 系统待办（荣耀日历 App 里的待办）是真正的待办：逾期未完成的 → 「逾期」，没有日期的 → 「无日期」；
 * - 最近 3 天标记已处理的事件 → 「最近完成」；
 * - 已经过去的事件不算「逾期」（会议开完了不是拖延），只在往日的时间轴和日历里看。
 */
internal fun mergeCalendar(td: TodoData, cal: CalendarState, didaOn: Boolean, today: LocalDate): TodoData {
    if (!cal.active) return td
    // 滴答已连接但还没读到概览：先别拿日历事件顶上，界面还在加载
    val base = td.overview ?: if (didaOn) return td else DidaOverview()
    val lo = today.toString()
    val hi = today.plusDays(7).toString()
    val nowMs = System.currentTimeMillis()
    val upcoming = cal.events.filter { !it.done && it.date != null && it.date >= lo && it.date <= hi }
    val overdue = cal.events.filter { !it.done && it.isSystemTodo && it.date != null && it.date < lo }
    val undated = cal.events.filter { !it.done && it.isSystemTodo && it.date == null }
    val done = cal.events
        .filter { it.done && nowMs - (it.completedAt ?: 0L) < DONE_WINDOW_MS }
        .sortedByDescending { it.completedAt ?: 0L }
    return td.copy(
        overview = base.copy(
            overdue = base.overdue + overdue,
            upcoming = base.upcoming + upcoming,
            undated = base.undated + undated,
            done = base.done + done,
            projects = base.projects + cal.names,
        ),
    )
}

/** 日历缓存里并入日历事件（完成与否都放进去，日历格子 / 当天面板 / 项目页都能看到） */
internal fun mergeCalendarRanged(ranged: Map<String, DidaTask>, cal: CalendarState): Map<String, DidaTask> {
    if (!cal.active || cal.events.isEmpty()) return ranged
    return ranged + cal.events.associateBy { "${it.id}|c" }
}

private const val DONE_WINDOW_MS = 3L * 24 * 3600 * 1000
