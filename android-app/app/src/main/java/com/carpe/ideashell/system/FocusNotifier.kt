package com.carpe.ideashell.system

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.carpe.ideashell.R
import com.carpe.ideashell.data.focus.FocusRun
import com.carpe.ideashell.ui.MainActivity
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * 专注期间的系统层：一条常驻通知（系统自己倒计时，应用不在前台也在走，带「暂停 / 结束」按钮）、
 * 到点的闹钟（把进程叫醒去记录）、结束后的提醒通知。状态都来自 [FocusRun]，这里不保存任何东西。
 */
class FocusNotifier(private val context: Context) {

    /** 专注状态变了（开始 / 暂停 / 继续 / 结束 / 放弃）：同步通知与闹钟 */
    fun onSessionChanged(run: FocusRun?, hint: String? = null) {
        val nm = context.getSystemService(NotificationManager::class.java)
        if (run == null) {
            cancelAlarm()
            cancelTick()
            nm.cancel(RUNNING_ID)
            return
        }
        if (run.paused) {
            cancelAlarm()
            cancelTick()
        } else {
            scheduleAlarm(run.endAtMs)
            scheduleTick(run)
        }
        showRunning(nm, run, hint)
    }

    /**
     * 进行中每分钟醒一次：让通知栏的圆环、桌面小部件的进度弧跟着走（圆心的倒计时是系统自己在走，不靠这个）。
     * 用省电闹钟，晚几十秒无所谓；到点结束由 [scheduleAlarm] 的准点闹钟负责。
     */
    fun scheduleTick(run: FocusRun) {
        if (run.paused) return
        val now = System.currentTimeMillis()
        val intoMinute = run.elapsedMs(now) % 60_000L
        val at = (now + 60_000L - intoMinute).coerceAtMost(run.endAtMs)
        if (at <= now + 2_000L) return
        runCatching {
            context.getSystemService(AlarmManager::class.java)
                .setAndAllowWhileIdle(AlarmManager.RTC, at, action(ACTION_TICK, 24))
        }
    }

    private fun cancelTick() {
        context.getSystemService(AlarmManager::class.java).cancel(action(ACTION_TICK, 24))
    }

    /** 结束后的提醒：到点完成会响铃，提前结束只是静默记一笔 */
    fun showDone(
        title: String,
        minutes: Int,
        completed: Boolean,
        synced: Boolean,
        nextBreak: com.carpe.ideashell.data.focus.FocusKind? = null,
        nextBreakMin: Int = 0,
    ) {
        if (!canNotify()) return
        val nm = context.getSystemService(NotificationManager::class.java)
        ensureChannels(nm)
        val head = if (completed) "专注完成 · $minutes 分钟" else "已结束专注 · $minutes 分钟"
        val tail = if (synced) "已记入滴答清单" else "已保存在本机，联网后自动同步到滴答"
        val text = if (title.isBlank()) tail else "$title · $tail"
        val builder = NotificationCompat.Builder(context, if (completed) DONE_CHANNEL else QUIET_DONE_CHANNEL)
            .setSmallIcon(R.drawable.ic_tile)
            .setColor(ACCENT)
            .setContentTitle(head)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(openFocus())
            .setAutoCancel(true)
            .setCategory(if (completed) NotificationCompat.CATEGORY_ALARM else NotificationCompat.CATEGORY_STATUS)
            .setPriority(if (completed) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_LOW)
            .setOnlyAlertOnce(false)
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)
        // 番茄走完：直接在通知上开始休息（短休息；每 4 个番茄一次长休息），或者不休息
        if (nextBreak != null) {
            builder.addAction(0, "开始${nextBreak.label} $nextBreakMin 分钟", action(ACTION_START_BREAK, 35))
            builder.addAction(0, "跳过休息", action(ACTION_SKIP_BREAK, 36))
        }
        if (NotificationManagerCompat.from(context).areNotificationsEnabled()) nm.notify(DONE_ID, builder.build())
    }

    /** 点了通知上的休息按钮后，把「专注完成」那条收掉 */
    fun cancelDone() {
        context.getSystemService(NotificationManager::class.java).cancel(DONE_ID)
    }

    // ───────────────────────── 常驻通知 ─────────────────────────

    private fun showRunning(nm: NotificationManager, run: FocusRun, hint: String? = null) {
        if (!canNotify()) return
        ensureChannels(nm)
        val now = System.currentTimeMillis()
        val isBreak = run.kind.isBreak
        val label = run.kind.label
        val taskPart = if (isBreak) label else run.title.ifBlank { "自由专注" }
        val builder = NotificationCompat.Builder(context, RUNNING_CHANNEL)
            .setSmallIcon(R.drawable.ic_tile)
            .setColor(ACCENT)
            .setContentTitle(if (run.paused) "${label}已暂停" else "${label}中")
            .setContentIntent(openFocus())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addExtras(promotedExtras())
        if (run.paused) {
            val left = Math.ceil(run.remainingMs(now) / 60_000.0).toInt().coerceAtLeast(1)
            builder.setContentText(hint ?: "$taskPart · 还剩 $left 分钟")
                .setShowWhen(false)
                .addAction(0, "继续", action(ACTION_RESUME, 22))
        } else {
            // 系统自己倒计时到 endAt，不用每秒更新通知
            builder.setContentText(hint ?: "$taskPart · ${run.plannedMin} 分钟 · ${clock(run.endAtMs)} 结束")
                .setUsesChronometer(true)
                .setChronometerCountDown(true)
                .setShowWhen(true)
                .setWhen(run.endAtMs)
                .addAction(0, "暂停", action(ACTION_PAUSE, 21))
        }
        // 「记录」：弹出输入面板写一句话，追加到当前任务的任务笔记（并同步成滴答评论）；休息和没绑任务的自由专注没有这个按钮
        if (!isBreak && !run.taskId.isNullOrBlank()) builder.addAction(recordAction())
        builder.addAction(0, if (isBreak) "跳过" else "结束", action(ACTION_FINISH, 23))
        if (NotificationManagerCompat.from(context).areNotificationsEnabled()) nm.notify(RUNNING_ID, builder.build())
    }

    /** 「记录」：普通按钮，点开一个小输入面板（见 FocusRecordActivity）。有明确的文字，不依赖系统怎么渲染「回复」图标 */
    private fun recordAction(): NotificationCompat.Action {
        val pi = PendingIntent.getActivity(
            context, 26,
            Intent(context, com.carpe.ideashell.ui.focus.FocusRecordActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Action.Builder(0, "记录", pi).build()
    }

    /** 休息走完的提醒 */
    fun showBreakDone(kind: com.carpe.ideashell.data.focus.FocusKind, minutes: Int) {
        if (!canNotify()) return
        val nm = context.getSystemService(NotificationManager::class.java)
        ensureChannels(nm)
        val builder = NotificationCompat.Builder(context, DONE_CHANNEL)
            .setSmallIcon(R.drawable.ic_tile)
            .setColor(ACCENT)
            .setContentTitle("${kind.label}结束 · $minutes 分钟")
            .setContentText("休息好了，开始下一次专注吧")
            .setContentIntent(openFocus())
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)
        if (NotificationManagerCompat.from(context).areNotificationsEnabled()) nm.notify(DONE_ID, builder.build())
    }

    /** 记录失败后的提示（独立一条，不影响常驻通知）；把原文带上，免得白写 */
    fun showRecordResult(title: String, text: String) {
        if (!canNotify()) return
        val nm = context.getSystemService(NotificationManager::class.java)
        ensureChannels(nm)
        val builder = NotificationCompat.Builder(context, QUIET_DONE_CHANNEL)
            .setSmallIcon(R.drawable.ic_tile)
            .setColor(ACCENT)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
        if (NotificationManagerCompat.from(context).areNotificationsEnabled()) nm.notify(RECORD_ID, builder.build())
    }

    /**
     * 申请「实时通知」：Android 16 的状态栏胶囊（以及按它实现的厂商胶囊）会优先挑选「进行中 + 带计时」的通知。
     * 这只是申请：荣耀灵动胶囊目前没有开放给第三方的接入方式，是否展示由系统决定，不展示时就是一条普通的常驻通知。
     */
    private fun promotedExtras(): Bundle = Bundle().apply {
        // 不设 shortCriticalText：胶囊里直接显示系统倒计时（Chronometer），不会变成过期的静态文字
        putBoolean("android.requestPromotedOngoing", true)
    }

    private fun clock(ms: Long): String =
        DateTimeFormatter.ofPattern("HH:mm").format(Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()))

    private fun canNotify(): Boolean = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun ensureChannels(nm: NotificationManager) {
        nm.createNotificationChannel(
            NotificationChannel(RUNNING_CHANNEL, "专注计时", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) },
        )
        nm.createNotificationChannel(
            NotificationChannel(DONE_CHANNEL, "专注完成提醒", NotificationManager.IMPORTANCE_HIGH).apply {
                setShowBadge(false)
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 300, 150, 300)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(QUIET_DONE_CHANNEL, "专注记录", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) },
        )
    }

    // ───────────────────────── 闹钟 ─────────────────────────

    private fun scheduleAlarm(endAtMs: Long) {
        val am = context.getSystemService(AlarmManager::class.java)
        val pi = action(ACTION_ALARM, 20)
        // 多等半秒，保证醒来时倒计时一定已经归零
        val at = endAtMs + 500
        runCatching {
            if (Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            } else {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            }
        }
    }

    private fun cancelAlarm() {
        context.getSystemService(AlarmManager::class.java).cancel(action(ACTION_ALARM, 20))
    }

    // ───────────────────────── PendingIntent ─────────────────────────

    private fun action(action: String, code: Int): PendingIntent = PendingIntent.getBroadcast(
        context, code,
        Intent(context, FocusActionReceiver::class.java).setAction(action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun openFocus(): PendingIntent = PendingIntent.getActivity(
        context, 25,
        Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(MainActivity.EXTRA_OPEN_FOCUS, true)
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    companion object {
        const val ACTION_ALARM = "com.carpe.ideashell.action.FOCUS_ALARM"
        const val ACTION_PAUSE = "com.carpe.ideashell.action.FOCUS_PAUSE"
        const val ACTION_RESUME = "com.carpe.ideashell.action.FOCUS_RESUME"
        const val ACTION_FINISH = "com.carpe.ideashell.action.FOCUS_FINISH"
        const val ACTION_START = "com.carpe.ideashell.action.FOCUS_START"
        const val ACTION_TICK = "com.carpe.ideashell.action.FOCUS_TICK"
        const val ACTION_SKIP_BREAK = "com.carpe.ideashell.action.FOCUS_SKIP_BREAK"
        const val ACTION_START_BREAK = "com.carpe.ideashell.action.FOCUS_START_BREAK"

        private const val RUNNING_CHANNEL = "focus_running"
        private const val DONE_CHANNEL = "focus_done"
        private const val QUIET_DONE_CHANNEL = "focus_record"
        private const val RUNNING_ID = 2002
        private const val DONE_ID = 2003
        private const val RECORD_ID = 2004
        private const val ACCENT = 0xFFE0703F.toInt()
    }
}
