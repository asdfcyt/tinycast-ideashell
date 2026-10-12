package com.carpe.ideashell.data.capture

import com.carpe.ideashell.core.capture.CapturePlan
import com.carpe.ideashell.core.capture.CapturePlanner
import com.carpe.ideashell.core.capture.ClipBuilder
import com.carpe.ideashell.core.capture.ClipInput
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.data.db.CaptureDao
import com.carpe.ideashell.data.db.CaptureEntity
import com.carpe.ideashell.data.db.imageList
import com.carpe.ideashell.data.ideashell.FolderRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch

/** 保存后的回执，界面据此显示「已保存 · 撤销」 */
data class SubmitReceipt(
    val id: Long,
    val kind: CaptureKind,
    val summary: String,
    val detail: String,
)

/**
 * 记录入口的唯一出口：解析 → 写入离线队列（毫秒级，不碰网络）→ 安排后台同步。
 * 写入后留 [UNDO_WINDOW_MS] 的缓冲再真正同步，期间可以撤销（闪念贝壳没有删除接口，所以撤销必须发生在发送之前）。
 */
class CaptureRepository(
    private val dao: CaptureDao,
    private val folders: FolderRepository,
    private val scheduler: CaptureScheduler,
    private val processor: CaptureProcessor,
    private val scope: CoroutineScope,
) {
    val recent: Flow<List<CaptureEntity>> = dao.observeRecent(RECENT_LIMIT)

    /** 万能输入。返回 null 表示没有可保存的内容。 */
    suspend fun submitText(
        input: String,
        override: CaptureKind?,
        origin: String,
        /** 随笔记一起上传的本地图片文件；有图片时一律存为笔记（自动识别，忽略待办 / 日记），文字可以为空 */
        images: List<String> = emptyList(),
    ): SubmitReceipt? {
        if (images.isNotEmpty()) {
            // 带图片：一律存为笔记（待办和 Daily Note 都装不下图片）；文字可以为空
            val fallback = if (input.isBlank()) "图片" else input
            val plan = CapturePlanner.plan(fallback, CaptureKind.NOTE, folders.folders.value) ?: return null
            val base = entityOf(plan, origin)
            val title = if (input.isBlank()) {
                "图片 " + java.time.LocalDateTime.now().format(java.time.format.DateTimeFormatter.ofPattern("M月d日 HH:mm"))
            } else {
                base.noteTitle
            }
            return enqueue(
                base.copy(
                    noteTitle = title,
                    body = if (input.isBlank()) "" else base.body,
                    summary = title ?: base.summary,
                    detail = base.detail + " · ${images.size} 张图片",
                    images = images.joinToString("\n"),
                ),
            )
        }
        val plan = CapturePlanner.plan(input, override, folders.folders.value) ?: return null
        return enqueue(entityOf(plan, origin))
    }

    /** 分享 / 选中文字的摘录与收藏 */
    suspend fun submitClip(clip: ClipInput, annotation: String, origin: String): SubmitReceipt {
        val plan = ClipBuilder.plan(clip, annotation)
        val now = System.currentTimeMillis()
        val detail = buildString {
            append(plan.kindTag)
            clip.appName?.takeIf { it.isNotBlank() }?.let { append(" · ").append(it) }
            plan.folderName?.let { append(" · @").append(it) }
        }
        return enqueue(
            CaptureEntity(
                kind = CaptureKind.NOTE.name,
                noteTitle = plan.title,
                body = plan.body,
                todoDate = null,
                todoTime = null,
                important = false,
                tags = plan.tags.joinToString("\n"),
                folderName = plan.folderName,
                summary = plan.title,
                detail = detail,
                origin = origin,
                createdAt = now,
                readyAt = now + UNDO_WINDOW_MS,
            ),
        )
    }

    /** 直接存一条笔记（模板录入 / 项目「记一条」用）：标题、正文、标签、文件夹都已确定 */
    suspend fun submitNote(
        title: String,
        body: String,
        tags: List<String>,
        folderName: String?,
        label: String,
        origin: String,
    ): SubmitReceipt {
        val now = System.currentTimeMillis()
        val detail = buildString {
            append(label)
            folderName?.let { append(" · 📁").append(it) }
            if (tags.isNotEmpty()) append(" · ").append(tags.joinToString(" ") { "#$it" })
        }
        return enqueue(
            CaptureEntity(
                kind = CaptureKind.NOTE.name,
                noteTitle = title,
                body = body,
                todoDate = null,
                todoTime = null,
                important = false,
                tags = tags.joinToString("\n"),
                folderName = folderName,
                summary = title,
                detail = detail,
                origin = origin,
                createdAt = now,
                readyAt = now + UNDO_WINDOW_MS,
            ),
        )
    }

    /** 撤销还没开始发送的记录；返回是否成功 */
    suspend fun undo(id: Long): Boolean {
        val item = dao.get(id)
        val ok = dao.deletePending(id) > 0
        if (ok && item != null) CaptureImages.delete(item.imageList())
        return ok
    }

    /** 立即同步（跳过撤销缓冲） */
    fun syncNow() {
        scope.launch { runCatching { processor.drain() } }
    }

    /** 手动重试失败的记录 */
    suspend fun retry(id: Long) {
        if (dao.requeue(id, System.currentTimeMillis()) > 0) {
            scheduler.schedule(0)
            scope.launch { runCatching { processor.drain() } }
        }
    }

    suspend fun clearDone() = dao.clearDone()

    private suspend fun enqueue(entity: CaptureEntity): SubmitReceipt {
        val id = dao.insert(entity)
        scheduler.schedule(UNDO_WINDOW_MS)
        // 进程还活着时直接在窗口结束后同步，不依赖系统调度（国产系统上 WorkManager 可能被延后）
        scope.launch {
            delay(UNDO_WINDOW_MS + 200)
            runCatching { processor.drain() }
        }
        return SubmitReceipt(id, CaptureKind.valueOf(entity.kind), entity.summary, entity.detail)
    }

    private fun entityOf(plan: CapturePlan, origin: String): CaptureEntity {
        val now = System.currentTimeMillis()
        val detail = buildString {
            when (plan.kind) {
                CaptureKind.TODO -> {
                    append("待办 · ").append(CapturePlanner.describeWhen(plan.todoDate, plan.todoTime))
                    if (plan.important) append(" · 重要")
                }
                CaptureKind.DAILY -> append("Daily Note")
                CaptureKind.NOTE -> append("笔记")
            }
            plan.folderName?.let { append(" · 📁").append(it) }
            if (plan.tags.isNotEmpty()) append(" · ").append(plan.tags.joinToString(" ") { "#$it" })
        }
        return CaptureEntity(
            kind = plan.kind.name,
            noteTitle = if (plan.kind == CaptureKind.NOTE) plan.title else null,
            body = plan.body,
            todoDate = plan.todoDate,
            todoTime = plan.todoTime,
            important = plan.important,
            tags = plan.tags.joinToString("\n"),
            folderName = plan.folderName,
            summary = plan.title,
            detail = detail,
            origin = origin,
            createdAt = now,
            readyAt = now + UNDO_WINDOW_MS,
        )
    }

    companion object {
        /** 保存后可撤销的缓冲时间 */
        const val UNDO_WINDOW_MS = 5_000L
        private const val RECENT_LIMIT = 60
    }
}
