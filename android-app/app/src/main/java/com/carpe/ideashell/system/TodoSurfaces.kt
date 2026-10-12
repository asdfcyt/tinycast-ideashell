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
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
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
    /** 通知上「>」当前停在哪个任务 */
    @Volatile
    private var cursorId: String? = null

    private val order = compareBy<DidaTask>({ it.date ?: "" }, { it.time ?: "" }, { -it.priority })

    /** 小部件与通知都要显示的「逾期 + 今天」 */
    private class Snapshot(val overdue: List<DidaTask>, val today: List<DidaTask>, val done: Int) {
        val all: List<DidaTask> get() = overdue + today

        /** 今天的完成度：已完成 /（已完成 + 还剩），和「今天」页的圆环同一口径 */
        val progress: Float get() = (done + all.size).let { if (it == 0) 0f else done.toFloat() / it }
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
            done = overview.done.size,
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
                showEmpty(rv, "今天没有待办")
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
        priority >= 5 -> ContextCompat.getColor(context, R.color.notification_fill)
        priority >= 3 -> 0xFFF5A524.toInt()
        priority >= 1 -> 0xFF3E8BFF.toInt()
        overdue -> ContextCompat.getColor(context, R.color.notification_fill)
        else -> 0xFF8C7566.toInt()
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
        val all = snap?.all.orEmpty()
        // 当前显示的那一项：按任务 id 记位置，任务被完成或列表变化后回到第一项
        val currentIndex = all.indexOfFirst { it.id == cursorId }.let { if (it < 0) 0 else it }
        val current = all.getOrNull(currentIndex)

        // 收起：第一行 = 任务标题，第二行 =「今天 16:00」；右侧内联 > 下一项、+ 记一条（与滴答清单一致）
        val collapsed = RemoteViews(context.packageName, R.layout.notification_todo_collapsed).apply {
            setImageViewBitmap(R.id.n_ring, ringBitmap(all.size, snap?.progress ?: 0f))
            when {
                current != null -> {
                    setTextViewText(R.id.n_title, current.title)
                    val suffix = if (all.size > 1) " · ${currentIndex + 1}/${all.size}" else ""
                    setTextViewText(R.id.n_sub, flash ?: (whenLabel(current, current in (snap?.overdue.orEmpty())) + suffix))
                }

                else -> {
                    setTextViewText(R.id.n_title, if (snap == null) "待办" else "今天没有待办")
                    setTextViewText(R.id.n_sub, flash ?: if (snap == null) "正在同步…" else "点右侧 + 记一条")
                }
            }
            setViewVisibility(R.id.n_next, if (all.size > 1) View.VISIBLE else View.GONE)
            setOnClickPendingIntent(R.id.n_next, nextIntent())
            setOnClickPendingIntent(R.id.n_add, quickAdd())
            setOnClickPendingIntent(R.id.n_info, openApp(tab = 1))
        }

        // 展开：概览 + 逐行任务，每行圆圈直接完成
        val big = RemoteViews(context.packageName, R.layout.notification_todo_big).apply {
            setImageViewBitmap(R.id.n_ring, ringBitmap(all.size, snap?.progress ?: 0f))
            setTextViewText(R.id.n_title, snap?.summary ?: "待办")
            setTextViewText(
                R.id.n_sub,
                when {
                    snap == null -> "正在同步…"
                    all.isEmpty() -> if (snap.done > 0) "已完成 ${snap.done} 件" else "今天很清爽"
                    else -> "还剩 ${all.size} 件" + if (snap.done > 0) " · 已完成 ${snap.done}" else ""
                },
            )
            setOnClickPendingIntent(R.id.n_add, quickAdd())
            removeAllViews(R.id.n_rows)
            if (all.isEmpty()) {
                setViewVisibility(R.id.n_empty, View.VISIBLE)
                setTextViewText(R.id.n_empty, flash ?: if (snap == null) "正在同步…" else "今天没有要做的事，点右上角 + 记一条")
            } else {
                setViewVisibility(R.id.n_empty, View.GONE)
                val overdue = snap?.overdue.orEmpty()
                all.take(MAX_BIG_ROWS).forEach { t ->
                    val row = RemoteViews(context.packageName, R.layout.notification_todo_row)
                    row.setTextViewText(R.id.r_title, t.title)
                    row.setTextViewText(R.id.r_time, shortWhen(t, t in overdue))
                    if (t in overdue) row.setTextColor(R.id.r_time, ContextCompat.getColor(context, R.color.notification_accent))
                    row.setInt(R.id.r_check, "setColorFilter", priorityColor(t.priority, t in overdue))
                    row.setOnClickPendingIntent(R.id.r_check, completeIntent(t.id))
                    row.setOnClickPendingIntent(R.id.r_title, openApp(tab = 1))
                    addView(R.id.n_rows, row)
                }
            }
        }

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_tile)
            .setColor(0xFFFF5A00.toInt())
            .setStyle(NotificationCompat.DecoratedCustomViewStyle())
            .setCustomContentView(collapsed)
            .setCustomBigContentView(big)
            // 无障碍 / 不支持自定义视图的场景用的纯文本兜底
            .setContentTitle(current?.title ?: snap?.summary ?: "待办")
            .setContentText(flash ?: snap?.summary)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setContentIntent(openApp(tab = 1))

        if (NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            nm.notify(NOTIFICATION_ID, builder.build())
        }
    }

    /**
     * 通知左侧的小圆环：和「今天」页的大圆环同一套画法——环弧是完成度，圆心是「还剩几件」。
     * 通知背景由系统决定，所以只按系统深浅色选字色，环弧用 notification_fill（浅色柔橙 / 深色品牌橙）。
     */
    private fun ringBitmap(remaining: Int, progress: Float): Bitmap {
        val size = (44 * context.resources.displayMetrics.density).toInt()
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val ink = ContextCompat.getColor(context, R.color.notification_ink)

        val stroke = size * 0.16f
        val rect = RectF(stroke / 2, stroke / 2, size - stroke / 2, size - stroke / 2)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = stroke
            color = (ink and 0x00FFFFFF) or 0x33000000
        }
        canvas.drawArc(rect, 0f, 360f, false, paint)
        if (progress > 0f) {
            paint.color = ContextCompat.getColor(context, R.color.notification_fill)
            canvas.drawArc(rect, -90f, 360f * progress.coerceAtMost(1f), false, paint)
        }

        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ink
            textAlign = Paint.Align.CENTER
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            textSize = size * if (remaining >= 10) 0.30f else 0.38f
        }
        canvas.drawText(remaining.toString(), size / 2f, size / 2f - (text.ascent() + text.descent()) / 2f, text)
        return bitmap
    }

    /** 通知上的「>」：切到下一项任务（循环），只刷新通知，不动数据 */
    fun showNext() {
        val snap = todos.peek()?.let { snapshot(it) } ?: return
        val all = snap.all
        if (all.isEmpty()) return
        val index = all.indexOfFirst { it.id == cursorId }
        cursorId = all[(index + 1).mod(all.size)].id
        updateNotification()
    }

    /** 「今天 16:00」「今天」「逾期 · 10月9日」 */
    private fun whenLabel(t: DidaTask, overdue: Boolean): String {
        if (overdue) return "逾期 · " + (dateLabel(t.date) ?: "")
        return if (t.time != null) "今天 ${t.time}" else "今天"
    }

    private fun shortWhen(t: DidaTask, overdue: Boolean): String =
        if (overdue) dateLabel(t.date).orEmpty() else t.time.orEmpty()

    private fun dateLabel(date: String?): String? =
        date?.let { runCatching { LocalDate.parse(it) }.getOrNull() }?.let { "${it.monthValue}月${it.dayOfMonth}日" }

    // ───────────────────────── PendingIntent ─────────────────────────

    private fun openApp(tab: Int): PendingIntent = PendingIntent.getActivity(
        context, tab,
        Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(MainActivity.EXTRA_TAB, tab)
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    /** 通知上的「＋」：打开轻量输入面板，不预设类型，由输入内容自动判断待办 / 笔记 / 日记 */
    private fun quickAdd(): PendingIntent = PendingIntent.getActivity(
        context, 101,
        Intent(context, QuickCaptureActivity::class.java).apply {
            action = QuickCaptureActivity.ACTION_QUICK_CAPTURE
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
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

    private fun nextIntent(): PendingIntent = PendingIntent.getBroadcast(
        context, 11,
        Intent(context, TodoActionReceiver::class.java).setAction(TodoActionReceiver.ACTION_NEXT),
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
        private const val MAX_BIG_ROWS = 5
    }
}
