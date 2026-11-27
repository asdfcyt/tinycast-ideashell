package com.carpe.ideashell.data.assistant

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import com.carpe.ideashell.AppContainer
import com.carpe.ideashell.R
import com.carpe.ideashell.data.voice.VoiceAgent
import com.carpe.ideashell.system.AssistantScheduler
import kotlinx.coroutines.CancellationException
import java.time.LocalDate

/** 执行助手任务：交给助手办，结果推通知；条件不满足不打扰，失败也告诉你一声 */
object AssistantRunner {
    private const val CHANNEL = "assistant_tasks"
    const val SKIP = "[SKIP]"

    /** 把所有「到点了还没执行」的任务跑一遍（闹钟 / 开机补跑 / 应用打开时都走这里） */
    suspend fun runDue(container: AppContainer) {
        val now = System.currentTimeMillis()
        for (task in container.assistantTasks.state.value) {
            if (!task.enabled) continue
            val due = TaskTime.lastDue(task, now) ?: continue
            run(container, task, due, manual = false)
        }
        AssistantScheduler.reschedule(container.appContext)
    }

    /**
     * 执行一次。[manual]（设置里点「立即执行」）不占用计划时刻，也不受「一天只提醒一次」限制，但同样会推通知。
     * [scheduledAt] 是这次对应的计划时刻。
     */
    suspend fun run(container: AppContainer, task: AssistantTask, scheduledAt: Long, manual: Boolean): TaskRun {
        val tasks = container.assistantTasks
        val today = LocalDate.now().toString()
        // 先占住这次的计划时刻，免得跑得慢时被下一个触发重复执行
        if (!manual) {
            tasks.update(task.id) { it.copy(lastRunAt = scheduledAt, enabled = if (it.onceDate != null) false else it.enabled) }
        }
        val record: TaskRun = when {
            !manual && task.condition != null && task.lastNotifyDay == today ->
                TaskRun(System.currentTimeMillis(), "skipped", "今天已经提醒过了")
            else -> try {
                val text = VoiceAgent.answer(container, buildPrompt(task), scheduled = true).text
                if (text.contains(SKIP)) {
                    TaskRun(System.currentTimeMillis(), "skipped", "条件不满足，没有打扰你")
                } else {
                    notify(container, task, text)
                    if (!manual && task.condition != null) tasks.update(task.id) { it.copy(lastNotifyDay = today) }
                    TaskRun(System.currentTimeMillis(), "ok", text.take(200))
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val msg = e.message ?: e.javaClass.simpleName
                notify(container, task, "没能按时执行：$msg", failed = true)
                TaskRun(System.currentTimeMillis(), "failed", msg.take(200))
            }
        }
        tasks.addRun(task.id, record)
        return record
    }

    private fun buildPrompt(task: AssistantTask): String = buildString {
        append("【定时任务「${task.title}」，系统在 ${task.timeText} 自动运行，用户没有在看手机；你的回答会原样作为一条通知推给他，所以不要提问、不要寒暄，直接给内容。】\n")
        append("任务：${task.prompt}")
        if (!task.condition.isNullOrBlank()) {
            append("\n触发条件：${task.condition}")
            append("\n先用工具查清楚条件是否满足。不满足时只回复 $SKIP 这五个字符，不要说别的；满足时直接给出要通知的内容。")
        }
    }

    private fun notify(container: AppContainer, task: AssistantTask, text: String, failed: Boolean = false) {
        val context = container.appContext
        if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "助手任务", NotificationManager.IMPORTANCE_HIGH))
        val open = PendingIntent.getActivity(
            context, task.id.hashCode(),
            Intent(context, com.carpe.ideashell.ui.MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        nm.notify(
            task.id.hashCode(),
            NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_shiyi)
                .setContentTitle(if (failed) "助手任务「${task.title}」" else task.title)
                .setContentText(text.lineSequence().firstOrNull().orEmpty())
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setContentIntent(open)
                .setAutoCancel(true)
                .build(),
        )
    }
}
