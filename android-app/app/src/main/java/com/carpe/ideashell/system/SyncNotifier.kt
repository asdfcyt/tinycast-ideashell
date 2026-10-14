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
import com.carpe.ideashell.R
import com.carpe.ideashell.ui.MainActivity

/**
 * 「有记录没能同步」的提示：一条低打扰的普通通知（无声音、可划掉），独占 [NotificationIds.SYNC_PROBLEM]。
 * 只在队列从正常变成异常时发一次（见 CaptureProcessor.refreshHealth）；点开直接进「连接与诊断」的同步队列。
 */
object SyncNotifier {
    private const val CHANNEL = "sync_problem"
    private const val NOTIFICATION_ID = NotificationIds.SYNC_PROBLEM

    fun show(context: Context, count: Int, reason: String?) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, "同步异常提示", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) },
        )
        val open = PendingIntent.getActivity(
            context, NOTIFICATION_ID,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(MainActivity.EXTRA_OPEN_CONNECTION, true)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val text = (reason?.takeIf { it.isNotBlank() }?.let { "原因：${it.take(60)}。" } ?: "") + "点开查看，可以一键重试或丢弃"
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_shiyi)
            .setContentTitle("有 $count 条记录没能同步")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(open)
            .addAction(0, "查看", open)
            .setAutoCancel(true)
            .setOngoing(false)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .build()
        runCatching { nm.notify(NOTIFICATION_ID, notification) }
    }

    fun cancel(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
    }
}
