package com.carpe.ideashell.system

import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.core.voice.TodoOp
import com.carpe.ideashell.core.voice.VoiceResult
import com.carpe.ideashell.data.voice.VoiceAgent
import com.carpe.ideashell.data.voice.VoiceSearch
import com.carpe.ideashell.data.voice.VoiceSession
import com.carpe.ideashell.ui.capture.voiceIntentBody
import com.carpe.ideashell.ui.capture.voiceIntentSchedule

/** 语音胶囊的「动作」：把识别结果整理成草稿、保存草稿、跑语音助手，不碰界面（结果通过返回值 / 小胶囊显示）。 */
private const val ORIGIN = "voice"


/** 待办操作的一句话摘要：「开会」改到 14:40，备注加「带上办公电脑」 / 完成「开会」 / 删除「开会」 */
internal fun VoiceCapsuleService.editSummary(draft: CapsuleDraft): String {
    val task = draft.task
        ?: return "没找到要" + (when (draft.op()) { TodoOp.COMPLETE -> "完成"; TodoOp.DELETE -> "删除"; else -> "修改" }) +
            "的待办" + (draft.intent?.target?.let { "「$it」" } ?: "")
    return when (draft.op()) {
        TodoOp.COMPLETE -> "完成「${task.title.take(24)}」"
        TodoOp.DELETE -> "删除「${task.title.take(24)}」（不可恢复）"
        else -> (application as IdeashellApp).container.todoEditor.describe(task, draft.editOf())
    }
}

/** 跑一次语音助手回答；失败也返回一条能显示的文字，不抛异常。回答放进「最近对话」，下一句追问能接上 */
internal suspend fun VoiceCapsuleService.answerOf(container: com.carpe.ideashell.AppContainer, question: String, raw: String): VoiceSearch.Result = try {
    // 流式：回答边生成边显示在「正在整理」那个小胶囊里
    val a = VoiceAgent.answer(container, question, VoiceSession.format(VoiceSession.recent().filter { it.raw != raw }), onPartial = { postPartial(it) })
    VoiceSession.attach(raw, "回答：" + a.text)
    VoiceSearch.Result(a.text, a.hits, "", isAnswer = true)
} catch (e: kotlinx.coroutines.CancellationException) {
    throw e
} catch (e: Exception) {
    VoiceSearch.Result("没能回答：" + (e.message ?: "未知错误"), emptyList(), "", isAnswer = true)
}

internal suspend fun VoiceCapsuleService.buildDrafts(result: VoiceResult): List<CapsuleDraft> {
    val editor = (application as IdeashellApp).container.todoEditor
    if (result.intents.isEmpty()) {
        return listOf(CapsuleDraft(if (result.appendToLast) CapsuleMode.APPEND else CapsuleMode.AUTO, result.cleaned, null))
    }
    return result.intents.map { intent ->
        if (intent.edit) return@map CapsuleDraft(CapsuleMode.EDIT, intent.content, intent, editor.find(intent.target))
        val mode = when {
            intent.ask -> CapsuleMode.ASK
            intent.append -> CapsuleMode.APPEND
            else -> when (intent.type) {
                CaptureKind.TODO -> CapsuleMode.TODO
                CaptureKind.DAILY -> CapsuleMode.DAILY
                CaptureKind.NOTE -> CapsuleMode.NOTE
            }
        }
        CapsuleDraft(mode, intent.content, intent)
    }
}

/** [quiet]：自动保存倒计时结束后的保存，小胶囊原地变成 ✓ 很快收起，不再重复滑出 */
internal suspend fun VoiceCapsuleService.saveAll(list: List<CapsuleDraft>, note: String?, quiet: Boolean = false) {
    val app = application as IdeashellApp
    val captures = app.container.captures
    val saved = mutableListOf<CapsuleSaved>()
    val asks = mutableListOf<String>()
    val failures = mutableListOf<String>()
    // 在确认卡片里把同音错字改对了：记下来，下次识别 / 整理自动改对
    val learned = list.filter { it.mode != CapsuleMode.EDIT && it.text != it.original }
        .mapNotNull { app.container.lexicon.learnFromEdit(it.original, it.text) }
        .map { "已记住「${it.first}→${it.second}」" }
    list.filter { it.isValid() }.forEach { draft ->
        val text = draft.text.trim()
        if (draft.mode == CapsuleMode.EDIT) {
            val task = draft.task
            if (task == null) {
                failures += editSummary(draft)
            } else {
                val editor = app.container.todoEditor
                val op = draft.op()
                val edit = draft.editOf()
                val result = when (op) {
                    TodoOp.COMPLETE -> editor.complete(task)
                    TodoOp.DELETE -> editor.delete(task)
                    else -> editor.apply(task, edit)
                }
                // 完成 / 修改可以撤销；删除不可恢复，没有撤销
                val undo: (suspend () -> Result<String>)? = when (op) {
                    TodoOp.COMPLETE -> ({ editor.undoComplete(task) })
                    TodoOp.DELETE -> null
                    else -> ({ editor.undoApply(task, edit) })
                }
                result
                    .onSuccess { saved += CapsuleSaved(op.label, it, undo) }
                    .onFailure { failures += "${op.label}失败：" + (it.message ?: "未知错误") }
            }
            return@forEach
        }
        if (draft.mode == CapsuleMode.ASK) {
            asks += text
            return@forEach
        }
        val intent = draft.intent
        val kind = when (draft.mode) {
            CapsuleMode.TODO -> CaptureKind.TODO
            CapsuleMode.DAILY -> CaptureKind.DAILY
            CapsuleMode.NOTE, CapsuleMode.APPEND -> CaptureKind.NOTE
            else -> null
        }
        val body = if (intent != null) voiceIntentBody(intent.copy(content = text)) else text
        val isTodo = draft.mode == CapsuleMode.TODO && intent != null
        val schedule = if (isTodo) voiceIntentSchedule(intent!!) else null
        if (captures.submitText(body, kind, ORIGIN, schedule = schedule, appendToLast = draft.mode == CapsuleMode.APPEND) != null) {
            val whenText = if (isTodo) scheduleText(intent!!.date, intent.time) else ""
            saved += CapsuleSaved(modeLabel(draft.mode, saved = true), (if (whenText.isNotEmpty()) "$whenText · " else "") + text)
        }
    }
    if (asks.isNotEmpty()) {
        // 和快速输入面板一致：交给闪念贝壳 AI（无障碍开着就自动点发送）；转交失败就记成一条笔记，不丢
        val question = asks.joinToString("\n")
        // 说到「这页 / 这段」：把当时屏幕上的文字一起带给对面的 AI（它看不到我们的屏幕）
        val withScreen = com.carpe.ideashell.data.assistant.ScreenContext.attachTo(question) { jpeg ->
            app.container.ocr.recognize(jpeg).joinToString("\n") { it.text }
        }
        if (IdeashellBridge.askAi(this, withScreen, preferAutoSend = true)) {
            saved += CapsuleSaved("问 AI", question)
        } else if (captures.submitText(question, CaptureKind.NOTE, ORIGIN) != null) {
            saved += CapsuleSaved("笔记", question)
        }
    }
    if (saved.isEmpty()) {
        showMessage(failures.firstOrNull() ?: "没有可保存的内容", error = true)
        return
    }
    val tail = (listOfNotNull(note) + failures + learned).joinToString("；").ifBlank { null }
    showSaved(saved, tail, quiet && failures.isEmpty() && learned.isEmpty() && saved.none { it.undo != null })
}
