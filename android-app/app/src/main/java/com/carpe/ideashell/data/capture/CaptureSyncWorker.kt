package com.carpe.ideashell.data.capture

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.CoroutineWorker
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.carpe.ideashell.IdeashellApp
import java.util.concurrent.TimeUnit

/** 后台同步离线队列：有网络时执行；队列里还有没发出去的就让 WorkManager 稍后重试。 */
class CaptureSyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val container = (applicationContext as IdeashellApp).container
        val hasRemaining = container.processor.drain()
        return if (hasRemaining) Result.retry() else Result.success()
    }
}

/** 安排后台同步。进程还活着时另有一条进程内的快速路径（见 CaptureRepository），这里是兜底。 */
class CaptureScheduler(context: Context) {
    private val workManager = WorkManager.getInstance(context.applicationContext)

    fun schedule(delayMs: Long) {
        val request = OneTimeWorkRequestBuilder<CaptureSyncWorker>()
            .setInitialDelay(delayMs, TimeUnit.MILLISECONDS)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.LINEAR, 20, TimeUnit.SECONDS)
            .build()
        // REPLACE：以最新一条的时间为准；正在发送的那一条在 NonCancellable 里会被发完，不会重复
        workManager.enqueueUniqueWork(UNIQUE_NAME, ExistingWorkPolicy.REPLACE, request)
    }

    private companion object {
        const val UNIQUE_NAME = "capture-sync"
    }
}
