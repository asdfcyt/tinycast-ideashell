package com.carpe.ideashell.system

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.SystemClock
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.sin
import kotlin.math.sqrt

/** 语音胶囊用到的小控件与样式：文字 / 按钮 / 胶囊背景、停止键、录音声波。 */
internal const val CAPSULE_RED = 0xFFFF4D4F.toInt()
internal const val CAPSULE_ACCENT = 0xFFE8794A.toInt()
internal const val CAPSULE_ON_ACCENT = 0xFF24150C.toInt()

/** 录音声波最宽多少 dp */
internal const val WAVE_MAX_DP = 132

/** 波形从最窄长到最宽用的时间，之后宽度固定 */
private const val GROW_MS = 8000L


internal fun VoiceCapsuleService.smallPill(): LinearLayout = LinearLayout(this).apply {
    orientation = LinearLayout.HORIZONTAL
    gravity = Gravity.CENTER_VERTICAL
    background = capsuleBackground(22)
    setPadding(dp(16), dp(9), dp(14), dp(9))
    elevation = dp(8).toFloat()
}

internal fun VoiceCapsuleService.capsuleBackground(radiusDp: Int): GradientDrawable {
    val r = dp(radiusDp).toFloat()
    return GradientDrawable().apply {
        setColor(pal.bg)
        setStroke(dp(1), pal.stroke)
        // 左边圆头，右边贴屏幕边缘
        cornerRadii = floatArrayOf(r, r, 0f, 0f, 0f, 0f, r, r)
    }
}

internal fun VoiceCapsuleService.label(value: String, sp: Float, bold: Boolean = false) = TextView(this).apply {
    text = value
    setTextColor(pal.text)
    setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
    if (bold) typeface = Typeface.DEFAULT_BOLD
}

internal fun VoiceCapsuleService.textButton(value: String, onClick: () -> Unit) = label(value, 15f).apply {
    alpha = 0.75f
    gravity = Gravity.CENTER
    setPadding(dp(14), dp(9), dp(14), dp(9))
    pressable()
    setOnClickListener { onClick() }
}

/** 录音面板上的停止键：红色圆里一个白色圆角方块 */
internal fun VoiceCapsuleService.stopButton(): View = FrameLayout(this).apply {
    background = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(CAPSULE_RED)
    }
    contentDescription = "完成"
    addView(Square(this@stopButton), FrameLayout.LayoutParams(dp(12), dp(12), Gravity.CENTER))
    pressable()
    setOnClickListener { voice?.finish() }
}

/** 按下时轻轻缩小一点，松手弹回（点击回调不受影响） */
@android.annotation.SuppressLint("ClickableViewAccessibility")
internal fun View.pressable() {
    setOnTouchListener { v, event ->
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> v.animate().scaleX(0.92f).scaleY(0.92f).setDuration(80).start()
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> v.animate().scaleX(1f).scaleY(1f).setDuration(140).start()
        }
        false
    }
}

internal class Square(context: Context) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
    override fun onDraw(canvas: Canvas) {
        canvas.drawRoundRect(RectF(0f, 0f, width.toFloat(), height.toFloat()), width * 0.22f, height * 0.22f, paint)
    }
}

/**
 * 声波：一排竖条，靠右（停止键一侧）对齐，随录音时间慢慢向左变长，约 [GROW_MS] 后固定。
 * 竖条位置固定、只有高度在动：音量先做「起得快、落得慢」的平滑，每根有自己的起伏相位、中间的更高，
 * 每一帧按真实帧间隔让高度指数式靠近目标；变长时左边新出现的竖条是渐显的。
 * 宽度只是视图在窗口里长大（窗口是预先开到最宽的），不触发系统重排悬浮窗。
 */
internal class WaveView(context: Context, color: Int) : View(context) {
    private val density = resources.displayMetrics.density
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        this.color = color
        strokeCap = Paint.Cap.ROUND
        strokeWidth = 2.6f * density
    }
    private val slot = 5.2f * density
    private val minW = 26f * density
    private val maxW = WAVE_MAX_DP * density
    private val maxBars = (maxW / slot).toInt() + 2
    private val heights = FloatArray(maxBars)
    private val phases = FloatArray(maxBars) { i -> ((i * 37) % 11) * 0.57f }
    private var desiredW = minW
    private var live = 0f
    private var clock = 0f
    private var lastNow = 0L

    fun update(level: Float, elapsedMs: Long) {
        val now = SystemClock.uptimeMillis()
        val dt = (if (lastNow == 0L) 16L else (now - lastNow).coerceIn(1L, 50L)) / 1000f
        lastNow = now

        // 变长：正弦缓出，开头快一点、接近上限时慢慢收住
        val f = (elapsedMs.toFloat() / GROW_MS).coerceIn(0f, 1f)
        val w = minW + (maxW - minW) * sin(f * (PI / 2)).toFloat()
        if (abs(w - desiredW) >= 0.5f) {
            desiredW = w
            requestLayout()
        }

        val tau = if (level > live) 0.05f else 0.28f
        live += (level.coerceIn(0f, 1f) - live) * (1f - exp(-dt / tau))
        val amp = sqrt(live)
        clock += dt
        val follow = 1f - exp(-dt / 0.07f)
        val half = (desiredW / 2).coerceAtLeast(1f)
        for (i in 0 until maxBars) {
            val x = desiredW - slot / 2 - i * slot
            val centerWeight = 0.55f + 0.45f * cos(((x - half) / half).coerceIn(-1f, 1f) * (PI / 2)).toFloat()
            val wobble = 0.5f + 0.5f * sin(clock * 6f + i * 0.75f + phases[i])
            val target = amp * centerWeight * (0.3f + 0.7f * wobble)
            heights[i] += (target - heights[i]) * follow
        }
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(desiredW.toInt(), MeasureSpec.getSize(heightMeasureSpec).takeIf { it > 0 } ?: (30 * density).toInt())
    }

    override fun onDraw(canvas: Canvas) {
        val minH = 3.5f * density
        val w = width.toFloat()
        for (i in 0 until maxBars) {
            val x = w - slot / 2 - i * slot
            if (x < slot / 4) break
            val h = (minH + (height - minH) * heights[i].coerceIn(0f, 1f)).coerceAtMost(height.toFloat())
            // 左边缘新长出来的竖条渐显
            paint.alpha = (255 * (x / (slot * 2.5f)).coerceIn(0f, 1f)).toInt()
            canvas.drawLine(x, (height - h) / 2, x, (height + h) / 2, paint)
        }
    }
}

internal fun VoiceCapsuleService.dp(v: Int): Int = (v * resources.displayMetrics.density + 0.5f).toInt()
