package com.carpe.ideashell.system

import android.content.Context
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.LayoutTransition
import android.animation.ValueAnimator
import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.Build
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsAnimation
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt
import kotlinx.coroutines.cancel

/** 语音胶囊的悬浮窗：窗口、居中、输入法上推、面板外壳与换面板动画、整列滑出。 */
/** 面板共同的水平中心线，离 restingY（录音胶囊顶边）的距离：录音胶囊高 56dp，所以是 28 */
private const val CENTER_OFFSET_DP = 28

/** 录音时悬浮窗的固定宽度：录音面板里除波形外约 190dp，加上波形最宽的 [WAVE_MAX_DP] */
private const val RECORD_WINDOW_DP = 190 + WAVE_MAX_DP + 6


internal fun VoiceCapsuleService.newTransition() = LayoutTransition().apply {
    enableTransitionType(LayoutTransition.CHANGING)
    setDuration(260)
    setInterpolator(LayoutTransition.CHANGING, DecelerateInterpolator(1.6f))
}

internal fun VoiceCapsuleService.ensureColumn(): LinearLayout {
    column?.let { return it }
    val col = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.END
        // 面板变宽 / 变高时平滑过渡，而不是一下子跳过去
        layoutTransition = newTransition()
    }
    // 外面套一层 FrameLayout：平时窗口贴内容大小；编辑文字时窗口铺满全屏，列用 topMargin 留在原位，再跟着输入法上推
    val h = FrameLayout(this)
    h.addView(col, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.END))
    restingY = (resources.displayMetrics.heightPixels * 0.62f -
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_MM, 5f, resources.displayMetrics)).toInt()
    panelY = restingY
    val p = WindowManager.LayoutParams(
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.TOP or Gravity.END
        y = restingY
        softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING
    }
    wm.addView(h, p)
    host = h
    column = col
    params = p
    return col
}

internal fun VoiceCapsuleService.updateWindow() {
    val h = host ?: return
    val p = params ?: return
    runCatching { wm.updateViewLayout(h, p) }
}

/**
 * 面板（录音胶囊 / 小胶囊 / 确认卡片）都以同一条水平线为中心：内容换了、变高了，窗口随之上下对称地长，
 * 所以小胶囊点开成卡片时是上下等距地原地张开，不会整体上跳或下沉。
 */
internal fun VoiceCapsuleService.recenter() {
    val h = host ?: return
    val p = params ?: return
    if (editing) return
    // 刚退出编辑、窗口还铺满全屏（卡片还在随输入法落回去）：内容既然要换了，直接落定再居中
    if (p.height != WindowManager.LayoutParams.WRAP_CONTENT) {
        handler.removeCallbacks(restoreWindow)
        restoreWindow.run()
    }
    val dm = resources.displayMetrics
    h.measure(
        View.MeasureSpec.makeMeasureSpec(dm.widthPixels, View.MeasureSpec.AT_MOST),
        View.MeasureSpec.makeMeasureSpec(dm.heightPixels, View.MeasureSpec.AT_MOST),
    )
    val y = (restingY + dp(CENTER_OFFSET_DP) - h.measuredHeight / 2).coerceAtLeast(dp(24))
    panelY = y
    p.y = y
    // 录音时窗口一次性开到最宽：波形变宽只是窗口里的视图在长，不用每帧都让系统重排整个悬浮窗，才顺滑
    p.width = if (shown == CapsuleShown.RECORDING) dp(RECORD_WINDOW_DP).coerceAtMost(dm.widthPixels) else WindowManager.LayoutParams.WRAP_CONTENT
    updateWindow()
}

internal fun VoiceCapsuleService.surfaceScreenRect(): Rect? {
    val s = surface ?: return null
    if (s.parent !== column || s.width == 0 || s.height == 0) return null
    val loc = IntArray(2)
    s.getLocationOnScreen(loc)
    return Rect(loc[0], loc[1], loc[0] + s.width, loc[1] + s.height)
}

/** 从 [from]（旧小胶囊在屏幕上的位置）原地张开成当前面板：用裁剪框从小到大，上下左右同时展开 */
internal fun VoiceCapsuleService.expandFrom(from: Rect) {
    val s = surface ?: return
    val loc = IntArray(2)
    ValueAnimator.ofFloat(0f, 1f).apply {
        duration = 300
        interpolator = DecelerateInterpolator(1.8f)
        addUpdateListener { a ->
            if (!s.isAttachedToWindow || s.width == 0 || s.height == 0) {
                s.clipBounds = Rect(0, 0, 0, 0) // 还没排好版：先不显示，免得闪一下完整卡片
                return@addUpdateListener
            }
            val t = a.animatedValue as Float
            s.getLocationOnScreen(loc)
            val fl = loc[0]
            val ft = loc[1]
            val fr = loc[0] + s.width
            val fb = loc[1] + s.height
            fun lerp(x: Int, y: Int) = x + ((y - x) * t).toInt()
            s.clipBounds = Rect(
                lerp(from.left, fl) - fl,
                lerp(from.top, ft) - ft,
                lerp(from.right, fr) - fl,
                lerp(from.bottom, fb) - ft,
            )
        }
        addListener(object : AnimatorListenerAdapter() {
            override fun onAnimationEnd(animation: Animator) {
                s.clipBounds = null
                if (!stopping) column?.layoutTransition = newTransition()
            }
        })
        start()
    }
}

/**
 * 点到文字框：悬浮窗拿焦点，再平滑地把卡片推到输入法正上方；点卡片外面的空白处收起输入法。
 *
 * 窗口的顶边和左右边这一刻都不动，只是往下加高（给输入法的高度信息和上移留出余地）——
 * 窗口顶边一动，系统会在新画面画好之前先把旧画面摆在新位置，看起来就是卡片从屏幕上方「闪下来」。
 * 之后「上推」是整个窗口的纵向位置平滑上移，窗口大小不再变化。
 */
internal fun VoiceCapsuleService.enterEditMode() {
    val p = params ?: return
    val h = host ?: return
    val col = column ?: return
    if (editing) return
    editing = true
    handler.removeCallbacks(restoreWindow)
    cancelShift()
    imeTop = Int.MAX_VALUE
    winOffset = IntArray(2).also { h.getLocationOnScreen(it) }[1] - p.y
    p.flags = (p.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv()) or
        WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH or
        WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
    p.height = resources.displayMetrics.heightPixels
    updateWindow()
    h.setOnClickListener { exitEditMode() }
    // 点到卡片之外（别的应用上）也收起输入法
    h.setOnTouchListener { _, event ->
        if (event.actionMasked == MotionEvent.ACTION_OUTSIDE) exitEditMode()
        false
    }
    h.addOnLayoutChangeListener(columnLayoutListener)
    col.addOnLayoutChangeListener(columnLayoutListener)
    // 系统在输入法动画开始时就把「最终」的输入法高度交给这里；动画中间的数值一概不理
    h.setOnApplyWindowInsetsListener { _, insets ->
        if (Build.VERSION.SDK_INT >= 30) updateImeTop(insets.getInsets(WindowInsets.Type.ime()).bottom)
        insets
    }
    if (Build.VERSION.SDK_INT >= 30) {
        h.setWindowInsetsAnimationCallback(object : WindowInsetsAnimation.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
            override fun onProgress(insets: WindowInsets, runningAnimations: MutableList<WindowInsetsAnimation>): WindowInsets = insets

            override fun onEnd(animation: WindowInsetsAnimation) {
                // 动画走完再核对一次最终高度（比如输入法换了高度）
                h.rootWindowInsets?.let { updateImeTop(it.getInsets(WindowInsets.Type.ime()).bottom) }
            }
        })
    }
    // 悬浮窗要等系统把焦点给它之后，输入法才能弹出来：点击那一刻窗口多半还没拿到焦点，焦点一到就补弹一次
    if (!h.hasWindowFocus()) {
        h.viewTreeObserver.addOnWindowFocusChangeListener(object : android.view.ViewTreeObserver.OnWindowFocusChangeListener {
            override fun onWindowFocusChanged(hasFocus: Boolean) {
                if (!hasFocus) return
                if (h.viewTreeObserver.isAlive) h.viewTreeObserver.removeOnWindowFocusChangeListener(this)
                val v = imeTarget ?: return
                if (!editing) return
                v.requestFocus()
                (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(v, InputMethodManager.SHOW_IMPLICIT)
            }
        })
    }
    h.requestApplyInsets()
}

/** 输入法占的高度（相对窗口底边）换算成它的顶边在屏幕上的位置，再按新位置重算上推 */
internal fun VoiceCapsuleService.updateImeTop(insetBottom: Int) {
    val h = host ?: return
    if (!editing) return
    val top = if (insetBottom <= 0) {
        Int.MAX_VALUE
    } else {
        val loc = IntArray(2)
        h.getLocationOnScreen(loc)
        // 窗口往下伸出了屏幕：系统给的输入法高度是按「屏幕内可见部分」的底边算的，所以底边要取屏幕底
        min(loc[1] + h.height, resources.displayMetrics.heightPixels) - insetBottom
    }
    if (top == imeTop) return
    imeTop = top
    retargetShift(animate = true)
}

/** 卡片该上推多少（负数 = 窗口比原位置往上移多少）：卡片底边停在输入法上方，同时顶边离屏幕顶部不少于 40dp */
internal fun VoiceCapsuleService.computeShift(): Float {
    val col = column ?: return 0f
    if (imeTop == Int.MAX_VALUE) return 0f
    val avail = imeTop - dp(10)
    // 窗口在屏幕上的实际位置比 params.y 低一个状态栏高度（winOffset），这里统一按屏幕坐标算
    val panelTop = panelY + winOffset
    val targetTop = min(panelTop, avail - col.height).coerceAtLeast(min(panelTop, dp(40)))
    return (targetTop - panelTop).toFloat()
}

internal fun VoiceCapsuleService.currentShift(): Float = ((params?.y ?: panelY) - panelY).toFloat()

internal fun VoiceCapsuleService.setShift(v: Float) {
    val p = params ?: return
    p.y = panelY + v.roundToInt()
    updateWindow()
}

/**
 * 重新算上推高度。[animate]：输入法升起 / 落下这类大幅变化用一次平滑动画过去；
 * 打字换行引起的小幅变化（卡片本身的高度变化已经有布局动画）直接跟上，不重启动画。
 */
internal fun VoiceCapsuleService.retargetShift(animate: Boolean) {
    if (column == null || !editing) return
    val target = computeShift()
    shiftTarget = target
    if (shiftAnimator != null) return // 正在动：它每帧读最新的 shiftTarget
    val diff = target - currentShift()
    when {
        kotlin.math.abs(diff) < 1f -> Unit
        animate || kotlin.math.abs(diff) > dp(48) -> animateShift(target, 280L)
        else -> setShift(target)
    }
}

internal fun VoiceCapsuleService.animateShift(target: Float, durationMs: Long, onEnd: (() -> Unit)? = null) {
    if (column == null) {
        onEnd?.invoke()
        return
    }
    cancelShift()
    shiftTarget = target
    val from = currentShift()
    if (kotlin.math.abs(target - from) < 1f) {
        setShift(target)
        onEnd?.invoke()
        return
    }
    shiftAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
        duration = durationMs
        interpolator = DecelerateInterpolator(2f)
        addUpdateListener { a ->
            val t = a.animatedValue as Float
            setShift(from + (shiftTarget - from) * t)
        }
        addListener(object : AnimatorListenerAdapter() {
            private var cancelled = false
            override fun onAnimationCancel(animation: Animator) {
                cancelled = true
            }

            override fun onAnimationEnd(animation: Animator) {
                if (cancelled) return
                shiftAnimator = null
                setShift(shiftTarget)
                onEnd?.invoke()
            }
        })
        start()
    }
}

internal fun VoiceCapsuleService.cancelShift() {
    shiftAnimator?.cancel()
    shiftAnimator = null
}

internal fun VoiceCapsuleService.exitEditMode() {
    if (!editing) return
    editing = false
    imeTop = Int.MAX_VALUE
    val col = column
    // 收输入法的同时卡片平滑落回原位；落定后再把窗口缩回内容大小
    col?.let { c ->
        (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(c.windowToken, 0)
        c.findFocus()?.clearFocus()
    }
    host?.setOnClickListener(null)
    host?.setOnTouchListener(null)
    host?.isClickable = false
    handler.removeCallbacks(restoreWindow)
    animateShift(0f, 220L) { restoreWindow.run() }
}

/** 主面板的外壳：贴右边缘，左边圆头、右边贴屏幕边 */
internal fun VoiceCapsuleService.ensureSurface(): FrameLayout {
    surface?.let { if (it.parent === column) return it }
    val col = ensureColumn()
    col.removeAllViews()
    val s = FrameLayout(this).apply {
        background = capsuleBackground(26)
        elevation = dp(8).toFloat()
        isClickable = true // 吃掉点击，免得落到外层「点空白处收起输入法」
    }
    col.addView(s, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))
    surface = s
    slideIn(s, 0L)
    return s
}

/** 换面板内容：旧的淡出、新的淡入，外壳的宽高由 [LayoutTransition] 平滑过渡 */
internal fun VoiceCapsuleService.swap(content: View, onSwapped: (() -> Unit)? = null) {
    val s = ensureSurface()
    val old = s.getChildAt(0)
    if (old == null) {
        s.addView(content)
        recenter()
        onSwapped?.invoke()
        return
    }
    for (i in 1 until s.childCount) s.getChildAt(i).animate().alpha(0f).setDuration(90).start()
    old.animate().alpha(0f).setDuration(90).withEndAction {
        s.removeAllViews()
        content.alpha = 0f
        s.addView(content)
        content.animate().alpha(1f).setDuration(200).setStartDelay(60).start()
        recenter()
        onSwapped?.invoke()
    }.start()
}

internal fun VoiceCapsuleService.addSmall(view: View, delayMs: Long = 0L, animate: Boolean = true) {
    val col = ensureColumn()
    col.addView(view, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
        if (col.childCount > 0) topMargin = dp(8)
    })
    if (animate) slideIn(view, delayMs)
}

internal fun VoiceCapsuleService.slideIn(view: View, delayMs: Long) {
    view.translationX = dp(360).toFloat()
    view.animate().translationX(0f).setStartDelay(delayMs).setDuration(300)
        .setInterpolator(DecelerateInterpolator(1.8f)).start()
}

/** 整列向右滑出屏幕，再收尾 */
internal fun VoiceCapsuleService.dismissWithSlide() {
    val col = column
    if (col == null || stopping) {
        stopSelfClean()
        return
    }
    exitEditMode()
    stopping = true
    handler.removeCallbacksAndMessages(null)
    dotAnimator?.cancel()
    col.layoutTransition = null
    col.animate().translationX(col.width.toFloat() + dp(20)).setDuration(220)
        .setInterpolator(android.view.animation.AccelerateInterpolator())
        .withEndAction { stopSelfClean() }.start()
}
