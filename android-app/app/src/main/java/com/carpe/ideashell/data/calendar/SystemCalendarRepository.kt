package com.carpe.ideashell.data.calendar

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import com.carpe.ideashell.data.dida.CalendarTaskOps
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.dida.SOURCE_CALENDAR
import com.carpe.ideashell.data.dida.calendarEventKey
import com.carpe.ideashell.data.settings.SettingsStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset

/** 系统里的一个日历（账户下的一个日历本） */
data class DeviceCalendar(
    val id: Long,
    val name: String,
    val account: String,
    val color: Int,
    val visible: Boolean,
    val writable: Boolean,
    val local: Boolean,
) {
    /** 默认要同步：可写（用户自己的日历）、不是应用写的本地提醒类日历 */
    val defaultSelected: Boolean get() = visible && writable && !local
}

/**
 * 日历同步的当前状态。[events] 是已经套好「已处理」和本地标签的任务（来源 = 日历），
 * 覆盖 [from]..[to] 这段日期。
 */
data class CalendarState(
    val enabled: Boolean = false,
    val permission: Boolean = false,
    val events: List<DidaTask> = emptyList(),
    /** 日历 id（形如 `cal:3`）→ 显示名；任务行 / 详情里当「清单名」用 */
    val names: Map<String, String> = emptyMap(),
    val loading: Boolean = false,
    val error: String? = null,
    val from: LocalDate = LocalDate.now(),
    val to: LocalDate = LocalDate.now(),
    val updatedAt: Long = 0L,
)

@Serializable
private data class CalendarLocal(
    /** 任务 id → 标记「已处理」的时刻 */
    val done: Map<String, Long> = emptyMap(),
    /** 事件键 → 本地加的标签（归入项目用；不会写回系统日历） */
    val tags: Map<String, List<String>> = emptyMap(),
)

/**
 * 系统日历 → 待办（只读导入）：读系统日历里选中的日历的事件（含重复事件的每一次），
 * 变成「来源 = 日历」的任务，和滴答任务一起显示在待办页。
 * 不会改系统日历里的事件：「完成」只在本机标记已处理；归入项目的标签也只存本机。
 * 唯一的例外：开启「完成状态同步回系统待办」后，系统待办（非重复）的完成 / 恢复会写回荣耀待办库。
 */
class SystemCalendarRepository(
    context: Context,
    private val settings: SettingsStore,
    private val scope: CoroutineScope,
    private val localFile: File,
) : CalendarTaskOps {
    private val appContext = context.applicationContext
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val zone: ZoneId get() = ZoneId.systemDefault()

    private val _state = MutableStateFlow(CalendarState())
    val state: StateFlow<CalendarState> = _state.asStateFlow()

    private val loadLock = Mutex()
    private val localLock = Mutex()
    private var local = CalendarLocal()
    private var raw: List<DidaTask> = emptyList()
    private var names: Map<String, String> = emptyMap()
    private var rangeFrom: LocalDate = LocalDate.now().minusDays(PAST_DAYS)
    private var rangeTo: LocalDate = LocalDate.now().plusDays(FUTURE_DAYS)
    private var reloadJob: Job? = null

    private val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) = scheduleReload()
    }
    private var observing = false

    fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(appContext, Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED

    init {
        scope.launch(Dispatchers.IO) {
            local = runCatching { json.decodeFromString(CalendarLocal.serializer(), localFile.readText()) }.getOrDefault(CalendarLocal())
            publish()
        }
        // 开关 / 选中的日历一变就重新读
        scope.launch {
            settings.state.map { Triple(it.calendarSync, it.calendarIdsText, it.calendarTasks) }.distinctUntilChanged().collect {
                refresh()
            }
        }
    }

    /** 重新读一遍（回到应用、系统日历有变化、开关变了时调用） */
    fun refresh() {
        scope.launch { reload() }
    }

    private fun scheduleReload() {
        reloadJob?.cancel()
        reloadJob = scope.launch {
            delay(800)
            reload()
        }
    }

    /** 日历视图翻到更远的月份时，把读取范围扩过去 */
    fun ensureRange(from: LocalDate, to: LocalDate) {
        if (!settings.current.calendarSync) return
        if (from >= rangeFrom && to <= rangeTo) return
        rangeFrom = minOf(rangeFrom, from)
        rangeTo = maxOf(rangeTo, to)
        // 窗口别无限长：最多读前后各约两年
        val today = LocalDate.now()
        rangeFrom = maxOf(rangeFrom, today.minusDays(800))
        rangeTo = minOf(rangeTo, today.plusDays(800))
        refresh()
    }

    /** 读某一天的事件（时间轴往前翻看过去的日子）：窗口里没有就直接读那一天 */
    suspend fun eventsOn(day: LocalDate): List<DidaTask> {
        val s = _state.value
        if (!s.enabled || !s.permission) return emptyList()
        val ds = day.toString()
        if (day >= s.from && day <= s.to) return s.events.filter { it.date == ds }
        val ids = selectedIds(withContext(Dispatchers.IO) { calendars() })
        val list = withContext(Dispatchers.IO) {
            val events = runCatching { query(day, day, ids) }.getOrDefault(emptyList())
            val todos = if (settings.current.calendarTasks) runCatching { queryTasks(day, day, withOverdue = false).first }.getOrDefault(emptyList()) else emptyList()
            events + todos
        }
        return list.map { applyLocal(it) }
    }

    // ───────────── 系统日历 ─────────────

    /** 系统里所有的日历（没有权限时为空） */
    fun calendars(): List<DeviceCalendar> {
        if (!hasPermission()) return emptyList()
        val out = ArrayList<DeviceCalendar>()
        runCatching {
            appContext.contentResolver.query(
                CalendarContract.Calendars.CONTENT_URI,
                arrayOf(
                    CalendarContract.Calendars._ID,
                    CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
                    CalendarContract.Calendars.ACCOUNT_NAME,
                    CalendarContract.Calendars.ACCOUNT_TYPE,
                    CalendarContract.Calendars.CALENDAR_COLOR,
                    CalendarContract.Calendars.VISIBLE,
                    CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
                ),
                null,
                null,
                CalendarContract.Calendars.ACCOUNT_NAME + " ASC, " + CalendarContract.Calendars.CALENDAR_DISPLAY_NAME + " ASC",
            )?.use { c ->
                while (c.moveToNext()) {
                    out += DeviceCalendar(
                        id = c.getLong(0),
                        name = c.getString(1).orEmpty().ifBlank { "日历" },
                        account = c.getString(2).orEmpty(),
                        color = c.getInt(4),
                        visible = c.getInt(5) != 0,
                        writable = c.getInt(6) >= CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR,
                        local = c.getString(3) == CalendarContract.ACCOUNT_TYPE_LOCAL,
                    )
                }
            }
        }
        return out
    }

    /** 实际要读的日历 id：用户选过就用选的，没选过用默认 */
    fun selectedIds(all: List<DeviceCalendar>): Set<Long> =
        settings.current.calendarIds?.filter { id -> all.any { it.id == id } }?.toSet()
            ?: all.filter { it.defaultSelected }.ifEmpty { all.filter { it.visible } }.map { it.id }.toSet()

    private suspend fun reload() {
        loadLock.withLock {
            val enabled = settings.current.calendarSync
            val permission = hasPermission()
            if (!enabled || !permission) {
                stopObserving()
                raw = emptyList()
                names = emptyMap()
                publish(enabled = enabled, permission = permission)
                return
            }
            startObserving()
            _state.value = _state.value.copy(enabled = true, permission = true, loading = true)
            try {
                val (list, nameMap) = withContext(Dispatchers.IO) {
                    val all = calendars()
                    val ids = selectedIds(all)
                    val events = if (ids.isEmpty()) emptyList() else query(rangeFrom, rangeTo, ids)
                    var names = all.filter { it.id in ids }.associate { "cal:${it.id}" to it.name }
                    // 系统待办（荣耀日历 App 里的待办）：读不到（别的品牌手机没有这个来源）就当没有
                    val todos = if (settings.current.calendarTasks) {
                        runCatching { queryTasks(rangeFrom, rangeTo, withOverdue = true) }.getOrNull()
                    } else {
                        null
                    }
                    if (todos != null) names = names + todos.second
                    (events + todos?.first.orEmpty()) to names
                }
                raw = list
                names = nameMap
                publish(error = null, updatedAt = System.currentTimeMillis())
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                publish(error = "读取日历失败：${e.message ?: "未知错误"}")
            }
        }
    }

    private fun startObserving() {
        if (observing) return
        runCatching {
            appContext.contentResolver.registerContentObserver(CalendarContract.CONTENT_URI, true, observer)
            observing = true
        }
        runCatching { appContext.contentResolver.registerContentObserver(TASK_URI, true, observer) }
    }

    private fun stopObserving() {
        if (!observing) return
        runCatching { appContext.contentResolver.unregisterContentObserver(observer) }
        observing = false
    }

    /** 读 [from]..[to]（含）里选中日历的事件实例；重复事件的每一次各一条 */
    private fun query(from: LocalDate, to: LocalDate, ids: Set<Long>): List<DidaTask> {
        if (ids.isEmpty()) return emptyList()
        val startMs = from.atStartOfDay(zone).toInstant().toEpochMilli()
        val endMs = to.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        val uri: Uri = CalendarContract.Instances.CONTENT_URI.buildUpon().also {
            ContentUris.appendId(it, startMs - ALL_DAY_SLACK_MS)
            ContentUris.appendId(it, endMs + ALL_DAY_SLACK_MS)
        }.build()
        val out = ArrayList<DidaTask>()
        val fromS = from.toString()
        val toS = to.toString()
        appContext.contentResolver.query(
            uri,
            arrayOf(
                CalendarContract.Instances.EVENT_ID,
                CalendarContract.Instances.BEGIN,
                CalendarContract.Instances.END,
                CalendarContract.Instances.TITLE,
                CalendarContract.Instances.DESCRIPTION,
                CalendarContract.Instances.EVENT_LOCATION,
                CalendarContract.Instances.ALL_DAY,
                CalendarContract.Instances.CALENDAR_ID,
                CalendarContract.Instances.RRULE,
                CalendarContract.Instances.STATUS,
            ),
            "${CalendarContract.Instances.CALENDAR_ID} IN (${ids.joinToString(",")})",
            null,
            "${CalendarContract.Instances.BEGIN} ASC",
        )?.use { c ->
            while (c.moveToNext()) {
                if (c.getInt(9) == CalendarContract.Events.STATUS_CANCELED) continue
                val eventId = c.getLong(0)
                val begin = c.getLong(1)
                val end = c.getLong(2)
                val title = c.getString(3).orEmpty().trim().ifEmpty { "（无标题）" }
                val description = c.getString(4).orEmpty().trim()
                val location = c.getString(5).orEmpty().trim().ifEmpty { null }
                val allDay = c.getInt(6) != 0
                val calId = c.getLong(7)
                val rrule = c.getString(8)?.takeIf { it.isNotBlank() }
                fun task(date: LocalDate, time: String?, endTime: String?): DidaTask? {
                    val ds = date.toString()
                    if (ds < fromS || ds > toS) return null
                    return DidaTask(
                        id = "cal:$eventId@$ds",
                        projectId = "cal:$calId",
                        title = title,
                        content = description,
                        date = ds,
                        time = time,
                        repeatFlag = rrule,
                        source = SOURCE_CALENDAR,
                        endTime = endTime,
                        location = location,
                    )
                }
                if (allDay) {
                    // 全天事件的时间是 UTC 的零点，结束日不含；跨几天就每天一条
                    val first = Instant.ofEpochMilli(begin).atZone(ZoneOffset.UTC).toLocalDate()
                    var last = Instant.ofEpochMilli(end).atZone(ZoneOffset.UTC).toLocalDate().minusDays(1)
                    if (last < first) last = first
                    if (last > first.plusDays(MAX_SPAN_DAYS)) last = first.plusDays(MAX_SPAN_DAYS)
                    var d = first
                    while (d <= last) {
                        task(d, null, null)?.let(out::add)
                        d = d.plusDays(1)
                    }
                } else {
                    val s = Instant.ofEpochMilli(begin).atZone(zone)
                    val e = Instant.ofEpochMilli(end).atZone(zone)
                    val endTime = if (end > begin && e.toLocalDate() == s.toLocalDate()) "%02d:%02d".format(e.hour, e.minute) else null
                    task(s.toLocalDate(), "%02d:%02d".format(s.hour, s.minute), endTime)?.let(out::add)
                }
            }
        }
        return out.sortedWith(compareBy({ it.date }, { it.time ?: "" }, { it.title }))
    }

    /**
     * 读荣耀日历 App 里的待办（`com.android.calendar.task` 提供，同样用「读取日历」权限）。
     * 返回 [from]..[to] 里的待办，加上更早的、还没完成的（[withOverdue]，即逾期未完成）和没有日期的未完成待办；
     * 第二个结果是 清单键 → 清单名（工作 / 个人 / 购物……）。
     */
    private fun queryTasks(from: LocalDate, to: LocalDate, withOverdue: Boolean): Pair<List<DidaTask>, Map<String, String>> {
        val resolver = appContext.contentResolver
        val folders = HashMap<String, String>()
        resolver.query(Uri.withAppendedPath(TASK_URI, "folders"), arrayOf("uuid", "display_name"), "delete_flag=0", null, null)?.use { c ->
            while (c.moveToNext()) {
                val uuid = c.getString(0).orEmpty()
                folders["cal:t:$uuid"] = folderLabel(c.getString(1).orEmpty())
            }
        }
        val out = ArrayList<DidaTask>()
        val fromS = from.toString()
        val toS = to.toString()
        resolver.query(
            Uri.withAppendedPath(TASK_URI, "tasks"),
            arrayOf("_id", "title", "body", "complete", "importance", "due_date", "isAllDay", "folder_uuid", "rrule", "date_completed", "modify_time", "location"),
            "delete_flag=0",
            null,
            "due_date ASC",
        )?.use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(0)
                val done = c.getInt(3) == 1
                val due = c.getLong(5)
                val allDay = c.getInt(6) != 0
                var date: String? = null
                var time: String? = null
                if (due > 0) {
                    if (allDay) {
                        // 全天待办的截止时间是 UTC 零点（和系统日历的全天事件一样）
                        date = Instant.ofEpochMilli(due).atZone(ZoneOffset.UTC).toLocalDate().toString()
                    } else {
                        val z = Instant.ofEpochMilli(due).atZone(zone)
                        date = z.toLocalDate().toString()
                        time = "%02d:%02d".format(z.hour, z.minute)
                    }
                }
                val keep = when {
                    date == null -> !done // 没有日期的：只要还没完成的
                    date in fromS..toS -> true
                    else -> withOverdue && !done && date < fromS // 更早的：只要逾期未完成的
                }
                if (!keep) continue
                val folder = c.getString(7).orEmpty()
                val completedAt = c.getLong(9).takeIf { it > 0 } ?: c.getLong(10).takeIf { it > 0 }
                out += DidaTask(
                    id = "cal:t$id" + (date?.let { "@$it" } ?: ""),
                    projectId = "cal:t:$folder",
                    title = c.getString(1).orEmpty().trim().ifEmpty { "（无标题）" },
                    content = c.getString(2).orEmpty().trim(),
                    date = date,
                    time = time,
                    priority = when (c.getInt(4)) {
                        0 -> 0
                        1 -> 1
                        2 -> 3
                        else -> 5
                    },
                    done = done,
                    completedAt = if (done) completedAt else null,
                    repeatFlag = c.getString(8)?.takeIf { it.isNotBlank() },
                    source = SOURCE_CALENDAR,
                    location = c.getString(11)?.trim()?.ifEmpty { null },
                )
            }
        }
        return out to folders
    }

    private fun folderLabel(name: String): String = when (name) {
        "default_unclassified" -> "默认"
        "default_task_work" -> "工作"
        "default_task_personal" -> "个人"
        "default_task_shop" -> "购物"
        else -> name.ifBlank { "待办" }
    }

    // ───────────── 本地状态：已处理 / 标签 ─────────────

    private fun applyLocal(t: DidaTask): DidaTask {
        val doneAt = local.done[t.id]
        val tags = local.tags[calendarEventKey(t.id)].orEmpty()
        return if (doneAt == null && tags.isEmpty()) t else t.copy(done = t.done || doneAt != null, completedAt = doneAt ?: t.completedAt, tags = tags)
    }

    private fun publish(
        enabled: Boolean = settings.current.calendarSync,
        permission: Boolean = hasPermission(),
        error: String? = _state.value.error,
        updatedAt: Long = _state.value.updatedAt,
    ) {
        _state.value = CalendarState(
            enabled = enabled,
            permission = permission,
            events = raw.map(::applyLocal),
            names = names,
            loading = false,
            error = error,
            from = rangeFrom,
            to = rangeTo,
            updatedAt = updatedAt,
        )
    }

    private suspend fun saveLocal() = withContext(Dispatchers.IO) {
        runCatching { localFile.writeText(json.encodeToString(CalendarLocal.serializer(), local)) }
    }

    fun hasWritePermission(): Boolean =
        ContextCompat.checkSelfPermission(appContext, Manifest.permission.WRITE_CALENDAR) == PackageManager.PERMISSION_GRANTED

    /**
     * 把系统待办的完成状态写回荣耀待办库。只处理「系统待办、不是重复待办、开关开着、有写入权限」的任务；
     * 重复待办写回会把整个系列一起完成，所以只记在本机。返回是否真的写进去了。
     */
    private suspend fun writeDone(task: DidaTask, done: Boolean): Boolean {
        if (!task.isSystemTodo || !task.repeatFlag.isNullOrBlank()) return false
        if (!settings.current.calendarWriteback || !hasWritePermission()) return false
        val rowId = task.id.removePrefix("cal:t").substringBefore('@').toLongOrNull() ?: return false
        return withContext(Dispatchers.IO) {
            runCatching {
                val values = android.content.ContentValues().apply {
                    put("complete", if (done) 1 else 0)
                    put("modify_time", System.currentTimeMillis())
                }
                appContext.contentResolver.update(Uri.withAppendedPath(TASK_URI, "tasks"), values, "_id=?", arrayOf(rowId.toString())) > 0
            }.getOrDefault(false)
        }
    }

    override suspend fun complete(task: DidaTask): Result<Unit> {
        val wrote = writeDone(task, true)
        localLock.withLock {
            local = if (wrote) local.copy(done = local.done - task.id) else local.copy(done = local.done + (task.id to System.currentTimeMillis()))
            saveLocal()
        }
        if (wrote) raw = raw.map { if (it.id == task.id) it.copy(done = true, completedAt = System.currentTimeMillis()) else it }
        publish()
        return Result.success(Unit)
    }

    override suspend fun undoComplete(task: DidaTask): Result<Unit> {
        val wrote = writeDone(task, false)
        localLock.withLock {
            local = local.copy(done = local.done - task.id)
            saveLocal()
        }
        if (wrote) raw = raw.map { if (it.id == task.id) it.copy(done = false, completedAt = null) else it }
        publish()
        return Result.success(Unit)
    }

    override suspend fun setTags(task: DidaTask, tags: List<String>): Result<Unit> {
        localLock.withLock {
            val key = calendarEventKey(task.id)
            local = local.copy(tags = if (tags.isEmpty()) local.tags - key else local.tags + (key to tags))
            saveLocal()
        }
        publish()
        return Result.success(Unit)
    }

    companion object {
        /** 荣耀日历 App 的待办库 */
        private val TASK_URI: Uri = Uri.parse("content://com.android.calendar.task")
        const val PAST_DAYS = 7L
        const val FUTURE_DAYS = 60L
        private const val MAX_SPAN_DAYS = 30L

        /** 全天事件用 UTC 零点记时间，查询范围前后各放宽一天，避免时区差把边缘的事件漏掉（读出来后再按本地日期过滤） */
        private const val ALL_DAY_SLACK_MS = 24L * 3600 * 1000
    }
}
