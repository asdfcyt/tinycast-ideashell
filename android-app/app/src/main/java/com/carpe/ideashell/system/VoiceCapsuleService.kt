package com.carpe.ideashell.system

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.R
import com.carpe.ideashell.core.parse.CaptureKind
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
import kotlin.math.sqrt

/**
 * 「语音记一条」的悬浮录音胶囊：在任何界面上方浮出一条黑色胶囊（红点 + 秒数 + 声波 + 完成键），
 * 点「完成」后在后台识别、整理并保存成一条记录，胶囊变成「已保存」提示后自动消失，不打开拾忆的界面。
 *
 * 用前台服务（麦克风类型）持有录音，用「显示在其他应用上层」的悬浮窗画胶囊，所以两个权限都要有（由 [VoiceCapsuleActivity] 检查）。
 */
class VoiceCapsuleService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val handler = Handler(Looper.getMainLooper())
    private val wm by lazy { getSystemService(WINDOW_SERVICE) as WindowManager }

    /** 贴在屏幕右边缘的一列胶囊：录音时只有一个，保存后每条记录一个 */
    private var root: LinearLayout? = null
    private var voice: VoiceInputController? = null
    private var shown = Shown.NONE
    private var pill: LinearLayout? = null
    private var timerText: TextView? = null
    private var dot: View? = null
    private var wave: WaveView? = null
    private var stopping = false
    private val levels = ArrayDeque<Float>()
    private var peak = 0f
    private var lastSampleMs = 0L

    private enum class Shown { NONE, RECORDING, PROCESSING, MESSAGE }

    private val tick = object : Runnable {
        override fun run() {
            val v = voice ?: return
            when (v.phase) {
                VoicePhase.RECORDING, VoicePhase.LOCKED -> {
                    if (shown != Shown.RECORDING) renderRecording()
                    val sec = (v.elapsedMs / 1000).toInt()
                    timerText?.text = "%d:%02d".format(sec / 60, sec % 60)
                    dot?.alpha = if ((v.elapsedMs / 500) % 2 == 0L) 1f else 0.35f
                    // 每 1 秒取一根竖条（这段时间的最大音量）；竖条越多胶囊越长，满了之后左边的滚出去
                    peak = maxOf(peak, v.level)
                    if (v.elapsedMs - lastSampleMs >= SAMPLE_MS) {
                        lastSampleMs = v.elapsedMs
                        levels.addLast(peak)
                        peak = 0f
                        while (levels.size > WAVE_BARS) levels.removeFirst()
                        wave?.set(levels.toList())
                    }
                }
                VoicePhase.PROCESSING -> if (shown != Shown.PROCESSING) renderProcessing()
                VoicePhase.IDLE -> Unit
            }
            handler.postDelayed(this, 80)
        }
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
                val v = voice
                // 已经在录：再点一次就是「完成」
                if (v != null && (v.phase == VoicePhase.RECORDING || v.phase == VoicePhase.LOCKED)) v.finish() else begin()
            }
        }
        return START_NOT_STICKY
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

    private fun begin() {
        if (!Settings.canDrawOverlays(this)) {
            stopSelfClean()
            return
        }
        val container = (application as IdeashellApp).container
        val controller = VoiceInputController(
            scope = scope,
            settings = container.settings,
            asr = container.asr,
            local = container.localAsr,
            llm = container.llm,
            lexicon = container.lexicon,
            extraHotwords = { container.folders.folders.value.map { it.name } },
            onError = { showMessage(it, error = true) },
            onResult = { result -> scope.launch { save(result) } },
        )
        voice = controller
        ensureRoot()
        if (!controller.start()) {
            // start() 已经通过 onError 说明了原因
            return
        }
        stopping = false
        levels.clear()
        peak = 0f
        lastSampleMs = 0L
        renderRecording()
        handler.removeCallbacks(tick)
        handler.post(tick)
    }

    /** 保存下来的一条记录，在胶囊上显示 */
    private class SavedItem(val tag: String, val text: String)

    /** 保存：整理出几件事存几条；没整理（没有大模型）就存本地清洗过的转写，类型让解析器判断 */
    private suspend fun save(result: VoiceResult) {
        val captures = (application as IdeashellApp).container.captures
        val saved = mutableListOf<SavedItem>()
        if (result.intents.isEmpty()) {
            if (captures.submitText(result.cleaned, null, ORIGIN) != null) saved += SavedItem("已保存", result.cleaned)
        } else {
            result.intents.forEach { intent ->
                // 「问 AI」类的话在胶囊里没法转交，照样记成一条笔记，不丢
                val body = if (intent.ask) intent.content else voiceIntentBody(intent)
                val type = if (intent.ask) CaptureKind.NOTE else intent.type
                val schedule = if (type == CaptureKind.TODO) voiceIntentSchedule(intent) else null
                if (captures.submitText(body, type, ORIGIN, schedule = schedule) != null) {
                    val tag = when (type) {
                        CaptureKind.TODO -> "待办"
                        CaptureKind.DAILY -> "日记"
                        CaptureKind.NOTE -> "笔记"
                    }
                    val whenText = if (type == CaptureKind.TODO) scheduleText(intent.date, intent.time) else ""
                    saved += SavedItem(tag, (if (whenText.isNotEmpty()) "$whenText · " else "") + intent.content)
                }
            }
        }
        if (saved.isEmpty()) {
            showMessage("没有可保存的内容", error = true)
            return
        }
        showSaved(saved, result.polishError)
    }

    private fun scheduleText(date: java.time.LocalDate?, time: java.time.LocalTime?): String {
        if (date == null) return ""
        val today = java.time.LocalDate.now()
        val day = when (date) {
            today -> "今天"
            today.plusDays(1) -> "明天"
            today.plusDays(2) -> "后天"
            else -> "${date.monthValue}月${date.dayOfMonth}日"
        }
        return if (time != null) day + " %02d:%02d".format(time.hour, time.minute) else day
    }

    // ───────────────────────────── 胶囊界面 ─────────────────────────────

    /** 贴右边缘的透明竖列窗口；胶囊一个个从右侧滑进来 */
    private fun ensureRoot(): LinearLayout {
        root?.let { return it }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.END
        }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.END
            // 贴右边缘、偏下的位置（约在屏幕高度的 62% 处）：单手拇指够得着，也不挡住顶部的状态栏
            // 再往上挪 5 毫米
            y = (resources.displayMetrics.heightPixels * 0.62f -
                TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_MM, 5f, resources.displayMetrics)).toInt()
        }
        wm.addView(column, params)
        root = column
        return column
    }

    /** 一个贴右边缘的深色胶囊：左边是圆头，右边贴着屏幕边 */
    private fun newPill(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        val r = dp(26).toFloat()
        background = GradientDrawable().apply {
            setColor(0xF2202020.toInt())
            cornerRadii = floatArrayOf(r, r, 0f, 0f, 0f, 0f, r, r)
        }
        setPadding(dp(16), dp(8), dp(12), dp(8))
        elevation = dp(6).toFloat()
    }

    private fun addPill(view: LinearLayout, delayMs: Long = 0L) {
        val column = ensureRoot()
        column.addView(view, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            if (column.childCount > 0) topMargin = dp(8)
        })
        slideIn(view, delayMs)
    }

    private fun slideIn(view: View, delayMs: Long) {
        view.translationX = dp(360).toFloat()
        view.animate().translationX(0f).setStartDelay(delayMs).setDuration(280)
            .setInterpolator(android.view.animation.DecelerateInterpolator(1.6f)).start()
    }

    private fun renderRecording() {
        val first = shown == Shown.NONE
        val column = ensureRoot()
        shown = Shown.RECORDING
        column.removeAllViews()
        val box = newPill()
        pill = box
        val redDot = View(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0xFFFF4D4F.toInt())
            }
        }
        box.addView(redDot, LinearLayout.LayoutParams(dp(10), dp(10)).apply { marginEnd = dp(10) })
        dot = redDot
        val timer = text("0:00", 18f, bold = true)
        box.addView(timer, LinearLayout.LayoutParams(dp(46), LinearLayout.LayoutParams.WRAP_CONTENT))
        timerText = timer
        // 声波随录音时间变长，整条胶囊跟着变长
        val w = WaveView(this).also { it.set(levels.toList()) }
        box.addView(w, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(28)).apply { marginStart = dp(4); marginEnd = dp(10) })
        wave = w
        box.addView(
            iconButton(0x26FFFFFF) { Square(this) }.also { it.setOnClickListener { voice?.finish() } },
            LinearLayout.LayoutParams(dp(36), dp(36)),
        )
        box.addView(
            text("×", 22f).apply {
                gravity = Gravity.CENTER
                alpha = 0.7f
                contentDescription = "取消"
                setOnClickListener {
                    voice?.cancel()
                    stopSelfClean()
                }
            },
            LinearLayout.LayoutParams(dp(36), dp(36)).apply { marginStart = dp(4) },
        )
        column.addView(box, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        if (first) slideIn(box, 0L)
    }

    private fun renderProcessing() {
        val box = pill ?: return
        shown = Shown.PROCESSING
        box.removeAllViews()
        box.addView(text("正在识别整理…", 15f), LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            marginEnd = dp(12)
        })
        box.addView(
            text("放弃", 14f).apply {
                alpha = 0.7f
                setPadding(dp(8), dp(6), dp(8), dp(6))
                setOnClickListener {
                    voice?.cancel()
                    stopSelfClean()
                }
            },
        )
    }

    /** 保存成功：每条记录一个胶囊，依次从右侧滑出；整理出几条就是几个 */
    private fun showSaved(items: List<SavedItem>, note: String?) {
        if (stopping) return
        val column = ensureRoot()
        handler.removeCallbacks(tick)
        shown = Shown.MESSAGE
        column.removeAllViews()
        items.forEachIndexed { index, item ->
            val box = newPill()
            box.addView(text("✓", 15f, bold = true).apply { setTextColor(0xFF7BE0A0.toInt()) }, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { marginEnd = dp(8) })
            box.addView(
                text(item.tag, 12f, bold = true).apply {
                    setTextColor(0xFFFFC9A8.toInt())
                    setPadding(0, 0, dp(8), 0)
                },
            )
            box.addView(
                text(item.text.take(60), 15f).apply {
                    maxWidth = dp(220)
                    maxLines = 2
                    ellipsize = android.text.TextUtils.TruncateAt.END
                },
            )
            addPill(box, index * 140L)
        }
        if (!note.isNullOrBlank()) {
            val box = newPill()
            box.addView(text(note, 12f).apply { maxWidth = dp(260); alpha = 0.8f })
            addPill(box, items.size * 140L)
        }
        column.setOnClickListener { dismissWithSlide() }
        handler.postDelayed({ dismissWithSlide() }, 2800L + items.size * 400L)
    }

    private fun showMessage(message: String, error: Boolean) {
        if (stopping) return
        val column = ensureRoot()
        handler.removeCallbacks(tick)
        shown = Shown.MESSAGE
        column.removeAllViews()
        val box = newPill()
        box.addView(
            text(message, 15f).apply {
                maxWidth = dp(260)
                if (error) setTextColor(0xFFFFB4B4.toInt())
            },
        )
        addPill(box)
        column.setOnClickListener { dismissWithSlide() }
        handler.postDelayed({ dismissWithSlide() }, if (error) 4000L else 2500L)
    }

    /** 整列向右滑出屏幕，再收尾 */
    private fun dismissWithSlide() {
        val column = root
        if (column == null || stopping) {
            stopSelfClean()
            return
        }
        stopping = true
        handler.removeCallbacksAndMessages(null)
        column.animate().translationX(column.width.toFloat() + dp(20)).setDuration(220)
            .withEndAction { stopSelfClean() }.start()
    }

    private fun stopSelfClean() {
        stopping = true
        handler.removeCallbacksAndMessages(null)
        root?.let { runCatching { wm.removeView(it) } }
        root = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        voice?.release()
        root?.let { runCatching { wm.removeView(it) } }
        root = null
        scope.cancel()
        super.onDestroy()
    }

    // ───────────────────────────── 小工具 ─────────────────────────────

    private fun text(value: String, sp: Float, bold: Boolean = false) = TextView(this).apply {
        text = value
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        if (bold) typeface = Typeface.DEFAULT_BOLD
    }

    /** 圆形按钮，里面放 [content] 画的图形 */
    private fun iconButton(fill: Int, content: () -> View): FrameHolder {
        val holder = FrameHolder(this)
        holder.background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(fill)
        }
        holder.contentDescription = "完成"
        holder.addView(content(), android.widget.FrameLayout.LayoutParams(dp(12), dp(12), Gravity.CENTER))
        return holder
    }

    private class FrameHolder(context: Context) : android.widget.FrameLayout(context)

    /** 停止键里的白色圆角方块 */
    private class Square(context: Context) : View(context) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
        override fun onDraw(canvas: Canvas) {
            canvas.drawRoundRect(RectF(0f, 0f, width.toFloat(), height.toFloat()), width * 0.2f, height * 0.2f, paint)
        }
    }

    /** 声波：每根竖条是一小段时间的音量；竖条越多，这个 View 越宽 */
    private class WaveView(context: Context) : View(context) {
        private val density = resources.displayMetrics.density
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            strokeCap = Paint.Cap.ROUND
            strokeWidth = 3f * density
        }
        private var bars: List<Float> = emptyList()
        private val slot = 6f * density

        fun set(values: List<Float>) {
            val grew = values.size != bars.size
            bars = values
            if (grew) requestLayout()
            invalidate()
        }

        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            val w = (maxOf(bars.size, 1) * slot).toInt()
            setMeasuredDimension(w, MeasureSpec.getSize(heightMeasureSpec).takeIf { it > 0 } ?: (28 * density).toInt())
        }

        override fun onDraw(canvas: Canvas) {
            val minH = 4f * density
            bars.forEachIndexed { i, raw ->
                val h = (minH + (height - minH) * sqrt(raw.coerceIn(0f, 1f))).coerceAtMost(height.toFloat())
                val x = i * slot + slot / 2
                canvas.drawLine(x, (height - h) / 2, x, (height + h) / 2, paint)
            }
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density + 0.5f).toInt()

    companion object {
        private const val CHANNEL = "voice_capsule"
        private const val NOTIFICATION_ID = 7301
        private const val ORIGIN = "voice"
        private const val WAVE_BARS = 30
        private const val SAMPLE_MS = 1000L
        const val ACTION_FINISH = "com.carpe.ideashell.action.VOICE_CAPSULE_FINISH"
        const val ACTION_CANCEL = "com.carpe.ideashell.action.VOICE_CAPSULE_CANCEL"

        /** 没在录就开始录，正在录就结束并保存 */
        fun toggle(context: Context) {
            context.startForegroundService(Intent(context, VoiceCapsuleService::class.java))
        }
    }
}
