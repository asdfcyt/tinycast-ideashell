package com.carpe.ideashell.system

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput
import com.carpe.ideashell.IdeashellApp
import kotlinx.coroutines.CancellationException
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
            // 通知里的「记录」：内容追加到当前任务的任务笔记，并同步成滴答评论
            FocusNotifier.ACTION_RECORD -> {
                val text = RemoteInput.getResultsFromIntent(intent)
                    ?.getCharSequence(FocusNotifier.KEY_RECORD_TEXT)?.toString()?.trim().orEmpty()
                val run = container.focus.session.value
                val taskId = run?.taskId
                if (text.isEmpty() || taskId.isNullOrBlank()) {
                    container.focus.refreshNotification(null)
                    return
                }
                val pending = goAsync()
                container.appScope.launch {
                    try {
                        val synced = container.projects.recordForTask(taskId, text)
                        val brief = text.take(24) + (if (text.length > 24) "…" else "")
                        container.focus.refreshNotification("已记录：" + brief + (if (synced) "" else "（滴答评论未同步）"))
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        container.focus.refreshNotification(null)
                        container.focus.notifier.showRecordResult("记录失败", "${e.message ?: "未知错误"}\n\n你写的内容：$text")
                    } finally {
                        pending.finish()
                    }
                }
            }
            FocusNotifier.ACTION_START_BREAK -> {
                val k = com.carpe.ideashell.data.focus.FocusKind.SHORT_BREAK
                container.focus.start(null, null, "", container.focus.lastMinutes(k), k)
            }
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
