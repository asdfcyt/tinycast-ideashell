package com.carpe.ideashell.data.dida

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File

/** 离线时记在本机、联网后再提交给滴答的待办操作种类 */
@Serializable
enum class PendingKind { COMPLETE, REOPEN, RESCHEDULE, PRIORITY, TITLE, CONTENT, TAGS, DELETE }

/**
 * 一条还没提交到滴答的待办操作。只记「任务 id + 项目 id + 要改成什么」：
 * 提交时不需要完整任务，也就不会拿旧快照覆盖滴答上刚改过的别的字段。
 */
@Serializable
data class PendingTodoOp(
    val kind: PendingKind,
    val taskId: String,
    val projectId: String,
    val date: String? = null,
    val time: String? = null,
    val priority: Int = 0,
    val text: String? = null,
    val tags: List<String> = emptyList(),
    /** 操作发生的时刻（完成时刻也用它） */
    val at: Long = System.currentTimeMillis(),
) {
    /** 提交用的最小任务对象：接口只用得到 id 和 projectId */
    fun stub(): DidaTask = DidaTask(id = taskId, projectId = projectId, title = "")
}

/**
 * 待提交操作的队列（按发生顺序）。加入新操作时会和同一任务的旧操作合并，
 * 联网后少发请求，也避免「完成又撤销」「改了好几次期」这类操作重复提交：
 * - 删除：这个任务之前所有没提交的操作都作废；
 * - 完成 ↔ 撤销完成：互相抵消（都还没提交，等于什么都没做）；
 * - 改期 / 优先级 / 标题 / 备注 / 标签：同一个字段只留最后一次。
 */
object PendingTodoQueue {
    fun merge(queue: List<PendingTodoOp>, op: PendingTodoOp): List<PendingTodoOp> {
        val same = queue.filter { it.taskId == op.taskId }
        val rest = queue.filter { it.taskId != op.taskId }
        val merged: List<PendingTodoOp> = when (op.kind) {
            PendingKind.DELETE -> listOf(op)
            PendingKind.COMPLETE, PendingKind.REOPEN -> {
                val opposite = if (op.kind == PendingKind.COMPLETE) PendingKind.REOPEN else PendingKind.COMPLETE
                val last = same.lastOrNull { it.kind == opposite || it.kind == op.kind }
                when {
                    // 已经有一条相反的：互相抵消（只抵消最后那一条）
                    last != null && last.kind == opposite ->
                        same.toMutableList().also { it.remove(last) }
                    // 已经有一条一样的：保持一条
                    last != null -> same
                    else -> same + op
                }
            }
            else -> same.filterNot { it.kind == op.kind } + op
        }
        // 保持其他任务的相对顺序，本任务的操作放在队尾，让「先完成后改期」这类顺序不乱
        return rest + merged
    }
}

/** 队列落盘：进程被杀、重启手机后还在 */
class PendingTodoStore(private val file: File, private val json: Json) {
    fun load(): List<PendingTodoOp> =
        runCatching { json.decodeFromString(ListSerializer(PendingTodoOp.serializer()), file.readText()) }
            .getOrDefault(emptyList())

    fun save(ops: List<PendingTodoOp>) {
        runCatching {
            if (ops.isEmpty()) file.delete() else file.writeText(json.encodeToString(ListSerializer(PendingTodoOp.serializer()), ops))
        }
    }
}
