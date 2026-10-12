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
import com.carpe.ideashell.data.ideashell.NoteBrief
import com.carpe.ideashell.data.ideashell.NoteInfo
import com.carpe.ideashell.data.mcp.McpAuthException
import com.carpe.ideashell.domain.DossierData
import com.carpe.ideashell.domain.MemoryData
import com.carpe.ideashell.domain.MemoryLane
import com.carpe.ideashell.domain.Timeline
import com.carpe.ideashell.domain.TimelineData
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** 一块异步数据的状态：加载中仍可显示旧数据（先显示后刷新） */
data class Async<T>(
    val loading: Boolean = false,
    val data: T? = null,
    val error: String? = null,
)

/** 今天的 Daily Note；[note] 为空表示今天还没有记过日记 */
data class TodayDaily(val note: com.carpe.ideashell.data.ideashell.NoteDetail?)

enum class ReviewPane(val label: String) {
    TIMELINE("时间线"),
    DAILY("Daily"),
    MEMORY("回顾"),
    DOSSIER("档案"),
}

/** 时间线的快捷范围，文字交给 [TimeRanges.parse]，规则与桌面一致 */
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

class ReviewViewModel(private val container: AppContainer) : ViewModel() {
    private val repo = container.notes

    val connected: StateFlow<Boolean> = container.credentials.ideashellConnected

    var pane by mutableStateOf(ReviewPane.TIMELINE)
        private set

    /** 列表滚动位置放在这里：进笔记全文页再返回，界面会重建，位置仍在 */
    val listState = LazyListState()

    val dailyFolder: String get() = container.settings.current.dailyFolder

    fun selectPane(p: ReviewPane) {
        if (p == pane) return
        pane = p
        listState.requestScrollToItem(0)
    }

    // ── 时间线 ──
    var preset by mutableStateOf<RangePreset?>(RangePreset.LAST7)
        private set
    var range by mutableStateOf(RangePreset.LAST7.range())
        private set
    private val _timeline = MutableStateFlow(Async<TimelineData>())
    val timeline: StateFlow<Async<TimelineData>> = _timeline.asStateFlow()
    private var timelineJob: Job? = null

    // ── Daily Note ──
    private val _daily = MutableStateFlow(Async<List<NoteBrief>>())
    val daily: StateFlow<Async<List<NoteBrief>>> = _daily.asStateFlow()

    /** 今天的 Daily Note 全文（没有就是 note 为空） */
    private val _dailyToday = MutableStateFlow(Async<TodayDaily>())
    val dailyToday: StateFlow<Async<TodayDaily>> = _dailyToday.asStateFlow()

    // ── 往日回顾 ──
    private val _memory = MutableStateFlow(Async<MemoryData>())
    val memory: StateFlow<Async<MemoryData>> = _memory.asStateFlow()
    var randomNote by mutableStateOf<NoteInfo?>(null)
        private set

    // ── 档案 ──
    var dossierText by mutableStateOf("")
    private val _dossier = MutableStateFlow(Async<DossierData>())
    val dossier: StateFlow<Async<DossierData>> = _dossier.asStateFlow()
    private var dossierJob: Job? = null

    /** 切到某个页签时：还没有数据就拉一次 */
    fun ensureLoaded(pane: ReviewPane) {
        if (!connected.value) return
        when (pane) {
            ReviewPane.TIMELINE -> if (_timeline.value.data == null && !_timeline.value.loading) loadTimeline()
            // 每次进入 Daily 都悄悄刷新一次：刚在「记录」页写的日记要立刻能在这里看到（旧内容先显示，不白屏）
            ReviewPane.DAILY -> if (!_daily.value.loading && !_dailyToday.value.loading) loadDaily()
            ReviewPane.MEMORY -> if (_memory.value.data == null && !_memory.value.loading) loadMemory()
            ReviewPane.DOSSIER -> Unit
        }
    }

    fun refresh(pane: ReviewPane) {
        when (pane) {
            ReviewPane.TIMELINE -> loadTimeline()
            ReviewPane.DAILY -> loadDaily()
            ReviewPane.MEMORY -> loadMemory()
            ReviewPane.DOSSIER -> _dossier.value.data?.let { openDossier(it.query) }
        }
    }

    // ── 时间线 ──

    fun selectPreset(p: RangePreset) {
        preset = p
        range = p.range()
        loadTimeline(clear = true)
    }

    fun selectCustom(from: java.time.LocalDate, toInclusive: java.time.LocalDate) {
        preset = null
        range = TimeRanges.custom(from, toInclusive)
        loadTimeline(clear = true)
    }

    private fun loadTimeline(clear: Boolean = false) {
        timelineJob?.cancel()
        val target = range
        if (clear) _timeline.value = Async(loading = true) else _timeline.update { it.copy(loading = true, error = null) }
        timelineJob = viewModelScope.launch {
            runLoad(_timeline) { repo.timeline(target) }
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

    // ── Daily Note ──

    fun loadDaily() {
        _daily.update { it.copy(loading = true, error = null) }
        _dailyToday.update { it.copy(loading = true, error = null) }
        viewModelScope.launch {
            runLoad(_daily) { repo.dailyNoteList() }
            loadToday()
        }
    }

    /** 从已加载的 Daily 列表里找出今天那一篇，拉取全文（强制刷新，保证看到刚记下的内容） */
    private suspend fun loadToday() {
        val list = _daily.value.data
        if (list == null) {
            // 列表本身没加载成功，今天的内容也无从谈起；错误信息由列表那一块展示
            _dailyToday.update { it.copy(loading = false) }
            return
        }
        val today = java.time.LocalDate.now().toString()
        val brief = list.firstOrNull { it.title.contains(today) }
        if (brief == null) {
            _dailyToday.value = Async(data = TodayDaily(null))
            return
        }
        runLoad(_dailyToday) { TodayDaily(repo.note(brief.id, force = true)) }
    }

    // ── 往日回顾 ──

    fun loadMemory() {
        _memory.update { it.copy(loading = true, error = null) }
        viewModelScope.launch {
            runLoad(_memory) { repo.memory() }
            _memory.value.data?.let { m -> randomNote = MemoryLane.pickRandom(m.pool, MemoryLane.sameDayIds(m)) }
        }
    }

    /** 换一条随机笔记（避开往日同期里已有的，也避开当前这条） */
    fun shuffle() {
        val m = _memory.value.data ?: return
        val avoid = MemoryLane.sameDayIds(m) + listOfNotNull(randomNote?.id)
        randomNote = MemoryLane.pickRandom(m.pool, avoid)
    }

    // ── 档案 ──

    fun openDossier(query: String = dossierText) {
        val q = query.trim()
        if (q.isEmpty()) return
        dossierText = q
        dossierJob?.cancel()
        _dossier.value = Async(loading = true)
        dossierJob = viewModelScope.launch {
            runLoad(_dossier) { repo.dossier(q) }
        }
    }

    /** 从搜索页 / 笔记标签跳到某个关键词的档案 */
    fun jumpToDossier(query: String) {
        selectPane(ReviewPane.DOSSIER)
        openDossier(query)
    }

    // ── 公共 ──

    private suspend fun <T> runLoad(state: MutableStateFlow<Async<T>>, block: suspend () -> T) {
        try {
            state.value = Async(data = block())
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            state.update { it.copy(loading = false, error = friendly(e)) }
        }
    }

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
