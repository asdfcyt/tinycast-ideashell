package com.carpe.ideashell.data.project

import com.carpe.ideashell.core.notes.NoteSections
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.data.capture.CaptureRepository
import com.carpe.ideashell.data.capture.SubmitReceipt
import com.carpe.ideashell.data.dida.DaySummaryService
import com.carpe.ideashell.data.dida.DidaApi
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.dida.FocusParser
import com.carpe.ideashell.data.dida.FocusSummary
import com.carpe.ideashell.data.dida.HabitRepository
import com.carpe.ideashell.data.ideashell.IdeashellApi
import com.carpe.ideashell.data.notes.NotesRepository
import com.carpe.ideashell.domain.Dossier
import com.carpe.ideashell.domain.NoteText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.time.LocalDate

fun didaTaskUrl(projectId: String, taskId: String) = "https://dida365.com/webapp/#p/$projectId/tasks/$taskId"

/** 项目统计（随时可丢弃重建，只留在内存里） */
data class ProjectStats(
    val keyword: String,
    val at: Long,
    /** 最近一次提及的日期；没有记录为 null */
    val lastDay: LocalDate?,
    val lastTitle: String,
    val count30: Int,
    val total: Int,
    /** 近 12 个月每月提及的笔记数 */
    val series: List<Int>,
    /** Markdown 简报（可复制） */
    val brief: String,
)

/** 一条任务笔记（任务 id + 对应关系） */
data class TaskNoteEntry(val taskKey: String, val ref: TaskNoteRef) {
    val taskId: String get() = taskKey.removePrefix("dida:")
}

class LogResult(val receipt: SubmitReceipt, val habit: String?)

/**
 * 项目 / 任务笔记（防弹笔记法）：一个任务，一条笔记；笔记的单位是「要交付的成果」。
 * 项目主页笔记把项目的所有任务笔记、资料、进展汇到一处。
 * 它们都只是普通的闪念贝壳笔记，本地只记「任务 ↔ 笔记 id」「项目 ↔ 主页笔记 id」，可丢弃重建。
 */
class ProjectService(
    private val ideashell: IdeashellApi,
    private val dida: DidaApi,
    private val notes: NotesRepository,
    private val captures: CaptureRepository,
    private val habits: HabitRepository,
    private val daySummary: DaySummaryService,
    private val store: WorkspaceStore,
    private val hasDida: () -> Boolean,
) {
    val workspace: StateFlow<Workspace> = store.state

    private val _stats = MutableStateFlow<Map<String, ProjectStats>>(emptyMap())
    val stats: StateFlow<Map<String, ProjectStats>> = _stats.asStateFlow()

    // ───────────── 项目列表 ─────────────

    val projects: List<Project> get() = store.current.projects

    /** 新增项目；已存在（忽略大小写）返回 false */
    fun add(keyword: String, tags: List<String> = emptyList()): Boolean {
        val k = keyword.trim().trimStart('#')
        if (k.isEmpty() || projects.any { it.keyword.equals(k, ignoreCase = true) }) return false
        store.update { it.copy(projects = it.projects + Project(keyword = k, tags = tags.filterNot { t -> t.equals(k, true) })) }
        return true
    }

    fun remove(keyword: String) {
        store.update { w ->
            w.copy(
                projects = w.projects.filterNot { it.keyword == keyword },
                homes = w.homes - keyword,
            )
        }
        _stats.update { it - keyword }
    }

    private fun edit(keyword: String, change: (Project) -> Project) {
        store.update { w -> w.copy(projects = w.projects.map { if (it.keyword == keyword) change(it) else it }) }
    }

    fun setStaleDays(keyword: String, days: Int) = edit(keyword) { it.copy(staleDays = days) }
    fun setStatus(keyword: String, status: ProjectStatus) = edit(keyword) { it.copy(status = status) }
    fun setNext(keyword: String, next: String) = edit(keyword) { it.copy(next = next.trim()) }
    fun setTags(keyword: String, tags: List<String>) = edit(keyword) { p ->
        p.copy(tags = tags.map { it.trim().trimStart('#') }.filter { it.isNotEmpty() && !it.equals(p.keyword, true) }.distinct())
    }

    /** 待办属于哪个项目：文字里含项目关键词或其标签（取第一个命中的） */
    fun projectOf(task: DidaTask): Project? = projectOf(task.title, task.tags)

    fun projectOf(content: String, tags: List<String> = emptyList()): Project? =
        projects.firstMatching(content, tags)

    // ───────────── 项目统计 ─────────────

    /** 重新统计一个项目：关键词和标签各检索一次再合并 */
    suspend fun refreshStats(p: Project, today: LocalDate = LocalDate.now()): ProjectStats {
        val datas = p.terms.map { notes.dossier(it, today) }
        val direct = datas.flatMap { it.direct }
            .groupBy { it.note.id }
            .map { (_, list) -> list.first() }
            .filter { it.day != null }
            .sortedByDescending { it.note.createdAt.orEmpty() }
        val days = direct.mapNotNull { it.day }
        val stats = ProjectStats(
            keyword = p.keyword,
            at = System.currentTimeMillis(),
            lastDay = days.firstOrNull(),
            lastTitle = direct.firstOrNull()?.note?.title.orEmpty(),
            count30 = days.count { Dossier.daysBetween(it, today) <= 30 },
            total = days.size,
            series = Dossier.monthlySeries(days, today).second,
            brief = datas.firstOrNull()?.brief.orEmpty(),
        )
        _stats.update { it + (p.keyword to stats) }
        return stats
    }

    /** 距上次提及的天数；没有统计或没有记录为 null */
    fun gapDays(p: Project, today: LocalDate = LocalDate.now()): Int? =
        _stats.value[p.keyword]?.lastDay?.let { Dossier.daysBetween(it, today) }

    /** 超过提醒天数没提及；搁置的项目不提醒 */
    fun isStale(p: Project, today: LocalDate = LocalDate.now()): Boolean {
        if (p.status == ProjectStatus.PAUSED) return false
        val gap = gapDays(p, today) ?: return false
        return gap >= p.staleDays
    }

    /** 项目「记一条」：保存为一条独立的带项目标签的笔记（不写入 Daily Note），并给同名习惯打卡 */
    suspend fun log(p: Project, text: String): LogResult {
        val body = text.trim()
        val title = NoteText.truncate(body.lines().firstOrNull().orEmpty(), 30)
        val receipt = captures.submitNote(title, body, p.terms, null, "项目「${p.keyword}」", "app")
        return LogResult(receipt, habits.autoCheckinByName(p.keyword))
    }

    // ───────────── 任务笔记 ─────────────

    fun taskNote(taskId: String): TaskNoteRef? = store.current.taskNotes[taskKeyOf(taskId)]

    fun taskNotesOf(p: Project): List<TaskNoteEntry> {
        val terms = p.terms.map { it.lowercase() }
        return store.current.taskNotes.entries
            .filter { (_, r) -> r.project != null && r.project.lowercase() in terms }
            .map { TaskNoteEntry(it.key, it.value) }
            .sortedByDescending { it.ref.createdAt }
    }

    private fun noteIdOf(created: String): String =
        (RE_NOTE_ID_JSON.find(created) ?: RE_NOTE_ID_TEXT.find(created) ?: RE_NOTE_ID_HEX.find(created))?.groupValues?.get(1)
            ?: error("没有从创建结果里取到笔记 id：${created.take(100)}")

    suspend fun createTaskNote(task: DidaTask, deliverable: String, purpose: String, steps: String): TaskNoteRef {
        val project = projectOf(task)?.keyword
        val goal = deliverable.trim()
        val body = NoteSections.taskNoteBody(
            NoteSections.TaskNoteInput(
                taskTitle = TodoMeta.cleanTitle(task.title),
                deliverable = goal,
                purpose = purpose,
                steps = steps,
                project = project,
                taskLink = didaTaskUrl(task.projectId, task.id),
            ),
        )
        val created = ideashell.createNote(
            title = NoteText.truncate(goal, 30),
            body = body,
            tags = listOf("任务笔记") + listOfNotNull(project),
        )
        val ref = TaskNoteRef(noteId = noteIdOf(created), deliverable = goal, project = project)
        store.update { it.copy(taskNotes = it.taskNotes + (taskKeyOf(task.id) to ref)) }

        // 笔记链接写回滴答任务，在滴答里也能找到它（失败不影响主流程）
        val line = "任务笔记：${noteUrl(ref.noteId)}"
        softly { dida.setContent(task, if (task.content.isNotBlank()) "${task.content}\n$line" else line) }
        if (project != null) softly { syncHomeLinks(project) }
        return ref
    }

    /** 在任务笔记的「进展记录」里追加一条，并同步成滴答任务上的一条评论 */
    suspend fun addProgress(noteId: String, text: String, task: DidaTask?): Boolean {
        val line = text.trim()
        editNote(noteId, "进展记录") { old -> "$old${if (old.isNotEmpty()) "\n" else ""}- ${NoteSections.minuteStamp()} $line" }
        return task != null && comment(task.projectId, task.id, "进展：$line")
    }

    suspend fun addReview(noteId: String, text: String) {
        editNote(noteId, "复盘") { old ->
            "$old${if (old.isNotEmpty()) "\n\n" else ""}${NoteSections.minuteStamp()}：${text.trim()}"
        }
    }

    /** 任务完成后：属于项目的，自动在项目主页「里程碑与进展」记一行；有复盘就写进任务笔记（或单独存一条复盘笔记）。返回提示语 */
    suspend fun afterComplete(task: DidaTask, review: String): String {
        val ref = taskNote(task.id)
        val project = projectOf(task)
        if (project != null) {
            softly {
                recordMilestone(
                    project.keyword,
                    NoteSections.milestoneText(TodoMeta.cleanTitle(task.title), ref?.deliverable, ref?.let { noteUrl(it.noteId) }),
                )
            }
        }
        val text = review.trim()
        if (text.isEmpty()) return "已完成"
        val synced = softly { comment(task.projectId, task.id, "复盘：$text") } == true
        val suffix = if (synced) "（已同步到滴答评论）" else ""
        return if (ref != null) {
            addReview(ref.noteId, text)
            "已完成 · 复盘已写入任务笔记$suffix"
        } else {
            val tags = listOf("复盘") + listOfNotNull(project?.keyword)
            val receipt = captures.submitNote(
                title = NoteText.truncate("完成复盘：${TodoMeta.cleanTitle(task.title)}", 30),
                body = "完成复盘：${TodoMeta.cleanTitle(task.title)}\n\n$text",
                tags = tags,
                folderName = null,
                label = "复盘笔记",
                origin = "app",
            )
            "已完成 · 复盘已保存（${receipt.detail}）$suffix"
        }
    }

    private suspend fun comment(projectId: String, taskId: String, text: String): Boolean {
        if (!hasDida()) return false
        return try {
            dida.addComment(projectId, taskId, text)
            true
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            false
        }
    }

    // ───────────── 项目主页笔记 ─────────────

    fun homeOf(keyword: String): String? = store.current.homes[keyword]

    private fun taskNoteLinks(entries: List<TaskNoteEntry>): String =
        entries.joinToString("\n") { "- [${it.ref.deliverable}](${noteUrl(it.ref.noteId)})" }

    // ───────────── 自动发现（以笔记 / 滴答任务内容为准，与桌面端互通） ─────────────

    private fun tagKey(t: String) = t.trim().trimStart('#').trim().lowercase()

    private fun homeTitle(keyword: String) = NoteText.truncate("$keyword 项目主页", 30)

    /**
     * 在闪念贝壳里找项目主页笔记：标题是「<关键词> 项目主页」，或同时带「项目主页」与关键词两个标签。
     * 找到就记到本机，下次直接用；找不到（或网络失败）返回 null。
     */
    suspend fun findHome(keyword: String): String? {
        val list = softly { ideashell.searchNotes("$keyword 项目主页", 20) } ?: return null
        val title = homeTitle(keyword)
        val kw = tagKey(keyword)
        val hit = list.firstOrNull { it.title.trim() == title }
            ?: list.firstOrNull { n ->
                val tags = n.tags.map(::tagKey)
                "项目主页" in tags && kw in tags
            }
        if (hit != null) store.update { it.copy(homes = it.homes + (keyword to hit.id)) }
        return hit?.id
    }

    /** 项目主页笔记 id：先看本机记录，没有再去笔记里找 */
    suspend fun resolveHome(keyword: String): String? = homeOf(keyword) ?: findHome(keyword)

    /** 把闪念贝壳里已有的「项目主页」笔记（比如在桌面端建的）导入为项目；返回新增的个数 */
    suspend fun discoverProjects(): Int {
        val list = softly { ideashell.searchNotes("项目主页", 20) } ?: return 0
        var added = 0
        for (n in list) {
            val tags = n.tags.map { it.trim().trimStart('#').trim() }.filter { it.isNotEmpty() }
            val suffix = " 项目主页"
            val isHome = "项目主页" in tags || n.title.trim().endsWith(suffix)
            if (!isHome) continue
            val keyword = tags.firstOrNull { it != "项目主页" } ?: n.title.trim().removeSuffix(suffix).trim()
            if (keyword.isEmpty() || projects.any { it.keyword.equals(keyword, ignoreCase = true) }) continue
            if (add(keyword)) {
                store.update { it.copy(homes = it.homes + (keyword to n.id)) }
                added++
            }
        }
        return added
    }

    private val restoreTried = HashSet<String>()

    /**
     * 从滴答任务内容里的「任务笔记：<链接>」恢复本机没有的「任务 ↔ 笔记」对应关系
     * （比如桌面端建的任务笔记）。返回恢复的条数。
     */
    suspend fun restoreTaskNotes(tasks: List<DidaTask>): Int {
        val known = store.current.taskNotes
        val todo = tasks.mapNotNull { t ->
            val key = taskKeyOf(t.id)
            if (key in known || key in restoreTried) return@mapNotNull null
            val id = RE_TASK_NOTE_LINK.find(t.content)?.groupValues?.get(1) ?: return@mapNotNull null
            Triple(key, id, t)
        }.take(20)
        if (todo.isEmpty()) return 0
        todo.forEach { restoreTried += it.first }
        val found = coroutineScope {
            todo.map { (key, id, _) ->
                async {
                    val d = softly { ideashell.noteFull(id) } ?: return@async null
                    val project = d.tags.map { it.trim().trimStart('#').trim() }.firstOrNull { it.isNotEmpty() && it != "任务笔记" }
                    key to TaskNoteRef(noteId = id, deliverable = d.title.ifBlank { "任务笔记" }, project = project)
                }
            }.awaitAll().filterNotNull()
        }
        if (found.isNotEmpty()) store.update { it.copy(taskNotes = it.taskNotes + found) }
        return found.size
    }

    suspend fun createHome(p: Project): String {
        // 已经有了（比如在桌面端建过）就直接用，不重复创建
        findHome(p.keyword)?.let { return it }
        val links = taskNoteLinks(taskNotesOf(p))
        val created = ideashell.createNote(
            title = homeTitle(p.keyword),
            body = NoteSections.projectHomeBody(p.keyword, p.tags, links),
            tags = listOf("项目主页", p.keyword),
        )
        val id = noteIdOf(created)
        store.update { it.copy(homes = it.homes + (p.keyword to id)) }
        return id
    }

    /** 只刷新项目主页里「任务笔记（自动汇总）」小节 */
    private suspend fun syncHomeLinks(keyword: String) {
        val p = projects.firstOrNull { it.keyword == keyword } ?: return
        val homeId = resolveHome(keyword) ?: return
        val links = taskNoteLinks(taskNotesOf(p))
        editNote(homeId, "任务笔记（自动汇总）") { links.ifEmpty { "（还没有任务笔记）" } }
    }

    /** 在项目主页「里程碑与进展」追加一行；没有项目主页就什么都不做 */
    private suspend fun recordMilestone(keyword: String, text: String) {
        val homeId = resolveHome(keyword) ?: return
        editNote(homeId, "里程碑与进展") { old -> "$old${if (old.isNotEmpty()) "\n" else ""}- ${NoteSections.minuteStamp()} $text" }
    }

    /**
     * 项目主页自动汇总：每个成果的状态、步骤进度、近 7 天专注，以及项目的下一步，写进主页笔记的两个小节。
     * 全部是精确读取（任务状态 / `- [x]` 计数 / 专注记录），没有任何猜测。
     */
    suspend fun refreshSummary(p: Project, today: LocalDate = LocalDate.now()) {
        val homeId = resolveHome(p.keyword) ?: error("还没有项目主页笔记")
        val focus: FocusSummary? = softly { daySummary.focus(today) }
        val entries = taskNotesOf(p).take(15)

        class Row(val line: String, val open: Boolean, val delivered: Boolean, val min: Int)

        val rows = coroutineScope {
            entries.map { e ->
                async {
                    val state = if (hasDida()) softly { dida.fetchTask(e.taskId) }?.let { if (it.done) "done" else "open" } else null
                    val detail = softly { ideashell.noteDetail(e.ref.noteId) }
                    val progress = detail?.let { NoteSections.stepProgress(it.content) }
                    val min = focus?.byTask?.get(e.taskId)?.weekMin ?: 0
                    val parts = mutableListOf(
                        when (state) {
                            "done" -> "已交付"
                            "open" -> "进行中"
                            else -> "状态未知"
                        },
                    )
                    if (progress != null) parts += "步骤 ${progress.first}/${progress.second}"
                    if (min > 0) parts += "近 7 天专注 ${FocusParser.formatMinutes(min)}"
                    Row(
                        line = "- [${e.ref.deliverable}](${noteUrl(e.ref.noteId)}) · ${parts.joinToString(" · ")}",
                        open = state != "done",
                        delivered = state == "done",
                        min = min,
                    )
                }
            }.awaitAll()
        }
        val open = rows.count { it.open }
        val delivered = rows.count { it.delivered }
        val weekMin = rows.sumOf { it.min }

        val status = listOf(
            "更新于 $today",
            "- 下一步：${p.next.ifEmpty { "（还没写，在项目页设置）" }}",
            "- 成果：进行中 $open · 已交付 $delivered",
            "- 近 7 天专注（成果相关任务）：${if (weekMin > 0) FocusParser.formatMinutes(weekMin) else "无"}",
        ).joinToString("\n")

        val detail = ideashell.noteDetail(homeId)
        var content = detail.content
        content = NoteSections.editSection(content, "任务笔记（自动汇总）") { rows.joinToString("\n") { it.line }.ifEmpty { "（还没有任务笔记）" } }
        content = NoteSections.editSection(content, "项目状态（自动汇总）") { status }
        ideashell.updateNoteBody(homeId, content)
    }

    // ───────────── 笔记小节读写 ─────────────

    private suspend fun editNote(noteId: String, section: String, fn: (String) -> String) {
        val detail = ideashell.noteDetail(noteId)
        ideashell.updateNoteBody(noteId, NoteSections.editSection(detail.content, section, fn))
    }

    private suspend fun <T> softly(block: suspend () -> T): T? = try {
        block()
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    private companion object {
        val RE_TASK_NOTE_LINK = Regex("任务笔记[：:]\\s*https?://[^\\s/]+/boards/([a-f0-9]+)", RegexOption.IGNORE_CASE)
        val RE_NOTE_ID_JSON = Regex("\"note_id\"\\s*:\\s*\"([^\"]+)\"")
        val RE_NOTE_ID_TEXT = Regex("note_id[:\\s]+([0-9a-f]{16,})", RegexOption.IGNORE_CASE)
        val RE_NOTE_ID_HEX = Regex("([a-f0-9]{32})", RegexOption.IGNORE_CASE)
    }
}
