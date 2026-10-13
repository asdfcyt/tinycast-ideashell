package com.carpe.ideashell.system

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.carpe.ideashell.AppContainer
import com.carpe.ideashell.IdeashellApp
import kotlinx.coroutines.CancellationException
import java.time.Duration
import java.time.LocalDateTime
import java.time.LocalTime
import java.util.concurrent.TimeUnit

/** 每晚 23:20 自动生成今日小结（和「回顾 → 生成今日小结」同一份内容，重复生成只会替换，不会堆叠）。 */
class DaySummaryWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val container = (applicationContext as IdeashellApp).container
        return if (DaySummaryAuto.runIfDue(container)) Result.retry() else Result.success()
    }
}

object DaySummaryAuto {
    /** 每天自动生成的时间 */
    val DUE: LocalTime = LocalTime.of(23, 20)

    /** 过了这个点还没成功就不再重试了（再晚就跨天了） */
    private val GIVE_UP: LocalTime = LocalTime.of(23, 55)

    /**
     * 到了 23:20 且今天还没自动生成过，就生成一次。
     * 后台定时任务可能被系统推迟，所以每 30 分钟的待办刷新、滴答连接时也会调用它——一天只会成功生成一次。
     * 返回 true 表示失败了、稍后值得再试。
     */
    suspend fun runIfDue(container: AppContainer): Boolean {
        if (!container.settings.current.autoDaySummary) return false
        val now = LocalDateTime.now()
        if (now.toLocalTime().isBefore(DUE)) return false
        val today = now.toLocalDate().toString()
        if (container.settings.lastAutoSummaryDate() == today) return false
        if (container.credentials.didaToken.isNullOrBlank()) return false
        return try {
            // 今天什么都没有时返回 null、不写入，也算今天处理过了
            container.daySummary.write()
            container.settings.setLastAutoSummaryDate(today)
            false
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            LocalDateTime.now().toLocalTime().isBefore(GIVE_UP)
        }
    }
}

object DaySummaryScheduler {
    private const val UNIQUE_NAME = "day-summary"

    fun schedule(context: Context) {
        val now = LocalDateTime.now()
        var next = now.toLocalDate().atTime(DaySummaryAuto.DUE)
        if (!now.isBefore(next)) next = next.plusDays(1)
        val delayMs = Duration.between(now, next).toMillis()
        val request = PeriodicWorkRequestBuilder<DaySummaryWorker>(24, TimeUnit.HOURS)
            .setInitialDelay(delayMs, TimeUnit.MILLISECONDS)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        // UPDATE：每次进入应用都按「下一个 23:20」重新对齐，不会因为系统推迟而越漂越远
        WorkManager.getInstance(context.applicationContext)
            .enqueueUniquePeriodicWork(UNIQUE_NAME, ExistingPeriodicWorkPolicy.UPDATE, request)
    }

    fun cancel(context: Context) {
        WorkManager.getInstance(context.applicationContext).cancelUniqueWork(UNIQUE_NAME)
    }
}
