package com.carpe.ideashell.ui.search

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.Companion.APPLICATION_KEY
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.carpe.ideashell.AppContainer
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.core.parse.TodoMeta
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.dida.TodoData
import com.carpe.ideashell.data.ideashell.NoteInfo
import com.carpe.ideashell.data.mcp.McpAuthException
import com.carpe.ideashell.data.project.Project
import com.carpe.ideashell.data.project.Workspace
import com.carpe.ideashell.ui.review.Async
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** 搜索：项目与待办在本机即时过滤；笔记走闪念贝壳的语义搜索（回车才发起） */
class SearchViewModel(private val container: AppContainer) : ViewModel() {
    val ideashellConnected: StateFlow<Boolean> = container.credentials.ideashellConnected
    val todoData: StateFlow<TodoData> = container.todos.state
    val workspace: StateFlow<Workspace> = container.projects.workspace

    var query by mutableStateOf("")

    /** 最近一次真正发起的笔记搜索词 */
    var submitted by mutableStateOf("")
        private set

    val recent = mutableStateListOf<String>()

    private val _notes = MutableStateFlow(Async<List<NoteInfo>>())
    val notes: StateFlow<Async<List<NoteInfo>>> = _notes.asStateFlow()
    private var job: Job? = null

    fun submit(text: String = query) {
        val q = text.trim()
        if (q.isEmpty()) return
        query = q
        submitted = q
        recent.remove(q)
        recent.add(0, q)
        while (recent.size > MAX_RECENT) recent.removeAt(recent.lastIndex)
        job?.cancel()
        _notes.value = Async(loading = true)
        job = viewModelScope.launch {
            _notes.value = try {
                Async(data = container.notes.search(q))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Async(
                    error = if (e is McpAuthException) {
                        "闪念贝壳 API Key 无效或已失效，请到「连接与诊断」重新填写"
                    } else {
                        e.message ?: "搜索失败"
                    },
                )
            }
        }
    }

    fun clear() {
        query = ""
        submitted = ""
        job?.cancel()
        _notes.value = Async()
    }

    fun clearRecent() = recent.clear()

    /** 项目：关键词或标签含搜索词 */
    fun matchProjects(q: String, projects: List<Project>): List<Project> {
        val k = q.trim().lowercase()
        if (k.isEmpty()) return emptyList()
        return projects.filter { p -> p.terms.any { it.lowercase().contains(k) } }
    }

    /** 待办：标题 / 备注 / 标签含搜索词（未完成的在前） */
    fun matchTasks(q: String, data: TodoData): List<DidaTask> {
        val k = q.trim().lowercase()
        val o = data.overview ?: return emptyList()
        if (k.isEmpty()) return emptyList()
        return (o.overdue + o.upcoming + o.undated + o.done)
            .filter { t ->
                TodoMeta.cleanTitle(t.title).lowercase().contains(k) ||
                    t.content.lowercase().contains(k) ||
                    t.tags.any { it.lowercase().contains(k) }
            }
            .distinctBy { it.id }
            .sortedBy { it.done }
    }

    companion object {
        private const val MAX_RECENT = 6

        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = this[APPLICATION_KEY] as IdeashellApp
                SearchViewModel(app.container)
            }
        }
    }
}
