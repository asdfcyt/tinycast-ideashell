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
        if (container.credentials.didaToken.isNullOrBlank()) return Result.success()
        container.todos.refreshNow()
        container.surfaces.updateAll()
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
