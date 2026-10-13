package com.carpe.ideashell.system

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.carpe.ideashell.IdeashellApp
import java.util.concurrent.TimeUnit

/** 后台定时刷新待办，并更新小部件 / 通知。系统（尤其国产系统）可能推迟或省略，所以进入应用时也会刷新。 */
class TodoRefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val container = (applicationContext as IdeashellApp).container
        // 记录时间河小部件读的是闪念贝壳，不依赖滴答；没放小部件 / 没连接时它自己什么也不做
        runCatching { container.widgets.refreshRiver() }
        if (container.credentials.didaToken.isNullOrBlank()) return Result.success()
        container.todos.refreshNow()
        // 通知栏的专注环要用：读一下今天的专注时长（失败就沿用上次的）
        runCatching { container.daySummary.focus() }
        container.surfaces.updateAll()
        container.widgets.updateFocus()
        // 顺手对账专注：到点没记的补记、没传成功的补传
        runCatching { container.focus.settle() }
        // 23:20 的今日小结如果被系统推迟了，这里补上（一天只会生成一次）
        runCatching { DaySummaryAuto.runIfDue(container) }
        return Result.success()
    }
}

object TodoRefreshScheduler {
    private const val UNIQUE_NAME = "todo-refresh"

    fun schedule(context: Context) {
        val request = PeriodicWorkRequestBuilder<TodoRefreshWorker>(30, TimeUnit.MINUTES)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(context.applicationContext)
            .enqueueUniquePeriodicWork(UNIQUE_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    fun cancel(context: Context) {
        WorkManager.getInstance(context.applicationContext).cancelUniqueWork(UNIQUE_NAME)
    }
}
