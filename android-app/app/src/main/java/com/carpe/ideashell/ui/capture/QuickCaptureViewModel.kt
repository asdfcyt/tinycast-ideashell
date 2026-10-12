package com.carpe.ideashell.ui.capture

import android.content.Context
import android.net.Uri
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
import com.carpe.ideashell.core.capture.CapturePlanner
import com.carpe.ideashell.core.capture.ClipInput
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.core.parse.FolderInfo
import com.carpe.ideashell.data.capture.CaptureImages
import com.carpe.ideashell.data.capture.SubmitReceipt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.carpe.ideashell.core.template.Template
import com.carpe.ideashell.core.template.Templates
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

sealed interface QuickState {
    data object Composing : QuickState
    data class Saved(val receipt: SubmitReceipt) : QuickState
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

    /** 已选 / 已拍的图片（本地文件路径）。保存后文件交给记录队列，没保存就关闭则在 [onCleared] 里清掉 */
    val images = mutableStateListOf<String>()
    var importing by mutableStateOf(false)
        private set

    /** 模板录入（内置模板 + 自定义模板），从工具栏的模板图标进入 */
    val templates: StateFlow<List<Template>> = container.workspace.state
        .map { Templates.merge(it.templates) }
        .stateIn(viewModelScope, SharingStarted.Eagerly, Templates.merge(container.workspace.current.templates))
    var showTemplates by mutableStateOf(false)

    /** 用模板保存：标题「模板名 日期」，正文每个字段一段。返回是否已提交 */
    fun submitTemplate(template: Template, values: Map<String, String>): Boolean {
        val built = Templates.buildNote(template, values)
        if (built.filled == 0) {
            error = "请至少填写一项"
            return false
        }
        viewModelScope.launch {
            val receipt = container.captures.submitNote(
                title = built.title,
                body = built.body,
                tags = template.tags,
                folderName = template.folderName,
                label = "模板「${template.name}」",
                origin = origin,
            )
            showTemplates = false
            state = QuickState.Saved(receipt)
        }
        return true
    }

    fun saveTemplate(template: Template, replacing: String?) {
        container.workspace.update { w ->
            val key = (replacing ?: template.name).lowercase()
            val rest = w.templates.filterNot { it.name.lowercase() == key || it.name.lowercase() == template.name.lowercase() }
            w.copy(templates = rest + template.copy(builtin = false))
        }
    }

    fun deleteTemplate(name: String) {
        container.workspace.update { w -> w.copy(templates = w.templates.filterNot { it.name.equals(name, ignoreCase = true) }) }
    }

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

    /**
     * 面板已经开着时又来了一份新内容（例如荣耀任意门连续拖了两次、分享菜单再点一次）：
     * 丢掉旧输入，按新内容重新开始。和 [configure] 不同，它每次都生效。
     */
    fun reconfigure(clip: ClipInput?, preset: CaptureKind?, origin: String) {
        configured = false
        CaptureImages.delete(images.toList())
        images.clear()
        text = ""
        error = null
        state = QuickState.Composing
        configure(clip, preset, origin)
    }

    /** 从相册 / 相机拿到的图片：缩小压缩后加入列表，最多 [CaptureImages.MAX_COUNT] 张 */
    fun addImages(context: Context, uris: List<Uri>) {
        if (uris.isEmpty()) return
        val appContext = context.applicationContext
        viewModelScope.launch {
            importing = true
            val room = CaptureImages.MAX_COUNT - images.size
            val imported = withContext(Dispatchers.IO) { uris.take(room.coerceAtLeast(0)).mapNotNull { CaptureImages.import(appContext, it) } }
            images.addAll(imported)
            importing = false
            error = when {
                imported.size < uris.size && room <= 0 -> "最多 ${CaptureImages.MAX_COUNT} 张图片"
                imported.size < uris.size -> "有图片没能读取，已跳过"
                else -> null
            }
        }
    }

    fun removeImage(path: String) {
        if (images.remove(path)) CaptureImages.delete(listOf(path))
    }

    override fun onCleared() {
        if (state !is QuickState.Saved) CaptureImages.delete(images.toList())
    }

    fun submit(readClipboard: () -> String?) {
        error = null
        val currentClip = clip
        viewModelScope.launch {
            if (currentClip == null && images.isNotEmpty()) {
                // 带图片：存为笔记或 Daily Note（看类型），文字可以为空
                val sending = images.toList()
                val receipt = container.captures.submitText(text, override, origin, sending)
                if (receipt == null) {
                    error = "没有可保存的内容"
                } else {
                    images.clear()
                    state = QuickState.Saved(receipt)
                }
                return@launch
            }
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

    companion object {
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = this[APPLICATION_KEY] as IdeashellApp
                QuickCaptureViewModel(app.container)
            }
        }
    }
}
