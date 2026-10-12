package com.carpe.ideashell.system

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import androidx.core.content.ContextCompat
import com.carpe.ideashell.R
import com.carpe.ideashell.core.parse.TimeRanges
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.focus.FocusRepository
import com.carpe.ideashell.data.notes.NotesRepository
import com.carpe.ideashell.data.secure.CredentialStore
import com.carpe.ideashell.data.settings.SettingsStore
import com.carpe.ideashell.domain.TimelineData
import com.carpe.ideashell.ui.MainActivity
import com.carpe.ideashell.ui.capture.QuickCaptureActivity
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale

/** 记录时间河小部件里的一行：[kind] 0 笔记 / 1 日记 / 2 完成的待办 */
@Serializable
data class RiverItem(val kind: Int, val epochDay: Long, val clock: String, val text: String)

@Serializable
private data class RiverCache(val items: List<RiverItem>, val updatedAt: Long)

/**
 * 另外两个桌面小部件：
 * - 专注：环 + 一键开始 / 暂停 / 结束，专注中圆心是系统倒计时（不需要每秒刷新）；
 * - 记录时间河：最近几天的笔记、日记、完成的待办排成一条线。时间河要联网读，所以读到后存一份本地缓存，小部件只读缓存。
 */
class ExtraWidgets(
    private val context: Context,
    private val focus: FocusRepository,
    private val notes: NotesRepository,
    private val settings: SettingsStore,
    private val credentials: CredentialStore,
    private val todayFocusMin: () -> Int?,
    private val cacheFile: File,
) {
    private val json = Json { ignoreUnknownKeys = true }

    @Volatile
    private var cache: RiverCache? = null

    fun updateAll() {
        updateFocus()
        updateRiver()
    }

    // ───────────────────────── 专注小部件 ─────────────────────────

    fun updateFocus(onlyIds: IntArray? = null) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = onlyIds ?: manager.getAppWidgetIds(ComponentName(context, FocusWidgetProvider::class.java))
        if (ids.isEmpty()) return
        for (id in ids) runCatching { manager.updateAppWidget(id, buildFocus()) }
    }

    private fun buildFocus(): RemoteViews {
        val rv = RemoteViews(context.packageName, R.layout.widget_focus)
        val run = focus.session.value
        val now = System.currentTimeMillis()
        val open = openFocus()
        rv.setOnClickPendingIntent(R.id.f_ring_box, open)
        rv.setOnClickPendingIntent(R.id.f_title, open)
        rv.setOnClickPendingIntent(R.id.f_sub, open)

        if (run != null) {
            val remain = run.remainingMs(now)
            rv.setImageViewBitmap(R.id.f_ring, ring(run.elapsedMs(now).toFloat() / run.plannedMs))
            rv.setViewVisibility(R.id.f_ring_text, View.GONE)
            rv.setViewVisibility(R.id.f_ring_timer, View.VISIBLE)
            rv.setChronometerCountDown(R.id.f_ring_timer, true)
            rv.setChronometer(R.id.f_ring_timer, SystemClock.elapsedRealtime() + remain, null, !run.paused)
            rv.setTextViewText(R.id.f_title, if (run.paused) "专注已暂停" else "专注中")
            val what = run.title.takeIf { it.isNotBlank() }?.let(TodoMeta::cleanTitle) ?: "自由专注"
            rv.setTextViewText(R.id.f_sub, "$what · 共 ${run.plannedMin} 分钟")
            rv.setTextViewText(R.id.f_btn_main, if (run.paused) "继续" else "暂停")
            rv.setOnClickPendingIntent(
                R.id.f_btn_main,
                action(if (run.paused) FocusNotifier.ACTION_RESUME else FocusNotifier.ACTION_PAUSE, 32),
            )
            rv.setViewVisibility(R.id.f_btn_sub, View.VISIBLE)
            rv.setTextViewText(R.id.f_btn_sub, "结束")
            rv.setOnClickPendingIntent(R.id.f_btn_sub, action(FocusNotifier.ACTION_FINISH, 33))
        } else {
            val min = todayFocusMin()
            val goal = settings.current.focusGoalMin.coerceAtLeast(1)
            rv.setImageViewBitmap(R.id.f_ring, ring(((min ?: 0).toFloat() / goal).coerceIn(0f, 1f)))
            rv.setViewVisibility(R.id.f_ring_timer, View.GONE)
            rv.setViewVisibility(R.id.f_ring_text, View.VISIBLE)
            rv.setTextViewText(R.id.f_ring_text, ringLabel(min))
            rv.setTextViewText(R.id.f_title, "今天专注")
            rv.setTextViewText(
                R.id.f_sub,
                if (credentials.didaToken.isNullOrBlank()) "未连接滴答清单" else "目标 ${compact(goal)} · ${((min ?: 0) * 100 / goal).coerceAtMost(100)}%",
            )
            rv.setTextViewText(R.id.f_btn_main, "开始 ${focus.lastMinutes} 分钟")
            rv.setOnClickPendingIntent(R.id.f_btn_main, action(FocusNotifier.ACTION_START, 31))
            rv.setViewVisibility(R.id.f_btn_sub, View.GONE)
        }
        return rv
    }

    private fun ring(progress: Float): Bitmap {
        val size = (76 * context.resources.displayMetrics.density).toInt()
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val stroke = size * 0.11f
        val rect = RectF(stroke / 2, stroke / 2, size - stroke / 2, size - stroke / 2)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = stroke
            color = RING_TRACK
        }
        canvas.drawArc(rect, 0f, 360f, false, paint)
        if (progress > 0f) {
            paint.color = ContextCompat.getColor(context, R.color.widget_chip)
            paint.strokeCap = Paint.Cap.ROUND
            canvas.drawArc(rect, -90f, 360f * progress.coerceAtMost(1f), false, paint)
        }
        return bitmap
    }

    private fun ringLabel(min: Int?): String = when {
        min == null -> "–"
        min < 60 -> "${min}分"
        min % 60 == 0 -> "${min / 60}h"
        else -> String.format(Locale.ROOT, "%.1fh", min / 60.0)
    }

    private fun compact(min: Int): String = when {
        min < 60 -> "${min}m"
        min % 60 == 0 -> "${min / 60}h"
        else -> "${min / 60}h${min % 60}m"
    }

    // ───────────────────────── 记录时间河小部件 ─────────────────────────

    fun updateRiver(onlyIds: IntArray? = null) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = onlyIds ?: riverIds(manager)
        if (ids.isEmpty()) return
        val connected = !credentials.ideashellKey.isNullOrBlank()
        val items = if (connected) loadCache()?.items else null
        for (id in ids) runCatching { manager.updateAppWidget(id, buildRiver(manager, id, connected, items)) }
    }

    private fun riverIds(manager: AppWidgetManager = AppWidgetManager.getInstance(context)): IntArray =
        manager.getAppWidgetIds(ComponentName(context, RiverWidgetProvider::class.java))

    /** 读最近 3 天的记录存成缓存并重绘；没放小部件、没连接闪念贝壳时什么也不做。失败抛异常，由调用方决定怎么处理 */
    suspend fun refreshRiver() {
        if (riverIds().isEmpty() || credentials.ideashellKey.isNullOrBlank()) return
        val data = notes.timeline(TimeRanges.lastDays(RIVER_DAYS))
        val fresh = RiverCache(itemsOf(data), System.currentTimeMillis())
        cache = fresh
        runCatching { cacheFile.writeText(json.encodeToString(RiverCache.serializer(), fresh)) }
        updateRiver()
    }

    /** 缓存不到 [maxAgeMs] 就不用重新读 */
    fun riverFresh(maxAgeMs: Long): Boolean = loadCache()?.let { System.currentTimeMillis() - it.updatedAt < maxAgeMs } == true

    private fun loadCache(): RiverCache? {
        cache?.let { return it }
        val read = runCatching { json.decodeFromString(RiverCache.serializer(), cacheFile.readText()) }.getOrNull()
        cache = read
        return read
    }

    /** 和回顾页的「河」同一口径：日记 / 笔记 / 完成的待办，每天内按时间从晚到早，天与天之间新的在前 */
    private fun itemsOf(data: TimelineData): List<RiverItem> {
        val zone = ZoneId.systemDefault()
        val out = ArrayList<RiverItem>()
        for (day in data.days) {
            val epoch = day.date.toEpochDay()
            val rows = ArrayList<RiverItem>()
            day.daily.forEach { rows += RiverItem(1, epoch, it.time, oneLine(it.text)) }
            day.notes.forEach { n ->
                val text = n.title.takeIf { it.isNotBlank() && it != "无标题" } ?: n.summary ?: n.title
                rows += RiverItem(0, epoch, n.localClock.orEmpty(), oneLine(text))
            }
            day.todos.filter { it.done }.forEach { t -> rows += RiverItem(2, epoch, doneClock(t, zone), oneLine(TodoMeta.cleanTitle(t.title))) }
            out += rows.filter { it.text.isNotBlank() }.sortedByDescending { it.clock }
        }
        return out.take(RIVER_MAX_ITEMS)
    }

    private fun doneClock(t: DidaTask, zone: ZoneId): String {
        val at = t.completedAt ?: return t.time.orEmpty()
        val z = Instant.ofEpochMilli(at).atZone(zone)
        return "%02d:%02d".format(z.hour, z.minute)
    }

    private fun oneLine(s: String): String = s.replace(Regex("\\s+"), " ").trim()

    private fun buildRiver(manager: AppWidgetManager, widgetId: Int, connected: Boolean, items: List<RiverItem>?): RemoteViews {
        val rv = RemoteViews(context.packageName, R.layout.widget_river)
        val maxHeightDp = manager.getAppWidgetOptions(widgetId).getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 180)
        // 头部约 56dp，每行 38dp
        val maxRows = ((maxHeightDp - 56 - 24) / 38).coerceIn(1, 8)
        val open = openApp(tab = 2)
        rv.setOnClickPendingIntent(R.id.river_title, open)
        rv.setOnClickPendingIntent(R.id.river_summary, open)
        rv.setOnClickPendingIntent(R.id.river_empty, open)
        rv.setOnClickPendingIntent(R.id.river_add, quickAdd())
        rv.removeAllViews(R.id.river_rows)

        fun empty(summary: String, text: String) {
            rv.setTextViewText(R.id.river_summary, summary)
            rv.setViewVisibility(R.id.river_rows, View.GONE)
            rv.setViewVisibility(R.id.river_empty, View.VISIBLE)
            rv.setTextViewText(R.id.river_empty, text)
        }

        when {
            !connected -> empty("未连接闪念贝壳", "点这里打开应用，连接闪念贝壳")
            items == null -> empty("加载中…", "正在同步记录…")
            items.isEmpty() -> empty("最近 $RIVER_DAYS 天", "最近几天还没有记录，点右上角 + 记一条")
            else -> {
                val today = LocalDate.now().toEpochDay()
                val todayCount = items.count { it.epochDay == today }
                rv.setTextViewText(R.id.river_summary, if (todayCount > 0) "今天 $todayCount 条" else "最近 $RIVER_DAYS 天")
                rv.setViewVisibility(R.id.river_empty, View.GONE)
                rv.setViewVisibility(R.id.river_rows, View.VISIBLE)
                items.take(maxRows).forEach { rv.addView(R.id.river_rows, buildRiverRow(it, today, open)) }
            }
        }
        return rv
    }

    private fun buildRiverRow(item: RiverItem, today: Long, open: PendingIntent): RemoteViews {
        val row = RemoteViews(context.packageName, R.layout.widget_river_row)
        val time = when (today - item.epochDay) {
            0L -> item.clock
            1L -> "昨 ${item.clock}".trim()
            else -> LocalDate.ofEpochDay(item.epochDay).let { "${it.monthValue}/${it.dayOfMonth}" }
        }
        row.setTextViewText(R.id.rr_time, time)
        row.setTextViewText(R.id.rr_text, item.text)
        row.setInt(
            R.id.rr_node,
            "setBackgroundResource",
            when (item.kind) {
                1 -> R.drawable.river_node_daily
                2 -> R.drawable.river_node_todo
                else -> R.drawable.river_node_note
            },
        )
        row.setOnClickPendingIntent(R.id.rr_text, open)
        row.setOnClickPendingIntent(R.id.rr_time, open)
        return row
    }

    // ───────────────────────── PendingIntent ─────────────────────────

    private fun action(action: String, code: Int): PendingIntent = PendingIntent.getBroadcast(
        context, code,
        Intent(context, FocusActionReceiver::class.java).setAction(action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun openFocus(): PendingIntent = PendingIntent.getActivity(
        context, 104,
        Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(MainActivity.EXTRA_OPEN_FOCUS, true)
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun openApp(tab: Int): PendingIntent = PendingIntent.getActivity(
        context, tab,
        Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(MainActivity.EXTRA_TAB, tab)
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun quickAdd(): PendingIntent = PendingIntent.getActivity(
        context, 105,
        Intent(context, QuickCaptureActivity::class.java).apply {
            action = QuickCaptureActivity.ACTION_QUICK_CAPTURE
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private companion object {
        const val RIVER_DAYS = 3
        const val RIVER_MAX_ITEMS = 12

        /** 圆环轨道：中性灰半透明，深浅底都看得出来 */
        const val RING_TRACK = 0x47888888
    }
}

/** 专注小部件：内容由 [ExtraWidgets] 渲染，这里只负责系统回调 */
class FocusWidgetProvider : android.appwidget.AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        val container = (context.applicationContext as com.carpe.ideashell.IdeashellApp).container
        container.widgets.updateFocus(appWidgetIds)
        // 顺手对账：到点没记的专注补记，并读一下今天的专注时长
        container.appScope.launch {
            container.focus.settle()
            runCatching { container.daySummary.focus() }
            container.widgets.updateFocus()
        }
    }

    override fun onEnabled(context: Context) {
        TodoRefreshScheduler.schedule(context)
    }
}

/** 记录时间河小部件 */
class RiverWidgetProvider : android.appwidget.AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        val container = (context.applicationContext as com.carpe.ideashell.IdeashellApp).container
        container.widgets.updateRiver(appWidgetIds)
        if (!container.widgets.riverFresh(2 * 60_000L)) {
            container.appScope.launch { runCatching { container.widgets.refreshRiver() } }
        }
    }

    override fun onAppWidgetOptionsChanged(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int, newOptions: android.os.Bundle) {
        val container = (context.applicationContext as com.carpe.ideashell.IdeashellApp).container
        container.widgets.updateRiver(intArrayOf(appWidgetId))
    }

    override fun onEnabled(context: Context) {
        TodoRefreshScheduler.schedule(context)
    }
}
