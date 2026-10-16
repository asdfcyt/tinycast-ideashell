package com.carpe.ideashell.system

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.LayerDrawable
import android.graphics.drawable.TransitionDrawable
import android.animation.ValueAnimator
import android.view.accessibility.AccessibilityWindowInfo
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.Toast
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.data.capture.ExcerptDrafts
import com.carpe.ideashell.ui.capture.ExcerptSheetActivity
import com.carpe.ideashell.R
import com.carpe.ideashell.data.settings.ThemeMode
import com.carpe.ideashell.data.capture.ExcerptNotes
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlin.math.abs

/**
 * 「快速摘录模式」：开启后屏幕边缘吸附着一个小小的竖向胶囊（一半藏在屏幕外），里面只有一个闪电。
 * 在任何 App 里选中文字后，胶囊会整个滑出来并描上主题色；点一下，选中的文字就存成闪念贝壳的一条摘录笔记
 * （带来源、`#摘录` 标签），可在抽屉里写想法。
 * App 不上报选中文字时（如微信、小红书），改为读剪贴板：点胶囊时先替用户点一下选区菜单里的「复制」，再读剪贴板。
 *
 * 只在模式开着时、且只读取「你选中的那段文字」，不后台读取其他内容。
 * 密码框、支付 / 银行类 App 一律忽略。
 */
class ExcerptService : AccessibilityService() {

    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val container get() = (application as IdeashellApp).container
    private val wm by lazy { getSystemService(WINDOW_SERVICE) as WindowManager }
    private val density get() = resources.displayMetrics.density

    /** 悬浮的竖向胶囊：平时一半吸附在屏幕边缘；有选中的文字时整个滑出来，点一下就摘录 */
    private var capsule: FrameLayout? = null
    private var capsuleParams: WindowManager.LayoutParams? = null
    private var capsuleIcon: ImageView? = null
    private var xAnim: ValueAnimator? = null
    private var shownActive = false

    /** 最近一次选中的内容（选区事件或扫描得到）；null 表示没有 */
    @Volatile private var pending: Selection? = null
    private val clearPending = Runnable { pending = null; refreshStyle() }

    /** 屏幕上是否有选区菜单（带「复制」按钮）：App 不上报选区事件时，用它判断「有选中的文字」 */
    @Volatile private var menuUp = false
    private var menuCheckQueued = false
    private var menuScanning = false
    private var tapBusy = false

    /** 上一次扫描「复制」菜单结束的时间：没菜单时扫描不能一个接一个（界面一直在刷新的 App 会被我们拖慢） */
    private var lastScanEnd = 0L

    /** 最近一次找到的「复制」按钮：菜单在时用它做廉价的复查，点胶囊时直接点它，不用再遍历界面树 */
    @Volatile private var copyNode: AccessibilityNodeInfo? = null

    /** 选中后在后台提前识别书名 / 文章标题：点胶囊时已经备好，不用现扫 */
    private var titleJob: java.util.concurrent.Future<String?>? = null

    private val menuCheck: Runnable = object : Runnable {
      override fun run() {
        menuCheckQueued = false
        if (sheetOpen || capsule == null) return
        // 找「复制」要跨进程等别的 App 响应，放在后台线程；上一次还没扫完就等一会儿
        if (menuScanning) {
            menuCheckQueued = true
            main.postDelayed(this, 150)
            return
        }
        menuScanning = true
        scanExec.execute {
            // 菜单已经在：只确认缓存的那个「复制」按钮还在（一次调用）；不在了或没菜单才遍历
            val up = runCatching { menuStillUp() || hasCopyMenu() }.getOrDefault(false)
            main.post {
                menuScanning = false
                lastScanEnd = android.os.SystemClock.uptimeMillis()
                if (capsule == null) return@post
                if (up != menuUp) {
                    menuUp = up
                    refreshStyle()
                }
                // 菜单在时每 0.4 秒复查一次（很便宜）：有的 App 菜单消失时不一定发窗口事件
                if (menuUp && !menuCheckQueued) {
                    menuCheckQueued = true
                    main.postDelayed(this, 400)
                }
            }
        }
      }
    }

    /** 安排一次菜单检查：菜单已在 → 很快复查；没菜单 → 和上一次扫描隔开一点 */
    private fun queueMenuCheck() {
        if (menuCheckQueued || capsule == null) return
        menuCheckQueued = true
        val gap = if (menuUp) 120L
        else maxOf(120L, 320L - (android.os.SystemClock.uptimeMillis() - lastScanEnd))
        main.postDelayed(menuCheck, gap)
    }

    /** 缓存的「复制」按钮是否还在屏幕上 */
    private fun menuStillUp(): Boolean {
        val n = copyNode ?: return false
        val ok = runCatching { n.refresh() && n.isVisibleToUser }.getOrDefault(false)
        if (!ok) copyNode = null
        return ok
    }

    // ───────────── 财新等「复制不写剪贴板、认不出选区工具条」的 App：走它的「分享」 ─────────────
    // 财新工具条里的「复制」不会更新系统剪贴板，界面又一直在刷新（滚动广告、热点条），事件一多、扫界面树就卡。
    // 但它的「分享」能把选中的文字交给系统分享菜单。所以：
    //   用户点「分享」（或点胶囊，由我们替他点「⋮ → 分享」）→ 系统分享菜单弹出 → 从分享菜单的内容预览里读出文字
    //   → 返回键关掉分享菜单 → 弹摘录抽屉。
    // 只在这一次点击之后读一次界面（后台线程），平时不做任何事件驱动的扫描。

    /** 最近一个前台 App 的包名（取自无障碍事件，不遍历界面） */
    @Volatile private var lastPkg: String? = null
    /** 三条互不排队的后台线程：扫描菜单 / 处理点击 / 识别标题（点胶囊时不能排在一次慢扫描后面） */
    private val scanExec = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val tapExec = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val titleExec = java.util.concurrent.Executors.newSingleThreadExecutor()
    private var shareBusy = false

    /** 点胶囊（财新这类 App）：有没提交的想法就重开抽屉；否则替用户点「⋮ → 分享」，再从分享菜单里取文字 */
    private fun onClipboardAppTap(pkg: String) {
        val draft = ExcerptDrafts.alive()
        if (draft != null) {
            runCatching {
                startActivity(
                    ExcerptSheetActivity.intent(this, draft.pkg, draft.appName, draft.docTitle, draft.quote)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION),
                )
            }
            return
        }
        if (shareBusy) return
        shareBusy = true
        tapExec.execute {
            val clicked = runCatching {
                clickLabel("分享") || (clickLabel("更多选项") && run { Thread.sleep(450); clickLabel("分享") })
            }.getOrDefault(false)
            if (clicked) {
                captureFromShareSheet(pkg)
            } else {
                main.post { shareBusy = false; toast("先选中文字，再点这里") }
            }
        }
    }

    /** 用户自己点了「分享」：同样从弹出的分享菜单里取文字 */
    private fun onShareClicked(pkg: String) {
        if (shareBusy) return
        shareBusy = true
        tapExec.execute { captureFromShareSheet(pkg) }
    }

    /** （后台线程）等分享菜单出来，读出里面的文字，关掉分享菜单，回主线程弹抽屉 */
    private fun captureFromShareSheet(pkg: String) {
        var text: String? = null
        try {
            val deadline = android.os.SystemClock.uptimeMillis() + 3000
            var last: String? = null
            while (text == null && android.os.SystemClock.uptimeMillis() < deadline) {
                Thread.sleep(80)
                val t = runCatching { readShareSheetText(pkg) }.getOrNull()
                // 长文字一读到就用（分享菜单里的 App 名都很短）；短的要连续两次读到一样，防止拿到半截
                if (t != null && (t.length >= 12 || t == last)) text = t
                last = t
            }
            // 读到就马上关掉分享菜单、弹抽屉，不再多等
            if (text != null) performGlobalAction(GLOBAL_ACTION_BACK)
        } finally {
            val result = text
            main.post {
                shareBusy = false
                if (result != null) {
                    tapDocTitle = null
                    saveExcerpt(Selection(result.take(2000), pkg))
                } else {
                    toast("没读到分享的文字")
                }
            }
        }
    }

    /** 在别的窗口（分享菜单）里找最长的一段文字，当作分享内容（分享内容的预览，比应用名之类的标签都长得多） */
    private fun readShareSheetText(pkg: String): String? {
        var best: String? = null
        for (w in windows.orEmpty()) {
            if (w.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD) continue
            val root = w.root ?: continue
            val p = root.packageName?.toString() ?: continue
            if (p == pkg || p == packageName || p.contains("systemui", ignoreCase = true)) continue
            val budget = Budget()
            fun walk(n: AccessibilityNodeInfo, depth: Int) {
                if (depth > 30 || budget.spent()) return
                val t = n.text?.toString()?.trim()
                if (t != null && t.length >= 4 && t.length > (best?.length ?: 0)) best = t
                for (i in 0 until n.childCount) n.getChild(i)?.let { walk(it, depth + 1) }
            }
            walk(root, 0)
        }
        return best
    }

    /** 点一下界面里标签恰好是 [label] 的按钮（往上找几层能点的）；找不到返回 false */
    private fun clickLabel(label: String): Boolean {
        val roots = buildList {
            rootInActiveWindow?.let { add(it) }
            windows?.forEach { w ->
                if (w.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD) return@forEach
                w.root?.takeIf { it.packageName != packageName }?.let { add(it) }
            }
        }
        for (root in roots) {
            for (hit in root.findAccessibilityNodeInfosByText(label)) {
                val t = (hit.text ?: hit.contentDescription)?.toString()?.trim()
                if (t != label || !hit.isVisibleToUser) continue
                var n: AccessibilityNodeInfo? = hit
                var depth = 0
                while (n != null && depth < 5) {
                    if (n.isClickable && n.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
                    n = n.parent
                    depth++
                }
            }
        }
        return false
    }

    /** 未提交的想法（[ExcerptDrafts]）过期时刷新胶囊：缩回边缘 */
    private val draftExpire = Runnable { refreshStyle() }

    /** 抽屉里的草稿有变化（暂存 / 保存 / 丢弃）：草稿还活着时胶囊保持滑出，点一下接着写；到期后缩回 */
    fun onDraftChanged() {
        main.post {
            main.removeCallbacks(draftExpire)
            val d = ExcerptDrafts.alive()
            if (d != null) main.postDelayed(draftExpire, ExcerptDrafts.MAX_AGE_MS - (System.currentTimeMillis() - d.at) + 200)
            refreshStyle()
        }
    }

    /** 点胶囊那一刻识别到的书名 / 文章标题（识别不到为 null） */
    @Volatile private var tapDocTitle: String? = null

    private data class Selection(val text: String, val pkg: String)

    override fun onServiceConnected() {
        instance = this
        scope.launch {
            container.settings.state.map { it.excerptMode to it.themeMode }.distinctUntilChanged().collect { (on, _) ->
                hideAll()
                if (on) showCapsule()
            }
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event ?: return
        if (!container.settings.current.excerptMode) return
        // 摘录抽屉开着（正在打字）：键盘每按一下都会发窗口事件，这里再去遍历所有窗口会把主线程占住，输入就卡；抽屉开着时什么都不做
        if (sheetOpen) return
        val pkg = event.packageName?.toString() ?: return
        if (pkg == packageName || pkg == "com.android.systemui" || isSensitive(pkg)) return
        lastPkg = pkg
        // 财新这类 App：不做事件驱动的扫描（见上面的说明）；只看「点了分享」这一个点击事件（点击很少，几乎不花时间）
        if (pkg in CLIPBOARD_DRIVEN) {
            if (event.eventType == AccessibilityEvent.TYPE_VIEW_CLICKED) {
                val label = (event.text?.joinToString("") ?: event.contentDescription?.toString()).orEmpty().trim()
                if (label == "分享") onShareClicked(pkg)
            }
            return
        }
        if (event.eventType != AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED) {
            // 窗口变化：App 不上报选区时（微信、微信读书…），靠「选区菜单（复制）出现 / 消失」判断有没有选中文字
            // 只是文字在变（计时、滚动里的文案）不可能冒出选区菜单，没菜单时不理它，省得白扫
            if (!menuUp && event.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED &&
                event.contentChangeTypes == AccessibilityEvent.CONTENT_CHANGE_TYPE_TEXT
            ) return
            queueMenuCheck()
            return
        }
        if (event.isPassword) return

        val full = event.text?.joinToString("") ?: return
        val from = minOf(event.fromIndex, event.toIndex)
        val to = maxOf(event.fromIndex, event.toIndex)
        main.removeCallbacks(clearPending)
        if (from < 0 || to > full.length || to - from < 1) {
            // 选区取消了：稍等再清（点气泡时 App 往往也会清掉选区，所以不立刻清）
            main.postDelayed(clearPending, 3000)
            return
        }
        val selected = full.substring(from, to).trim()
        if (selected.isEmpty()) return
        pending = selectionOf(selected, pkg)
        refreshStyle()
    }

    override fun onInterrupt() = Unit

    /** 系统深色 / 浅色切换：胶囊的颜色跟着变 */
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (capsule != null) {
            hideAll()
            showCapsule()
        }
    }

    override fun onUnbind(intent: Intent?): Boolean {
        teardown()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        teardown()
        super.onDestroy()
    }

    private fun teardown() {
        if (instance === this) instance = null
        scanExec.shutdownNow(); tapExec.shutdownNow(); titleExec.shutdownNow()
        main.removeCallbacksAndMessages(null)
        hideAll()
        scope.cancel()
    }

    // ───────────────────────── 选中的内容 ─────────────────────────

    private fun selectionOf(selected: String, pkg: String) = Selection(selected, pkg)

    private fun isSensitive(pkg: String): Boolean =
        pkg in BLOCKED || pkg.contains("bank", ignoreCase = true) || pkg.contains("pay", ignoreCase = true)

    private fun appLabel(pkg: String): String = runCatching {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    }.getOrDefault(pkg)

    // ───────────────────────── 保存 ─────────────────────────

    /**
     * 保存一段摘录（不再加入重温）：
     * - 「摘录后写想法」开着：弹出抽屉，写想法、确认来源和标签（来源 / 标签在同一个 App 里延续），点保存才写进笔记；
     * - 关着：不弹抽屉，直接把原文 + 来源存进笔记，没有想法。
     * 同一个 App、同一个来源下连续摘录，都追加进同一篇笔记。
     */
    private fun saveExcerpt(sel: Selection) {
        val label = appLabel(sel.pkg)
        val docTitle = tapDocTitle
        val c = container
        if (c.settings.current.excerptWriteNote) {
            runCatching {
                startActivity(
                    ExcerptSheetActivity.intent(this, sel.pkg, label, docTitle, sel.text)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION),
                )
            }.onFailure { toast("没能打开摘录抽屉") }
        } else {
            val suggestion = c.excerpts.suggest(sel.pkg, docTitle, label)
            c.appScope.launch {
                val r = c.excerpts.write(ExcerptNotes.Entry(sel.pkg, label, suggestion.source, suggestion.tags, sel.text, ""))
                toast(ExcerptSheetActivity.messageOf(r))
            }
        }
        pending = null
        menuUp = false
        refreshStyle()
    }

    private fun toast(msg: String) = main.post { Toast.makeText(this, msg, Toast.LENGTH_SHORT).show() }

    // ───────────────────────── 悬浮胶囊 ─────────────────────────

    private fun dp(v: Int) = (v * density).toInt()

    private fun isDark(): Boolean = when (container.settings.current.themeMode) {
        ThemeMode.DARK -> true
        ThemeMode.LIGHT -> false
        else -> (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    }

    private val orange get() = if (isDark()) 0xFFE0703F.toInt() else 0xFFE8794A.toInt()
    private fun overlayParams(): WindowManager.LayoutParams = WindowManager.LayoutParams(
        dp(CAPSULE_W),
        dp(CAPSULE_H),
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
        PixelFormat.TRANSLUCENT,
    ).apply { gravity = Gravity.TOP or Gravity.START }

    /** 停靠时的横坐标：平时一半藏在屏幕外，有选中的文字时整个露出来 */
    private fun dockX(out: Boolean): Int {
        val w = resources.displayMetrics.widthPixels
        val size = dp(CAPSULE_W)
        return if (dockRight) {
            if (out) w - size - dp(4) else w - size / 2
        } else {
            if (out) dp(4) else -size / 2
        }
    }

    private fun showCapsule() {
        if (capsule != null) return
        val bolt = ImageView(this).apply {
            setImageResource(R.drawable.ic_bolt)
            setColorFilter(orange)
        }
        val box = FrameLayout(this).apply {
            contentDescription = "快速摘录：先选中文字，再点这里"
            // 图标放在露出来的那一半里
            addView(bolt, FrameLayout.LayoutParams(dp(18), dp(18), Gravity.CENTER))
        }
        // 平常态和高亮态叠在一起，切换时淡入淡出（而不是一下子换掉）
        box.background = TransitionDrawable(arrayOf(capsuleBackground(highlight = false), capsuleBackground(highlight = true))).apply {
            isCrossFadeEnabled = true
        }
        shownActive = false
        val params = overlayParams().apply {
            x = dockX(out = false)
            y = if (lastY >= 0) lastY else resources.displayMetrics.heightPixels / 3
        }
        box.setOnTouchListener(DragListener(params))
        // 刚出现时淡入，不是突然冒出来
        box.alpha = 0f
        wm.addView(box, params)
        box.animate().alpha(1f).setDuration(280).start()
        capsule = box
        capsuleParams = params
        capsuleIcon = bolt
        refreshStyle()
    }

    /**
     * 液态玻璃质感：半透明的底 + 自上而下的高光渐变 + 内侧一圈亮边 + 外侧细描边。
     * （系统悬浮窗没法采样其他 App 的画面，开源的液态玻璃库都做不了真正的折射，所以用分层的半透明模拟。）
     * 有选中的文字时，外圈改描主题色。
     */
    private fun capsuleBackground(highlight: Boolean): LayerDrawable {
        val r = dp(CAPSULE_W / 2).toFloat()
        val dark = isDark()
        val base = GradientDrawable().apply {
            cornerRadius = r
            setColor(if (dark) 0xA62A2522.toInt() else 0xB8FFFFFF.toInt())
            if (highlight) setStroke(dp(2), orange) else setStroke(dp(1), if (dark) 0x40FFFFFF else 0x22000000)
        }
        val sheen = GradientDrawable(
            GradientDrawable.Orientation.TOP_BOTTOM,
            if (dark) intArrayOf(0x40FFFFFF, 0x08FFFFFF, 0x18FFFFFF) else intArrayOf(0xCCFFFFFF.toInt(), 0x22FFFFFF, 0x66FFFFFF),
        ).apply {
            cornerRadius = r
        }
        val rim = GradientDrawable().apply {
            cornerRadius = r
            setStroke(dp(1), if (dark) 0x55FFFFFF else 0xE6FFFFFF.toInt())
        }
        val inset = dp(if (highlight) 2 else 1)
        return LayerDrawable(arrayOf(base, sheen, rim)).apply {
            setLayerInset(1, inset, inset, inset, inset)
            setLayerInset(2, inset, inset, inset, inset)
        }
    }

    /** 有没有选中的文字，决定胶囊是滑出来（描上主题色）还是缩回边缘；位置和描边都是渐变过去的 */
    private fun refreshStyle() {
        val box = capsule ?: return
        // 刚选中文字：趁用户还没点胶囊，后台把书名 / 标题识别好；选区没了就作废
        if (pending != null || menuUp) kickTitleJob() else titleJob = null
        val active = pending != null || menuUp || ExcerptDrafts.alive() != null
        if (active != shownActive) {
            shownActive = active
            (box.background as? TransitionDrawable)?.let { if (active) it.startTransition(CAPSULE_ANIM_MS) else it.reverseTransition(CAPSULE_ANIM_MS) }
            // 闪电：滑出来时弹一下，缩回时恢复
            capsuleIcon?.animate()?.cancel()
            if (active) {
                capsuleIcon?.animate()?.scaleX(1.25f)?.scaleY(1.25f)?.setDuration(CAPSULE_ANIM_MS.toLong())?.setInterpolator(OvershootInterpolator(2.2f))?.start()
            } else {
                capsuleIcon?.animate()?.scaleX(1f)?.scaleY(1f)?.setDuration(CAPSULE_ANIM_MS.toLong())?.setInterpolator(DecelerateInterpolator())?.start()
            }
        }
        slideTo(dockX(out = active), overshoot = active)
    }

    /** 把胶囊平滑地挪到横坐标 [target]：滑出来时带一点点回弹，缩回 / 吸边时减速停住 */
    private fun slideTo(target: Int, overshoot: Boolean) {
        val box = capsule ?: return
        val params = capsuleParams ?: return
        xAnim?.cancel()
        if (params.x == target) return
        xAnim = ValueAnimator.ofInt(params.x, target).apply {
            duration = CAPSULE_ANIM_MS.toLong()
            interpolator = if (overshoot) OvershootInterpolator(1.4f) else DecelerateInterpolator(1.8f)
            addUpdateListener {
                params.x = it.animatedValue as Int
                runCatching { wm.updateViewLayout(box, params) }
            }
            start()
        }
    }

    private inner class DragListener(private val params: WindowManager.LayoutParams) : View.OnTouchListener {
        private var downX = 0f
        private var downY = 0f
        private var startX = 0
        private var startY = 0
        private var moved = false

        override fun onTouch(v: View, e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    xAnim?.cancel()
                    downX = e.rawX; downY = e.rawY
                    startX = params.x; startY = params.y
                    moved = false
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - downX
                    val dy = e.rawY - downY
                    if (moved || abs(dx) > dp(6) || abs(dy) > dp(6)) {
                        moved = true
                        params.x = (startX + dx).toInt()
                        params.y = (startY + dy).toInt()
                        runCatching { wm.updateViewLayout(v, params) }
                    }
                }
                MotionEvent.ACTION_UP -> {
                    if (moved) dockToNearestEdge() else onCapsuleTap()
                }
            }
            return true
        }
    }

    /** 松手后吸附到最近的屏幕边缘（一半藏起来） */
    private fun dockToNearestEdge() {
        val p = capsuleParams ?: return
        val w = resources.displayMetrics.widthPixels
        dockRight = p.x + dp(CAPSULE_W) / 2 >= w / 2
        p.y = p.y.coerceIn(dp(40), resources.displayMetrics.heightPixels - dp(CAPSULE_H) - dp(60))
        lastY = p.y
        refreshStyle()
    }

    /**
     * 尽量认出正在读的书 / 文章：先看窗口标题（浏览器等会用网页标题），再找 id 里带 title 的标题控件。
     * 认不出来返回 null，这时同一个 App 里的摘录合并成一篇。
     */
    private fun detectDocTitle(): String? {
        val root = rootInActiveWindow ?: return null
        val pkg = root.packageName?.toString() ?: return null
        val label = appLabel(pkg)
        fun clean(t: CharSequence?): String? {
            // 浏览器的窗口标题形如「Edge: 站点」，去掉前面的 App 名
            val s = t?.toString()?.trim()?.replace(Regex("\\s+"), " ")
                ?.removePrefix("$label: ")?.removePrefix("$label：")?.removePrefix("$label - ") ?: return null
            if (s.length < 2 || s == label || s == pkg) return null
            return s.take(60)
        }
        windows?.firstOrNull { it.isActive }?.title?.let { clean(it) }?.let { return it }

        val h = resources.displayMetrics.heightPixels
        val rect = android.graphics.Rect()
        val budget = Budget(1200, 700L)
        fun walk(n: AccessibilityNodeInfo, depth: Int): String? {
            if (depth > 30 || budget.spent()) return null
            val id = n.viewIdResourceName?.substringAfter('/')?.lowercase()
            val text = n.text?.toString()?.trim()
            if (id != null && text != null && text.length in 4..80 && n.isVisibleToUser &&
                id.contains("title") && !id.contains("sub") && !id.contains("toolbar")
            ) {
                n.getBoundsInScreen(rect)
                if (rect.top in 0 until (h * 0.6).toInt()) return clean(text)
            }
            for (i in 0 until n.childCount) {
                n.getChild(i)?.let { child -> walk(child, depth + 1)?.let { return it } }
            }
            return null
        }
        return walk(root, 0)
    }

    /** 遍历别人界面树的预算：最多看 [maxNodes] 个节点、[maxMs] 毫秒，超了就放弃（界面很大的 App 不能把我们拖死） */
    private class Budget(private val maxNodes: Int = MAX_NODES, private val maxMs: Long = MAX_MS) {
        private val start = android.os.SystemClock.uptimeMillis()
        private var nodes = 0
        fun spent(): Boolean = ++nodes > maxNodes || android.os.SystemClock.uptimeMillis() - start > maxMs
    }

    /**
     * 点胶囊：取当前选中的文字直接摘录；读不到选区时走剪贴板兜底。
     * 读界面树要跨进程等别的 App 响应（微信、小红书这类界面大的 App 很慢），全部放到后台线程；
     * 选区菜单已经在时（微信、小红书）什么都不扫，直接点缓存的「复制」→ 读剪贴板 → 开抽屉；书名 / 标题早在选中时就在后台识别好了。
     */
    private fun onCapsuleTap() {
        lastPkg?.takeIf { it in CLIPBOARD_DRIVEN }?.let { onClipboardAppTap(it); return }
        if (tapBusy) return
        tapBusy = true
        tapExec.execute {
            try {
                val menu = menuUp
                // 有选区菜单时不去扫选区：直接走「复制」
                val sel = pending ?: if (menu) null else runCatching { scanSelection() }.getOrNull()
                val draft = ExcerptDrafts.alive()
                when {
                    // 没有新的划线、但有没提交的想法：重新打开抽屉，接着写
                    sel == null && !menu && draft != null -> runCatching {
                        startActivity(
                            ExcerptSheetActivity.intent(this, draft.pkg, draft.appName, draft.docTitle, draft.quote)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION),
                        )
                    }
                    sel != null -> {
                        val title = readyTitle(titleJob, 300)
                        main.post { tapDocTitle = title; saveExcerpt(sel) }
                    }
                    else -> viaClipboard()
                }
            } finally {
                main.post { tapBusy = false }
            }
        }
    }

    /** 借剪贴板：先替用户点一下选区菜单里的「复制」（找得到才点），马上拉起读剪贴板的透明页 */
    private fun viaClipboard() {
        val pkg = lastPkg ?: runCatching { rootInActiveWindow?.packageName?.toString() }.getOrNull()
        if (pkg == null || pkg == packageName || isSensitive(pkg)) {
            toast("先选中一段文字，再点这里")
            return
        }
        val job = titleJob
        val since = System.currentTimeMillis()
        val clicked = runCatching { clickCopyFast() }.getOrDefault(false)
        // 标题先用已经识别好的；还没好的话，等它一小会儿，赶在读到文字之前填上
        tapDocTitle = readyTitle(job, 0)
        runCatching {
            startActivity(
                Intent(this, ExcerptClipActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
                    .putExtra(ExcerptClipActivity.EXTRA_PKG, pkg)
                    .putExtra(ExcerptClipActivity.EXTRA_FRESH_ONLY, !clicked)
                    .putExtra(ExcerptClipActivity.EXTRA_SINCE, if (clicked) since else 0L),
            )
        }.onFailure { toast("先选中一段文字，再点这里") }
        if (tapDocTitle == null) tapDocTitle = readyTitle(job, 500)
    }

    /** 选中后在后台识别标题（每次选中只识别一次） */
    private fun kickTitleJob() {
        if (titleJob != null) return
        titleJob = titleExec.submit<String?> { runCatching { detectDocTitle() }.getOrNull() }
    }

    /** 取识别好的标题；最多等 [waitMs] 毫秒（后台线程调用）；没有就 null */
    private fun readyTitle(job: java.util.concurrent.Future<String?>?, waitMs: Long): String? {
        job ?: return null
        return runCatching {
            if (waitMs <= 0) (if (job.isDone) job.get() else null) else job.get(waitMs, java.util.concurrent.TimeUnit.MILLISECONDS)
        }.getOrNull()
    }

    /** 在所有窗口（除了自己的悬浮窗）里找选区菜单上的「复制」按钮 */
    private fun findCopyNode(): AccessibilityNodeInfo? {
        val roots = buildList {
            windows?.forEach { w ->
                // 键盘、状态栏 / 导航栏这类系统窗口、自己的悬浮窗：不会有「复制」菜单，连根节点都不用去取
                if (w.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD || w.type == AccessibilityWindowInfo.TYPE_SYSTEM ||
                    w.type == AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY
                ) return@forEach
                w.root?.takeIf { it.packageName != packageName }?.let { add(it) }
            }
            if (isEmpty()) rootInActiveWindow?.let { add(it) }
        }
        for (root in roots) {
            for (key in COPY_LABELS) {
                for (hit in root.findAccessibilityNodeInfosByText(key)) {
                    val label = (hit.text ?: hit.contentDescription)?.toString()?.trim()
                    if ((label == "复制" || label == "Copy") && hit.isVisibleToUser) return hit
                }
            }
        }
        return null
    }

    private fun hasCopyMenu(): Boolean {
        val n = findCopyNode()
        copyNode = n
        return n != null
    }

    /** 点一下选区菜单里的「复制」：优先用缓存的按钮（只多一次刷新），没有才遍历；找不到返回 false */
    private fun clickCopyFast(): Boolean {
        var n: AccessibilityNodeInfo? = copyNode?.takeIf { menuStillUp() } ?: findCopyNode()
        while (n != null) {
            if (n.isClickable && n.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
            n = n.parent
        }
        return false
    }

    /** [ExcerptClipActivity] 读到剪贴板里的文字后回调 */
    internal fun onClipboardText(text: String?, pkg: String) {
        val t = text?.trim().orEmpty()
        if (t.isEmpty()) {
            toast("没读到刚复制的文字：请先选中文字，再点这里")
            return
        }
        saveExcerpt(Selection(t.take(2000), pkg))
    }

    /** 兜底：有的 App 不上报选区事件，点胶囊时主动在节点树里找选中的文字 */
    private fun scanSelection(): Selection? {
        val root = rootInActiveWindow ?: return null
        val pkg = root.packageName?.toString() ?: return null
        if (pkg == packageName || isSensitive(pkg)) return null
        val budget = Budget(1000, 600L)
        fun walk(n: AccessibilityNodeInfo, depth: Int): Selection? {
            if (depth > 40 || budget.spent()) return null
            val text = n.text?.toString()
            val a = n.textSelectionStart
            val b = n.textSelectionEnd
            if (text != null && !n.isPassword && a >= 0 && b >= 0 && a != b) {
                val from = minOf(a, b)
                val to = maxOf(a, b)
                if (to <= text.length && text.substring(from, to).isNotBlank()) {
                    return selectionOf(text.substring(from, to).trim(), pkg)
                }
            }
            for (i in 0 until n.childCount) {
                n.getChild(i)?.let { child -> walk(child, depth + 1)?.let { return it } }
            }
            return null
        }
        return walk(root, 0)
    }

    private fun hideAll() {
        main.removeCallbacks(clearPending)
        main.removeCallbacks(menuCheck)
        main.removeCallbacks(draftExpire)
        menuCheckQueued = false
        menuUp = false
        copyNode = null
        titleJob = null
        xAnim?.cancel()
        xAnim = null
        capsule?.let { runCatching { it.animate().cancel(); wm.removeView(it) } }
        capsule = null
        capsuleParams = null
        capsuleIcon = null
    }

    companion object {
        private const val CAPSULE_W = 30
        private const val CAPSULE_H = 46
        private const val CAPSULE_ANIM_MS = 260
        private const val MAX_NODES = 3000
        private const val MAX_MS = 1500L
        /** 中文界面只搜「复制」，其他语言再加搜「Copy」：每多搜一个词，就多跨一次进程 */
        private val COPY_LABELS = if (java.util.Locale.getDefault().language == "zh") listOf("复制") else listOf("Copy", "复制")

        /** 复制不写剪贴板、界面一直刷新的 App：走「分享」取文字，不扫界面树 */
        private val CLIPBOARD_DRIVEN = setOf("com.caing.news")

        /** 摘录抽屉是否在前台：开着时服务不去遍历窗口，免得打字时主线程被占住而卡顿 */
        @Volatile var sheetOpen = false
        private var dockRight = true
        private var lastY = -1

        /** 支付 / 银行类 App 不处理 */
        private val BLOCKED = setOf(
            "com.eg.android.AlipayGphone",
            "com.tencent.mm.plugin.wallet",
            "com.unionpay",
            "com.android.settings",
        )

        @Volatile var instance: ExcerptService? = null
            private set

        /** 系统设置里是否已打开本服务 */
        fun isEnabled(context: Context): Boolean {
            val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
            val me = ComponentName(context, ExcerptService::class.java)
            return enabled.split(':').any { ComponentName.unflattenFromString(it) == me }
        }

        /** 前往系统「无障碍」页，并提示要打开哪一项 */
        fun openAccessibilitySettings(context: Context) {
            runCatching {
                context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            Toast.makeText(context, "在列表里找到「拾忆 · 快速摘录」并打开", Toast.LENGTH_LONG).show()
        }

        /** 开始 / 结束快速摘录模式（设置、磁贴、桌面快捷方式共用）；返回切换后是否开启 */
        fun toggle(context: Context): Boolean {
            val settings = (context.applicationContext as IdeashellApp).container.settings
            val on = !settings.current.excerptMode
            settings.setExcerptMode(on)
            if (on) {
                if (isEnabled(context)) {
                    Toast.makeText(context, "摘录模式已开启", Toast.LENGTH_LONG).show()
                } else {
                    openAccessibilitySettings(context)
                }
            } else {
                Toast.makeText(context, "摘录模式已关闭", Toast.LENGTH_SHORT).show()
            }
            return on
        }
    }
}
