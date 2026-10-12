package com.carpe.ideashell.system

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.carpe.ideashell.IdeashellApp
import kotlinx.coroutines.launch

/** 专注通知上的按钮（暂停 / 继续 / 结束）与到点的闹钟；状态与记录都交给 [com.carpe.ideashell.data.focus.FocusRepository] */
class FocusActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val container = (context.applicationContext as IdeashellApp).container
        when (intent.action) {
            FocusNotifier.ACTION_PAUSE -> container.focus.pause()
            FocusNotifier.ACTION_RESUME -> container.focus.resume()
            // 桌面小部件上的「开始 N 分钟」：用上次的时长，不绑定任务
            FocusNotifier.ACTION_START -> container.focus.start(null, null, "", container.focus.lastMinutes)
            FocusNotifier.ACTION_TICK -> {
                container.focus.tick()
                container.surfaces.updateAll()
                container.widgets.updateFocus()
            }
            FocusNotifier.ACTION_FINISH, FocusNotifier.ACTION_ALARM -> {
                val pending = goAsync()
                val finishNow = intent.action == FocusNotifier.ACTION_FINISH
                container.appScope.launch {
                    try {
                        if (finishNow) container.focus.finish() else container.focus.settle()
                    } finally {
                        pending.finish()
                    }
                }
            }
        }
    }
}
