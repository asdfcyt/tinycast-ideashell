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
import com.carpe.ideashell.domain.DossierNote
import com.carpe.ideashell.domain.NoteText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.withLock
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
    /** 第一次提及的日期 */
    val firstDay: LocalDate? = null,
    /** 直接提及的笔记（关键词与标签合并去重，新的在前）：项目页「提及的笔记」 */
    val mentions: List<DossierNote> = emptyList(),
    /** 语义相关但没有直接写到关键词的笔记（去重，至多 6 条） */
    val related: List<DossierNote> = emptyList(),
    /** 提及这些笔记时常带的标签 */
    val topTags: List<Pair<String, Int>> = emptyList(),
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
    /** 任务完成时回调：（任务, 它的任务笔记, 这次写的复盘）；用来给用户做完成反馈 */
    private val onTaskDone: (DidaTask, TaskNoteRef?, String) -> Unit = { _, _, _ -> },
) {
    val workspace: StateFlow<Workspace> = store.state

    private val _stats = MutableStateFlow<Map<String, ProjectStats>>(emptyMap())
    val stats: StateFlow<Map<String, ProjectStats>> = _stats.asStateFlow()

    private val _delivery = MutableStateFlow<Map<String, ProjectDelivery>>(emptyMap())

    /** 各项目的成果交付情况（项目页打开时统计，只留在内存里） */
    val delivery: StateFlow<Map<String, ProjectDelivery>> = _delivery.asStateFlow()

    private val _focusStats = MutableStateFlow<Map<String, ProjectFocusStats>>(emptyMap())

    /** 各项目的专注统计（项目页打开时统计，只留在内存里） */
    val focusStats: StateFlow<Map<String, ProjectFocusStats>> = _focusStats.asStateFlow()

    private val _monthlyFocus = MutableStateFlow<Map<String, ProjectMonthlyFocus>>(emptyMap())

    /** 各项目近 12 个月每月的专注时长（打开「近 12 个月」抽屉时统计，只留在内存里） */
    val monthlyFocus: StateFlow<Map<String, ProjectMonthlyFocus>> = _monthlyFocus.asStateFlow()

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
        _delivery.update { it - keyword }
        _focusStats.update { it - keyword }
        _monthlyFocus.update { it - keyword }
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
        val directIds = direct.map { it.note.id }.toSet()
        val related = datas.flatMap { it.related }
            .distinctBy { it.note.id }
            .filter { it.note.id !in directIds }
            .take(6)
        val tagCount = LinkedHashMap<String, Int>()
        for (d in datas) for ((t, c) in d.topTags) {
            if (p.terms.none { it.equals(t, ignoreCase = true) }) tagCount[t] = (tagCount[t] ?: 0) + c
        }
        val stats = ProjectStats(
            keyword = p.keyword,
            at = System.currentTimeMillis(),
            lastDay = days.firstOrNull(),
            lastTitle = direct.firstOrNull()?.note?.title.orEmpty(),
            count30 = days.count { Dossier.daysBetween(it, today) < 30 },
            total = days.size,
            series = Dossier.monthlySeries(days, today).second,
            brief = datas.firstOrNull()?.brief.orEmpty(),
            firstDay = days.lastOrNull(),
            mentions = direct,
            related = related,
            topTags = tagCount.entries.sortedByDescending { it.value }.take(6).map { it.key to it.value },
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
            // 笔记标题用任务本身的名字；交付成果写在正文里
            title = NoteText.truncate(TodoMeta.cleanTitle(task.title), 30),
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

    private val recordLock = kotlinx.coroutines.sync.Mutex()

    /**
     * 专注通知里的「记录」：把一句话记到当前任务。任务还没有任务笔记就先在闪念贝壳里建一条（第一次记录时创建），
     * 然后把这句话追加到笔记的「进展记录」，同时在滴答任务下追加一条评论。
     * 连点几次不会建出多条笔记（串行执行）。失败抛异常，由调用方提示。
     * @return 是否同步到了滴答评论
     */
    suspend fun recordForTask(taskId: String, text: String): Boolean = recordLock.withLock {
        val line = text.trim()
        // 要拿到完整的任务：创建任务笔记时会把笔记链接追加到任务备注里，不能用空备注覆盖
        val task = if (hasDida()) dida.fetchTask(taskId) else null
        val ref = taskNote(taskId) ?: run {
            val t = task ?: error("读不到滴答任务，无法创建任务笔记")
            val goal = TodoMeta.cleanTitle(t.title).ifBlank { t.title }
            createTaskNote(t, goal, "", "")
        }
        addProgress(ref.noteId, line, task)
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
        val text = review.trim()
        runCatching { onTaskDone(task, ref, text) }
        if (project != null) {
            if (ref != null && ref.archived && text.isNotEmpty()) {
                // 笔记已经归档过（比如重新完成）：新写的复盘也要汇到里程碑
                softly {
                    val homeId = resolveHome(project.keyword) ?: return@softly
                    appendMilestones(homeId, listOf("- ${NoteSections.minuteStamp()} 〔${ref.deliverable}〕复盘：${text.replace(Regex("\\s*\\n\\s*"), " ")}"))
                }
            } else if (ref != null) {
                // 有任务笔记：把笔记里的进展（和这次的复盘）移到「里程碑与进展」，再记一行「完成」，笔记随之归档
                softly { archiveTaskNote(project.keyword, TaskNoteEntry(taskKeyOf(task.id), ref), text) }
            } else {
                softly {
                    recordMilestone(
                        project.keyword,
                        NoteSections.milestoneText(TodoMeta.cleanTitle(task.title), null, null),
                    )
                }
            }
        }
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
                    // 笔记标题是任务名，交付成果要从正文的「交付成果」小节里读
                    val deliverable = NoteSections.sectionBody(d.content, "交付成果")
                        ?.lines()?.map { it.trim() }?.firstOrNull { it.isNotEmpty() && !NoteSections.isPlaceholderLine(it) }
                    key to TaskNoteRef(noteId = id, deliverable = deliverable ?: d.title.ifBlank { "任务笔记" }, project = project)
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

    /** 改项目主页笔记里的某个小节（[fn] 收到现有正文、返回新正文）；没有项目主页就报错 */
    suspend fun editHomeSection(keyword: String, section: String, fn: (String) -> String) {
        val homeId = resolveHome(keyword) ?: error("还没有项目主页笔记")
        editNote(homeId, section, fn)
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

    /** 往「里程碑与进展」追加若干行，正文已经有的（忽略时间戳和〔来源〕）不重复写 */
    private suspend fun appendMilestones(homeId: String, lines: List<String>) {
        if (lines.isEmpty()) return
        editNote(homeId, "里程碑与进展") { old ->
            val have = old.lines().map(NoteSections::milestoneKey).toHashSet()
            val fresh = lines.filter { have.add(NoteSections.milestoneKey(it)) }
            if (fresh.isEmpty()) old else "$old${if (old.isNotEmpty()) "\n" else ""}${fresh.joinToString("\n")}"
        }
    }

    private val archiveLock = kotlinx.coroutines.sync.Mutex()

    /**
     * 任务完成：把任务笔记「进展记录」里的每一条（和这次的复盘）移到项目主页「里程碑与进展」，再记一行「完成」，
     * 然后给笔记打上已归档标记（它不再出现在项目页的任务笔记列表里，但仍算已交付的成果）。
     * 项目还没有主页笔记时什么都不做（笔记保持原样）；读写失败抛异常，下次打开项目页会再试。
     */
    private suspend fun archiveTaskNote(keyword: String, entry: TaskNoteEntry, review: String): Boolean = archiveLock.withLock {
        val ref = store.current.taskNotes[entry.taskKey] ?: return@withLock false
        if (ref.archived) return@withLock false
        val homeId = resolveHome(keyword) ?: return@withLock false
        val tag = "〔${ref.deliverable}〕"
        val detail = ideashell.noteDetail(ref.noteId)
        val lines = mutableListOf<String>()
        // 里程碑只汇总任务笔记的「复盘」总结：笔记里已经写的复盘，加上这次完成时写的；过程中的进展记录留在任务笔记里
        for (para in NoteSections.reviewParagraphs(detail.content)) {
            val (stamp, body) = NoteSections.splitStamp(para)
            lines += "- ${stamp ?: NoteSections.minuteStamp()} ${tag}复盘：${body.replace(Regex("\\s*\\n\\s*"), " ")}"
        }
        val now = NoteSections.minuteStamp()
        if (review.isNotBlank()) lines += "- $now ${tag}复盘：${review.trim().replace(Regex("\\s*\\n\\s*"), " ")}"
        lines += "- $now ${NoteSections.milestoneText("", ref.deliverable, noteUrl(ref.noteId))}"
        appendMilestones(homeId, lines)
        store.update { w -> w.copy(taskNotes = w.taskNotes + (entry.taskKey to ref.copy(archived = true, reviewSynced = true))) }
        true
    }

    /**
     * 旧数据补齐：已经完成归档、但复盘总结没汇到里程碑的任务笔记（以前的版本不汇，或复盘是完成之后才写进笔记的），
     * 读它的「复盘」小节补一份到项目主页。每个笔记只补一次；返回是否写入了新内容（界面据此重读主页）。
     */
    suspend fun backfillReviews(p: Project): Boolean = archiveLock.withLock {
        val entries = taskNotesOf(p).filter { it.ref.archived && !it.ref.reviewSynced }.take(15)
        if (entries.isEmpty()) return@withLock false
        val homeId = resolveHome(p.keyword) ?: return@withLock false
        var wrote = false
        for (e in entries) {
            val detail = softly { ideashell.noteDetail(e.ref.noteId) } ?: continue
            val tag = "〔${e.ref.deliverable}〕"
            val lines = NoteSections.reviewParagraphs(detail.content).map { para ->
                val (stamp, body) = NoteSections.splitStamp(para)
                "- ${stamp ?: NoteSections.minuteStamp()} ${tag}复盘：${body.replace(Regex("\\s*\\n\\s*"), " ")}"
            }
            if (lines.isNotEmpty()) {
                if (softly { appendMilestones(homeId, lines) } == null) continue
                wrote = true
            }
            store.update { w ->
                val cur = w.taskNotes[e.taskKey] ?: return@update w
                w.copy(taskNotes = w.taskNotes + (e.taskKey to cur.copy(reviewSynced = true)))
            }
        }
        wrote
    }

    /**
     * 撤销完成（任务恢复为未完成）：任务笔记重新回到项目页的任务笔记列表，
     * 并把完成时写进「里程碑与进展」的「完成：…」一行和复盘一行删掉（别的进展记录保留）。
     * 失败不影响任务本身，下次完成时会重新写入。
     */
    suspend fun afterUndo(task: DidaTask) {
        val key = taskKeyOf(task.id)
        val ref = store.current.taskNotes[key]
        if (ref != null && ref.archived) store.update { w -> w.copy(taskNotes = w.taskNotes + (key to ref.copy(archived = false))) }
        val project = projectOf(task) ?: return
        val homeId = softly { resolveHome(project.keyword) } ?: return
        val title = TodoMeta.cleanTitle(task.title)
        // 完成那一行有两种写法：有任务笔记写成果名（带笔记链接），没有就写任务标题
        val doneKeys = buildSet {
            add(NoteSections.milestoneKey(NoteSections.milestoneText(title, null, null)))
            if (ref != null) add(NoteSections.milestoneKey(NoteSections.milestoneText(title, ref.deliverable, noteUrl(ref.noteId))))
        }
        val reviewPrefix = ref?.let { "〔${it.deliverable}〕复盘：" }
        softly {
            editNote(homeId, "里程碑与进展") { old ->
                old.lines().filterNot { line ->
                    val body = NoteSections.splitStamp(line).second
                    NoteSections.milestoneKey(line) in doneKeys || (reviewPrefix != null && body.startsWith(reviewPrefix))
                }.joinToString("\n")
            }
        }
    }

    /**
     * 专注通知上的「记录」：绑定了任务就记到任务笔记（并同步滴答评论）；
     * 从项目页发起的专注，还会记一行到项目主页的「里程碑与进展」（项目还没有主页笔记就先建一个）。
     * @return 任务评论是否同步到了滴答（没有绑定任务时为 true）
     */
    suspend fun recordFocus(taskId: String?, project: String?, text: String): Boolean {
        val line = text.trim()
        var synced = true
        var failure: Exception? = null
        if (!taskId.isNullOrBlank()) {
            try {
                synced = recordForTask(taskId, line)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                failure = e
            }
        }
        val p = project?.let { k -> projects.firstOrNull { it.keyword == k } }
        if (p != null) {
            try {
                val label = if (taskId.isNullOrBlank()) "专注" else taskNote(taskId)?.deliverable ?: "专注"
                recordLock.withLock {
                    val homeId = resolveHome(p.keyword) ?: createHome(p)
                    appendMilestones(homeId, listOf("- ${NoteSections.minuteStamp()} 〔$label〕${line.replace(Regex("\\s*\\n\\s*"), " ")}"))
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (failure == null) failure = e
            }
        }
        failure?.let { throw it }
        return synced
    }

    // ───────────── 项目进展：成果交付 ─────────────

    /**
     * 统计项目的成果交付情况（见 [ProjectDelivery]）。[openIds] / [doneIds] 是滴答缓存里已知的未完成 / 近期已完成任务 id，
     * 其余成果的任务再去滴答查一次状态；查不到的记为「状态未知」，不计入。
     * 顺带把已经完成、但进展还没移到「里程碑与进展」的任务笔记归档（比如在滴答里直接完成的任务）。
     */
    suspend fun refreshDelivery(p: Project, openIds: Set<String>, doneIds: Set<String>, archive: Boolean = true): ProjectDelivery {
        val entries = taskNotesOf(p).take(20)
        val items = coroutineScope {
            entries.map { e ->
                async {
                    val state = when {
                        e.ref.archived || e.taskId in doneIds -> DeliveryState.DONE
                        e.taskId in openIds -> DeliveryState.ACTIVE
                        hasDida() -> softly { dida.fetchTask(e.taskId) }?.let { if (it.done) DeliveryState.DONE else DeliveryState.ACTIVE }
                            ?: DeliveryState.UNKNOWN
                        else -> DeliveryState.UNKNOWN
                    }
                    val steps = if (state == DeliveryState.ACTIVE) {
                        softly { ideashell.noteDetail(e.ref.noteId) }?.let { NoteSections.stepProgress(it.content) }
                    } else {
                        null
                    }
                    DeliveryItem(e.ref.deliverable, e.ref.noteId, state, steps?.first ?: 0, steps?.second ?: 0)
                }
            }.awaitAll()
        }
        if (archive) {
            entries.forEachIndexed { i, e ->
                if (items[i].state == DeliveryState.DONE && !e.ref.archived) softly { archiveTaskNote(p.keyword, e, "") }
            }
        }
        val d = ProjectDelivery(p.keyword, System.currentTimeMillis(), items)
        _delivery.update { it + (p.keyword to d) }
        return d
    }

    // ───────────── 项目进展：专注 ─────────────

    /**
     * 统计项目的专注：滴答里近 [FOCUS_DAYS] 天的专注中，任务属于该项目的（[taskIds]、任务笔记对应的任务，或任务标题含项目关键词 / 标签），
     * 再加上从项目页发起的专注（本机留的记录；和滴答里同一次的按开始时间去重）。
     */
    suspend fun refreshFocus(p: Project, taskIds: Set<String>, today: LocalDate = LocalDate.now()): ProjectFocusStats {
        val zone = java.time.ZoneId.systemDefault()
        val from = today.minusDays(FOCUS_DAYS - 1L)
        val ids = taskIds + taskNotesOf(p).map { it.taskId }
        val summary = if (hasDida()) softly { daySummary.focusIn(from, today.plusDays(1), today) } else null
        val titles = summary?.titles.orEmpty()

        class Item(val start: Long, val end: Long, val title: String)

        val items = ArrayList<Item>()
        for (s in summary?.sessions.orEmpty()) {
            val title = s.title ?: s.taskId?.let { titles[it] }
            val mine = (s.taskId != null && s.taskId in ids) || (title != null && p.matches(title))
            if (mine) items += Item(s.startMs, s.endMs, TodoMeta.cleanTitle(title.orEmpty()).ifBlank { "（未命名任务）" })
        }
        val fromMs = from.atStartOfDay(zone).toInstant().toEpochMilli()
        for (l in store.current.focusLog) {
            if (l.project != p.keyword || l.startMs < fromMs) continue
            if (items.any { kotlin.math.abs(it.start - l.startMs) < 90_000L }) continue
            items += Item(l.startMs, l.endMs, TodoMeta.cleanTitle(l.title).ifBlank { "（项目专注）" })
        }

        var todayMin = 0
        var weekMin = 0
        var monthMin = 0
        var totalMin = 0
        val daily = IntArray(14)
        val active = HashSet<LocalDate>()
        val byTask = LinkedHashMap<String, Int>()
        for (i in items) {
            val day = java.time.Instant.ofEpochMilli(i.start).atZone(zone).toLocalDate()
            val m = Math.round((i.end - i.start) / 60000.0).toInt().coerceAtLeast(0)
            val ago = Dossier.daysBetween(day, today)
            totalMin += m
            if (ago <= 29) monthMin += m
            if (ago <= 6) weekMin += m
            if (ago <= 0) todayMin += m
            if (ago in 0..13) daily[13 - ago] += m
            active += day
            byTask[i.title] = (byTask[i.title] ?: 0) + m
        }
        val stats = ProjectFocusStats(
            keyword = p.keyword,
            at = System.currentTimeMillis(),
            todayMin = todayMin,
            weekMin = weekMin,
            monthMin = monthMin,
            totalMin = totalMin,
            windowDays = FOCUS_DAYS,
            count = items.size,
            daily14 = daily.toList(),
            byTask = byTask.entries.sortedByDescending { it.value }.map { it.key to it.value },
            sessions = items.sortedByDescending { it.start }.take(12).map { ProjectFocusSession(it.start, it.end, it.title) },
            activeDays = active,
        )
        _focusStats.update { it + (p.keyword to stats) }
        return stats
    }

    /**
     * 近 12 个月（含本月）每个月的专注分钟：归属规则与 [refreshFocus] 相同，
     * 按自然月逐月向滴答取数（单次范围小，也不怕被接口限制），再并入本机留的项目专注记录。
     * 滴答里取不到的月份按 0 算，不影响其它月份。
     */
    suspend fun refreshMonthlyFocus(p: Project, taskIds: Set<String>, today: LocalDate = LocalDate.now()): ProjectMonthlyFocus {
        val zone = java.time.ZoneId.systemDefault()
        val ids = taskIds + taskNotesOf(p).map { it.taskId }
        val first = today.withDayOfMonth(1).minusMonths(11)
        val tomorrow = today.plusDays(1)
        val summaries = if (hasDida()) {
            coroutineScope {
                (0..11).map { i ->
                    val s = first.plusMonths(i.toLong())
                    val e = minOf(s.plusMonths(1), tomorrow)
                    async { softly { daySummary.focusIn(s, e, today) } }
                }.awaitAll()
            }
        } else {
            emptyList()
        }

        val seen = HashSet<Long>()
        val starts = ArrayList<Pair<Long, Long>>()
        for (summary in summaries) {
            if (summary == null) continue
            for (s in summary.sessions) {
                val title = s.title ?: s.taskId?.let { summary.titles[it] }
                val mine = (s.taskId != null && s.taskId in ids) || (title != null && p.matches(title))
                if (mine && seen.add(s.startMs)) starts += s.startMs to s.endMs
            }
        }
        val fromMs = first.atStartOfDay(zone).toInstant().toEpochMilli()
        for (l in store.current.focusLog) {
            if (l.project != p.keyword || l.startMs < fromMs) continue
            if (starts.any { kotlin.math.abs(it.first - l.startMs) < 90_000L }) continue
            starts += l.startMs to l.endMs
        }

        val minutes = LinkedHashMap<String, Int>()
        for ((start, end) in starts) {
            val day = java.time.Instant.ofEpochMilli(start).atZone(zone).toLocalDate()
            val key = "%04d-%02d".format(day.year, day.monthValue)
            val m = Math.round((end - start) / 60000.0).toInt().coerceAtLeast(0)
            minutes[key] = (minutes[key] ?: 0) + m
        }
        val result = ProjectMonthlyFocus(p.keyword, System.currentTimeMillis(), minutes)
        _monthlyFocus.update { it + (p.keyword to result) }
        return result
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
        /** 项目专注统计往回看多少天 */
        const val FOCUS_DAYS = 90
        val RE_TASK_NOTE_LINK = Regex("任务笔记[：:]\\s*https?://[^\\s/]+/boards/([a-f0-9]+)", RegexOption.IGNORE_CASE)
        val RE_NOTE_ID_JSON = Regex("\"note_id\"\\s*:\\s*\"([^\"]+)\"")
        val RE_NOTE_ID_TEXT = Regex("note_id[:\\s]+([0-9a-f]{16,})", RegexOption.IGNORE_CASE)
        val RE_NOTE_ID_HEX = Regex("([a-f0-9]{32})", RegexOption.IGNORE_CASE)
    }
}
