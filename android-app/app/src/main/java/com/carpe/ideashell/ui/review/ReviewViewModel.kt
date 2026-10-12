package com.carpe.ideashell.ui.review

import androidx.compose.foundation.lazy.LazyListState
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
import com.carpe.ideashell.core.parse.TimeRange
import com.carpe.ideashell.core.parse.TimeRanges
import com.carpe.ideashell.data.mcp.McpAuthException
import com.carpe.ideashell.data.project.Workspace
import com.carpe.ideashell.domain.ProjectFlow
import com.carpe.ideashell.domain.Timeline
import com.carpe.ideashell.domain.TimelineData
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.LocalDate

/** 一块异步数据的状态：加载中仍可显示旧数据（先显示后刷新） */
data class Async<T>(
    val loading: Boolean = false,
    val data: T? = null,
    val error: String? = null,
)

/** 时间河的快捷范围，文字交给 [TimeRanges.parse]，规则与桌面一致 */
enum class RangePreset(val label: String, val text: String) {
    TODAY("今天", "今天"),
    YESTERDAY("昨天", "昨天"),
    LAST7("最近 7 天", ""),
    THIS_WEEK("本周", "本周"),
    LAST_WEEK("上周", "上周"),
    THIS_MONTH("本月", "本月"),
    LAST_MONTH("上月", "上月"),
    ;

    fun range(): TimeRange = TimeRanges.parse(text) ?: TimeRanges.lastDays(7)
}

/**
 * 回看：一条按时间戳排开的河——笔记、完成的待办、Daily Note 里的每一条日记混在一起，
 * 顶部是这段时间「时间去哪了」（按项目拆分）。数据都在这里，切走页签再回来不会丢。
 */
class ReviewViewModel(private val container: AppContainer) : ViewModel() {
    private val repo = container.notes

    val connected: StateFlow<Boolean> = container.credentials.ideashellConnected
    val workspace: StateFlow<Workspace> = container.projects.workspace

    /** 列表滚动位置放在这里：进笔记全文页再返回，界面会重建，位置仍在 */
    val listState = LazyListState()

    var preset by mutableStateOf<RangePreset?>(RangePreset.LAST7)
        private set
    var range by mutableStateOf(RangePreset.LAST7.range())
        private set

    private val _timeline = MutableStateFlow(Async<TimelineData>())
    val timeline: StateFlow<Async<TimelineData>> = _timeline.asStateFlow()
    private var timelineJob: Job? = null

    private val _flow = MutableStateFlow(ProjectFlow.Empty)
    val flow: StateFlow<ProjectFlow> = _flow.asStateFlow()
    private var flowJob: Job? = null

    /** 进页面时：还没有数据就拉一次；已经有了就保持（下拉刷新才重读） */
    fun ensureLoaded() {
        if (!connected.value) return
        if (_timeline.value.data == null && !_timeline.value.loading) loadTimeline()
    }

    fun refresh() = loadTimeline()

    fun selectPreset(p: RangePreset) {
        preset = p
        range = p.range()
        loadTimeline(clear = true)
    }

    fun selectCustom(from: LocalDate, toInclusive: LocalDate) {
        preset = null
        range = TimeRanges.custom(from, toInclusive)
        loadTimeline(clear = true)
    }

    private fun loadTimeline(clear: Boolean = false) {
        timelineJob?.cancel()
        flowJob?.cancel()
        val target = range
        if (clear) {
            _timeline.value = Async(loading = true)
            _flow.value = ProjectFlow.Empty
        } else {
            _timeline.update { it.copy(loading = true, error = null) }
        }
        timelineJob = viewModelScope.launch {
            try {
                val data = repo.timeline(target)
                _timeline.value = Async(data = data)
                loadFlow(data)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _timeline.update { it.copy(loading = false, error = friendly(e)) }
            }
        }
    }

    /**
     * 「时间去哪了」：专注记录按项目拆分。专注读不到（没连接滴答 / 请求失败）就只按记录条数拆，不影响河本身。
     * 项目统计（距上次提及多少天）用已经算好的，没有就不显示「没记」提醒。
     */
    private fun loadFlow(data: TimelineData) {
        flowJob?.cancel()
        val projects = container.projects.projects
        if (projects.isEmpty()) {
            _flow.value = ProjectFlow.Empty
            return
        }
        // 先用现有数据画一版（没有专注），专注读回来再替换
        _flow.value = ProjectFlow.build(projects, data, null, container.projects.stats.value)
        if (container.credentials.didaToken.isNullOrBlank()) return
        flowJob = viewModelScope.launch {
            val focus = try {
                container.daySummary.focusIn(data.range.start, data.range.endExclusive)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            }
            _flow.value = ProjectFlow.build(container.projects.projects, data, focus, container.projects.stats.value)
        }
    }

    /** 今日小结：今天完成的任务 + 专注时长，插到今天 Daily Note 的最前面（重复生成会替换，不堆叠） */
    var summaryBusy by mutableStateOf(false)
        private set

    fun writeDaySummary(onDone: (String) -> Unit) {
        if (summaryBusy) return
        summaryBusy = true
        viewModelScope.launch {
            val text = try {
                container.daySummary.hud(container.daySummary.write())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                "生成失败：${friendly(e)}"
            } finally {
                summaryBusy = false
            }
            onDone(text)
        }
    }

    fun timelineReport(): String? = _timeline.value.data?.let { Timeline.report(it) }

    private fun friendly(e: Exception): String =
        if (e is McpAuthException) "闪念贝壳 API Key 无效或已失效，请到「连接与诊断」重新填写" else (e.message ?: "加载失败")

    companion object {
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = this[APPLICATION_KEY] as IdeashellApp
                ReviewViewModel(app.container)
            }
        }
    }
}
