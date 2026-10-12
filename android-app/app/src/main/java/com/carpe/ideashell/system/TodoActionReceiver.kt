package com.carpe.ideashell.system

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import com.carpe.ideashell.IdeashellApp
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** 小部件与通知上的按钮：完成任务、通知栏「下一项」、手动刷新 */
class TodoActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val container = (context.applicationContext as IdeashellApp).container
        val appContext = context.applicationContext

        when (intent.action) {
            ACTION_COMPLETE -> {
                val id = intent.getStringExtra(EXTRA_TASK_ID) ?: return
                val task = container.todos.peek()?.findOpen(id)
                val pending = goAsync()
                container.appScope.launch {
                    try {
                        if (task != null) {
                            // 网络请求放在独立任务里：即使等待超时，请求也会继续跑完
                            val job = launch {
                                container.todos.complete(task).onFailure {
                                    toast(appContext, "完成失败：${it.message ?: "网络异常"}")
                                }
                            }
                            withTimeoutOrNull(8_000L) { job.join() }
                        }
                        container.surfaces.updateAll()
                    } finally {
                        pending.finish()
                    }
                }
            }

            ACTION_NEXT -> container.surfaces.showNext()

            ACTION_REFRESH -> {
                val pending = goAsync()
                container.appScope.launch {
                    try {
                        container.todos.refreshNow()
                        container.surfaces.updateAll()
                    } finally {
                        pending.finish()
                    }
                }
            }
        }
    }

    private fun toast(context: Context, text: String) {
        Handler(Looper.getMainLooper()).post { Toast.makeText(context, text, Toast.LENGTH_SHORT).show() }
    }

    companion object {
        const val ACTION_COMPLETE = "com.carpe.ideashell.action.COMPLETE_TODO"
        const val ACTION_NEXT = "com.carpe.ideashell.action.NEXT_TODO"
        const val ACTION_REFRESH = "com.carpe.ideashell.action.REFRESH_TODOS"
        const val EXTRA_TASK_ID = "task_id"
    }
}
