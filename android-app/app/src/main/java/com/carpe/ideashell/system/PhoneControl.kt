package com.carpe.ideashell.system

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityNodeInfo
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * 借无障碍服务替你「动手」：返回 / 回桌面 / 最近任务 / 通知栏 / 锁屏 / 截屏，以及点控制中心里的开关（WLAN、蓝牙、飞行模式……）。
 * 这些开关 Android 10 以后不允许应用直接开关，只能走系统自己的控制中心；所以这里是「下拉控制中心 → 点那个磁贴 → 收起」，
 * 效果和你手动点一样。需要打开拾忆的无障碍服务；控制中心的布局因手机而异，找不到磁贴时会如实说。
 */
object PhoneControl {
    private const val NEED_SERVICE = "要先开启拾忆的无障碍服务（设置 → 语音助手 → 系统权限 → 无障碍服务）"

    /** [action]：back / home / recents / notifications / quick_settings / lock_screen / screenshot / power_menu */
    fun globalAction(action: String): String {
        val svc = ExcerptService.instance ?: return NEED_SERVICE
        val (code, label) = when (action) {
            "back" -> AccessibilityService.GLOBAL_ACTION_BACK to "返回"
            "home" -> AccessibilityService.GLOBAL_ACTION_HOME to "回到桌面"
            "recents" -> AccessibilityService.GLOBAL_ACTION_RECENTS to "打开最近任务"
            "notifications" -> AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS to "拉下通知栏"
            "quick_settings" -> AccessibilityService.GLOBAL_ACTION_QUICK_SETTINGS to "拉下控制中心"
            "lock_screen" -> AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN to "锁屏"
            "screenshot" -> AccessibilityService.GLOBAL_ACTION_TAKE_SCREENSHOT to "截屏"
            "power_menu" -> AccessibilityService.GLOBAL_ACTION_POWER_DIALOG to "打开电源菜单"
            else -> return "action 只能是 back / home / recents / notifications / quick_settings / lock_screen / screenshot / power_menu"
        }
        return if (svc.performGlobalAction(code)) "已$label" else "系统没有执行「$label」"
    }

    /** 一次只能操作一个控制中心（助手可能并行调用好几个） */
    private val panelLock = Mutex()

    /** 点一下控制中心里名字含 [name] 的开关，再收起控制中心；返回点完之后它的状态（读得到的话） */
    suspend fun toggleQuickSetting(name: String): String = panelLock.withLock { toggleLocked(name) }

    private suspend fun toggleLocked(name: String): String {
        val svc = ExcerptService.instance ?: return NEED_SERVICE
        val n = name.trim()
        if (n.isEmpty()) return "没有说要点哪个开关"
        if (!svc.performGlobalAction(AccessibilityService.GLOBAL_ACTION_QUICK_SETTINGS)) return "没能拉下控制中心"
        var tile: AccessibilityNodeInfo? = null
        for (wait in listOf(900L, 700L, 700L)) {
            delay(wait)
            tile = findTile(svc, n)
            if (tile != null) break
        }
        val node = tile
        if (node == null) {
            svc.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)
            return "没在控制中心里找到「$n」（可能不在第一页，或者名字不一样）。可以改用 open_settings 打开对应的设置页"
        }
        val ok = node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        delay(600)
        val after = findTile(svc, n)?.let { describe(it) }.orEmpty()
        svc.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)
        return when {
            !ok -> "找到了「$n」但点不动，请手动点一下"
            after.isNotBlank() -> "已点「$n」，现在：$after"
            else -> "已点「$n」（读不到点完的状态，请看一眼是否生效）"
        }
    }

    private fun findTile(svc: AccessibilityService, name: String): AccessibilityNodeInfo? {
        val roots = buildList {
            runCatching { svc.windows.forEach { w -> w.root?.let { add(it) } } }
            svc.rootInActiveWindow?.let { add(it) }
        }
        for (root in roots) {
            if (root.packageName?.toString() == svc.packageName) continue
            val hits = runCatching { root.findAccessibilityNodeInfosByText(name) }.getOrNull().orEmpty()
            for (h in hits) {
                clickableSelfOrParent(h)?.let { return it }
            }
        }
        return null
    }

    private fun clickableSelfOrParent(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        var cur: AccessibilityNodeInfo? = node
        var depth = 0
        while (cur != null && depth < 5) {
            if (cur.isClickable) return cur
            cur = cur.parent
            depth++
        }
        return null
    }

    /** 磁贴的文字 + 描述 + 状态，如「WLAN 已开启」 */
    private fun describe(node: AccessibilityNodeInfo): String {
        val parts = mutableListOf<String>()
        node.text?.toString()?.let { parts += it }
        node.contentDescription?.toString()?.let { parts += it }
        runCatching { node.stateDescription?.toString() }.getOrNull()?.let { parts += it }
        if (parts.isEmpty()) {
            for (i in 0 until node.childCount) node.getChild(i)?.let { c ->
                c.text?.toString()?.let { parts += it }
                c.contentDescription?.toString()?.let { parts += it }
            }
        }
        if (node.isChecked) parts += "已开启"
        return parts.distinct().joinToString(" ").take(60)
    }
}
