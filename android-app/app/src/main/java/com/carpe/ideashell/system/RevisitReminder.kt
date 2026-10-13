package com.carpe.ideashell.system

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.R
import com.carpe.ideashell.data.revisit.RevisitRepository
import com.carpe.ideashell.ui.MainActivity
import java.time.DayOfWeek
import java.time.Duration
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.concurrent.TimeUnit

/**
 * 每天固定时间一条通知「今天有 N 条待重温」。只给数量，不暴露正文；点开直接进重温页。
 * 到点才读库统计（和「今天」页同一口径：已按每日上限截断）；系统可能推迟或省略，所以「今天」页顶部的卡片是兜底。
 */
class RevisitReminderWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val container = (applicationContext as IdeashellApp).container
        val settings = container.settings.current
        if (!settings.revisitReminder) return Result.success()

        // 顺手把带 #重温 标签的新笔记收进来（读不到就算了，下次再说）
        if (!container.credentials.ideashellKey.isNullOrBlank()) {
            runCatching { container.revisit.autoAddTagged(container.notes.search("#${RevisitRepository.TAG}")) }
        }

        val today = LocalDate.now()
        if (settings.revisitSkipWeekends && (today.dayOfWeek == DayOfWeek.SATURDAY || today.dayOfWeek == DayOfWeek.SUNDAY)) {
            return Result.success()
        }
        val count = container.revisit.remainingToday()
        if (count > 0) RevisitNotifier.show(applicationContext, count)
        return Result.success()
    }
}

/**
 * 到期提醒是一条独立的、可以划掉的普通通知：独占 [NotificationIds.REVISIT_DUE] 和自己的渠道，
 * 不是常驻通知（不 ongoing），不和待办常驻通知 / 专注实时通知共用 id；当天过完就自己消失。
 */
object RevisitNotifier {
    private const val CHANNEL = "revisit_reminder"
    private const val NOTIFICATION_ID = NotificationIds.REVISIT_DUE

    fun show(context: Context, count: Int) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, "笔记重温提醒", NotificationManager.IMPORTANCE_DEFAULT).apply { setShowBadge(false) },
        )
        val open = PendingIntent.getActivity(
            context, NOTIFICATION_ID,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(MainActivity.EXTRA_OPEN_REVISIT, true)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val endOfDay = LocalDate.now().plusDays(1).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_shiyi)
            .setContentTitle("今天有 $count 条待重温")
            .setContentText("点开开始，每条只要几秒钟")
            .setContentIntent(open)
            .addAction(0, "开始重温", open)
            .setAutoCancel(true)
            .setOngoing(false)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setTimeoutAfter((endOfDay - System.currentTimeMillis()).coerceAtLeast(60_000L))
            .build()
        runCatching { nm.notify(NOTIFICATION_ID, notification) }
    }

    fun cancel(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
    }
}

object RevisitReminderScheduler {
    private const val UNIQUE_NAME = "revisit-reminder"

    /** 按设置安排 / 取消每天的提醒；每次进入应用、改设置都会按「下一个提醒时刻」重新对齐 */
    fun apply(context: Context, enabled: Boolean, minutesOfDay: Int) {
        val wm = WorkManager.getInstance(context.applicationContext)
        if (!enabled) {
            wm.cancelUniqueWork(UNIQUE_NAME)
            return
        }
        val now = LocalDateTime.now()
        var next = now.toLocalDate().atTime(minutesOfDay / 60, minutesOfDay % 60)
        if (!now.isBefore(next)) next = next.plusDays(1)
        val request = PeriodicWorkRequestBuilder<RevisitReminderWorker>(24, TimeUnit.HOURS)
            .setInitialDelay(Duration.between(now, next).toMillis(), TimeUnit.MILLISECONDS)
            .build()
        wm.enqueueUniquePeriodicWork(UNIQUE_NAME, ExistingPeriodicWorkPolicy.UPDATE, request)
    }
}
