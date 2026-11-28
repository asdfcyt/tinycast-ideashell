package com.carpe.ideashell.system

import android.app.NotificationManager
import android.content.Context
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/** 「开勿扰一小时」到点自动关掉勿扰；之后用户自己又开 / 关了，也以最新一次设置为准（重新设置会替换这个定时） */
class DndResetWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val nm = applicationContext.getSystemService(NotificationManager::class.java)
        runCatching {
            if (nm.isNotificationPolicyAccessGranted) nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_ALL)
        }
        return Result.success()
    }

    companion object {
        private const val NAME = "dnd_auto_reset"

        fun schedule(context: Context, minutes: Int) {
            val req = OneTimeWorkRequestBuilder<DndResetWorker>().setInitialDelay(minutes.toLong(), TimeUnit.MINUTES).build()
            androidx.work.WorkManager.getInstance(context).enqueueUniqueWork(NAME, ExistingWorkPolicy.REPLACE, req)
        }

        fun cancel(context: Context) {
            androidx.work.WorkManager.getInstance(context).cancelUniqueWork(NAME)
        }
    }
}
