package com.carpe.ideashell.system

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.LayoutTransition
import android.animation.ValueAnimator
import android.animation.ObjectAnimator
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.text.InputType
import android.text.TextUtils
import android.util.TypedValue
import android.view.Choreographer
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsAnimation
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.R
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.core.voice.VoiceIntent
import com.carpe.ideashell.data.settings.ThemeMode
import com.carpe.ideashell.core.voice.VoiceResult
import com.carpe.ideashell.ui.capture.voiceIntentBody
import com.carpe.ideashell.ui.capture.voiceIntentSchedule
import com.carpe.ideashell.ui.components.VoiceInputController
import com.carpe.ideashell.ui.components.VoicePhase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.LocalTime
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.sin
import kotlin.math.min
import kotlin.math.sqrt

/**
 * 「语音记一条」的悬浮录音胶囊（贴在屏幕右边缘）：
 * 录音（红点 + 秒数 + 声波 + 停止）→ 整理中 → 确认卡片（可改字、改类型、放弃、重新说）→ 保存后每条一个小胶囊滑出。
 * 开了「松手自动保存」时不弹确认卡片，只显示小胶囊并倒计时几秒后自动保存，点它才展开确认卡片。
 * 「问 AI」「追加到上一条笔记」这类话和快速输入面板一样处理。
 * 颜色跟随应用主题（浅色 / 深色）。
 *
 * 结束录音有三种方式：点停止、说完停顿自动结束（设置里可关）、音量键按住说话时松手（[VoiceKeyHandler]）。
 * 用前台服务（麦克风类型）持有录音，用「显示在其他应用上层」的悬浮窗画胶囊，所以两个权限都要有。
 */
class VoiceCapsuleService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val handler = Handler(Looper.getMainLooper())
    private val wm by lazy { getSystemService(WINDOW_SERVICE) as WindowManager }
    private val settings get() = (application as IdeashellApp).container.settings

    /** 贴右边缘的透明竖列窗口：里面是主面板（录音 / 整理 / 确认），或保存后的几个小胶囊 */
    private var host: FrameLayout? = null
    private var column: LinearLayout? = null
    private var params: WindowManager.LayoutParams? = null
    private var surface: FrameLayout? = null
    private var restingY = 0

    /** 面板当前所在的 y（窗口顶边） */
    private var panelY = 0

    private var voice: VoiceInputController? = null
    private var shown = Shown.NONE
    private var stopping = false
    private var holdMode = false

    // 录音面板里要刷新的控件
    private var timerText: TextView? = null
    private var wave: WaveView? = null
    private var dotAnimator: ObjectAnimator? = null
    private var recStart = 0L
    private var lastTimerSec = -1

    // 说完停顿自动结束
    private var noise = 0f
    private var speechMs = 0L
    private var lastVoiceMs = 0L
    private var lastTickMs = 0L

    // 确认卡片
    private enum class Mode(val label: String) {
        AUTO("自动"), TODO("待办"), DAILY("日记"), NOTE("笔记"), APPEND("追加"), ASK("问 AI"),
    }

    private class Draft(var mode: Mode, var text: String, val intent: VoiceIntent?)
    private val drafts = ArrayList<Draft>()
    private var editing = false

    /** 松手自动保存：小胶囊倒计时，结束时才真正保存 */
    private var countdown: ValueAnimator? = null

    // 编辑文字时跟着输入法上推
    private var imeBottom = 0
    private var imeAnimating = false

    private enum class Shown { NONE, RECORDING, PROCESSING, CONFIRM, PENDING, MESSAGE }

    private class Palette(dark: Boolean) {
        val bg = if (dark) 0xF01C1C1E.toInt() else 0xF7FFFFFF.toInt()
        val stroke = if (dark) 0x26FFFFFF else 0x1F000000
        val text = if (dark) 0xFFFFFFFF.toInt() else 0xFF1C1C1E.toInt()
        val accentSoft = if (dark) 0xFFFFB48A.toInt() else 0xFFC4561F.toInt()
        val chipBg = if (dark) 0x33E8794A else 0x1FE8794A
        val green = if (dark) 0xFF7BE0A0.toInt() else 0xFF1E9E57.toInt()
        val error = if (dark) 0xFFFFB4B4.toInt() else 0xFFC62828.toInt()
    }

    private var pal = Palette(true)

    private fun resolvePalette(): Palette {
        val dark = when (settings.current.themeMode) {
            ThemeMode.DARK -> true
            ThemeMode.LIGHT -> false
            ThemeMode.SYSTEM -> (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        }
        return Palette(dark)
    }

    /** 跟着屏幕刷新（vsync）驱动，比 Handler 定时更跟手，波形滚动不会一顿一顿 */
    private val frameCallback: Choreographer.FrameCallback = Choreographer.FrameCallback { tick.run() }

    private fun scheduleTick() = Choreographer.getInstance().postFrameCallback(frameCallback)

    private fun stopTick() = Choreographer.getInstance().removeFrameCallback(frameCallback)

    private val tick: Runnable = object : Runnable {
        override fun run() {
            if (stopping) return
            val v = voice ?: return
            when (v.phase) {
                VoicePhase.RECORDING, VoicePhase.LOCKED -> {
                    if (shown != Shown.RECORDING) renderRecording()
                    onRecordingTick(v)
                }
                VoicePhase.PROCESSING -> if (shown != Shown.PROCESSING) renderProcessing()
                VoicePhase.IDLE -> Unit
            }
            scheduleTick()
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CANCEL -> {
                voice?.cancel()
                stopSelfClean()
            }
            ACTION_FINISH -> {
                startForegroundNow()
                val v = voice
                if (v == null) stopSelfClean() else v.finish()
            }
            else -> {
                startForegroundNow()
                val hold = intent?.getBooleanExtra(EXTRA_HOLD, false) == true
                val v = voice
                val recording = v != null && (v.phase == VoicePhase.RECORDING || v.phase == VoicePhase.LOCKED)
                when {
                    // 已经在录：点磁贴 / 快捷方式再来一次就是「完成」；按住说话的重复触发忽略
                    recording -> if (!hold) v?.finish()
                    // 正在整理 / 等着确认：不重复开始
                    v != null && (shown == Shown.PROCESSING || shown == Shown.CONFIRM || shown == Shown.PENDING) -> Unit
                    else -> begin(hold)
                }
            }
        }
        return START_NOT_STICKY
    }

    /** 音量键松手：结束录音（按住说话） */
    fun onKeyReleased() {
        val v = voice
        if (v != null && holdMode && (v.phase == VoicePhase.RECORDING || v.phase == VoicePhase.LOCKED)) v.finish()
        else pendingRelease = true // 录音还没真正开始就松手了：开始后立刻结束
    }

    private fun startForegroundNow() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "语音记一条", NotificationManager.IMPORTANCE_LOW))
        val finish = PendingIntent.getService(
            this, 0, Intent(this, VoiceCapsuleService::class.java).setAction(ACTION_FINISH),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_shiyi)
            .setContentTitle("拾忆 · 语音记一条")
            .setContentText("正在录音，说完点「完成」")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(0, "完成", finish)
            .build()
        val type = if (Build.VERSION.SDK_INT >= 30) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
    }

    private fun begin(hold: Boolean) {
        if (!Settings.canDrawOverlays(this)) {
            stopSelfClean()
            return
        }
        val container = (application as IdeashellApp).container
        val controller = voice ?: VoiceInputController(
            scope = scope,
            settings = container.settings,
            asr = container.asr,
            local = container.localAsr,
            llm = container.llm,
            lexicon = container.lexicon,
            extraHotwords = { container.folders.folders.value.map { it.name } },
            onError = { showMessage(it, error = true) },
            onResult = { result -> onResult(result) },
        ).also { voice = it }
        holdMode = hold
        stopping = false
        drafts.clear()
        cancelCountdown()
        pal = resolvePalette()
        ensureColumn()
        if (!controller.start()) return // start() 已经通过 onError 说明了原因
        recStart = SystemClock.uptimeMillis()
        lastTimerSec = -1
        noise = 0f
        speechMs = 0L
        lastVoiceMs = 0L
        lastTickMs = 0L
        renderRecording()
        stopTick()
        scheduleTick()
        if (hold && pendingRelease) {
            pendingRelease = false
            controller.finish()
        }
    }

    // ───────────────────────────── 录音中的刷新与自动结束 ─────────────────────────────

    private fun onRecordingTick(v: VoiceInputController) {
        val elapsed = SystemClock.uptimeMillis() - recStart
        val sec = (elapsed / 1000).toInt()
        if (sec != lastTimerSec) {
            lastTimerSec = sec
            timerText?.text = "%d:%02d".format(sec / 60, sec % 60)
        }

        // 声波：位置固定的一排竖条，每帧弹性地靠近各自的目标高度（见 [WaveView]）
        wave?.update(v.level)

        // 说完停顿自动结束：说话达到一小段后，安静超过设定时间就结束；一直没人说话就放弃
        if (holdMode || !settings.current.voiceAutoStop) return
        val dt = if (lastTickMs == 0L) 0L else elapsed - lastTickMs
        lastTickMs = elapsed
        val level = v.level
        val threshold = maxOf(0.06f, noise * 2.5f + 0.03f)
        if (level > threshold) {
            speechMs += dt
            lastVoiceMs = elapsed
        } else if (elapsed - lastVoiceMs > 400) {
            noise = if (noise == 0f) level else noise * 0.9f + level * 0.1f
        }
        val heard = speechMs >= 250
        if (heard && elapsed - lastVoiceMs >= settings.current.voiceSilenceMs) {
            v.finish()
        } else if (!heard && elapsed >= NO_SPEECH_MS) {
            v.cancel()
            showMessage("没有听到声音", error = true)
        }
    }

    // ───────────────────────────── 结果：确认或直接保存 ─────────────────────────────

    private fun onResult(result: VoiceResult) {
        drafts.clear()
        drafts.addAll(buildDrafts(result))
        // 开了「松手自动保存」：不弹确认卡片，只显示小胶囊倒计时；点它才展开卡片修改
        if (settings.current.voiceAutoSend) renderPending(result.polishError) else renderConfirm(result.polishError)
    }

    private fun buildDrafts(result: VoiceResult): List<Draft> {
        if (result.intents.isEmpty()) {
            return listOf(Draft(if (result.appendToLast) Mode.APPEND else Mode.AUTO, result.cleaned, null))
        }
        return result.intents.map { intent ->
            val mode = when {
                intent.ask -> Mode.ASK
                intent.append -> Mode.APPEND
                else -> when (intent.type) {
                    CaptureKind.TODO -> Mode.TODO
                    CaptureKind.DAILY -> Mode.DAILY
                    CaptureKind.NOTE -> Mode.NOTE
                }
            }
            Draft(mode, intent.content, intent)
        }
    }

    private class SavedItem(val tag: String, val text: String)

    /** [quiet]：自动保存倒计时结束后的保存，小胶囊原地变成 ✓ 很快收起，不再重复滑出 */
    private suspend fun saveAll(list: List<Draft>, note: String?, quiet: Boolean = false) {
        val app = application as IdeashellApp
        val captures = app.container.captures
        val saved = mutableListOf<SavedItem>()
        val asks = mutableListOf<String>()
        list.filter { it.text.isNotBlank() }.forEach { draft ->
            val text = draft.text.trim()
            if (draft.mode == Mode.ASK) {
                asks += text
                return@forEach
            }
            val intent = draft.intent
            val kind = when (draft.mode) {
                Mode.TODO -> CaptureKind.TODO
                Mode.DAILY -> CaptureKind.DAILY
                Mode.NOTE, Mode.APPEND -> CaptureKind.NOTE
                else -> null
            }
            val body = if (intent != null) voiceIntentBody(intent.copy(content = text)) else text
            val isTodo = draft.mode == Mode.TODO && intent != null
            val schedule = if (isTodo) voiceIntentSchedule(intent!!) else null
            if (captures.submitText(body, kind, ORIGIN, schedule = schedule, appendToLast = draft.mode == Mode.APPEND) != null) {
                val whenText = if (isTodo) scheduleText(intent!!.date, intent.time) else ""
                saved += SavedItem(modeLabel(draft.mode, saved = true), (if (whenText.isNotEmpty()) "$whenText · " else "") + text)
            }
        }
        if (asks.isNotEmpty()) {
            // 和快速输入面板一致：交给闪念贝壳 AI（无障碍开着就自动点发送）；转交失败就记成一条笔记，不丢
            val question = asks.joinToString("\n")
            if (IdeashellBridge.askAi(this, question, preferAutoSend = true)) {
                saved += SavedItem("问 AI", question)
            } else if (captures.submitText(question, CaptureKind.NOTE, ORIGIN) != null) {
                saved += SavedItem("笔记", question)
            }
        }
        if (saved.isEmpty()) {
            showMessage("没有可保存的内容", error = true)
            return
        }
        showSaved(saved, note, quiet)
    }

    private fun modeLabel(mode: Mode, saved: Boolean = false): String =
        if (saved && mode == Mode.AUTO) "已保存" else mode.label

    private fun scheduleText(date: LocalDate?, time: LocalTime?): String {
        if (date == null) return ""
        val today = LocalDate.now()
        val day = when (date) {
            today -> "今天"
            today.plusDays(1) -> "明天"
            today.plusDays(2) -> "后天"
            else -> "${date.monthValue}月${date.dayOfMonth}日"
        }
        return if (time != null) day + " %02d:%02d".format(time.hour, time.minute) else day
    }

    // ───────────────────────────── 窗口 ─────────────────────────────

    private fun newTransition() = LayoutTransition().apply {
        enableTransitionType(LayoutTransition.CHANGING)
        setDuration(260)
        setInterpolator(LayoutTransition.CHANGING, DecelerateInterpolator(1.6f))
    }

    private fun ensureColumn(): LinearLayout {
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

    private fun updateWindow() {
        val h = host ?: return
        val p = params ?: return
        runCatching { wm.updateViewLayout(h, p) }
    }

    private val columnLayoutListener = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> applyImeShift() }

    private val restoreWindow = Runnable {
        if (editing) return@Runnable
        val p = params ?: return@Runnable
        val h = host ?: return@Runnable
        val col = column ?: return@Runnable
        imeBottom = 0
        imeAnimating = false
        h.setOnApplyWindowInsetsListener(null)
        if (Build.VERSION.SDK_INT >= 30) h.setWindowInsetsAnimationCallback(null)
        h.setOnClickListener(null)
        h.isClickable = false
        col.removeOnLayoutChangeListener(columnLayoutListener)
        col.translationY = 0f
        (col.layoutParams as FrameLayout.LayoutParams).topMargin = 0
        col.requestLayout()
        p.flags = p.flags or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
        p.width = WindowManager.LayoutParams.WRAP_CONTENT
        p.height = WindowManager.LayoutParams.WRAP_CONTENT
        p.y = panelY
        updateWindow()
    }

    /**
     * 面板（录音胶囊 / 小胶囊 / 确认卡片）都以同一条水平线为中心：内容换了、变高了，窗口随之上下对称地长，
     * 所以小胶囊点开成卡片时是上下等距地原地张开，不会整体上跳或下沉。
     */
    private fun recenter() {
        val h = host ?: return
        val p = params ?: return
        if (editing || p.height == WindowManager.LayoutParams.MATCH_PARENT) return
        val dm = resources.displayMetrics
        h.measure(
            View.MeasureSpec.makeMeasureSpec(dm.widthPixels, View.MeasureSpec.AT_MOST),
            View.MeasureSpec.makeMeasureSpec(dm.heightPixels, View.MeasureSpec.AT_MOST),
        )
        val y = (restingY + dp(CENTER_OFFSET_DP) - h.measuredHeight / 2).coerceAtLeast(dp(24))
        panelY = y
        p.y = y
        updateWindow()
    }

    private fun surfaceScreenRect(): Rect? {
        val s = surface ?: return null
        if (s.parent !== column || s.width == 0 || s.height == 0) return null
        val loc = IntArray(2)
        s.getLocationOnScreen(loc)
        return Rect(loc[0], loc[1], loc[0] + s.width, loc[1] + s.height)
    }

    /** 从 [from]（旧小胶囊在屏幕上的位置）原地张开成当前面板：用裁剪框从小到大，上下左右同时展开 */
    private fun expandFrom(from: Rect) {
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
     * 点到文字框：悬浮窗拿焦点、铺满全屏（卡片位置不变），再随输入法弹出的动画一路推上去，
     * 最终停在输入法正上方；点卡片外面的空白处收起输入法。
     */
    private fun enterEditMode() {
        val p = params ?: return
        val h = host ?: return
        val col = column ?: return
        if (editing) return
        editing = true
        handler.removeCallbacks(restoreWindow)
        p.flags = p.flags and (WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS).inv()
        p.width = WindowManager.LayoutParams.MATCH_PARENT
        p.height = WindowManager.LayoutParams.MATCH_PARENT
        p.y = 0
        (col.layoutParams as FrameLayout.LayoutParams).topMargin = panelY
        updateWindow()
        h.setOnClickListener { exitEditMode() }
        col.addOnLayoutChangeListener(columnLayoutListener)
        h.setOnApplyWindowInsetsListener { _, insets ->
            if (!imeAnimating) {
                imeBottom = insets.getInsets(WindowInsets.Type.ime()).bottom
                applyImeShift()
            }
            insets
        }
        if (Build.VERSION.SDK_INT >= 30) {
            h.setWindowInsetsAnimationCallback(object : WindowInsetsAnimation.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                override fun onPrepare(animation: WindowInsetsAnimation) {
                    imeAnimating = true
                }

                override fun onProgress(insets: WindowInsets, runningAnimations: MutableList<WindowInsetsAnimation>): WindowInsets {
                    imeBottom = insets.getInsets(WindowInsets.Type.ime()).bottom
                    applyImeShift()
                    return insets
                }

                override fun onEnd(animation: WindowInsetsAnimation) {
                    imeAnimating = false
                    h.rootWindowInsets?.let { imeBottom = it.getInsets(WindowInsets.Type.ime()).bottom }
                    applyImeShift()
                }
            })
        }
        h.requestApplyInsets()
    }

    /** 把卡片推到输入法上方（输入法没出来就留在原位） */
    private fun applyImeShift() {
        val h = host ?: return
        val col = column ?: return
        if (!editing && imeBottom == 0) return
        if (h.height == 0) return
        val bottomRest = panelY + col.height
        val avail = h.height - imeBottom - dp(10)
        val ty = if (imeBottom <= 0) 0f else min(0f, (avail - bottomRest).toFloat())
        col.translationY = ty.coerceAtLeast(-(panelY - dp(40)).toFloat())
    }

    private fun exitEditMode() {
        if (!editing) return
        editing = false
        val col = column
        // 先收输入法：卡片随输入法下沉的动画回到原位，动画结束后再把窗口还原成小窗口
        col?.let { c ->
            (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(c.windowToken, 0)
            c.findFocus()?.clearFocus()
        }
        host?.setOnClickListener(null)
        host?.isClickable = false
        handler.removeCallbacks(restoreWindow)
        handler.postDelayed(restoreWindow, 320)
    }

    // ───────────────────────────── 面板：录音 / 整理 / 确认 ─────────────────────────────

    /** 主面板的外壳：贴右边缘，左边圆头、右边贴屏幕边 */
    private fun ensureSurface(): FrameLayout {
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
    private fun swap(content: View, onSwapped: (() -> Unit)? = null) {
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

    private fun renderRecording() {
        shown = Shown.RECORDING
        dotAnimator?.cancel()
        column?.layoutTransition = newTransition()
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(18), dp(9), dp(12), dp(9))
        }
        val redDot = View(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(RED)
            }
        }
        row.addView(redDot, LinearLayout.LayoutParams(dp(10), dp(10)).apply { marginEnd = dp(10) })
        // 红点慢慢「呼吸」
        dotAnimator = ObjectAnimator.ofFloat(redDot, View.ALPHA, 1f, 0.3f).apply {
            duration = 700
            repeatMode = ObjectAnimator.REVERSE
            repeatCount = ObjectAnimator.INFINITE
            start()
        }
        val timer = label("0:00", 18f, bold = true)
        timer.typeface = Typeface.create(Typeface.DEFAULT_BOLD, Typeface.NORMAL)
        row.addView(timer, LinearLayout.LayoutParams(dp(46), LinearLayout.LayoutParams.WRAP_CONTENT))
        timerText = timer
        val w = WaveView(this, pal.text)
        row.addView(w, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(30)).apply {
            marginStart = dp(4)
            marginEnd = dp(12)
        })
        wave = w
        row.addView(stopButton(), LinearLayout.LayoutParams(dp(38), dp(38)))
        row.addView(
            label("×", 22f).apply {
                gravity = Gravity.CENTER
                alpha = 0.65f
                contentDescription = "取消"
                pressable()
                setOnClickListener {
                    voice?.cancel()
                    dismissWithSlide()
                }
            },
            LinearLayout.LayoutParams(dp(38), dp(38)).apply { marginStart = dp(2) },
        )
        swap(row)
    }

    private fun renderProcessing() {
        shown = Shown.PROCESSING
        dotAnimator?.cancel()
        column?.layoutTransition = newTransition()
        wave = null
        timerText = null
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(18), dp(11), dp(14), dp(11))
        }
        row.addView(
            ProgressBar(this).apply {
                isIndeterminate = true
                indeterminateTintList = android.content.res.ColorStateList.valueOf(ACCENT)
            },
            LinearLayout.LayoutParams(dp(20), dp(20)).apply { marginEnd = dp(10) },
        )
        row.addView(label("正在识别整理…", 15f), LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            marginEnd = dp(14)
        })
        row.addView(
            label("放弃", 14f).apply {
                alpha = 0.65f
                setPadding(dp(8), dp(8), dp(8), dp(8))
                pressable()
                setOnClickListener {
                    voice?.cancel()
                    dismissWithSlide()
                }
            },
        )
        swap(row)
    }

    /** 确认卡片：整理后的文字可直接改，类型可点着切换，底部 放弃 / 重新说 / 保存 */
    private fun renderConfirm(note: String?) {
        // 从「正在整理」或倒计时小胶囊点开：记下它现在在屏幕上的位置，等卡片排好版后从这里原地张开
        val from = if (shown == Shown.PENDING || shown == Shown.PROCESSING) surfaceScreenRect() else null
        val fromPending = shown == Shown.PENDING
        shown = Shown.CONFIRM
        dotAnimator?.cancel()
        cancelCountdown()
        val keep = surface
        if (fromPending) {
            keep?.apply {
                setOnClickListener(null)
                setOnTouchListener(null)
                isClickable = true // 变成卡片后吃掉点击，不再触发「展开」
                scaleX = 1f
                scaleY = 1f
            }
            // 其余的小胶囊淡出，卡片排好版时再移除
            column?.let { col ->
                (0 until col.childCount).map { col.getChildAt(it) }.filter { it !== keep }
                    .forEach { it.animate().alpha(0f).setDuration(90).start() }
            }
        }
        // 张开用裁剪框动画，期间不再套布局过渡
        column?.layoutTransition = if (from != null) null else newTransition()
        wave = null
        timerText = null
        stopTick()
        val maxWidth = minOf(dp(330), resources.displayMetrics.widthPixels - dp(20))
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(14), dp(14), dp(10))
            minimumWidth = maxWidth
        }
        val head = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        head.addView(label("确认记录", 13f, bold = true).apply { alpha = 0.6f })
        if (!note.isNullOrBlank()) {
            head.addView(
                label(note, 11f).apply {
                    alpha = 0.45f
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                    setPadding(dp(8), 0, 0, 0)
                },
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
            )
        }
        card.addView(head)

        val list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        fun rebuildRows() {
            list.removeAllViews()
            drafts.forEachIndexed { index, draft -> list.addView(draftRow(draft, index) { rebuildRows() }) }
        }
        rebuildRows()
        val scroll = ScrollView(this).apply {
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            addView(list)
        }
        card.addView(
            scroll,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) },
        )

        val buttons = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL or Gravity.END }
        buttons.addView(textButton("放弃") { exitEditMode(); dismissWithSlide() })
        buttons.addView(textButton("重新说") {
            exitEditMode()
            drafts.clear()
            begin(false)
        })
        buttons.addView(
            label("保存", 15f, bold = true).apply {
                setTextColor(ON_ACCENT)
                gravity = Gravity.CENTER
                background = GradientDrawable().apply {
                    setColor(ACCENT)
                    cornerRadius = dp(20).toFloat()
                }
                setPadding(dp(22), dp(9), dp(22), dp(9))
                pressable()
                setOnClickListener {
                    exitEditMode()
                    val snapshot = drafts.toList()
                    scope.launch { saveAll(snapshot, note) }
                }
            },
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginStart = dp(6) },
        )
        card.addView(
            buttons,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8) },
        )
        swap(card) {
            column?.let { col ->
                (0 until col.childCount).map { col.getChildAt(it) }.filter { it !== surface }.forEach { col.removeView(it) }
            }
            recenter()
            if (from != null) expandFrom(from) else column?.layoutTransition = newTransition()
        }
    }

    /** 确认卡片里的一件事：类型小标签 + 可编辑的文字 + 待办的日期 + 删除 */
    private fun draftRow(draft: Draft, index: Int, onChanged: () -> Unit): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(6), 0, dp(6))
        }
        val chip = label(modeLabel(draft.mode), 12f, bold = true).apply {
            setTextColor(pal.accentSoft)
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                setColor(pal.chipBg)
                cornerRadius = dp(12).toFloat()
            }
            setPadding(dp(10), dp(4), dp(10), dp(4))
            pressable()
            setOnClickListener {
                draft.mode = nextMode(draft.mode, draft.intent != null)
                text = modeLabel(draft.mode)
                onChanged()
            }
        }
        row.addView(chip, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(2)
            marginEnd = dp(10)
        })
        val body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val edit = EditText(this).apply {
            setText(draft.text)
            setTextColor(pal.text)
            setHintTextColor((pal.text and 0x00FFFFFF) or 0x66000000)
            hint = "说的内容"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            background = null
            setPadding(0, dp(2), 0, dp(2))
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            imeOptions = EditorInfo.IME_ACTION_DONE
            setHorizontallyScrolling(false)
            maxLines = 5
            setOnTouchListener { v, event ->
                if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                    enterEditMode()
                    v.post {
                        v.requestFocus()
                        (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(v, InputMethodManager.SHOW_IMPLICIT)
                    }
                }
                false
            }
            setOnEditorActionListener { _, actionId, _ ->
                if (actionId == EditorInfo.IME_ACTION_DONE) {
                    exitEditMode()
                    true
                } else {
                    false
                }
            }
            addTextChangedListener(object : android.text.TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
                override fun afterTextChanged(s: android.text.Editable?) {
                    draft.text = s?.toString().orEmpty()
                }
            })
        }
        body.addView(edit, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        val intent = draft.intent
        if (draft.mode == Mode.TODO && intent != null) {
            val whenText = scheduleText(intent.date, intent.time) + (intent.repeat?.let { " · $it" } ?: "")
            if (whenText.isNotBlank()) body.addView(label(whenText, 12f).apply { setTextColor(pal.accentSoft) })
        }
        row.addView(body, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        if (drafts.size > 1) {
            row.addView(
                label("×", 20f).apply {
                    gravity = Gravity.CENTER
                    alpha = 0.55f
                    contentDescription = "去掉这一项"
                    pressable()
                    setOnClickListener {
                        drafts.removeAt(index)
                        onChanged()
                    }
                },
                LinearLayout.LayoutParams(dp(34), dp(34)).apply { marginStart = dp(4) },
            )
        }
        return row
    }

    private fun nextMode(mode: Mode, hasIntent: Boolean): Mode {
        val order = if (hasIntent) listOf(Mode.TODO, Mode.DAILY, Mode.NOTE, Mode.APPEND, Mode.ASK)
        else listOf(Mode.AUTO, Mode.TODO, Mode.DAILY, Mode.NOTE, Mode.APPEND, Mode.ASK)
        val i = order.indexOf(mode)
        return order[(i + 1) % order.size]
    }

    /** 松手自动保存：不弹确认卡片，每条一个小胶囊 + 倒计时细线；点任意一个展开确认卡片，倒计时走完才真正保存 */
    private fun renderPending(note: String?) {
        shown = Shown.PENDING
        stopTick()
        dotAnimator?.cancel()
        wave = null
        timerText = null
        val col = ensureColumn()
        col.layoutTransition = newTransition()
        col.removeAllViews()
        surface = null
        val lines = ArrayList<View>()
        drafts.filter { it.text.isNotBlank() }.forEachIndexed { index, draft ->
            val intent = draft.intent
            val whenText = if (draft.mode == Mode.TODO && intent != null) scheduleText(intent.date, intent.time) else ""
            val box = FrameLayout(this).apply {
                background = capsuleBackground(26)
                elevation = dp(8).toFloat()
                isClickable = true
                pressable()
                setOnClickListener { renderConfirm(note) }
            }
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(16), dp(9), dp(14), dp(13))
            }
            row.addView(label(modeLabel(draft.mode, saved = true).let { if (draft.mode == Mode.AUTO) "记录" else it }, 12f, bold = true).apply {
                setTextColor(pal.accentSoft)
                setPadding(0, 0, dp(8), 0)
            })
            row.addView(
                label((if (whenText.isNotEmpty()) "$whenText · " else "") + draft.text.trim().take(60), 15f).apply {
                    maxWidth = dp(230)
                    maxLines = 2
                    ellipsize = TextUtils.TruncateAt.END
                },
            )
            box.addView(row, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT))
            val line = View(this).apply {
                setBackgroundColor(ACCENT)
                alpha = 0.75f
                pivotX = 0f
            }
            box.addView(line, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, dp(2), Gravity.BOTTOM).apply {
                marginStart = dp(16)
                marginEnd = dp(14)
                bottomMargin = dp(6)
            })
            lines += line
            addSmall(box, index * 120L)
            // 第一条小胶囊同时是「主面板」：点开时它原地长成确认卡片
            if (index == 0) surface = box
        }
        if (!note.isNullOrBlank()) {
            val box = smallPill()
            box.addView(label(note, 12f).apply { maxWidth = dp(260); alpha = 0.8f })
            addSmall(box, lines.size * 120L)
        }
        recenter()
        val snapshot = drafts.toList()
        countdown = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = PENDING_MS
            interpolator = android.view.animation.LinearInterpolator()
            addUpdateListener { a ->
                val f = a.animatedValue as Float
                lines.forEach { it.scaleX = 1f - f }
            }
            addListener(object : AnimatorListenerAdapter() {
                private var cancelled = false
                override fun onAnimationCancel(animation: Animator) {
                    cancelled = true
                }

                override fun onAnimationEnd(animation: Animator) {
                    if (!cancelled && !stopping) scope.launch { saveAll(snapshot, note, quiet = true) }
                }
            })
            startDelay = 300
            start()
        }
    }

    private fun cancelCountdown() {
        countdown?.cancel()
        countdown = null
    }

    /** 保存成功：每条记录一个小胶囊，依次从右侧滑出；整理出几条就是几个 */
    private fun showSaved(items: List<SavedItem>, note: String?, quiet: Boolean = false) {
        if (stopping) return
        stopTick()
        dotAnimator?.cancel()
        cancelCountdown()
        shown = Shown.MESSAGE
        val col = ensureColumn()
        col.removeAllViews()
        surface = null
        items.forEachIndexed { index, item ->
            val box = smallPill()
            box.addView(label("✓", 15f, bold = true).apply { setTextColor(pal.green) }, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { marginEnd = dp(8) })
            box.addView(label(item.tag, 12f, bold = true).apply {
                setTextColor(pal.accentSoft)
                setPadding(0, 0, dp(8), 0)
            })
            box.addView(
                label(item.text.take(60), 15f).apply {
                    maxWidth = dp(220)
                    maxLines = 2
                    ellipsize = TextUtils.TruncateAt.END
                },
            )
            addSmall(box, if (quiet) 0L else index * 140L, animate = !quiet)
        }
        if (!note.isNullOrBlank() && !quiet) {
            val box = smallPill()
            box.addView(label(note, 12f).apply { maxWidth = dp(260); alpha = 0.8f })
            addSmall(box, items.size * 140L)
        }
        recenter()
        col.setOnClickListener { dismissWithSlide() }
        handler.postDelayed({ dismissWithSlide() }, if (quiet) 1100L else 2800L + items.size * 400L)
    }

    private fun showMessage(message: String, error: Boolean) {
        if (stopping) return
        stopTick()
        dotAnimator?.cancel()
        cancelCountdown()
        exitEditMode()
        shown = Shown.MESSAGE
        val col = ensureColumn()
        col.removeAllViews()
        surface = null
        val box = smallPill()
        box.addView(label(message, 15f).apply {
            maxWidth = dp(260)
            if (error) setTextColor(pal.error)
        })
        addSmall(box)
        recenter()
        col.setOnClickListener { dismissWithSlide() }
        handler.postDelayed({ dismissWithSlide() }, if (error) 4000L else 2500L)
    }

    private fun smallPill(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = capsuleBackground(22)
        setPadding(dp(16), dp(9), dp(14), dp(9))
        elevation = dp(8).toFloat()
    }

    private fun addSmall(view: View, delayMs: Long = 0L, animate: Boolean = true) {
        val col = ensureColumn()
        col.addView(view, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            if (col.childCount > 0) topMargin = dp(8)
        })
        if (animate) slideIn(view, delayMs)
    }

    private fun slideIn(view: View, delayMs: Long) {
        view.translationX = dp(360).toFloat()
        view.animate().translationX(0f).setStartDelay(delayMs).setDuration(300)
            .setInterpolator(DecelerateInterpolator(1.8f)).start()
    }

    /** 整列向右滑出屏幕，再收尾 */
    private fun dismissWithSlide() {
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

    private fun stopSelfClean() {
        stopping = true
        stopTick()
        handler.removeCallbacksAndMessages(null)
        dotAnimator?.cancel()
        cancelCountdown()
        host?.let { runCatching { wm.removeView(it) } }
        host = null
        column = null
        surface = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        handler.removeCallbacksAndMessages(null)
        dotAnimator?.cancel()
        voice?.release()
        cancelCountdown()
        host?.let { runCatching { wm.removeView(it) } }
        host = null
        column = null
        scope.cancel()
        super.onDestroy()
    }

    // ───────────────────────────── 小工具 ─────────────────────────────

    private fun capsuleBackground(radiusDp: Int): GradientDrawable {
        val r = dp(radiusDp).toFloat()
        return GradientDrawable().apply {
            setColor(pal.bg)
            setStroke(dp(1), pal.stroke)
            // 左边圆头，右边贴屏幕边缘
            cornerRadii = floatArrayOf(r, r, 0f, 0f, 0f, 0f, r, r)
        }
    }

    private fun label(value: String, sp: Float, bold: Boolean = false) = TextView(this).apply {
        text = value
        setTextColor(pal.text)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        if (bold) typeface = Typeface.DEFAULT_BOLD
    }

    private fun textButton(value: String, onClick: () -> Unit) = label(value, 15f).apply {
        alpha = 0.75f
        gravity = Gravity.CENTER
        setPadding(dp(14), dp(9), dp(14), dp(9))
        pressable()
        setOnClickListener { onClick() }
    }

    /** 录音面板上的停止键：红色圆里一个白色圆角方块 */
    private fun stopButton(): View = FrameLayout(this).apply {
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(RED)
        }
        contentDescription = "完成"
        addView(Square(this@VoiceCapsuleService), FrameLayout.LayoutParams(dp(12), dp(12), Gravity.CENTER))
        pressable()
        setOnClickListener { voice?.finish() }
    }

    /** 按下时轻轻缩小一点，松手弹回（点击回调不受影响） */
    @android.annotation.SuppressLint("ClickableViewAccessibility")
    private fun View.pressable() {
        setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> v.animate().scaleX(0.92f).scaleY(0.92f).setDuration(80).start()
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> v.animate().scaleX(1f).scaleY(1f).setDuration(140).start()
            }
            false
        }
    }

    private class Square(context: Context) : View(context) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
        override fun onDraw(canvas: Canvas) {
            canvas.drawRoundRect(RectF(0f, 0f, width.toFloat(), height.toFloat()), width * 0.22f, height * 0.22f, paint)
        }
    }

    /**
     * 声波：位置固定、宽度固定的一排竖条（常见的语音输入法做法）。
     * 音量先做「起得快、落得慢」的平滑；每根竖条有自己的起伏相位，中间的更高；
     * 每一帧按真实帧间隔让高度指数式靠近目标，所以不论音量多久更新一次，动起来都是连续的。
     */
    private class WaveView(context: Context, color: Int) : View(context) {
        private val density = resources.displayMetrics.density
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color
            strokeCap = Paint.Cap.ROUND
            strokeWidth = 2.8f * density
        }
        private val count = 20
        private val slot = 5.4f * density
        private val heights = FloatArray(count)
        private val phases = FloatArray(count) { i -> ((i * 37) % 11) * 0.57f }
        private var live = 0f
        private var clock = 0f
        private var lastNow = 0L

        fun update(level: Float) {
            val now = SystemClock.uptimeMillis()
            val dt = (if (lastNow == 0L) 16L else (now - lastNow).coerceIn(1L, 50L)) / 1000f
            lastNow = now
            val tau = if (level > live) 0.05f else 0.28f
            live += (level.coerceIn(0f, 1f) - live) * (1f - exp(-dt / tau))
            val amp = sqrt(live)
            clock += dt
            val follow = 1f - exp(-dt / 0.07f)
            val mid = (count - 1) / 2f
            for (i in 0 until count) {
                val centerWeight = 0.55f + 0.45f * cos((i - mid) / mid * (PI / 2)).toFloat()
                val wobble = 0.5f + 0.5f * sin(clock * 6f + i * 0.75f + phases[i])
                val target = amp * centerWeight * (0.3f + 0.7f * wobble)
                heights[i] += (target - heights[i]) * follow
            }
            invalidate()
        }

        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            setMeasuredDimension((count * slot).toInt(), MeasureSpec.getSize(heightMeasureSpec).takeIf { it > 0 } ?: (30 * density).toInt())
        }

        override fun onDraw(canvas: Canvas) {
            val minH = 3.5f * density
            for (i in 0 until count) {
                val h = (minH + (height - minH) * heights[i].coerceIn(0f, 1f)).coerceAtMost(height.toFloat())
                val x = slot * i + slot / 2
                canvas.drawLine(x, (height - h) / 2, x, (height + h) / 2, paint)
            }
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density + 0.5f).toInt()

    companion object {
        private const val CHANNEL = "voice_capsule"
        private const val NOTIFICATION_ID = 7301
        private const val ORIGIN = "voice"

        /** 面板共同的水平中心线，离 [restingY]（录音胶囊顶边）的距离：录音胶囊高 56dp，所以是 28 */
        private const val CENTER_OFFSET_DP = 28

        /** 松手自动保存：小胶囊倒计时多久后保存 */
        private const val PENDING_MS = 3000L

        /** 一直没人说话就放弃的时间 */
        private const val NO_SPEECH_MS = 6000L

        private const val RED = 0xFFFF4D4F.toInt()
        private const val ACCENT = 0xFFE8794A.toInt()
        private const val ON_ACCENT = 0xFF24150C.toInt()

        const val ACTION_FINISH = "com.carpe.ideashell.action.VOICE_CAPSULE_FINISH"
        const val ACTION_CANCEL = "com.carpe.ideashell.action.VOICE_CAPSULE_CANCEL"
        private const val EXTRA_HOLD = "hold"

        /** 按住期间松手得比录音开始还早时，记下来，开始后立刻结束 */
        @Volatile
        private var pendingRelease = false

        /** 音量键松手 */
        fun releaseHold() {
            val s = instance
            if (s != null) s.onKeyReleased() else pendingRelease = true
        }

        /** 正在运行的服务（音量键松手时用它结束录音） */
        @Volatile
        var instance: VoiceCapsuleService? = null
            private set

        /** 没在录就开始录，正在录就结束并保存 */
        fun toggle(context: Context) {
            context.startForegroundService(Intent(context, VoiceCapsuleService::class.java))
        }

        /** 音量键按住：开始录，松手由 [onKeyReleased] 结束（录音期间不做说完自动结束） */
        fun startHold(context: Context) {
            pendingRelease = false
            context.startForegroundService(Intent(context, VoiceCapsuleService::class.java).putExtra(EXTRA_HOLD, true))
        }
    }
}
