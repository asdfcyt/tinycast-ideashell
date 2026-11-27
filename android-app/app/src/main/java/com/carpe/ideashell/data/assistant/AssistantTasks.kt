package com.carpe.ideashell.data.assistant

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.time.LocalDate
import java.time.ZoneId

/** 一次执行的记录：[status] 是 ok（已通知）/ skipped（条件不满足 / 今天已提醒）/ failed */
@Serializable
data class TaskRun(val at: Long, val status: String, val text: String)

/**
 * 助手任务：到点让助手（大模型 + 查数据的工具）按 [prompt] 办一件事，结果推一条通知。
 * 有 [condition] 的是条件任务：每次先判断条件，满足才通知，一天最多通知一次。
 */
@Serializable
data class AssistantTask(
    val id: String,
    val title: String,
    /** 到点交给助手的完整指令（脱离上下文也能执行） */
    val prompt: String,
    val hour: Int,
    val minute: Int,
    /** 星期掩码：bit0 = 周一 … bit6 = 周日；[onceDate] 不为空时忽略 */
    val days: Int = ALL_DAYS,
    /** 只执行一次的日期（yyyy-MM-dd）；null = 按 [days] 重复 */
    val onceDate: String? = null,
    val condition: String? = null,
    val enabled: Boolean = true,
    /** 上一次「按计划」执行对应的计划时刻（毫秒）；防止同一次重复执行 */
    val lastRunAt: Long = 0L,
    val lastNotifyDay: String? = null,
    val runs: List<TaskRun> = emptyList(),
) {
    val timeText: String get() = "%02d:%02d".format(hour, minute)

    /** 「每天 08:00」「工作日 08:00」「每周一、三 09:30」「6月3日 07:00」 */
    val whenText: String
        get() {
            onceDate?.let { d ->
                val date = runCatching { LocalDate.parse(d) }.getOrNull()
                return (date?.let { "${it.monthValue}月${it.dayOfMonth}日" } ?: d) + " $timeText"
            }
            val label = when (days) {
                ALL_DAYS -> "每天"
                0b0011111 -> "工作日"
                0b1100000 -> "周末"
                else -> "每周" + (0..6).filter { (days shr it) and 1 == 1 }.joinToString("、") { WEEK[it] }
            }
            return "$label $timeText"
        }

    companion object {
        const val ALL_DAYS = 0x7F
        private val WEEK = listOf("一", "二", "三", "四", "五", "六", "日")

        /** 1 = 周一 … 7 = 周日 的列表转掩码；空 = 每天 */
        fun maskOf(days: List<Int>): Int {
            val m = days.filter { it in 1..7 }.fold(0) { acc, d -> acc or (1 shl (d - 1)) }
            return if (m == 0) ALL_DAYS else m
        }
    }
}

/** 计划时间的计算 */
object TaskTime {
    private fun at(task: AssistantTask, date: LocalDate, zone: ZoneId): Long =
        date.atTime(task.hour, task.minute).atZone(zone).toInstant().toEpochMilli()

    private fun matches(task: AssistantTask, date: LocalDate): Boolean =
        task.onceDate?.let { it == date.toString() } ?: (((task.days shr (date.dayOfWeek.value - 1)) and 1) == 1)

    /** 严格晚于 [now] 的下一次计划时刻；没有返回 null */
    fun next(task: AssistantTask, now: Long, zone: ZoneId = ZoneId.systemDefault()): Long? {
        val today = LocalDate.now(zone)
        for (i in 0..8) {
            val d = today.plusDays(i.toLong())
            if (!matches(task, d)) continue
            val t = at(task, d, zone)
            if (t > now) return t
        }
        return null
    }

    /** 已经到点、还没执行过、且没晚太久（[LATE_MS] 内）的最近一次计划时刻；没有返回 null */
    fun lastDue(task: AssistantTask, now: Long, zone: ZoneId = ZoneId.systemDefault()): Long? {
        val today = LocalDate.now(zone)
        for (i in 0 downTo -1) {
            val d = today.plusDays(i.toLong())
            if (!matches(task, d)) continue
            val t = at(task, d, zone)
            if (t > now) continue
            return t.takeIf { it > task.lastRunAt && now - it <= LATE_MS }
        }
        return null
    }

    private const val LATE_MS = 3 * 3_600_000L
}

/** 助手任务清单：存在应用私有目录；有变化时通知调度器重新排闹钟 */
class AssistantTasks(context: Context, private val onChanged: () -> Unit = {}) {
    private val file = File(context.filesDir, "assistant_tasks.json")
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true }
    private val _state = MutableStateFlow(load())
    val state: StateFlow<List<AssistantTask>> = _state.asStateFlow()

    @Synchronized
    fun add(task: AssistantTask): Result<AssistantTask> {
        if (_state.value.size >= MAX_TASKS) return Result.failure(IllegalStateException("助手任务最多 $MAX_TASKS 个，先删掉一些"))
        publish(_state.value + task)
        return Result.success(task)
    }

    @Synchronized
    fun update(id: String, change: (AssistantTask) -> AssistantTask) {
        if (_state.value.none { it.id == id }) return
        publish(_state.value.map { if (it.id == id) change(it) else it })
    }

    @Synchronized
    fun remove(id: String) = publish(_state.value.filterNot { it.id == id })

    fun get(id: String): AssistantTask? = _state.value.firstOrNull { it.id == id }

    @Synchronized
    fun addRun(id: String, run: TaskRun) = update(id) { it.copy(runs = (listOf(run) + it.runs).take(MAX_RUNS)) }

    private fun publish(list: List<AssistantTask>) {
        _state.value = list
        runCatching { file.writeText(json.encodeToString(list)) }
        onChanged()
    }

    private fun load(): List<AssistantTask> = runCatching {
        if (!file.isFile) emptyList() else json.decodeFromString<List<AssistantTask>>(file.readText())
    }.getOrDefault(emptyList())

    private companion object {
        const val MAX_TASKS = 20
        const val MAX_RUNS = 10
    }
}
