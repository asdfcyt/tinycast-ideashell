package com.carpe.ideashell.data.focus

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File
import kotlin.math.abs

/** 成果小票的本机留存：最近 300 张，点「最近完成」的任务 / 「最近专注」的记录时凭它找回小票 */
class TicketStore(private val file: File) {
    private val json = Json { ignoreUnknownKeys = true }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _items = MutableStateFlow<List<Celebration>>(emptyList())
    val items: StateFlow<List<Celebration>> = _items.asStateFlow()

    init {
        val saved = runCatching { json.decodeFromString(ListSerializer(Celebration.serializer()), file.readText()) }.getOrNull()
        if (saved != null) _items.value = saved
    }

    fun add(c: Celebration) {
        _items.update { (it + c).takeLast(MAX) }
        val snapshot = _items.value
        scope.launch {
            runCatching { file.writeText(json.encodeToString(ListSerializer(Celebration.serializer()), snapshot)) }
        }
    }

    /** 这个任务完成时的小票（同一个任务完成过多次取最近一次） */
    fun forTask(taskId: String): Celebration? =
        _items.value.lastOrNull { it.kind == Celebration.Kind.TASK && it.taskId == taskId }

    /** 这段专注的小票：开始时刻相差不到 3 分钟就算同一次（滴答读回来的时刻可能有取整） */
    fun forFocus(startMs: Long, taskId: String?): Celebration? =
        _items.value.lastOrNull {
            it.kind == Celebration.Kind.POMODORO && it.startMs > 0 && abs(it.startMs - startMs) <= 180_000L &&
                (taskId.isNullOrBlank() || it.taskId.isNullOrBlank() || it.taskId == taskId)
        }

    private companion object {
        const val MAX = 300
    }
}

