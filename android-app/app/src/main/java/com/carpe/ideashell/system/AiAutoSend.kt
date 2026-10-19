package com.carpe.ideashell.system

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.graphics.Rect
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * 「问 AI 自动发送」：闪念贝壳的 AI 对话页只能把问题预填进输入框，没有自动发送的入口，
 * 所以由这个无障碍服务在转交问题后帮忙点一下右下角的发送键。
 *
 * 只在两种条件同时满足时动作：
 * 1. 刚由 [IdeashellBridge.askAi] 转交过一个问题（[arm] 之后 [WINDOW_MS] 内，没发出去最多重点 [MAX_CLICKS] 次）；
 * 2. 前台窗口是闪念贝壳（无障碍配置里只订阅了它的两个包名）。
 * 除此之外不读取、不操作任何内容。
 *
 * 现在不再是单独的无障碍服务：并进统一的 [ExcerptService]（设置里只有一个无障碍开关），由它在收到事件时调用 [onEvent]。
 */
object AiAutoSend {

    /** 统一无障碍服务收到事件时调用 */
    fun onEvent(service: AccessibilityService) {
        if (pendingQuery == null) return
        host = java.lang.ref.WeakReference(service)
        step(service)
        schedulePoll()
    }

    /** 事件之间页面还在动画 / 重组时不一定再有事件，所以武装期间每 400ms 自己再看一次 */
    private fun schedulePoll() {
        if (polling || pendingQuery == null) return
        polling = true
        handler.postDelayed({
            polling = false
            val service = host?.get()
            if (service != null && pendingQuery != null) {
                step(service)
                schedulePoll()
            }
        }, 400)
    }

    private fun step(service: AccessibilityService) {
        val query = pendingQuery ?: return
        if (SystemClock.elapsedRealtime() - armedAt > WINDOW_MS) {
            disarm()
            return
        }
        val root = service.rootInActiveWindow ?: return
        if (root.packageName?.toString() !in IDEASHELL_PACKAGES) return
        val edit = findEditText(root)
        val typed = edit?.text?.toString().orEmpty()
        val filled = edit != null && typed.isNotBlank() && typed.trim().startsWith(query.take(20))
        if (clicks > 0 && !filled) {
            // 点过发送键，输入框已经清空 / 变了：发出去了
            disarm()
            return
        }
        if (!filled) return
        // 点过一次但输入框里还是这段话：没点中（或页面当时还在动），过一会儿再点，最多 3 次
        val now = SystemClock.elapsedRealtime()
        if (clicks > 0 && now - lastClickAt < 1_500) return
        if (clicks >= MAX_CLICKS) {
            disarm()
            return
        }
        val send = findSendButton(root, edit!!) ?: return
        if (send.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
            clicks++
            lastClickAt = now
        }
    }

    /**
     * 输入框所在的卡片里，只有图标、没有文字的可点控件从左到右是：「+」、麦克风、发送键
     * （「专家」这类模型选择按钮带文字，不算）。必须凑齐这三个、且最右边的一个是可用状态才点：
     * 发送键还没亮起来（输入框的内容还没被页面认领）时，最右边是麦克风，宁可等一会儿也不能点错。
     */
    private fun findSendButton(root: AccessibilityNodeInfo, edit: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        val editBox = Rect().also(edit::getBoundsInScreen)
        val rootBox = Rect().also(root::getBoundsInScreen)
        val icons = ArrayList<Pair<AccessibilityNodeInfo, Rect>>()
        collectIconButtons(root, icons)
        // 和输入框同一块区域：竖直上在输入框中线以下（排除顶部的关闭 / 历史按钮），水平上在页面里
        val inCard = icons.filter { (_, r) ->
            r.centerY() >= editBox.centerY() && r.centerX() in rootBox.left..rootBox.right
        }.sortedBy { it.second.right }
        if (inCard.size < 3) return null
        val (send, sendBox) = inCard.last()
        val mic = inCard[inCard.size - 2].second
        // 发送键要在麦克风右边、挨着，并且靠近输入框右缘
        if (sendBox.left < mic.right - 4 || sendBox.right < editBox.right - editBox.width() * 0.2f) return null
        return send.takeIf { it.isEnabled }
    }

    private fun hasText(node: AccessibilityNodeInfo): Boolean {
        if (!node.text.isNullOrBlank()) return true
        for (i in 0 until node.childCount) if (node.getChild(i)?.let(::hasText) == true) return true
        return false
    }

    private fun collectIconButtons(node: AccessibilityNodeInfo, out: MutableList<Pair<AccessibilityNodeInfo, Rect>>) {
        if (node.isClickable && node.className?.toString() != "android.widget.EditText" && !hasText(node)) {
            val r = Rect().also(node::getBoundsInScreen)
            if (!r.isEmpty) {
                out += node to r
                return
            }
        }
        for (i in 0 until node.childCount) node.getChild(i)?.let { collectIconButtons(it, out) }
    }

    private fun findEditText(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (node.className?.toString() == "android.widget.EditText") return node
        for (i in 0 until node.childCount) {
            val found = node.getChild(i)?.let(::findEditText)
            if (found != null) return found
        }
        return null
    }

    private val IDEASHELL_PACKAGES = setOf("com.roundreddot.ideashell", "com.rrd.ideaShell")
    private const val WINDOW_MS = 8_000L

    private const val MAX_CLICKS = 3
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private var host: java.lang.ref.WeakReference<AccessibilityService>? = null
    private var polling = false
    private var clicks = 0
    private var lastClickAt = 0L

    @Volatile private var pendingQuery: String? = null
    @Volatile private var armedAt = 0L

    /** 转交问题时调用：接下来 8 秒内，闪念贝壳输入框里出现这段文字就点发送 */
    fun arm(query: String) {
        pendingQuery = query.trim().takeIf { it.isNotEmpty() }
        armedAt = SystemClock.elapsedRealtime()
        clicks = 0
        lastClickAt = 0L
    }

    fun disarm() {
        pendingQuery = null
    }

    /** 统一无障碍服务（[ExcerptService]）是否已打开 */
    fun isEnabled(context: Context): Boolean = ExcerptService.isEnabled(context)
}
