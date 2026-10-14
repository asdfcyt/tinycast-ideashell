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
import kotlin.coroutines.cancellation.CancellationException

/**
 * 每周自动备份到闪念贝壳：和手动点「备份到闪念贝壳」是同一条路径（更新同一篇备份笔记），
 * 没连接闪念贝壳就静默跳过；失败只记下原因（设置页里能看到）并交给系统稍后重试，不打扰用户。
 */
class CloudBackupWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val container = (applicationContext as IdeashellApp).container
        if (!container.settings.current.autoCloudBackup) return Result.success()
        if (container.credentials.ideashellKey.isNullOrBlank()) return Result.success()
        return try {
            container.backup.pushToIdeashell()
            container.settings.setAutoBackupError(null)
            Result.success()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            container.settings.setAutoBackupError(e.message ?: "网络异常")
            Result.retry()
        }
    }
}

object CloudBackupScheduler {
    private const val UNIQUE_NAME = "cloud-backup-weekly"

    /**
     * 开启后每 7 天一次，要求有网络；KEEP：每次进应用调用都不会重置周期。
     * 刚开启时没有初始延迟，系统会很快先跑第一次。
     */
    fun apply(context: Context, enabled: Boolean) {
        val wm = WorkManager.getInstance(context.applicationContext)
        if (!enabled) {
            wm.cancelUniqueWork(UNIQUE_NAME)
            return
        }
        val request = PeriodicWorkRequestBuilder<CloudBackupWorker>(7, TimeUnit.DAYS)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        wm.enqueueUniquePeriodicWork(UNIQUE_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
    }
}
