package com.carpe.ideashell.ui.focus

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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
import com.carpe.ideashell.data.dida.DidaOverview
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.focus.FocusResult
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.time.LocalDate

class FocusViewModel(private val container: AppContainer) : ViewModel() {
    private val focus = container.focus

    val session = focus.session
    val summary = focus.summary
    val pending = focus.pending
    val connected: StateFlow<Boolean> = container.credentials.didaConnected

    /** 每日专注目标（分钟），在「设置」里改 */
    val goalMin: StateFlow<Int> = container.settings.state.map { it.focusGoalMin }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), container.settings.current.focusGoalMin)

    /** 可以绑定的任务：逾期 + 今天 + 没有日期的（滴答本地缓存里的），已排好顺序 */
    val tasks: StateFlow<List<DidaTask>> = container.todos.state
        .map { data -> data.overview?.let(::candidates).orEmpty() }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), container.todos.state.value.overview?.let(::candidates).orEmpty())

    /** 开始前选的时长（分钟）、绑定的任务；开始后它们就存进 [session]，这里只管下一次 */
    var minutes by mutableIntStateOf(focus.lastMinutes)
    var task by mutableStateOf<DidaTask?>(null)

    /** 正在新建任务（选择器里的「添加」按钮据此显示「添加中」） */
    var adding by mutableStateOf(false)
        private set

    private val _messages = Channel<String>(Channel.BUFFERED)
    val messages: Flow<String> = _messages.receiveAsFlow()

    init {
        container.todos.refresh()
        reload()
    }

    /** 进入页面 / 回到前台：对账（到点没记的补记、没传成功的补传）并读回滴答里的专注 */
    fun reload() {
        viewModelScope.launch {
            focus.settle()
            focus.refresh()
        }
    }

    fun start() {
        val t = task
        if (!focus.start(t?.id, t?.projectId, t?.title.orEmpty(), minutes)) {
            _messages.trySend("已经有一个专注在进行")
        }
    }

    fun pauseOrResume() {
        val s = session.value ?: return
        if (s.paused) focus.resume() else focus.pause()
    }

    /** 结束并记录；放在进程级作用域里，离开页面也会把写入滴答的请求跑完 */
    fun finish() {
        container.appScope.launch {
            when (val r = focus.finish()) {
                is FocusResult.Recorded ->
                    _messages.trySend(if (r.synced) "已记入滴答 · ${r.minutes} 分钟" else "已保存 · ${r.minutes} 分钟，联网后自动同步到滴答")
                FocusResult.TooShort -> _messages.trySend("不足 1 分钟，没有记录")
                FocusResult.None -> Unit
            }
        }
    }

    fun discard() = focus.discard()

    /** 在滴答里新建一个今天的待办并选中它；成功后回调 [onAdded]（用来关掉选择器） */
    fun addTask(title: String, onAdded: () -> Unit) {
        val t = title.trim()
        if (t.isEmpty() || adding) return
        if (!connected.value) {
            _messages.trySend("先连接滴答清单，才能新建任务")
            return
        }
        adding = true
        viewModelScope.launch {
            try {
                val created = focus.addTask(t)
                container.todos.refreshNow()
                val found = created ?: container.todos.state.value.overview?.let(::candidates).orEmpty().firstOrNull { it.title == t }
                if (found != null) {
                    task = found
                    onAdded()
                } else {
                    _messages.trySend("任务已创建，但没能自动选中，请在列表里选")
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _messages.trySend("新建任务失败，请检查网络和滴答连接")
            } finally {
                adding = false
            }
        }
    }

    fun syncNow() {
        viewModelScope.launch {
            focus.settle()
            focus.refresh()
            if (focus.pending.value.isNotEmpty()) _messages.trySend("同步失败，请检查网络和滴答连接")
        }
    }

    private fun candidates(ov: DidaOverview): List<DidaTask> {
        val today = LocalDate.now().toString()
        val order = compareBy<DidaTask>({ it.date ?: "9999" }, { it.time ?: "99:99" }, { -it.priority })
        return (ov.overdue + ov.upcoming.filter { it.date == today }).sortedWith(order) + ov.undated
    }

    object Factory {
        val instance: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = this[APPLICATION_KEY] as IdeashellApp
                FocusViewModel(app.container)
            }
        }
    }
}
