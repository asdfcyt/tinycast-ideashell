package com.carpe.ideashell.system

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.graphics.Rect
import android.os.SystemClock
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * 「问 AI 自动发送」：闪念贝壳的 AI 对话页只能把问题预填进输入框，没有自动发送的入口，
 * 所以由这个无障碍服务在转交问题后帮忙点一下右下角的发送键。
 *
 * 只在两种条件同时满足时动作：
 * 1. 刚由 [IdeashellBridge.askAi] 转交过一个问题（[arm] 之后 [WINDOW_MS] 内、只点一次）；
 * 2. 前台窗口是闪念贝壳（无障碍配置里只订阅了它的两个包名）。
 * 除此之外不读取、不操作任何内容。
 */
class AiAutoSendService : AccessibilityService() {

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val query = pendingQuery ?: return
        if (SystemClock.elapsedRealtime() - armedAt > WINDOW_MS) {
            disarm()
            return
        }
        val root = rootInActiveWindow ?: return
        if (root.packageName?.toString() !in IDEASHELL_PACKAGES) return
        if (trySend(root, query)) disarm()
    }

    override fun onInterrupt() = Unit

    private fun trySend(root: AccessibilityNodeInfo, query: String): Boolean {
        val edit = findEditText(root) ?: return false
        val typed = edit.text?.toString().orEmpty()
        // 输入框里要已经是我们预填的问题，避免点到别的页面或空输入
        if (typed.isBlank() || !typed.trim().startsWith(query.take(20))) return false
        val box = Rect().also(edit::getBoundsInScreen)
        // 输入框这一块里可点击的控件：左边「+」「专家」，右边麦克风、发送；发送键是最右边的一个
        val send = ArrayList<Pair<AccessibilityNodeInfo, Rect>>().also { collectClickable(root, box, it) }
            .maxByOrNull { it.second.right }
            ?.first ?: return false
        return send.performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }

    private fun findEditText(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (node.className?.toString() == "android.widget.EditText") return node
        for (i in 0 until node.childCount) {
            val found = node.getChild(i)?.let(::findEditText)
            if (found != null) return found
        }
        return null
    }

    private fun collectClickable(node: AccessibilityNodeInfo, box: Rect, out: MutableList<Pair<AccessibilityNodeInfo, Rect>>) {
        if (node.isClickable && node.className?.toString() != "android.widget.EditText") {
            val r = Rect().also(node::getBoundsInScreen)
            if (!r.isEmpty && box.contains(r)) out += node to r
        }
        for (i in 0 until node.childCount) node.getChild(i)?.let { collectClickable(it, box, out) }
    }

    companion object {
        private val IDEASHELL_PACKAGES = setOf("com.roundreddot.ideashell", "com.rrd.ideaShell")
        private const val WINDOW_MS = 8_000L

        @Volatile private var pendingQuery: String? = null
        @Volatile private var armedAt = 0L

        /** 转交问题时调用：接下来 8 秒内，闪念贝壳输入框里出现这段文字就点发送 */
        fun arm(query: String) {
            pendingQuery = query.trim().takeIf { it.isNotEmpty() }
            armedAt = SystemClock.elapsedRealtime()
        }

        fun disarm() {
            pendingQuery = null
        }

        /** 系统设置里是否已打开本服务 */
        fun isEnabled(context: Context): Boolean {
            val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
            val me = ComponentName(context, AiAutoSendService::class.java)
            return enabled.split(':').any { ComponentName.unflattenFromString(it) == me }
        }
    }
}
