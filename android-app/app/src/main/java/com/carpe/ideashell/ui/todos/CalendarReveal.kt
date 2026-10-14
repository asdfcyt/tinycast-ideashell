package com.carpe.ideashell.ui.todos

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.spring
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.abs

/**
 * 「任务 ⇄ 日历」的展开进度：0 = 只有任务列表，1 = 整个日历。
 * 手指拖动时进度跟着手指走（[dragBy]），松手后按位置和速度顺势滑到 0 或 1（[release]）；
 * 点按钮、菜单切换这类没有手势的情况直接 [settle]。
 */
@Stable
internal class CalendarReveal(initial: Float, private val scope: CoroutineScope) {
    /** 当前进度，只在绘制阶段（graphicsLayer）里读，拖动时不会引起重组 */
    var progress by mutableFloatStateOf(initial)
        private set

    /** 手指是否正按在上面 */
    var dragging by mutableStateOf(false)
        private set

    /** 走完整个过程对应的手指位移（像素），由界面按屏幕密度填入 */
    var travel: Float = 1f

    /** 最近一次要去的终点：true = 日历 */
    var target: Boolean = initial >= 1f
        private set

    private var origin = target
    private var job: Job? = null

    fun dragStart() {
        job?.cancel()
        dragging = true
        origin = target
    }

    /** dy > 0 是往下拖（展开日历），dy < 0 是往上拖（收起） */
    fun dragBy(dy: Float) {
        if (!dragging) dragStart()
        progress = (progress + dy / travel).coerceIn(0f, 1f)
    }

    /** 松手：返回最终停在日历（true）还是列表（false） */
    fun release(velocity: Float): Boolean {
        val v = velocity / travel
        val open = when {
            abs(v) > FLING -> v > 0
            // 从列表往下拉：过 30% 就算进；从日历往上推：要推过 30% 才算出
            origin -> progress > 0.7f
            else -> progress > 0.3f
        }
        dragging = false
        settle(open, v)
        return open
    }

    fun settle(open: Boolean, velocity: Float = 0f) {
        target = open
        job?.cancel()
        job = scope.launch {
            animate(
                initialValue = progress,
                targetValue = if (open) 1f else 0f,
                initialVelocity = velocity,
                animationSpec = spring(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = Spring.StiffnessMediumLow),
            ) { value, _ -> progress = value.coerceIn(0f, 1f) }
        }
    }

    private companion object {
        /** 每秒走完整个过程的比例，超过就按「甩」处理 */
        const val FLING = 1.6f
    }
}
