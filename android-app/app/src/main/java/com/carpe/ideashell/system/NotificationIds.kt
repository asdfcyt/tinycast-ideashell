package com.carpe.ideashell.system

/**
 * 应用里所有通知的 id 都在这里登记。同一个 id 的通知会互相顶替（甚至被对方 `cancel`），
 * 所以每种通知必须独占一个 id：新增通知先在这里加一行，不要在别处另起数字。
 */
object NotificationIds {
    /** 待办常驻通知（今天的任务、可直接完成） */
    const val TODO_SUMMARY = 2002

    /** 专注结束 / 休息结束的提醒 */
    const val FOCUS_DONE = 2003

    /** 专注中「记录」失败的提示 */
    const val FOCUS_RECORD = 2004

    /** 专注进行中的实时通知（带系统倒计时，申请 Android 16 的实时更新 / 状态栏胶囊） */
    const val FOCUS_RUNNING = 2020

    /** 间隔重温到期提醒 */
    const val REVISIT_DUE = 2010
}
