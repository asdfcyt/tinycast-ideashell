package com.carpe.ideashell.system

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import androidx.core.content.ContextCompat
import com.carpe.ideashell.R
import com.carpe.ideashell.data.dida.DidaOverview
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.dida.TodoRepository
import com.carpe.ideashell.data.secure.CredentialStore
import com.carpe.ideashell.data.settings.SettingsStore
import com.carpe.ideashell.ui.MainActivity
import com.carpe.ideashell.ui.capture.QuickCaptureActivity
import java.time.LocalDate

/** 把待办投射到应用之外的两个地方：桌面小部件、通知栏常驻通知。数据都来自 [TodoRepository] 的本地缓存。 */
class TodoSurfaces(
    private val context: Context,
    private val todos: TodoRepository,
    private val settings: SettingsStore,
    private val credentials: CredentialStore,
) {
    private val order = compareBy<DidaTask>({ it.date ?: "" }, { it.time ?: "" }, { -it.priority })

    /** 小部件与通知都要显示的「逾期 + 今天」 */
    private class Snapshot(val overdue: List<DidaTask>, val today: List<DidaTask>) {
        val all: List<DidaTask> get() = overdue + today
        val summary: String
            get() = if (overdue.isEmpty() && today.isEmpty()) "今天没有待办" else buildString {
                append("今天 ").append(today.size)
                if (overdue.isNotEmpty()) append(" · 逾期 ").append(overdue.size)
            }
    }

    private fun snapshot(overview: DidaOverview): Snapshot {
        val todayStr = LocalDate.now().toString()
        return Snapshot(
            overdue = overview.overdue.sortedWith(order),
            today = overview.upcoming.filter { it.date == todayStr }.sortedWith(order),
        )
    }

    fun updateAll(flash: String? = null) {
        updateWidgets()
        updateNotification(flash)
    }

    // ───────────────────────── 桌面小部件 ─────────────────────────

    fun updateWidgets(onlyIds: IntArray? = null) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = onlyIds ?: manager.getAppWidgetIds(ComponentName(context, TodoWidgetProvider::class.java))
        if (ids.isEmpty()) return
        val connected = !credentials.didaToken.isNullOrBlank()
        val snap = if (connected) todos.peek()?.let { snapshot(it) } else null
        for (id in ids) {
            runCatching { manager.updateAppWidget(id, buildWidget(manager, id, connected, snap)) }
        }
    }

    private fun buildWidget(manager: AppWidgetManager, widgetId: Int, connected: Boolean, snap: Snapshot?): RemoteViews {
        val rv = RemoteViews(context.packageName, R.layout.widget_todo)
        val maxHeightDp = manager.getAppWidgetOptions(widgetId).getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 180)
        // 头部约 56dp，每行 38dp
        val maxRows = ((maxHeightDp - 56 - 28) / 38).coerceIn(1, 8)

        val openTodos = openApp(tab = 1)
        rv.setOnClickPendingIntent(R.id.widget_title, openTodos)
        rv.setOnClickPendingIntent(R.id.widget_summary, openTodos)
        rv.setOnClickPendingIntent(R.id.widget_empty, openTodos)
        rv.setOnClickPendingIntent(R.id.widget_add, quickAddTodo())

        rv.removeAllViews(R.id.widget_rows)
        when {
            !connected -> {
                rv.setTextViewText(R.id.widget_summary, "未连接滴答清单")
                showEmpty(rv, "点这里打开应用，连接滴答清单")
            }

            snap == null -> {
                rv.setTextViewText(R.id.widget_summary, "加载中…")
                showEmpty(rv, "正在同步待办…")
            }

            snap.all.isEmpty() -> {
                rv.setTextViewText(R.id.widget_summary, snap.summary)
                showEmpty(rv, "今天没有待办 🎉")
            }

            else -> {
                rv.setTextViewText(R.id.widget_summary, snap.summary)
                rv.setViewVisibility(R.id.widget_empty, View.GONE)
                rv.setViewVisibility(R.id.widget_rows, View.VISIBLE)
                val shown = snap.all.take(maxRows)
                shown.forEach { task -> rv.addView(R.id.widget_rows, buildRow(task, overdue = task in snap.overdue)) }
                val hidden = snap.all.size - shown.size
                if (hidden > 0) {
                    rv.setTextViewText(R.id.widget_summary, snap.summary + " · 还有 $hidden 项")
                }
            }
        }
        return rv
    }

    private fun showEmpty(rv: RemoteViews, text: String) {
        rv.setViewVisibility(R.id.widget_rows, View.GONE)
        rv.setViewVisibility(R.id.widget_empty, View.VISIBLE)
        rv.setTextViewText(R.id.widget_empty, text)
    }

    private fun buildRow(task: DidaTask, overdue: Boolean): RemoteViews {
        val row = RemoteViews(context.packageName, R.layout.widget_todo_row)
        row.setTextViewText(R.id.row_title, task.title)
        val time = when {
            overdue -> task.date?.let { runCatching { LocalDate.parse(it) }.getOrNull() }?.let { "${it.monthValue}月${it.dayOfMonth}日" }.orEmpty()
            else -> task.time.orEmpty()
        }
        row.setTextViewText(R.id.row_time, time)
        row.setInt(R.id.row_check, "setColorFilter", priorityColor(task.priority, overdue))
        row.setOnClickPendingIntent(R.id.row_check, completeIntent(task.id))
        row.setOnClickPendingIntent(R.id.row_title, openApp(tab = 1))
        return row
    }

    private fun priorityColor(priority: Int, overdue: Boolean): Int = when {
        priority >= 5 -> 0xFFE5484D.toInt()
        priority >= 3 -> 0xFFF5A524.toInt()
        priority >= 1 -> 0xFF3E8BFF.toInt()
        overdue -> 0xFFE5484D.toInt()
        else -> 0xFF8A9A99.toInt()
    }

    // ───────────────────────── 常驻通知 ─────────────────────────

    /** @param flash 临时显示在通知正文的一句话（例如「已记下：…」），下一次刷新恢复正常 */
    fun updateNotification(flash: String? = null) {
        val nm = context.getSystemService(NotificationManager::class.java)
        val enabled = settings.current.persistentNotification && !credentials.didaToken.isNullOrBlank()
        if (!enabled) {
            nm.cancel(NOTIFICATION_ID)
            return
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, context.getString(R.string.todo_channel_name), NotificationManager.IMPORTANCE_LOW).apply {
                setShowBadge(false)
            },
        )

        val snap = todos.peek()?.let { snapshot(it) }
        val title = snap?.summary ?: "待办"
        val first = snap?.all?.firstOrNull()
        val text = flash ?: first?.title ?: if (snap == null) "正在同步…" else "没有要做的事 🎉"

        val replyInput = RemoteInput.Builder(KEY_REPLY).setLabel("记点什么…").build()
        val replyAction = NotificationCompat.Action.Builder(
            R.drawable.ic_tile,
            "记一条",
            PendingIntent.getBroadcast(
                context, 10,
                Intent(context, TodoActionReceiver::class.java).setAction(TodoActionReceiver.ACTION_REPLY),
                // 内联回复需要系统往里填输入的文字，必须是 MUTABLE
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            ),
        ).addRemoteInput(replyInput).build()

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_tile)
            .setColor(0xFF006A6A.toInt())
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setContentIntent(openApp(tab = 1))
            .addAction(replyAction)

        if (snap != null && snap.all.isNotEmpty()) {
            val style = NotificationCompat.InboxStyle().setBigContentTitle(title)
            snap.all.take(5).forEach { t ->
                style.addLine(if (t.time != null && t in snap.today) "${t.time}  ${t.title}" else t.title)
            }
            builder.setStyle(style)
        }
        if (first != null) {
            builder.addAction(
                R.drawable.ic_tile,
                "完成：" + first.title.take(8),
                completeIntent(first.id),
            )
        }
        builder.addAction(
            R.drawable.ic_tile,
            "刷新",
            PendingIntent.getBroadcast(
                context, 11,
                Intent(context, TodoActionReceiver::class.java).setAction(TodoActionReceiver.ACTION_REFRESH),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        )

        if (NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            nm.notify(NOTIFICATION_ID, builder.build())
        }
    }

    // ───────────────────────── PendingIntent ─────────────────────────

    private fun openApp(tab: Int): PendingIntent = PendingIntent.getActivity(
        context, tab,
        Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(MainActivity.EXTRA_TAB, tab)
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun quickAddTodo(): PendingIntent = PendingIntent.getActivity(
        context, 100,
        Intent(context, QuickCaptureActivity::class.java).apply {
            action = QuickCaptureActivity.ACTION_QUICK_CAPTURE
            putExtra(QuickCaptureActivity.EXTRA_KIND, "TODO")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    /** 每个任务一个独立的 PendingIntent（靠 data 区分），避免点 A 却完成了 B */
    private fun completeIntent(taskId: String): PendingIntent = PendingIntent.getBroadcast(
        context, 0,
        Intent(context, TodoActionReceiver::class.java).apply {
            action = TodoActionReceiver.ACTION_COMPLETE
            data = Uri.parse("ideashell://task/${Uri.encode(taskId)}")
            putExtra(TodoActionReceiver.EXTRA_TASK_ID, taskId)
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    companion object {
        const val CHANNEL_ID = "todo_summary"
        const val NOTIFICATION_ID = 2001
        const val KEY_REPLY = "quick_reply"
    }
}
