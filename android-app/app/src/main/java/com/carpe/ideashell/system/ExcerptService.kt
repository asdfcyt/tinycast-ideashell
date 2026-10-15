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
    private var pending: Selection? = null
    private val clearPending = Runnable { pending = null; refreshStyle() }

    /** 屏幕上是否有选区菜单（带「复制」按钮）：App 不上报选区事件时，用它判断「有选中的文字」 */
    private var menuUp = false
    private var menuCheckQueued = false
    private val menuCheck: Runnable = object : Runnable {
      override fun run() {
        menuCheckQueued = false
        if (sheetOpen) return
        val up = hasCopyMenu()
        if (up != menuUp) {
            menuUp = up
            refreshStyle()
        }
        // 菜单在时每半秒复查一次：有的 App 菜单消失时不一定发窗口事件
        if (menuUp && capsule != null) {
            menuCheckQueued = true
            main.postDelayed(this, 500)
        }
      }
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
    private var tapDocTitle: String? = null

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
        if (pkg == packageName || isSensitive(pkg)) return
        if (event.eventType != AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED) {
            // 窗口变化：App 不上报选区时（微信、微信读书…），靠「选区菜单（复制）出现 / 消失」判断有没有选中文字
            if (capsule != null && !menuCheckQueued) {
                menuCheckQueued = true
                main.postDelayed(menuCheck, 350)
            }
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
        fun walk(n: AccessibilityNodeInfo, depth: Int): String? {
            if (depth > 30) return null
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

    /** 点胶囊：取当前选中的文字直接摘录；读不到选区时走剪贴板兜底 */
    private fun onCapsuleTap() {
        tapDocTitle = detectDocTitle()
        val sel = pending ?: scanSelection()
        // 没有新的划线、但有没提交的想法：重新打开抽屉，接着写
        val draft = ExcerptDrafts.alive()
        if (sel == null && !menuUp && draft != null) {
            runCatching {
                startActivity(
                    ExcerptSheetActivity.intent(this, draft.pkg, draft.appName, draft.docTitle, draft.quote)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION),
                )
            }
            return
        }
        if (sel == null) {
            fromClipboard()
            return
        }
        saveExcerpt(sel)
    }

    /**
     * 兜底：App 不上报选区时（微信、小红书），借剪贴板：
     * 先替用户点一下选区菜单里的「复制」（找得到才点），再读剪贴板；读不到「刚复制」的文字就提示先复制。
     */
    private fun fromClipboard() {
        val pkg = rootInActiveWindow?.packageName?.toString()
        if (pkg == null || pkg == packageName || isSensitive(pkg)) {
            toast("先选中一段文字，再点这里")
            return
        }
        val clicked = clickCopyButton()
        main.postDelayed({
            runCatching {
                startActivity(
                    Intent(this, ExcerptClipActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
                        .putExtra(ExcerptClipActivity.EXTRA_PKG, pkg)
                        .putExtra(ExcerptClipActivity.EXTRA_FRESH_ONLY, !clicked),
                )
            }.onFailure { toast("先选中一段文字，再点这里") }
        }, if (clicked) 350L else 0L)
    }

    /** 在所有窗口（除了自己的悬浮窗）里找选区菜单上的「复制」按钮 */
    private fun findCopyNode(): AccessibilityNodeInfo? {
        val roots = buildList {
            // 键盘窗口的节点树又大又不会有「复制」菜单，跳过
            windows?.forEach { w ->
                if (w.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD) return@forEach
                w.root?.takeIf { it.packageName != packageName }?.let { add(it) }
            }
            rootInActiveWindow?.let { add(it) }
        }
        for (root in roots) {
            val hits = root.findAccessibilityNodeInfosByText("复制") + root.findAccessibilityNodeInfosByText("Copy")
            for (hit in hits) {
                val label = (hit.text ?: hit.contentDescription)?.toString()?.trim()
                if ((label == "复制" || label == "Copy") && hit.isVisibleToUser) return hit
            }
        }
        return null
    }

    private fun hasCopyMenu(): Boolean = findCopyNode() != null

    /** 点一下选区菜单里的「复制」；找不到返回 false */
    private fun clickCopyButton(): Boolean {
        var n: AccessibilityNodeInfo? = findCopyNode()
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
        fun walk(n: AccessibilityNodeInfo, depth: Int): Selection? {
            if (depth > 40) return null
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
