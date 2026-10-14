package com.carpe.ideashell.ui.diagnostics

import android.os.Build
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.Companion.APPLICATION_KEY
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.carpe.ideashell.AppContainer
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.data.db.CaptureEntity
import com.carpe.ideashell.data.db.CaptureStatus
import com.carpe.ideashell.data.diagnostics.ConnectivityChecker
import com.carpe.ideashell.data.diagnostics.McpTarget
import com.carpe.ideashell.data.diagnostics.StepResult
import com.carpe.ideashell.data.mcp.McpClient
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class SectionState(
    /** 输入框里的内容（保存后清空，不回显已保存的凭证） */
    val input: String = "",
    val saved: Boolean = false,
    val running: Boolean = false,
    val steps: List<StepResult> = emptyList(),
)

data class DiagnosticsUiState(
    val ideashell: SectionState = SectionState(),
    val dida: SectionState = SectionState(),
) {
    fun section(target: McpTarget) = if (target == McpTarget.IDEASHELL) ideashell else dida

    fun with(target: McpTarget, transform: (SectionState) -> SectionState) =
        if (target == McpTarget.IDEASHELL) copy(ideashell = transform(ideashell)) else copy(dida = transform(dida))
}

class DiagnosticsViewModel(private val container: AppContainer) : ViewModel() {
    private val checker = ConnectivityChecker()

    private val _state = MutableStateFlow(
        DiagnosticsUiState(
            ideashell = SectionState(saved = !container.credentials.ideashellKey.isNullOrBlank()),
            dida = SectionState(saved = !container.credentials.didaToken.isNullOrBlank()),
        ),
    )
    val state: StateFlow<DiagnosticsUiState> = _state.asStateFlow()

    /** 同步队列：还没发出去的记录（待发送 / 发送中 / 失败） */
    val queue: StateFlow<List<CaptureEntity>> = container.captures.queue
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    fun retry(id: Long) {
        viewModelScope.launch { container.captures.retry(id) }
    }

    fun retryAll() {
        viewModelScope.launch { container.captures.retryAll() }
    }

    fun syncNow() = container.captures.syncNow()

    fun discard(id: Long) {
        viewModelScope.launch { container.captures.discard(id) }
    }

    fun discardAllFailed() {
        viewModelScope.launch { container.captures.discardAllFailed() }
    }

    fun onInputChange(target: McpTarget, value: String) {
        _state.update { it.with(target) { s -> s.copy(input = value) } }
    }

    fun clearCredential(target: McpTarget) {
        when (target) {
            McpTarget.IDEASHELL -> container.credentials.ideashellKey = null
            McpTarget.DIDA -> container.credentials.didaToken = null
        }
        _state.update { it.with(target) { SectionState() } }
    }

    fun runCheck(target: McpTarget) {
        if (_state.value.section(target).running) return
        val input = _state.value.section(target).input
        if (input.isNotBlank()) {
            when (target) {
                McpTarget.IDEASHELL -> container.credentials.ideashellKey = input
                McpTarget.DIDA -> container.credentials.didaToken = input
            }
        }
        _state.update {
            it.with(target) { s -> s.copy(input = "", saved = hasCredential(target), running = true, steps = emptyList()) }
        }
        viewModelScope.launch {
            val steps = checker.run(clientOf(target), target)
            _state.update { it.with(target) { s -> s.copy(running = false, steps = steps) } }
            // 闪念贝壳连通后顺手把文件夹列表拉下来，输入框里的 @文件夹 预览要用
            if (target == McpTarget.IDEASHELL && steps.all { it.ok }) container.folders.refreshIfStale(0)
        }
    }

    /** 把检查结果整理成可复制的文本（不含任何凭证） */
    fun buildReport(): String = buildString {
        appendLine("拾忆 Android · M0 连通性诊断")
        appendLine("设备：${Build.MANUFACTURER} ${Build.MODEL} · Android ${Build.VERSION.RELEASE}（API ${Build.VERSION.SDK_INT}）")
        appendLine()
        appendLine("【同步队列】")
        val q = queue.value
        if (q.isEmpty()) {
            appendLine("全部已同步")
        } else {
            appendLine("未发出 ${q.size} 条（失败 ${q.count { it.status == CaptureStatus.FAILED.name }} 条）")
            q.take(20).forEach {
                appendLine("- ${it.kind} · ${it.status} · 已重试 ${it.attempts} 次" + (it.lastError?.let { e -> " · $e" } ?: ""))
            }
        }
        for (target in McpTarget.entries) {
            appendLine()
            appendLine("【${target.label}】")
            val steps = _state.value.section(target).steps
            if (steps.isEmpty()) {
                appendLine("（尚未检查）")
            } else {
                steps.forEach { appendLine("${if (it.ok) "✓" else "✗"} ${it.title}（${it.millis}ms）\n    ${it.detail.replace("\n", "\n    ")}") }
            }
        }
    }

    private fun hasCredential(target: McpTarget) = when (target) {
        McpTarget.IDEASHELL -> !container.credentials.ideashellKey.isNullOrBlank()
        McpTarget.DIDA -> !container.credentials.didaToken.isNullOrBlank()
    }

    private fun clientOf(target: McpTarget): McpClient =
        if (target == McpTarget.IDEASHELL) container.ideashell else container.dida

    companion object {
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = this[APPLICATION_KEY] as IdeashellApp
                DiagnosticsViewModel(app.container)
            }
        }
    }
}
