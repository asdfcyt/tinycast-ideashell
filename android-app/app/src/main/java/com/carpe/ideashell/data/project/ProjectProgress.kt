package com.carpe.ideashell.data.project

import com.carpe.ideashell.domain.Dossier
import java.time.LocalDate

/**
 * 项目进展的统计模型。原则：只用精确数据（任务状态、笔记里的 `- [x]`、提及的笔记、专注记录），不做猜测。
 *
 * - 主指标「交付进度」：以「成果」（一个任务笔记 = 一个要交付的成果）为单位，每个成果等权（挣值法）：
 *   已交付的成果记 1，进行中的成果按「行动步骤」勾选比例记分，没有步骤记 0；
 *   交付进度 = 得分之和 ÷ 成果数。没有任务笔记的项目，退回「任务完成率」。
 * - 辅助指标：在制品（进行中的成果数，看板理论：同时推进太多会拖慢交付）、势头（最近 7 天与前 7 天的活跃天数对比）、专注投入。
 */

enum class DeliveryState(val label: String) {
    DONE("已交付"),
    ACTIVE("进行中"),
    UNKNOWN("状态未知"),
}

/** 一个成果（任务笔记）的交付情况 */
data class DeliveryItem(
    val title: String,
    val noteId: String,
    val state: DeliveryState,
    val stepsDone: Int = 0,
    val stepsTotal: Int = 0,
) {
    /** 这个成果贡献的得分：已交付 1；进行中按步骤比例；其余 0 */
    val score: Float
        get() = when {
            state == DeliveryState.DONE -> 1f
            state == DeliveryState.ACTIVE && stepsTotal > 0 -> stepsDone.toFloat() / stepsTotal
            else -> 0f
        }
}

data class ProjectDelivery(
    val keyword: String,
    val at: Long,
    val items: List<DeliveryItem>,
) {
    val delivered: Int get() = items.count { it.state == DeliveryState.DONE }
    val active: Int get() = items.count { it.state == DeliveryState.ACTIVE }
    val unknown: Int get() = items.count { it.state == DeliveryState.UNKNOWN }

    /** 参与计算的成果数（状态未知的不计入，宁可少算也不乱猜） */
    val counted: Int get() = delivered + active

    /** 进行中成果的步骤合计 */
    val stepsDone: Int get() = items.filter { it.state == DeliveryState.ACTIVE }.sumOf { it.stepsDone }
    val stepsTotal: Int get() = items.filter { it.state == DeliveryState.ACTIVE }.sumOf { it.stepsTotal }

    /** 交付进度 0..1；没有可计的成果为 null */
    val progress: Float?
        get() = if (counted == 0) null else items.filter { it.state != DeliveryState.UNKNOWN }.sumOf { it.score.toDouble() }.toFloat() / counted
}

data class ProjectFocusSession(val startMs: Long, val endMs: Long, val title: String) {
    val minutes: Int get() = Math.round((endMs - startMs) / 60000.0).toInt().coerceAtLeast(0)
}

/** 项目的专注统计：滴答里属于该项目任务的专注，加上从项目页发起的专注（按开始时间去重） */
data class ProjectFocusStats(
    val keyword: String,
    val at: Long,
    val todayMin: Int,
    val weekMin: Int,
    val monthMin: Int,
    /** 统计窗口（[windowDays] 天）内的累计 */
    val totalMin: Int,
    val windowDays: Int,
    val count: Int,
    /** 近 14 天每天的分钟数，最早的在前 */
    val daily14: List<Int>,
    /** 按任务拆分（分钟，从多到少） */
    val byTask: List<Pair<String, Int>>,
    /** 最近的几次（新的在前） */
    val sessions: List<ProjectFocusSession>,
    /** 有专注的日子（算势头用） */
    val activeDays: Set<LocalDate>,
)

enum class Trend(val label: String, val arrow: String) {
    UP("加速", "↑"),
    FLAT("平稳", "→"),
    DOWN("放缓", "↓"),
    IDLE("停滞", "·"),
}

object ProjectPulse {
    /** 有动静的日子：提及了这个项目的笔记那天，或有过专注那天 */
    fun activeDays(stats: ProjectStats?, focus: ProjectFocusStats?): Set<LocalDate> {
        val out = HashSet<LocalDate>()
        stats?.mentions?.forEach { m -> m.day?.let(out::add) }
        focus?.let { out += it.activeDays }
        return out
    }

    /** （最近 7 天的活跃天数, 前 7 天的活跃天数） */
    fun windowCounts(days: Set<LocalDate>, today: LocalDate = LocalDate.now()): Pair<Int, Int> {
        var cur = 0
        var prev = 0
        for (d in days) {
            val ago = Dossier.daysBetween(d, today)
            if (ago in 0..6) cur++ else if (ago in 7..13) prev++
        }
        return cur to prev
    }

    /** 最近 7 天与前 7 天的活跃天数对比 */
    fun trend(days: Set<LocalDate>, today: LocalDate = LocalDate.now()): Trend {
        val (cur, prev) = windowCounts(days, today)
        return when {
            cur == 0 && prev == 0 -> Trend.IDLE
            cur > prev -> Trend.UP
            cur == prev -> Trend.FLAT
            else -> Trend.DOWN
        }
    }

    /** 同时进行的成果超过这个数，就提醒先收尾（看板的在制品限制） */
    const val WIP_LIMIT = 3
}
