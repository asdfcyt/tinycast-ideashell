package com.carpe.ideashell.data.dida

import com.carpe.ideashell.data.mcp.McpClient
import com.carpe.ideashell.data.mcp.callText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime

/** 滴答清单 MCP 的业务封装：新建 / 拉取 / 完成 / 改期 / 改优先级 */
class DidaApi(private val mcp: McpClient) {

    /**
     * 新建任务。没有日期 = 无日期任务（进滴答收集箱）；
     * 有具体时间：准点提醒；只有日期：当天 9:00 提醒。
     * @param priority 0 无 / 1 低 / 3 中 / 5 高
     */
    suspend fun createTask(title: String, date: String?, time: String?, priority: Int = 0) {
        val zone = ZoneId.systemDefault()
        mcp.callText(
            "create_task",
            buildJsonObject {
                put("task", taskObject(title, date, time, priority, zone))
                put("client_timezone", zone.id)
            },
        )
    }

    /** 完成任务 */
    suspend fun complete(task: DidaTask) {
        mcp.callText(
            "complete_task",
            buildJsonObject {
                put("project_id", task.projectId)
                put("task_id", task.id)
            },
        )
    }

    /** 把已完成的任务恢复为未完成（用于「撤销完成」） */
    suspend fun reopen(task: DidaTask) {
        update(task) { put("status", 0) }
    }

    /** 改期：date 为 null 表示不改日期（本接口不支持清除日期） */
    suspend fun reschedule(task: DidaTask, date: String, time: String?) {
        val zone = ZoneId.systemDefault()
        update(task) {
            val due = dueString(date, time, zone)
            put("startDate", due)
            put("dueDate", due)
            put("isAllDay", time == null)
            put("timeZone", zone.id)
            putJsonArray("reminders") { add(if (time != null) "TRIGGER:PT0S" else "TRIGGER:P0DT9H0M0S") }
        }
    }

    suspend fun setPriority(task: DidaTask, priority: Int) {
        update(task) { put("priority", priority) }
    }

    suspend fun setTitle(task: DidaTask, title: String) {
        update(task) { put("title", title) }
    }

    /** 整体替换标签 */
    suspend fun setTags(task: DidaTask, tags: List<String>) {
        update(task) { putJsonArray("tags") { tags.forEach { add(it) } } }
    }

    /** 整体替换备注 */
    suspend fun setContent(task: DidaTask, content: String) {
        update(task) { put("content", content) }
    }

    suspend fun deleteTask(task: DidaTask) {
        mcp.callText(
            "delete_task",
            buildJsonObject {
                put("project_id", task.projectId)
                put("task_id", task.id)
            },
        )
    }

    /** 给任务写一条评论（在滴答 / 手机上也能看到最新进展）；滴答评论最长 1024 个字符 */
    suspend fun addComment(projectId: String, taskId: String, text: String) {
        val title = text.trim().let { if (it.length > 1000) it.take(1000) + "…" else it }
        mcp.callText(
            "add_comment",
            buildJsonObject {
                put("project_id", projectId)
                put("task_id", taskId)
                put("title", title)
            },
        )
    }

    /** 查单个任务；查不到返回 null */
    suspend fun fetchTask(taskId: String): DidaTask? =
        DidaParser.extractTasks(mcp.callText("get_task_by_id", buildJsonObject { put("task_id", taskId) })).firstOrNull()

    /** 指定那一天完成的任务，按完成时间升序 */
    suspend fun completedOn(day: LocalDate): List<DidaTask> {
        val zone = ZoneId.systemDefault()
        val text = mcp.callText(
            "list_completed_tasks_by_date",
            buildJsonObject {
                put(
                    "search",
                    buildJsonObject {
                        put("startDate", dueString(day.toString(), null, zone))
                        put("endDate", dueString(day.plusDays(1).toString(), null, zone))
                    },
                )
                put("client_timezone", zone.id)
            },
        )
        return DidaParser.extractTasks(text, zone)
            .filter { it.done }
            .filter { t -> t.completedAt?.let { java.time.Instant.ofEpochMilli(it).atZone(zone).toLocalDate() == day } ?: true }
            .sortedBy { it.completedAt ?: 0L }
    }

    // ───────────── 习惯与专注（接口返回没有公开样例，解析见 DidaHabits.kt，全部宽松处理） ─────────────

    suspend fun habitsRaw(): String = mcp.callText("list_habits", JsonObject(emptyMap()))

    suspend fun habitCheckinsRaw(habitIds: List<String>, stamp: Int): String = habitCheckinsRangeRaw(habitIds, stamp, stamp)

    /** [fromStamp]..[toStamp]（含）每天的打卡记录 */
    suspend fun habitCheckinsRangeRaw(habitIds: List<String>, fromStamp: Int, toStamp: Int): String = mcp.callText(
        "get_habit_checkins",
        buildJsonObject {
            putJsonArray("habit_ids") { habitIds.forEach { add(it) } }
            put("from_stamp", fromStamp)
            put("to_stamp", toStamp)
            put("client_timezone", ZoneId.systemDefault().id)
        },
    )

    /** 打卡：写入目标值，状态为已完成；[checkinId] 有值则更新那条记录 */
    suspend fun upsertHabitCheckin(habitId: String, checkinId: String?, stamp: Int, goal: Double, now: ZonedDateTime) {
        val t = isoLocal(now)
        val value = if (goal % 1.0 == 0.0) JsonPrimitive(goal.toLong()) else JsonPrimitive(goal)
        mcp.callText(
            "upsert_habit_checkins",
            buildJsonObject {
                put("habit_id", habitId)
                put(
                    "checkin_data",
                    buildJsonObject {
                        if (checkinId != null) put("id", checkinId)
                        put("stamp", stamp)
                        put("time", t)
                        put("opTime", t)
                        put("value", value)
                        put("goal", value)
                        put("status", 2)
                    },
                )
                put("client_timezone", ZoneId.systemDefault().id)
            },
        )
    }

    /** type：0 番茄钟 / 1 正计时 */
    suspend fun focusRaw(from: LocalDate, toExclusive: LocalDate, type: Int): String {
        val zone = ZoneId.systemDefault()
        return mcp.callText(
            "get_focuses_by_time",
            buildJsonObject {
                put("from_time", dueString(from.toString(), null, zone))
                put("to_time", dueString(toExclusive.toString(), null, zone))
                put("type", type)
            },
        )
    }

    private fun isoLocal(t: ZonedDateTime): String {
        val seconds = t.offset.totalSeconds
        val sign = if (seconds >= 0) "+" else "-"
        val abs = kotlin.math.abs(seconds)
        return "%s-%02d-%02dT%02d:%02d:%02d.000%s%02d%02d".format(
            "%04d".format(t.year), t.monthValue, t.dayOfMonth, t.hour, t.minute, t.second, sign, abs / 3600, (abs % 3600) / 60,
        )
    }

    private suspend fun update(task: DidaTask, fields: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit) {
        val zone = ZoneId.systemDefault()
        mcp.callText(
            "update_task",
            buildJsonObject {
                put("task_id", task.id)
                put(
                    "task",
                    buildJsonObject {
                        put("id", task.id)
                        put("projectId", task.projectId)
                        fields()
                    },
                )
                put("client_timezone", zone.id)
            },
        )
    }

    /** 项目 id → 名称 */
    suspend fun projectNames(): Map<String, String> =
        DidaParser.extractProjects(mcp.callText("list_projects", JsonObject(emptyMap())))

    /**
     * 拉取概览：逾期（近 13 天）/ 今天起 7 天 / 最近完成（近 3 天）/ 收集箱无日期任务。
     * 接口单次最多 14 天；区间查询与「今天 / 未来 7 天」两种方式各拉一遍再合并，互相补漏全天任务的边界。
     * 全部失败才抛异常，部分失败写进 warning。
     */
    suspend fun fetchOverview(now: LocalDate = LocalDate.now()): DidaOverview = coroutineScope {
        val zone = ZoneId.systemDefault()
        fun range(from: Long, to: Long) = buildJsonObject {
            put(
                "search",
                buildJsonObject {
                    put("startDate", dueString(now.plusDays(from).toString(), null, zone))
                    put("endDate", dueString(now.plusDays(to + 1).toString(), null, zone))
                },
            )
            put("client_timezone", zone.id)
        }
        fun query(q: String) = buildJsonObject {
            put("query_command", q)
            put("client_timezone", zone.id)
        }

        val calls = listOf(
            Call("undone_overdue", "list_undone_tasks_by_date", range(-13, 0)),
            Call("undone_upcoming", "list_undone_tasks_by_date", range(-1, 7)),
            Call("undone_today", "list_undone_tasks_by_time_query", query("today")),
            Call("undone_next7", "list_undone_tasks_by_time_query", query("next7day")),
            Call("completed", "list_completed_tasks_by_date", range(-3, 0)),
            Call("undone_inbox", "get_project_with_undone_tasks", buildJsonObject { put("project_id", "inbox") }),
        )
        val projectsDeferred = async { runCatching { projectNames() }.getOrDefault(emptyMap()) }
        val results = calls.map { call -> async { call.key to attempt { mcp.callText(call.tool, call.args) } } }
            .map { it.await() }.toMap()
        val projects = projectsDeferred.await()

        val failures = results.filterValues { it.isFailure }
        if (failures.size == calls.size) throw failures.values.first().exceptionOrNull()!!

        fun tasksOf(key: String): List<DidaTask> =
            results[key]?.getOrNull()?.let { DidaParser.extractTasks(it, zone) }.orEmpty()

        val today = now.toString()
        val limit = now.plusDays(7).toString()
        val open = LinkedHashMap<String, DidaTask>()
        for (key in listOf("undone_overdue", "undone_upcoming", "undone_today", "undone_next7")) {
            for (t in tasksOf(key)) {
                val d = t.date
                if (t.done || d == null || d > limit || open.containsKey(t.id)) continue
                open[t.id] = t
            }
        }
        val all = open.values.toList()
        DidaOverview(
            overdue = all.filter { it.date!! < today },
            upcoming = all.filter { it.date!! >= today },
            undated = tasksOf("undone_inbox")
                .filter { !it.done && it.date == null }
                .sortedByDescending { it.createdAt ?: 0L }
                .take(100),
            done = tasksOf("completed").map { it.copy(done = true) }
                .sortedByDescending { it.completedAt ?: 0L },
            projects = projects,
            warning = if (failures.isEmpty()) {
                null
            } else {
                "部分滴答请求失败：" + failures.entries.joinToString("；") { "${it.key}：${it.value.exceptionOrNull()?.message}" }
            },
        )
    }

    /**
     * 指定日期范围内的任务（未完成 + 已完成），用于「时间线」回顾。
     * 接口单次最多 14 天，长范围按 14 天一段并行拉取；部分失败时跳过失败段，全部失败才抛异常。
     * 已完成任务的 `date` 为滴答返回的日期，`completedAt` 为完成时刻。
     */
    suspend fun tasksInRange(from: LocalDate, to: LocalDate): List<DidaTask> = coroutineScope {
        val zone = ZoneId.systemDefault()
        val windows = mutableListOf<Pair<LocalDate, LocalDate>>()
        var cursor = from
        while (!cursor.isAfter(to)) {
            val end = minOf(cursor.plusDays(WINDOW_DAYS - 1), to)
            windows += cursor to end
            cursor = end.plusDays(1)
        }

        fun args(a: LocalDate, b: LocalDate) = buildJsonObject {
            put(
                "search",
                buildJsonObject {
                    put("startDate", dueString(a.toString(), null, zone))
                    put("endDate", dueString(b.plusDays(1).toString(), null, zone))
                },
            )
            put("client_timezone", zone.id)
        }

        val jobs = windows.flatMap { (a, b) ->
            listOf(
                async { attempt { mcp.callText("list_undone_tasks_by_date", args(a, b)) }.map { DidaParser.extractTasks(it, zone) } },
                async {
                    attempt { mcp.callText("list_completed_tasks_by_date", args(a, b)) }
                        .map { text -> DidaParser.extractTasks(text, zone).map { it.copy(done = true) } }
                },
            )
        }
        val results = jobs.map { it.await() }
        if (results.isNotEmpty() && results.all { it.isFailure }) throw results.first().exceptionOrNull()!!

        val seen = HashSet<String>()
        results.flatMap { it.getOrNull().orEmpty() }.filter { seen.add("${it.id}|${it.done}") }
    }

    private class Call(val key: String, val tool: String, val args: JsonObject)

    /** 和 runCatching 一样，但不吞掉协程取消 */
    private inline fun <T> attempt(block: () -> T): Result<T> = try {
        Result.success(block())
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        Result.failure(e)
    }

    private fun taskObject(title: String, date: String?, time: String?, priority: Int, zone: ZoneId): JsonObject =
        buildJsonObject {
            put("title", title)
            if (priority > 0) put("priority", priority)
            if (date != null) {
                val due = dueString(date, time, zone)
                put("startDate", due)
                put("dueDate", due)
                put("isAllDay", time == null)
                put("timeZone", zone.id)
                putJsonArray("reminders") { add(if (time != null) "TRIGGER:PT0S" else "TRIGGER:P0DT9H0M0S") }
            }
        }

    private companion object {
        const val WINDOW_DAYS = 14L
    }

    /** yyyy-MM-dd'T'HH:mm:ss.000+0800 */
    private fun dueString(date: String, time: String?, zone: ZoneId): String {
        val dateTime = ZonedDateTime.of(LocalDate.parse(date), LocalTime.parse(time ?: "00:00"), zone)
        val seconds = dateTime.offset.totalSeconds
        val sign = if (seconds >= 0) "+" else "-"
        val abs = kotlin.math.abs(seconds)
        val offset = "%s%02d%02d".format(sign, abs / 3600, (abs % 3600) / 60)
        return "${date}T${"%02d:%02d".format(dateTime.hour, dateTime.minute)}:00.000$offset"
    }
}
