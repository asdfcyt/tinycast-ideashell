package com.carpe.ideashell.ui.capture

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
import com.carpe.ideashell.core.capture.ClipInput
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.core.parse.FolderInfo
import com.carpe.ideashell.data.capture.SubmitReceipt
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

sealed interface QuickState {
    data object Composing : QuickState
    data class Saved(val receipt: SubmitReceipt) : QuickState
    data object Undone : QuickState
}

/** 轻量输入面板（磁贴 / 桌面快捷方式 / 分享 / 选中文字菜单共用）的状态 */
class QuickCaptureViewModel(private val container: AppContainer) : ViewModel() {
    var text by mutableStateOf("")
    var override by mutableStateOf<CaptureKind?>(null)

    /** 分享 / 选中文字带来的内容；为 null 表示普通的「记一条」 */
    var clip by mutableStateOf<ClipInput?>(null)
        private set
    var state by mutableStateOf<QuickState>(QuickState.Composing)
        private set
    var error by mutableStateOf<String?>(null)
        private set

    private var origin = "quick"
    private var configured = false

    val folders: StateFlow<List<FolderInfo>> = container.folders.folders
    val connected: StateFlow<Boolean> = container.credentials.ideashellConnected

    /** 只在第一次生效（旋转屏幕等重建时不会重复覆盖用户已经输入的内容） */
    fun configure(clip: ClipInput?, preset: CaptureKind?, origin: String) {
        if (configured) return
        configured = true
        this.clip = clip
        this.override = preset
        this.origin = origin
    }

    fun submit(readClipboard: () -> String?) {
        error = null
        val currentClip = clip
        viewModelScope.launch {
            val receipt = if (currentClip != null) {
                container.captures.submitClip(currentClip, text, origin)
            } else {
                val resolved = CapturePlanner.resolveClipboard(text, readClipboard)
                if (resolved == null) {
                    error = "剪贴板里没有文字"
                    return@launch
                }
                val kind = override ?: if (resolved.fromClipboard) CaptureKind.NOTE else null
                container.captures.submitText(resolved.input, kind, origin)
            }
            if (receipt == null) {
                error = "没有可保存的内容"
                return@launch
            }
            state = QuickState.Saved(receipt)
        }
    }

    fun undo() {
        val saved = state as? QuickState.Saved ?: return
        viewModelScope.launch {
            if (container.captures.undo(saved.receipt.id)) {
                state = QuickState.Undone
            } else {
                error = "已经开始同步，无法撤销"
            }
        }
    }

    companion object {
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = this[APPLICATION_KEY] as IdeashellApp
                QuickCaptureViewModel(app.container)
            }
        }
    }
}
