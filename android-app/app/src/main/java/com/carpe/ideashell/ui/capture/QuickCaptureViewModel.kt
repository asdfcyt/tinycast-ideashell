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
import com.carpe.ideashell.core.capture.CaptureSchedule
import com.carpe.ideashell.core.capture.ClipInput
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.core.parse.FolderInfo
import com.carpe.ideashell.core.parse.RepeatParser
import com.carpe.ideashell.core.voice.VoiceIntent
import com.carpe.ideashell.core.voice.VoiceResult
import com.carpe.ideashell.ui.components.VoiceInputController
import com.carpe.ideashell.ui.components.VoiceUndo
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

    /** 追加开关：开着时保存成「追加到上一篇快记笔记」，类型固定为笔记 */
    var append by mutableStateOf(false)
        private set

    /** 追加会接到哪一篇（标题，给用户确认）；还没有上一篇为 null（会新建） */
    var appendTarget by mutableStateOf<String?>(null)
        private set

    /** 点追加按钮：开 / 关；打开时顺便查出目标笔记的标题，并去掉手动选的类型（追加一定是笔记） */
    fun toggleAppend() {
        append = !append
        if (append) {
            override = null
            viewModelScope.launch { appendTarget = container.captures.appendTarget() }
        }
    }

    /** 语音里说了「追加到上一条笔记」：直接打开追加开关（同点追加按钮） */
    private fun enableAppend() {
        if (append) return
        append = true
        override = null
        viewModelScope.launch { appendTarget = container.captures.appendTarget() }
    }

    /** 手动选了类型：和追加冲突，追加自动关掉 */
    fun selectKind(kind: CaptureKind?) {
        append = false
        override = kind
    }

    /** 在日期时间面板里选定的时间：不写进输入框，保存时直接带上 */
    var schedule by mutableStateOf<CaptureSchedule?>(null)

    /** 分享 / 选中文字带来的内容；为 null 表示普通的「记一条」 */
    var clip by mutableStateOf<ClipInput?>(null)
        private set
    var state by mutableStateOf<QuickState>(QuickState.Composing)
        private set
    var error by mutableStateOf<String?>(null)
        private set

    /** 大模型整理过语音后的「还原」入口；null 表示没有可还原的 */
    var voiceUndo by mutableStateOf<VoiceUndo?>(null)
        private set

    /** 大模型从一句话里拆出的多件事（≥2 项）：在面板里预览，点确认键分别保存；空表示没有 */
    val voiceItems = mutableStateListOf<VoiceIntent>()

    /** 预览里去掉一项；剩下不到 2 项就并回输入框，走普通保存 */
    fun removeVoiceItem(index: Int) {
        if (index !in voiceItems.indices) return
        voiceItems.removeAt(index)
        if (voiceItems.size == 1) {
            val only = voiceItems.removeAt(0)
            text = if (text.isBlank()) intentBody(only) else text.trimEnd() + "\n" + intentBody(only)
            if (override == null) override = only.type
            if (only.type == CaptureKind.TODO && schedule == null) schedule = intentSchedule(only)
        }
        if (voiceItems.isEmpty()) voiceUndo = null
    }

    /** 语音里说了「帮我查一下…」：整理好的问题；界面收到后转交闪念贝壳 AI 并收起面板，null 表示没有 */
    var askRequest by mutableStateOf<String?>(null)

    /** 快速设置磁贴「语音记一条」进来：面板准备好后自动开始录音（锁定模式，点「完成」结束） */
    var voiceStartRequest by mutableStateOf(false)

    /** 语音识别完且开了「松手直接发送」：界面收到后调用 [submit] */
    var pendingAutoSubmit by mutableStateOf(false)

    /** 按住说话：录音 → 腾讯云识别 → 大模型整理（日期时间由模型推算）→ [applyVoice] */
    val voice = VoiceInputController(
        scope = viewModelScope,
        settings = container.settings,
        asr = container.asr,
        local = container.localAsr,
        llm = container.llm,
        lexicon = container.lexicon,
        extraHotwords = { container.folders.folders.value.map { it.name } },
        onError = { error = it },
        onResult = ::applyVoice,
    )

    /**
     * 把语音结果放进输入框。
     * - 大模型整理出一件事：正文去口语；输入框原本是空的就同时设好类型（待办 / 日记 / 笔记）和待办的日期时间 / 重复 / 标签 / 优先级，
     *   这些都显示在工具栏上，不对可以改；原本有内容就只追加一行、不改类型；
     * - 整理出多件事（多意图）：先在面板里列成预览（可去掉某一项），点确认键后每件事各存一条（待办有各自的日期时间）；
     *   带图片 / 分享内容 / 追加模式时不好拆开，改成把各项并成几行放进输入框；
     * - 没开 / 失败：追加本地清洗过的转写，日期时间退回本地规则识别。
     */
    private fun applyVoice(result: VoiceResult) {
        error = result.polishError
        // 「帮我查一下…」是问闪念贝壳 AI，不是记录：单独拿出来，由界面转交给闪念贝壳
        val asks = result.intents.filter { it.ask }
        val intents = result.intents.filterNot { it.ask }
        if (asks.isNotEmpty()) {
            askRequest = asks.joinToString("\n") { it.content }
            // 同一句话里还说了要记的事：先直接存下，再去问 AI
            if (intents.isNotEmpty()) saveVoiceItems(intents)
            return
        }
        val hadText = text.isNotBlank()
        val undo = VoiceUndo(result.raw, text, override, schedule)

        if (intents.size > 1 && images.isEmpty() && clip == null && !append) {
            voiceItems.addAll(intents)
            voiceUndo = undo
            if (container.settings.current.voiceAutoSend) pendingAutoSubmit = true
            return
        }

        val intent = intents.firstOrNull()
        if (intent == null) {
            text = if (hadText) text.trimEnd() + "\n" + result.cleaned else result.cleaned
            if (result.appendToLast) enableAppend()
            // 没经过大模型：只留原话和「纠错」
            voiceUndo = VoiceUndo(result.raw, undo.prevText, undo.prevOverride, undo.prevSchedule, polished = false)
        } else {
            // 多件事但没法直接拆开存：并成几行放进输入框
            val body = intents.joinToString("\n") { intentBody(it) }
            text = if (hadText) text.trimEnd() + "\n" + body else body
            if (intent.append) {
                enableAppend()
            } else if (!hadText) {
                append = false
                override = intent.type
            }
            if (intents.size == 1 && intent.type == CaptureKind.TODO && schedule == null) {
                schedule = intentSchedule(intent)
            }
            voiceUndo = undo
        }
        if (container.settings.current.voiceAutoSend) pendingAutoSubmit = true
    }

    private fun intentBody(intent: VoiceIntent): String = voiceIntentBody(intent)

    private fun intentSchedule(intent: VoiceIntent): CaptureSchedule? = voiceIntentSchedule(intent)

    /** 多意图：输入框里已有的文字先存一条，再一件事存一条，全部排进离线队列后关闭面板 */
    private fun saveVoiceItems(items: List<VoiceIntent>) {
        viewModelScope.launch {
            var last: SubmitReceipt? = null
            var saved = 0
            if (text.isNotBlank()) {
                container.captures.submitText(text, override, origin, schedule = schedule)?.let {
                    last = it
                    saved++
                }
            }
            items.forEach { intent ->
                val itemSchedule = if (intent.type == CaptureKind.TODO) intentSchedule(intent) else null
                val receipt = container.captures.submitText(intentBody(intent), intent.type, origin, schedule = itemSchedule, appendToLast = intent.append)
                if (receipt != null) {
                    last = receipt
                    saved++
                }
            }
            val receipt = last
            if (receipt == null) {
                error = "没有可保存的内容"
            } else {
                val todos = items.count { it.type == CaptureKind.TODO }
                voiceItems.clear()
                markSaved(receipt.copy(detail = "共 $saved 条" + if (todos > 0) "（待办 $todos）" else ""))
            }
        }
    }

    /** 点「还原」：退回转写原文，类型 / 日期时间也退回语音之前 */
    fun revertVoice() {
        val u = voiceUndo ?: return
        voiceItems.clear()
        text = if (u.prevText.isBlank()) u.raw else u.prevText.trimEnd() + "\n" + u.raw
        override = u.prevOverride
        schedule = u.prevSchedule
        voiceUndo = null
        pendingAutoSubmit = false
    }

    /**
     * 纠错学习：把「识别成了 [from]、应该是 [to]」记进词库（以后自动改对），并改掉当前输入框 / 多项预览里的文字。
     */
    fun correctVoice(from: String, to: String) {
        if (from.isBlank() || to.isBlank() || from == to) return
        container.lexicon.addReplacement(from, to)
        text = text.replace(from, to)
        for (i in voiceItems.indices) voiceItems[i] = voiceItems[i].let { it.copy(content = it.content.replace(from, to)) }
        voiceUndo = voiceUndo?.let {
            VoiceUndo(it.raw.replace(from, to), it.prevText, it.prevOverride, it.prevSchedule, it.polished)
        }
    }

    fun dismissVoiceUndo() {
        voiceUndo = null
    }

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
            markSaved(receipt)
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

    /** 入口预填的文字（比如项目快捷方式的「#项目 」）：只剩它不算草稿，不用存 */
    var baselineText = ""

    /** 关闭面板（点到外面、返回键）时把没提交的文字存下来，下次打开放回输入框 */
    fun saveDraft() {
        val current = text
        if (state !is QuickState.Composing || clip != null) return
        if (current.isBlank() || current.trim() == baselineText.trim()) {
            if (current.isBlank()) container.captureDraft.clear()
            return
        }
        container.captureDraft.save(current)
    }

    /** 输入框是空的才放回，避免盖住别的入口带来的内容 */
    fun restoreDraft() {
        if (text.isNotBlank()) return
        val saved = container.captureDraft.load()
        if (saved.isNotBlank()) text = saved
    }

    private fun markSaved(receipt: SubmitReceipt) {
        container.captureDraft.clear()
        state = QuickState.Saved(receipt)
    }

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
        // 旧输入先存成草稿，不丢
        saveDraft()
        configured = false
        CaptureImages.delete(images.toList())
        images.clear()
        text = ""
        baselineText = ""
        schedule = null
        append = false
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

    /**
     * 相机页交回的结果：识别出的文字追加到输入框末尾（已有内容另起一行）；
     * 图片已经在相机页缩小压缩好了，直接加入列表，超出张数上限的丢掉并删文件。
     */
    fun applyCameraResult(result: CameraCaptureResult) {
        result.text?.let { recognized ->
            text = if (text.isBlank()) recognized else text.trimEnd() + "\n" + recognized
        }
        if (result.images.isNotEmpty()) {
            val room = (CaptureImages.MAX_COUNT - images.size).coerceAtLeast(0)
            images.addAll(result.images.take(room))
            result.images.drop(room).takeIf { it.isNotEmpty() }?.let {
                CaptureImages.delete(it)
                error = "最多 ${CaptureImages.MAX_COUNT} 张图片"
            }
        }
    }

    fun removeImage(path: String) {
        if (images.remove(path)) CaptureImages.delete(listOf(path))
    }

    override fun onCleared() {
        voice.release()
        if (state !is QuickState.Saved) CaptureImages.delete(images.toList())
    }

    fun submit(readClipboard: () -> String?) {
        error = null
        if (voiceItems.isNotEmpty()) {
            saveVoiceItems(voiceItems.toList())
            return
        }
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
                    markSaved(receipt)
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
                container.captures.submitText(resolved.input, kind, origin, schedule = schedule, appendToLast = append)
            }
            if (receipt == null) {
                error = "没有可保存的内容"
                return@launch
            }
            markSaved(receipt)
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
