package com.carpe.ideashell.data.project

import com.carpe.ideashell.core.template.Template
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import com.carpe.ideashell.data.dida.calendarEventKey
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

/** 项目状态：搁置的项目不再提醒 */
@Serializable
enum class ProjectStatus(val label: String) {
    ACTIVE("进行中"),
    SHORT("短期"),
    LONG("长期"),
    PAUSED("搁置"),
}

/**
 * 项目：用关键词 / 标签钉住的一件事。「什么算这件事」完全由关键词和标签定义，不做任何自动归类。
 */
@Serializable
data class Project(
    val keyword: String,
    val addedAt: Long = System.currentTimeMillis(),
    /** 超过这么多天没提及，就提示「该记一条了」 */
    val staleDays: Int = 7,
    val status: ProjectStatus = ProjectStatus.ACTIVE,
    /** 用户手写的「下一步」 */
    val next: String = "",
    /** 额外挂的标签：关键词 + 这些标签一起定义「什么算这件事」 */
    val tags: List<String> = emptyList(),
) {
    /** 全部检索词：关键词 + 标签（去重，忽略大小写） */
    val terms: List<String>
        get() {
            val seen = HashSet<String>()
            return (listOf(keyword) + tags).map { it.trim() }.filter { it.isNotEmpty() && seen.add(it.lowercase()) }
        }

    /**
     * 任务属于这个项目吗？任一检索词满足下面之一：
     * - 和任务的某个标签完全相同（忽略大小写和 `#`）；
     * - 标题里写了 `#检索词`（后面不是文字 / 数字，`#篆刻 阳刻` 算，`#篆刻学习` 不算）；
     * - 检索词至少 [MIN_TERM_LENGTH] 个字，并出现在标题里；英文 / 数字检索词要整词出现（`go` 不匹配 `google`）。
     * 单个字的检索词（以前建的「读」「书」）只靠前两条，不再按子串匹配，免得吞掉一大批无关任务。
     */
    fun matches(content: String, taskTags: List<String> = emptyList()): Boolean {
        val text = content.lowercase()
        val tagSet = taskTags.map { it.lowercase().trimStart('#') }.toSet()
        return terms.any { term -> termMatches(term.lowercase(), text, tagSet) }
    }

    companion object {
        /** 项目关键词 / 标签至少这么长，才允许按「出现在标题里」匹配（也是新建时的最短长度） */
        const val MIN_TERM_LENGTH = 2

        private fun termMatches(term: String, text: String, tagSet: Set<String>): Boolean {
            if (term in tagSet) return true
            if (hashMention(text, term)) return true
            if (term.length < MIN_TERM_LENGTH) return false
            return if (term.all { it.code < 128 && it.isLetterOrDigit() }) containsWord(text, term) else text.contains(term)
        }

        private fun hashMention(text: String, term: String): Boolean {
            var from = 0
            while (true) {
                val i = text.indexOf("#$term", from)
                if (i < 0) return false
                val end = i + 1 + term.length
                val next = text.getOrNull(end)
                if (next == null || !(next.isLetterOrDigit() || next == '_')) return true
                from = i + 1
            }
        }

        /** 英文 / 数字词整词出现：前后不能紧挨着别的英文字母或数字（紧挨汉字没关系） */
        private fun containsWord(text: String, term: String): Boolean {
            fun isAsciiWordChar(c: Char?) = c != null && c.code < 128 && c.isLetterOrDigit()
            var from = 0
            while (true) {
                val i = text.indexOf(term, from)
                if (i < 0) return false
                if (!isAsciiWordChar(text.getOrNull(i - 1)) && !isAsciiWordChar(text.getOrNull(i + term.length))) return true
                from = i + 1
            }
        }
    }
}

/** 待办属于哪个项目：文字里含项目关键词或其标签（取第一个命中的） */
fun List<Project>.firstMatching(content: String, tags: List<String> = emptyList()): Project? =
    firstOrNull { it.matches(content, tags) }

/** 任务 ↔ 任务笔记的对应关系（本地只记这个，笔记本身在闪念贝壳里，可丢弃重建） */
@Serializable
data class TaskNoteRef(
    val noteId: String,
    val deliverable: String,
    val project: String? = null,
    val createdAt: Long = System.currentTimeMillis(),
    /** 任务完成后，笔记里的进展已经移到项目主页的「里程碑与进展」：不再出现在项目页的任务笔记列表里，但仍算已交付的成果 */
    val archived: Boolean = false,
    /** 任务笔记「复盘」小节里的总结已经汇到项目主页的里程碑（旧数据没汇过，打开项目页时补一次） */
    val reviewSynced: Boolean = false,
)

/** 从某个项目发起的一次专注（本机留一份：没有绑定任务的专注滴答里按任务才查得到，统计项目专注时要靠它） */
@Serializable
data class ProjectFocusLog(
    val project: String,
    val startMs: Long,
    val endMs: Long,
    val taskId: String? = null,
    val title: String = "",
)

/** 本机记住今天已打过卡的习惯（接口返回解析不出来时的兜底） */
@Serializable
data class HabitDone(val stamp: Int = 0, val ids: List<String> = emptyList())

/** 项目 / 任务笔记 / 模板 / 习惯打卡兜底：本机的小数据，全部可丢弃重建 */
@Serializable
data class Workspace(
    val projects: List<Project> = emptyList(),
    /** 键为任务 key：`dida:<任务 id>` */
    val taskNotes: Map<String, TaskNoteRef> = emptyMap(),
    /** 项目关键词 → 项目主页笔记 id */
    val homes: Map<String, String> = emptyMap(),
    val templates: List<Template> = emptyList(),
    val habitDone: HabitDone = HabitDone(),
    val focusLog: List<ProjectFocusLog> = emptyList(),
)

/** 单个 JSON 文件持久化的 [Workspace]；读取同步（文件很小），写入放后台线程 */
class WorkspaceStore(private val file: File, private val scope: CoroutineScope) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val _state = MutableStateFlow(load())
    val state: StateFlow<Workspace> = _state.asStateFlow()
    val current: Workspace get() = _state.value

    private val writeLock = Any()

    fun update(transform: (Workspace) -> Workspace) {
        _state.update(transform)
        scope.launch(Dispatchers.IO) {
            synchronized(writeLock) {
                runCatching { file.writeText(json.encodeToString(Workspace.serializer(), _state.value)) }
            }
        }
    }

    private fun load(): Workspace =
        runCatching { json.decodeFromString(Workspace.serializer(), file.readText()) }.getOrDefault(Workspace())
}

fun noteUrl(noteId: String): String = "https://ideashell.site/boards/$noteId"

fun taskKeyOf(taskId: String): String =
    // 日历事件：重复事件的每一次共用同一篇任务笔记
    if (taskId.startsWith("cal:")) calendarEventKey(taskId) else "dida:$taskId"
