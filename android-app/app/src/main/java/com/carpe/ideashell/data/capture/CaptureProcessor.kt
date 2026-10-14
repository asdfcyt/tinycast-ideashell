package com.carpe.ideashell.data.capture

import com.carpe.ideashell.core.capture.truncate
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.core.parse.RepeatRule
import com.carpe.ideashell.data.db.CaptureDao
import com.carpe.ideashell.data.db.CaptureEntity
import com.carpe.ideashell.data.db.effectivePriority
import com.carpe.ideashell.data.db.imageList
import com.carpe.ideashell.data.db.tagList
import com.carpe.ideashell.data.dida.DidaApi
import com.carpe.ideashell.data.ideashell.DailyNoteService
import com.carpe.ideashell.data.ideashell.FolderRepository
import com.carpe.ideashell.data.ideashell.IdeashellApi
import com.carpe.ideashell.data.ideashell.ImageUpload
import com.carpe.ideashell.data.ideashell.TodoDraft
import com.carpe.ideashell.data.mcp.McpAuthException
import com.carpe.ideashell.data.mcp.McpException
import com.carpe.ideashell.data.mcp.McpHttpException
import com.carpe.ideashell.data.secure.CredentialStore
import com.carpe.ideashell.data.settings.SettingsStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.IOException
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId

/**
 * 把离线队列里的记录同步出去。
 * - 同一时刻只有一个同步在跑（Mutex），按记录时间先后逐条处理，保证 Daily Note 条目顺序；
 * - 每条记录的网络调用放在 NonCancellable 里：即使 WorkManager 任务被替换 / 取消，也会把这一条发完，避免重复；
 * - 断网等暂时性错误：放回队列稍后重试；凭证失效 / 服务端拒绝等：标记失败，等用户处理。
 */
class CaptureProcessor(
    private val dao: CaptureDao,
    private val credentials: CredentialStore,
    private val settings: SettingsStore,
    private val folders: FolderRepository,
    private val ideashell: IdeashellApi,
    private val dida: DidaApi,
    private val dailyNotes: DailyNoteService,
    /** 待办建到滴答后回调，用来刷新待办页 */
    private val onTodoCreated: () -> Unit = {},
    /** 同步出了问题（有失败 / 反复重试仍没发出去的记录）：参数是问题条数和最近一条的原因。只在「正常 → 异常」时回调一次 */
    private val onSyncProblem: (count: Int, reason: String?) -> Unit = { _, _ -> },
    /** 队列恢复正常（问题记录都发出去了 / 被重试成功 / 被丢弃） */
    private val onSyncHealthy: () -> Unit = {},
) {
    private val drainLock = Mutex()

    private sealed interface Outcome {
        data class Done(val text: String) : Outcome
        data class Retry(val error: String) : Outcome
        data class Fail(val error: String) : Outcome
    }

    /** 处理所有到期的记录。返回 true 表示队列里还有没发出去的（需要稍后再来一次）。 */
    suspend fun drain(): Boolean = drainLock.withLock {
        dao.resetStale(System.currentTimeMillis() - STALE_SENDING_MS)

        while (true) {
            currentCoroutineContext().ensureActive()
            val now = System.currentTimeMillis()
            val item = dao.nextReady(now) ?: break
            if (dao.claim(item.id, now) == 0) continue // 刚好被撤销

            val outcome = withContext(NonCancellable) { process(item) }
            val doneAt = System.currentTimeMillis()
            when (outcome) {
                is Outcome.Done -> dao.markDone(item.id, outcome.text, doneAt)
                is Outcome.Fail -> dao.markFailed(item.id, outcome.error, doneAt)
                is Outcome.Retry -> {
                    val attempts = item.attempts + 1
                    if (attempts >= MAX_ATTEMPTS) {
                        dao.markFailed(item.id, "多次重试仍失败：${outcome.error}", doneAt)
                    } else {
                        dao.markRetry(item.id, attempts, doneAt + retryDelay(attempts), outcome.error, doneAt)
                        break // 多半是断网，后面的也会失败，先停下
                    }
                }
            }
        }
        dao.pruneDone(KEEP_DONE)
        refreshHealth()
        dao.countUnsent() > 0
    }

    /**
     * 检查队列健康度并决定要不要提示：有失败的、或某条重试了 [ALERT_ATTEMPTS] 次还没发出去 → 提示一次；
     * 之后不再重复打扰，直到队列完全恢复正常（再出问题才会再提示）。
     */
    suspend fun refreshHealth() {
        val problems = dao.countFailed() + dao.countStuck(ALERT_ATTEMPTS)
        val alerted = settings.syncAlerted()
        if (problems == 0) {
            if (alerted) {
                settings.setSyncAlerted(false)
                runCatching { onSyncHealthy() }
            }
        } else if (!alerted) {
            settings.setSyncAlerted(true)
            runCatching { onSyncProblem(problems, dao.latestProblemError(ALERT_ATTEMPTS)) }
        }
    }

    private suspend fun process(item: CaptureEntity): Outcome =
        try {
            Outcome.Done(send(item))
        } catch (e: CancellationException) {
            throw e
        } catch (e: McpAuthException) {
            Outcome.Fail(e.message ?: "凭证无效，请在「设置 → 连接」里重新填写")
        } catch (e: McpHttpException) {
            if (e.httpCode >= 500 || e.httpCode == 429 || e.httpCode == 408) Outcome.Retry(e.message.orEmpty())
            else Outcome.Fail(e.message.orEmpty())
        } catch (e: IOException) {
            Outcome.Retry(e.message ?: "网络异常")
        } catch (e: McpException) {
            Outcome.Fail(e.message.orEmpty())
        } catch (e: Exception) {
            Outcome.Fail(e.message ?: e::class.java.simpleName)
        }

    private suspend fun send(item: CaptureEntity): String =
        when (CaptureKind.valueOf(item.kind)) {
            CaptureKind.TODO -> sendTodo(item)
            CaptureKind.DAILY -> sendDaily(item)
            CaptureKind.NOTE -> sendNote(item)
        }

    /** 待办：连接了滴答就建在滴答（没有日期 = 收集箱里的无日期任务），否则建在闪念贝壳 */
    private suspend fun sendTodo(item: CaptureEntity): String {
        if (!credentials.didaToken.isNullOrBlank()) {
            val repeat = item.repeatRule?.takeIf { it.isNotBlank() && item.todoDate != null }
            dida.createTask(item.body, item.todoDate, item.todoTime, priority = item.effectivePriority(), repeatFlag = repeat)
            runCatching { onTodoCreated() }
            val label = repeat?.let { RepeatRule.parse(it)?.label() }
            return "已建到滴答清单" + if (label != null) " · 重复：$label" else ""
        }
        val content = when (item.effectivePriority()) {
            5 -> "${item.body} !重要"
            else -> item.body
        }
        ideashell.createTodos(listOf(TodoDraft(content, item.todoDate, item.todoTime)))
        val repeatNote = if (item.repeatRule.isNullOrBlank()) "" else "，重复规则没有生效"
        return "已建到闪念贝壳待办（未连接滴答清单$repeatNote）"
    }

    private suspend fun sendDaily(item: CaptureEntity): String {
        val entry = (listOf(item.body.trim()) + item.tagList().map { "#$it" }).joinToString(" ").trim()
        val recordedAt: LocalDateTime = Instant.ofEpochMilli(item.createdAt).atZone(ZoneId.systemDefault()).toLocalDateTime()
        dailyNotes.append(entry, recordedAt)
        return "已追加到当天的 Daily Note"
    }

    /** 本地文件丢了就当没有这张图（不要因为一张图卡住整条记录） */
    private fun loadImages(paths: List<String>): List<ImageUpload> = paths.mapNotNull { path ->
        val file = java.io.File(path)
        if (file.isFile) ImageUpload(file.name, file.readBytes()) else null
    }

    private suspend fun sendNote(item: CaptureEntity): String {
        var folderId: String? = null
        var folderNote = ""
        val folderName = item.folderName
        if (folderName != null) {
            val folder = folders.resolve(folderName)
            if (folder != null) {
                folderId = folder.id
                folderNote = " 📁${folder.name}"
            } else {
                folderNote = "（文件夹「$folderName」不存在，已放在未归档）"
            }
        }
        val tags = (settings.current.defaultTags + item.tagList()).distinct()
        val title = item.noteTitle?.takeIf { it.isNotBlank() } ?: truncate(item.body.lineSequence().firstOrNull { it.isNotBlank() }.orEmpty().trim(), 30)
        val paths = item.imageList()
        val uploads = loadImages(paths)
        ideashell.createNote(title = title, body = item.body, tags = tags, folderId = folderId, images = uploads)
        CaptureImages.delete(paths)
        return "已保存为笔记$folderNote" + if (uploads.isNotEmpty()) "（${uploads.size} 张图片）" else ""
    }

    private fun retryDelay(attempt: Int): Long = minOf(30_000L * attempt, 10 * 60_000L)

    private companion object {
        const val MAX_ATTEMPTS = 10

        /** 同一条记录重试到第几次还没发出去，就算「有问题」并提示一次 */
        const val ALERT_ATTEMPTS = 3
        const val KEEP_DONE = 100
        const val STALE_SENDING_MS = 2 * 60_000L
    }
}
