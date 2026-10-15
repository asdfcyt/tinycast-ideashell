package com.carpe.ideashell.core.revisit

import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * FSRS-5（官方默认参数，不做参数优化）。纯函数，不依赖 Android。
 *
 * 只用三档评分：忘了 = Again(1)，记得 = Good(3)，太简单 = Easy(4)；不提供 Hard，减少选择负担。
 * 笔记没有标准答案，所以评分是「自评是否还记得要点」，只用来排期，不是学习成绩。
 */
object Fsrs {
    enum class Rating(val grade: Int) { AGAIN(1), GOOD(3), EASY(4) }

    /** 一张卡的记忆状态：稳定性 S（天，R 掉到 90% 所需的时间）与难度 D（1–10） */
    data class Memory(val stability: Double, val difficulty: Double)

    private val W = doubleArrayOf(
        0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
        1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621,
    )

    private const val DECAY = -0.5
    private const val FACTOR = 19.0 / 81.0
    private const val MIN_STABILITY = 0.01
    private const val MAX_INTERVAL_DAYS = 36500

    /** 目标记忆率的可选范围 */
    const val MIN_RETENTION = 0.80
    const val MAX_RETENTION = 0.95
    const val DEFAULT_RETENTION = 0.90

    /** 经过 [elapsedDays] 天后，还记得的概率 */
    fun retrievability(elapsedDays: Double, stability: Double): Double {
        if (elapsedDays <= 0.0) return 1.0
        return (1.0 + FACTOR * elapsedDays / max(stability, MIN_STABILITY)).pow(DECAY)
    }

    /** 想把记忆率维持在 [retention] 时，下次复习的间隔（天，至少 1） */
    fun intervalDays(stability: Double, retention: Double): Int {
        val r = retention.coerceIn(MIN_RETENTION, MAX_RETENTION)
        val days = stability / FACTOR * (r.pow(1.0 / DECAY) - 1.0)
        // 数据异常（稳定性是 NaN / 无穷）时 roundToInt 会抛异常：按最短间隔处理
        if (days.isNaN()) return 1
        return days.coerceIn(1.0, MAX_INTERVAL_DAYS.toDouble()).roundToInt()
    }

    private fun initialStability(r: Rating): Double = max(W[r.grade - 1], MIN_STABILITY)

    private fun initialDifficulty(grade: Int): Double =
        (W[4] - exp(W[5] * (grade - 1)) + 1.0).coerceIn(1.0, 10.0)

    /** 第一次复习：只看评分，不看经过了多久 */
    fun first(rating: Rating): Memory =
        Memory(initialStability(rating), initialDifficulty(rating.grade))

    /** 之后的复习：[elapsedDays] 是距上次复习过去的天数（可以是小数） */
    fun next(memory: Memory, elapsedDays: Double, rating: Rating): Memory {
        val s = max(memory.stability, MIN_STABILITY)
        val d = memory.difficulty
        val r = retrievability(elapsedDays, s)

        val newD = run {
            val delta = -W[6] * (rating.grade - 3)
            val damped = d + delta * (10.0 - d) / 9.0
            // 向「最简单」时的初始难度回归一点，避免难度越走越极端
            (W[7] * initialDifficulty(4) + (1.0 - W[7]) * damped).coerceIn(1.0, 10.0)
        }

        val newS = if (rating == Rating.AGAIN) {
            val forgot = W[11] * d.pow(-W[12]) * ((s + 1.0).pow(W[13]) - 1.0) * exp(W[14] * (1.0 - r))
            // 忘了之后的稳定性不会比忘之前更高
            min(forgot, s)
        } else {
            val easyBonus = if (rating == Rating.EASY) W[16] else 1.0
            s * (1.0 + exp(W[8]) * (11.0 - d) * s.pow(-W[9]) * (exp(W[10] * (1.0 - r)) - 1.0) * easyBonus)
        }
        return Memory(max(newS, MIN_STABILITY), newD)
    }

    /**
     * 这次评分之后，下次间隔多少天：忘了固定明天再来；记得按目标记忆率排；
     * 太简单一定比「记得」更长（至少多 1 天）。
     */
    fun nextIntervalDays(
        memory: Memory?,
        elapsedDays: Double,
        rating: Rating,
        retention: Double,
    ): Int {
        if (rating == Rating.AGAIN) return 1
        fun days(r: Rating): Int {
            val m = if (memory == null) first(r) else next(memory, elapsedDays, r)
            return intervalDays(m.stability, retention)
        }
        val good = days(Rating.GOOD)
        return if (rating == Rating.GOOD) good else max(days(Rating.EASY), good + 1)
    }
}
