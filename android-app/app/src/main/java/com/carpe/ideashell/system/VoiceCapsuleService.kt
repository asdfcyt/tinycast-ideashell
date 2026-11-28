package com.carpe.ideashell.system

import android.animation.ValueAnimator
import android.animation.ObjectAnimator
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.app.KeyguardManager
import android.content.pm.PackageManager
import android.provider.Settings
import android.view.Choreographer
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.data.settings.ThemeMode
import com.carpe.ideashell.core.voice.TodoOp
import com.carpe.ideashell.core.voice.VoiceResult
import com.carpe.ideashell.data.voice.VoiceSearch
import com.carpe.ideashell.ui.components.VoiceInputController
import com.carpe.ideashell.ui.components.VoicePhase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

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

    internal val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    internal val handler = Handler(Looper.getMainLooper())

    internal val wm by lazy { getSystemService(WINDOW_SERVICE) as WindowManager }

    internal val settings get() = (application as IdeashellApp).container.settings

    /** 贴右边缘的透明竖列窗口：里面是主面板（录音 / 整理 / 确认），或保存后的几个小胶囊 */
    internal var host: FrameLayout? = null

    internal var column: LinearLayout? = null

    internal var params: WindowManager.LayoutParams? = null

    internal var surface: FrameLayout? = null

    internal var restingY = 0

    /** 面板当前所在的 y（窗口顶边） */
    internal var panelY = 0

    internal var voice: VoiceInputController? = null

    internal var shown = CapsuleShown.NONE

    internal var stopping = false

    internal var holdMode = false

    /**
     * 守候模式（设置里的「熄屏也能用」）：服务常驻，录完回到待机而不是退出。
     * 麦克风前台服务不能在后台新建，所以提前在前台启动好，熄屏后音量键一按就能直接开录。
     */
    var armed = false
        private set

    /** 没有画面的录音（熄屏 / 锁屏）：不画胶囊，用震动反馈，结果直接保存 */
    internal var headless = false

    internal var keys: ScreenOffVoiceKeys? = null

    // 录音面板里要刷新的控件
    internal var timerText: TextView? = null

    internal var wave: WaveView? = null

    /** 录音胶囊里「已听到」的一行字（边说边识别出来的前几段）和它当前显示的内容 */
    internal var liveText: TextView? = null
    internal var liveShown = ""

    /** 「正在整理」胶囊里的文字：回答生成时边生成边显示 */
    internal var processingText: TextView? = null
    @Volatile
    private var pendingPartial: String? = null
    private val partialRunnable = Runnable { pendingPartial?.let { setProcessingText(it) } }

    /** 任意线程调用：把回答的最新文字交给界面（每 0.1 秒最多刷新一次） */
    internal fun postPartial(text: String) {
        pendingPartial = text
        if (!handler.hasCallbacks(partialRunnable)) handler.postDelayed(partialRunnable, 100)
    }

    internal var dotAnimator: ObjectAnimator? = null

    internal var recStart = 0L

    internal var lastTimerSec = -1

    // 说完停顿自动结束
    internal var noise = 0f

    internal var speechMs = 0L

    internal var lastVoiceMs = 0L

    internal var lastTickMs = 0L

    internal val drafts = ArrayList<CapsuleDraft>()

    internal var editing = false

    /** 松手自动保存：小胶囊倒计时，结束时才真正保存 */
    internal var countdown: ValueAnimator? = null

    // 编辑文字时跟着输入法上推：只认输入法「最终」的高度，用自己的动画平滑过去，
    // 不去跟系统输入法动画的逐帧数值（有的系统输入法会先冲过头再回落，卡片就会跟着乱弹）
    /** 输入法顶边在屏幕上的位置；Int.MAX_VALUE = 输入法没出来 */
    internal var imeTop = Int.MAX_VALUE

    /** 点中的输入框：悬浮窗拿到焦点之后才能弹出输入法，焦点来得晚时要补一次 */
    internal var imeTarget: View? = null

    /** 悬浮窗实际在屏幕上的位置减去 params.y（窗口避开状态栏带来的偏移） */
    internal var winOffset = 0

    internal var shiftAnimator: ValueAnimator? = null

    internal var shiftTarget = 0f

    internal var pal = CapsulePalette(true)

    internal fun resolvePalette(): CapsulePalette {
        val dark = when (settings.current.themeMode) {
            ThemeMode.DARK -> true
            ThemeMode.LIGHT -> false
            ThemeMode.SYSTEM -> (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        }
        return CapsulePalette(dark)
    }

    /** 跟着屏幕刷新（vsync）驱动，比 Handler 定时更跟手，波形滚动不会一顿一顿 */
    internal val frameCallback: Choreographer.FrameCallback = Choreographer.FrameCallback { tick.run() }

    /** 没有画面时屏幕不出帧（vsync 停了），改用 Handler 定时驱动（说完停顿自动结束要靠它） */
    internal val headlessTick = Runnable { tick.run() }

    internal fun scheduleTick() {
        if (headless) handler.postDelayed(headlessTick, 50) else Choreographer.getInstance().postFrameCallback(frameCallback)
    }

    internal fun stopTick() {
        Choreographer.getInstance().removeFrameCallback(frameCallback)
        handler.removeCallbacks(headlessTick)
    }

    internal val tick: Runnable = object : Runnable {
        override fun run() {
            if (stopping) return
            val v = voice ?: return
            when (v.phase) {
                VoicePhase.RECORDING, VoicePhase.LOCKED -> {
                    if (!headless && shown != CapsuleShown.RECORDING) renderRecording()
                    onRecordingTick(v)
                }
                VoicePhase.PROCESSING -> if (headless) shown = CapsuleShown.PROCESSING else if (shown != CapsuleShown.PROCESSING) renderProcessing()
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
            ACTION_ARM -> armService()
            ACTION_DISARM -> {
                settings.setVoiceKeyScreenOff(false)
                disarm()
            }
            ACTION_CANCEL -> {
                voice?.cancel()
                stopSelfClean()
            }
            ACTION_REPLAY -> {
                startForegroundNow()
                val id = intent.getStringExtra(EXTRA_REPLAY_ID)
                val v = voice
                val busy = v != null && v.phase != VoicePhase.IDLE || shown == CapsuleShown.CONFIRM || shown == CapsuleShown.PENDING
                if (id == null || busy) {
                    if (voice == null) stopSelfClean()
                } else {
                    replay(id, intent.getBooleanExtra(EXTRA_REPLAY_AUDIO, false))
                }
            }
            ACTION_FINISH -> {
                startForegroundNow()
                val v = voice
                if (v == null) stopSelfClean() else v.finish()
            }
            else -> {
                startForegroundNow()
                val hold = intent?.getBooleanExtra(EXTRA_HOLD, false) == true
                // 锁屏界面上（亮屏但没解锁）悬浮窗不可见：按没有画面处理
                val noScreen = intent?.getBooleanExtra(EXTRA_HEADLESS, false) == true
                val v = voice
                val recording = v != null && (v.phase == VoicePhase.RECORDING || v.phase == VoicePhase.LOCKED)
                when {
                    // 已经在录：点磁贴 / 快捷方式再来一次就是「完成」；按住说话的重复触发忽略
                    recording -> if (!hold) v?.finish()
                    // 正在整理 / 等着确认：不重复开始
                    v != null && (shown == CapsuleShown.PROCESSING || shown == CapsuleShown.CONFIRM || shown == CapsuleShown.PENDING) -> Unit
                    // 锁屏界面上按住音量键：和熄屏一样，震动提示 + 兜底的最长时间
                    noScreen -> if (hold) beginHeadlessHold() else toggleHeadless()
                    else -> begin(hold, headless = false)
                }
            }
        }
        return START_NOT_STICKY
    }

    /** 音量键松手：结束录音（按住说话） */
    fun onKeyReleased() {
        val v = voice
        if (v != null && holdMode && (v.phase == VoicePhase.RECORDING || v.phase == VoicePhase.LOCKED)) {
            if (headless) vibrate(VIB_STOP) // 没有画面：松手那一刻震一下，告诉你「收到了，在整理」
            v.finish()
        } else {
            pendingRelease = true // 录音还没真正开始就松手了：开始后立刻结束
        }
    }

    internal fun armService() {
        armed = true
        if (!startArmedForeground()) {
            armed = false
            if (voice == null) stopSelf()
            return
        }
        if (keys == null) {
            keys = ScreenOffVoiceKeys(
                context = this,
                settings = settings,
                onHoldStart = { beginHeadlessHold() },
                onHoldEnd = { endHeadlessHold() },
                onToggle = { toggleHeadless() },
            ).also { it.start() }
        }
    }

    /** 关闭守候：不再接管熄屏的按键，没在录音就退出服务 */
    fun disarm() {
        armed = false
        keys?.stop()
        keys = null
        stopSelfClean()
    }

    internal fun canRecordHeadless(): Boolean {
        if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            vibrate(VIB_ERROR)
            return false
        }
        val v = voice
        // 上一条还在录 / 识别 / 等确认：不重复开始
        return !(v != null && v.phase != VoicePhase.IDLE) && shown == CapsuleShown.NONE
    }

    /** 熄屏：音量键按够长按时间 → 震一下，开始录音 */
    internal fun beginHeadlessHold() {
        android.util.Log.i("ShiyiKeys", "beginHeadlessHold")
        if (!canRecordHeadless()) return
        if (startHeadless(hold = true)) vibrate(VIB_START)
    }

    /** 熄屏：音量键抬起 → 震一下，结束录音并处理 */
    internal fun endHeadlessHold() {
        finishHeadless()
    }

    /** 耳机键：没在录就开始，在录就结束 */
    internal fun toggleHeadless() {
        android.util.Log.i("ShiyiKeys", "toggleHeadless headless=$headless")
        val v = voice
        if (headless && v != null && (v.phase == VoicePhase.RECORDING || v.phase == VoicePhase.LOCKED)) {
            finishHeadless()
            return
        }
        if (!canRecordHeadless()) return
        if (startHeadless(hold = false)) vibrate(VIB_START)
    }

    internal fun startHeadless(hold: Boolean): Boolean {
        begin(hold, headless = true)
        val v = voice
        val recording = v != null && (v.phase == VoicePhase.RECORDING || v.phase == VoicePhase.LOCKED)
        // 万一松手的事件没收到，别一直录下去
        if (recording) handler.postDelayed(maxHeadless, HEADLESS_MAX_MS)
        return recording
    }

    internal val maxHeadless = Runnable { finishHeadless() }

    internal fun finishHeadless() {
        handler.removeCallbacks(maxHeadless)
        val v = voice ?: return
        if (headless && (v.phase == VoicePhase.RECORDING || v.phase == VoicePhase.LOCKED)) {
            vibrate(VIB_STOP)
            v.finish()
        }
    }

    /** 没有画面的录音处理完了：震动告知结果，回到待机 */
    internal fun headlessDone(ok: Boolean, detail: String? = null, searchQuery: String? = null, title: String? = null) {
        android.util.Log.i("ShiyiKeys", "headlessDone ok=$ok detail=$detail")
        vibrate(if (ok) VIB_OK else VIB_ERROR)
        if (!detail.isNullOrBlank()) postHeadlessResult(ok, detail, searchQuery, title)
        stopSelfClean()
    }

    internal fun ensureController(): VoiceInputController {
        val container = (application as IdeashellApp).container
        return voice ?: VoiceInputController(
            scope = scope,
            settings = container.settings,
            asr = container.asr,
            local = container.localAsr,
            llm = container.llm,
            lexicon = container.lexicon,
            extraHotwords = { container.voiceContext.hotwords() },
            todoContext = { container.voiceContext.todoLines() },
            skillNames = { container.assistantSkills.names() },
            history = container.voiceHistory,
            voicePrint = container.voicePrint,
            onError = { showMessage(it, error = true) },
            onResult = { result -> onResult(result) },
        ).also { voice = it }
    }

    /** 语音历史里的「重新识别（[audio]）/ 重新整理」：显示「正在识别整理」，结果和平时一样走确认卡片 / 自动保存 */
    internal fun replay(id: String, audio: Boolean) {
        if (!Settings.canDrawOverlays(this)) {
            stopSelfClean()
            return
        }
        val controller = ensureController()
        holdMode = false
        stopping = false
        drafts.clear()
        cancelCountdown()
        pal = resolvePalette()
        ensureColumn()
        renderProcessing()
        stopTick()
        scheduleTick()
        val history = (application as IdeashellApp).container.voiceHistory
        scope.launch {
            if (audio) {
                val pcm = history.audio(id)
                if (pcm == null) showMessage("这条的录音已经不在了", error = true) else controller.reprocessAudio(pcm, id)
            } else {
                val raw = history.get(id)?.raw
                if (raw.isNullOrBlank()) showMessage("这条没有识别出原话，可以试试「重新识别」", error = true)
                else controller.reprocessText(raw, id)
            }
        }
    }

    internal fun begin(hold: Boolean, headless: Boolean = false) {
        this.headless = headless
        if (!headless && !Settings.canDrawOverlays(this)) {
            stopSelfClean()
            return
        }
        // 新一轮录音开始：别让上一段语音回答还在响（也免得被麦克风录进去）
        (application as IdeashellApp).container.speech.stop()
        val controller = ensureController()
        holdMode = hold
        stopping = false
        drafts.clear()
        cancelCountdown()
        pal = resolvePalette()
        if (!headless) ensureColumn()
        if (!controller.start()) return // start() 已经通过 onError 说明了原因
        // 趁用户还停在要问的那一页：先抓一份屏幕文字（后台线程；只在内存里，说到「这页」时才会带给 AI）
        scope.launch(Dispatchers.Default) { runCatching { com.carpe.ideashell.data.assistant.ScreenContext.snapshotNow() } }
        // 智能家居：趁说话的时候把设备目录刷新好，说完直接用
        scope.launch(Dispatchers.IO) { runCatching { (application as IdeashellApp).container.homeAssistant.warm() } }
        // 位置：同样趁说话的时候刷新（缓存 10 分钟内的不动）
        scope.launch(Dispatchers.IO) { runCatching { (application as IdeashellApp).container.place.refresh() } }
        recStart = SystemClock.uptimeMillis()
        lastTimerSec = -1
        noise = 0f
        speechMs = 0L
        lastVoiceMs = 0L
        lastTickMs = 0L
        if (headless) shown = CapsuleShown.RECORDING else renderRecording()
        stopTick()
        scheduleTick()
        if (hold && pendingRelease) {
            pendingRelease = false
            if (headless) vibrate(VIB_STOP)
            controller.finish()
        }
    }

    internal fun onRecordingTick(v: VoiceInputController) {
        val elapsed = SystemClock.uptimeMillis() - recStart
        val sec = (elapsed / 1000).toInt()
        if (sec != lastTimerSec) {
            lastTimerSec = sec
            timerText?.text = "%d:%02d".format(sec / 60, sec % 60)
        }

        // 声波：位置固定的一排竖条，每帧弹性地靠近各自的目标高度（见 [WaveView]）
        wave?.update(v.level, elapsed)

        // 边说边识别：前几段识别完了，把「已听到」显示在波形下面
        val live = v.partial
        if (live != liveShown) {
            liveShown = live
            liveText?.let { tv ->
                if (live.isBlank()) {
                    tv.visibility = View.GONE
                } else {
                    tv.text = if (live.length > 36) "…" + live.takeLast(36) else live
                    tv.visibility = View.VISIBLE
                }
                recenter()
            }
        }

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
        // 没有屏幕时没法看进度，停顿时间缩短一点（约 2/3，至少 0.9 秒），更快进入整理
        val silenceMs = if (headless) (settings.current.voiceSilenceMs * 2 / 3).coerceAtLeast(900) else settings.current.voiceSilenceMs
        if (heard && elapsed - lastVoiceMs >= silenceMs) {
            if (headless) vibrate(VIB_STOP)
            v.finish()
        } else if (!heard && elapsed >= NO_SPEECH_MS) {
            v.cancel()
            showMessage("没有听到声音", error = true)
        }
    }

    internal fun onResult(result: VoiceResult) {
        // 说了指令（长录音 / 新建笔记 / 打开 AI）：丢掉这段，直接去闪念贝壳执行
        val command = result.command
        if (command != null) {
            if (stopping) return
            val ok = IdeashellBridge.run(this, command)
            if (headless) {
                headlessDone(ok)
            } else if (ok) {
                stopSelfClean()
            } else {
                showMessage("没能打开闪念贝壳（${command.label}）", error = true)
            }
            return
        }
        scope.launch {
            val editor = (application as IdeashellApp).container.todoEditor
            // 「今天还有什么没做」：纯查询，不保存任何东西，直接把清单显示出来
            val queries = result.intents.filter { it.edit && it.op == TodoOp.QUERY }
            val found = mutableListOf<VoiceSearch.Result>()
            for (q in queries) {
                val tasks = editor.query(q.range, q.target)
                found += VoiceSearch.Result(editor.formatQuery(q.range, q.target, tasks), VoiceSearch.taskHits(tasks), q.target.orEmpty())
            }
            // 「找一下关于招聘的笔记」：不调 AI，本机待办 + 闪念贝壳笔记里直接查
            val searches = result.intents.filter { it.searchScope != null }
            for (s in searches) found += VoiceSearch.find((application as IdeashellApp).container, s)
            // 「我昨天做了哪些事」：让语音助手（大模型 + 查数据的工具）基于你自己的记录回答
            val answers = result.intents.filter { it.answer }
            if (answers.isNotEmpty() && !headless) setProcessingText("正在思考…")
            for (a in answers) found += answerOf((application as IdeashellApp).container, a.content, result.raw)
            val queryText = found.joinToString("\n") { it.text }
            val rest = result.intents.filterNot { (it.edit && it.op == TodoOp.QUERY) || it.searchScope != null || it.answer }
            if (found.isNotEmpty() && rest.isEmpty()) {
                if (stopping) return@launch
                showResults(VoiceSearch.merge(found))
                return@launch
            }
            // 修改 / 完成 / 删除待办要先去滴答里找到那一条（可能要刷新一下），这期间界面还停在「正在识别整理」
            val built = buildDrafts(if (queries.isEmpty() && searches.isEmpty() && answers.isEmpty()) result else result.copy(intents = rest))
            if (stopping) return@launch
            drafts.clear()
            drafts.addAll(built)
            val note = listOfNotNull(result.polishError, queryText.ifBlank { null }).joinToString("\n").ifBlank { null }
            // 没有画面（熄屏 / 锁屏）：没法确认，直接保存；删除待办不可恢复，这种情况下一律不执行
            if (headless) {
                val safe = built.filterNot { it.mode == CapsuleMode.EDIT && it.op() == TodoOp.DELETE }
                if (safe.isEmpty()) {
                    headlessDone(false)
                } else {
                    drafts.clear()
                    drafts.addAll(safe)
                    saveAll(safe, note, quiet = true)
                }
                return@launch
            }
            // 删除待办不可恢复：即使开了「松手自动保存」也要弹出确认卡片，由用户点保存
            val needsConfirm = drafts.any { it.mode == CapsuleMode.EDIT && it.op() == TodoOp.DELETE && it.task != null }
            // 开了「松手自动保存」：不弹确认卡片，只显示小胶囊倒计时；点它才展开卡片修改
            if (settings.current.voiceAutoSend && !needsConfirm) renderPending(note) else renderConfirm(note)
        }
    }

    /** 卡片高度变了（输入换行等）或窗口刚铺满：按最新高度重新算该推多高 */
    internal val columnLayoutListener = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> retargetShift(animate = false) }

    internal val restoreWindow = Runnable {
        if (editing) return@Runnable
        val p = params ?: return@Runnable
        val h = host ?: return@Runnable
        val col = column ?: return@Runnable
        imeTop = Int.MAX_VALUE
        cancelShift()
        h.setOnApplyWindowInsetsListener(null)
        if (Build.VERSION.SDK_INT >= 30) h.setWindowInsetsAnimationCallback(null)
        h.setOnClickListener(null)
        h.setOnTouchListener(null)
        h.isClickable = false
        h.removeOnLayoutChangeListener(columnLayoutListener)
        col.removeOnLayoutChangeListener(columnLayoutListener)
        // 窗口只往下缩回内容大小：顶边不动，画面不会跳
        p.flags = (p.flags or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS) and
            (WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH).inv()
        p.height = WindowManager.LayoutParams.WRAP_CONTENT
        p.y = panelY
        updateWindow()
    }

    internal fun cancelCountdown() {
        countdown?.cancel()
        countdown = null
    }

    internal fun stopSelfClean() {
        stopping = true
        cancelShift()
        stopTick()
        handler.removeCallbacksAndMessages(null)
        dotAnimator?.cancel()
        cancelCountdown()
        host?.let { runCatching { wm.removeView(it) } }
        host = null
        column = null
        surface = null
        if (armed) {
            resetToIdle()
            return
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /** 守候模式下一条记录结束：不退出服务，清掉这一轮的状态，通知改回「守候中」 */
    internal fun resetToIdle() {
        voice?.let { if (it.phase != VoicePhase.IDLE) it.cancel() }
        drafts.clear()
        shown = CapsuleShown.NONE
        holdMode = false
        headless = false
        editing = false
        pendingRelease = false
        dotAnimator = null
        wave = null
        timerText = null
        stopping = false
        startArmedForeground(refreshOnly = true)
    }

    override fun onDestroy() {
        keys?.stop()
        keys = null
        if (instance === this) instance = null
        handler.removeCallbacksAndMessages(null)
        dotAnimator?.cancel()
        cancelShift()
        voice?.release()
        cancelCountdown()
        host?.let { runCatching { wm.removeView(it) } }
        host = null
        column = null
        scope.cancel()
        super.onDestroy()
    }

    companion object {

        /** 熄屏录音的最长时间：松手事件万一丢了，到点自动结束 */
        private const val HEADLESS_MAX_MS = 60_000L

        /** 一直没人说话就放弃的时间 */
        private const val NO_SPEECH_MS = 6000L

        const val ACTION_FINISH = "com.carpe.ideashell.action.VOICE_CAPSULE_FINISH"
        const val ACTION_CANCEL = "com.carpe.ideashell.action.VOICE_CAPSULE_CANCEL"
        const val ACTION_REPLAY = "com.carpe.ideashell.action.VOICE_CAPSULE_REPLAY"
        const val ACTION_ARM = "com.carpe.ideashell.action.VOICE_CAPSULE_ARM"
        const val ACTION_DISARM = "com.carpe.ideashell.action.VOICE_CAPSULE_DISARM"
        private const val EXTRA_HOLD = "hold"
        private const val EXTRA_HEADLESS = "headless"
        private const val EXTRA_REPLAY_ID = "replay_id"
        private const val EXTRA_REPLAY_AUDIO = "replay_audio"

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

        /** 系统助手入口（长按电源键等）：没在录就开始录，亮屏停在锁屏界面时按没有画面的方式录 */
        fun startAssist(context: Context) {
            val locked = context.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked == true
            context.startForegroundService(Intent(context, VoiceCapsuleService::class.java).putExtra(EXTRA_HEADLESS, locked))
        }

        /** 语音历史里的「重新识别 / 重新整理」：用胶囊显示进度和确认卡片（需要「显示在其他应用上层」权限） */
        fun replay(context: Context, historyId: String, audio: Boolean) {
            context.startForegroundService(
                Intent(context, VoiceCapsuleService::class.java)
                    .setAction(ACTION_REPLAY)
                    .putExtra(EXTRA_REPLAY_ID, historyId)
                    .putExtra(EXTRA_REPLAY_AUDIO, audio),
            )
        }

        /** 音量键按住：开始录，松手由 [onKeyReleased] 结束（录音期间不做说完自动结束） */
        fun startHold(context: Context) {
            pendingRelease = false
            // 亮屏但停在锁屏界面：悬浮窗看不见，按没有画面的方式录（震动反馈、直接保存）
            val locked = context.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked == true
            context.startForegroundService(
                Intent(context, VoiceCapsuleService::class.java).putExtra(EXTRA_HOLD, true).putExtra(EXTRA_HEADLESS, locked),
            )
        }

        /** 开启熄屏守候（要在应用在前台时调：麦克风前台服务不能在后台新建） */
        fun arm(context: Context) {
            context.startForegroundService(Intent(context, VoiceCapsuleService::class.java).setAction(ACTION_ARM))
        }

        /** 守候是否正在生效 */
        val isArmed: Boolean get() = instance?.armed == true

        /** 设置里开着「熄屏也能用」、权限也够，但服务没在守候（刚开机 / 被系统杀了）：应用打开时补一次 */
        fun armIfEnabled(context: Context) {
            val s = (context.applicationContext as IdeashellApp).container.settings.current
            if (!s.voiceKeyScreenOff || s.voiceKey == com.carpe.ideashell.data.settings.VoiceKey.OFF || isArmed) return
            if (context.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) return
            runCatching { arm(context) }
        }

        /** 关闭熄屏守候 */
        fun disarm(context: Context) {
            instance?.disarm()
        }
    }
}
