package com.carpe.ideashell.data.project

import com.carpe.ideashell.core.template.Template
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
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

    /** 文字或标签里含任一检索词 */
    fun matches(content: String, taskTags: List<String> = emptyList()): Boolean {
        val text = content.lowercase()
        val tagSet = taskTags.map { it.lowercase() }.toSet()
        return terms.any { t -> text.contains(t.lowercase()) || t.lowercase() in tagSet }
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

fun taskKeyOf(taskId: String): String = "dida:$taskId"
