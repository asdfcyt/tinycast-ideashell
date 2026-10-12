package com.carpe.ideashell.ui.home

import androidx.compose.runtime.getValue
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
import com.carpe.ideashell.core.capture.CapturePlanner
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.core.parse.FolderInfo
import com.carpe.ideashell.core.template.Template
import com.carpe.ideashell.core.template.Templates
import com.carpe.ideashell.data.capture.SubmitReceipt
import com.carpe.ideashell.data.db.CaptureEntity
import com.carpe.ideashell.data.dida.DidaOverview
import com.carpe.ideashell.data.dida.DidaTask
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

sealed interface HomeEvent {
    data class Saved(val receipt: SubmitReceipt) : HomeEvent
    data class Message(val text: String) : HomeEvent
}

class HomeViewModel(private val container: AppContainer) : ViewModel() {
    var text by mutableStateOf("")
    var override by mutableStateOf<CaptureKind?>(null)

    val folders: StateFlow<List<FolderInfo>> = container.folders.folders
    val connected: StateFlow<Boolean> = container.credentials.ideashellConnected

    val recent: StateFlow<List<CaptureEntity>> = container.captures.recent
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private val _events = Channel<HomeEvent>(Channel.BUFFERED)
    val events: Flow<HomeEvent> = _events.receiveAsFlow()

    /** 「今天」页展示的待办（来自滴答的本地缓存，后台刷新） */
    val overview: StateFlow<DidaOverview?> = container.todos.state
        .map { it.overview }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), container.todos.state.value.overview)

    init {
        container.todos.refresh()
    }

    fun refreshTodos() = container.todos.refresh(force = true)

    fun completeTask(task: DidaTask) {
        viewModelScope.launch {
            container.todos.complete(task).onFailure {
                _events.send(HomeEvent.Message("完成失败：${it.message ?: "网络异常"}"))
            }
            container.surfaces.updateAll()
        }
    }

    /** @param readClipboard 输入「剪贴板」时由界面提供剪贴板里的文字 */
    fun submit(readClipboard: () -> String?) {
        val resolved = CapturePlanner.resolveClipboard(text, readClipboard)
        if (resolved == null) {
            _events.trySend(HomeEvent.Message("剪贴板里没有文字"))
            return
        }
        // 剪贴板内容默认存为笔记（与桌面一致）；前缀仍然优先
        val kind = override ?: if (resolved.fromClipboard) CaptureKind.NOTE else null

        viewModelScope.launch {
            val receipt = container.captures.submitText(resolved.input, kind, ORIGIN_APP)
            if (receipt == null) {
                _events.send(HomeEvent.Message("没有可保存的内容"))
                return@launch
            }
            text = ""
            override = null
            _events.send(HomeEvent.Saved(receipt))
        }
    }

    /** 内置模板 + 自定义模板（同名时自定义优先） */
    val templates: StateFlow<List<Template>> = container.workspace.state
        .map { Templates.merge(it.templates) }
        .stateIn(viewModelScope, SharingStarted.Eagerly, Templates.merge(container.workspace.current.templates))

    /** 用模板录入：标题固定「模板名 日期」，正文每个字段一段 `**字段**：值`。返回是否已保存 */
    fun submitTemplate(template: Template, values: Map<String, String>): Boolean {
        val built = Templates.buildNote(template, values)
        if (built.filled == 0) {
            _events.trySend(HomeEvent.Message("请至少填写一项"))
            return false
        }
        viewModelScope.launch {
            val receipt = container.captures.submitNote(
                title = built.title,
                body = built.body,
                tags = template.tags,
                folderName = template.folderName,
                label = "模板「${template.name}」",
                origin = ORIGIN_APP,
            )
            _events.send(HomeEvent.Saved(receipt))
        }
        return true
    }

    fun saveTemplate(template: Template, replacing: String?) {
        container.workspace.update { w ->
            val key = (replacing ?: template.name).lowercase()
            val rest = w.templates.filterNot { it.name.lowercase() == key || it.name.lowercase() == template.name.lowercase() }
            w.copy(templates = rest + template.copy(builtin = false))
        }
        _events.trySend(HomeEvent.Message("已保存模板「${template.name}」"))
    }

    fun deleteTemplate(name: String) {
        container.workspace.update { w -> w.copy(templates = w.templates.filterNot { it.name.equals(name, ignoreCase = true) }) }
        _events.trySend(HomeEvent.Message("已删除模板「$name」"))
    }

    fun undo(id: Long) {
        viewModelScope.launch {
            val ok = container.captures.undo(id)
            _events.send(HomeEvent.Message(if (ok) "已撤销" else "已经开始同步，无法撤销"))
        }
    }

    fun retry(id: Long) {
        viewModelScope.launch { container.captures.retry(id) }
    }

    fun clearDone() {
        viewModelScope.launch { container.captures.clearDone() }
    }

    private companion object {
        const val ORIGIN_APP = "app"
    }

    object Factory {
        val instance: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = this[APPLICATION_KEY] as IdeashellApp
                HomeViewModel(app.container)
            }
        }
    }
}
