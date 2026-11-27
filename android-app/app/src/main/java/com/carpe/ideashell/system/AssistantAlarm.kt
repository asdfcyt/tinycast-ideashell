package com.carpe.ideashell.system

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.R
import com.carpe.ideashell.data.assistant.AssistantRunner
import com.carpe.ideashell.data.assistant.TaskTime

/**
 * 助手任务的准点调度：只留一个闹钟，指向所有任务里最近的下一次；响了就交给 WorkManager 去跑（要联网问大模型），
 * 跑完再排下一个。开机 / 升级 / 改时间后由 [AssistantBootReceiver] 补排并补跑错过的（3 小时内）。
 */
object AssistantScheduler {
    private const val REQUEST = 31
    private const val WORK = "assistant_tasks_run"

    fun reschedule(context: Context) {
        val app = context.applicationContext
        val container = (app as IdeashellApp).container
        val now = System.currentTimeMillis()
        val next = container.assistantTasks.state.value
            .filter { it.enabled }
            .mapNotNull { TaskTime.next(it, now) }
            .minOrNull()
        val am = app.getSystemService(AlarmManager::class.java)
        val pi = pending(app)
        if (next == null) {
            am.cancel(pi)
            return
        }
        // 多等半秒，保证醒来时已经过了计划时刻
        val at = next + 500
        runCatching {
            if (Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            } else {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            }
        }
    }

    /** 让 WorkManager 马上把到点的任务跑一遍 */
    fun runNow(context: Context) {
        val request = OneTimeWorkRequestBuilder<AssistantTaskWorker>()
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .build()
        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(WORK, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
    }

    private fun pending(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context, REQUEST,
        Intent(context, AssistantAlarmReceiver::class.java).setAction("com.carpe.ideashell.action.ASSISTANT_TASK_ALARM"),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

class AssistantAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // 先排好下一次：就算这次跑失败，后面的任务也不会断
        AssistantScheduler.reschedule(context)
        AssistantScheduler.runNow(context)
    }
}

/** 开机 / 应用升级 / 系统改了时间或时区：重排闹钟，并补跑错过的 */
class AssistantBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        AssistantScheduler.reschedule(context)
        AssistantScheduler.runNow(context)
    }
}

class AssistantTaskWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val container = (applicationContext as IdeashellApp).container
        AssistantRunner.runDue(container)
        return Result.success()
    }

    /** Android 12 以下的加急任务要以前台服务运行：显示一条低调的「正在执行」 */
    override suspend fun getForegroundInfo(): ForegroundInfo {
        val nm = applicationContext.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(RUNNING_CHANNEL, "助手任务执行中", NotificationManager.IMPORTANCE_LOW))
        val n = NotificationCompat.Builder(applicationContext, RUNNING_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_shiyi)
            .setContentTitle("拾忆助手正在执行任务")
            .setOngoing(true)
            .build()
        return ForegroundInfo(NOTIFICATION_ID, n)
    }

    private companion object {
        const val RUNNING_CHANNEL = "assistant_running"
        const val NOTIFICATION_ID = 7310
    }
}
