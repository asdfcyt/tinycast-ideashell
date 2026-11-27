package com.carpe.ideashell.data.assistant

import com.carpe.ideashell.system.ExcerptService

/**
 * 「用户现在在看什么」：助手要读屏幕时才取，不会提前上传。
 * 来源有两个：① 设为默认助手后，系统呼出助手时交过来的屏幕快照（[offer]，60 秒内有效）；
 * ② 没有快照时，用无障碍服务现读当前窗口（和摘录共用同一个无障碍开关）。
 */
object ScreenContext {
    class Snapshot(val at: Long, val pkg: String, val label: String, val text: String, val selection: String? = null)

    const val MAX_CHARS = 6000
    private const val FRESH_MS = 60_000L

    @Volatile
    private var offered: Snapshot? = null

    fun offer(pkg: String, label: String, text: String) {
        offered = Snapshot(System.currentTimeMillis(), pkg, label, text.take(MAX_CHARS))
    }

    /** 读取当前屏幕；读不到（没开无障碍 / 是拾忆自己 / 敏感应用）返回 null */
    fun read(): Snapshot? {
        offered?.takeIf { System.currentTimeMillis() - it.at < FRESH_MS }?.let { return it }
        return ExcerptService.instance?.readScreen()
    }
}
