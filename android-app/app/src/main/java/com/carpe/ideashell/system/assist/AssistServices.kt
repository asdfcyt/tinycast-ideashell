package com.carpe.ideashell.system.assist

import android.app.assist.AssistContent
import android.app.assist.AssistStructure
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionService
import android.speech.SpeechRecognizer
import android.service.voice.VoiceInteractionService
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService
import android.text.InputType
import com.carpe.ideashell.data.assistant.ScreenContext
import com.carpe.ideashell.system.VoiceCapsuleService

/**
 * 设为系统「默认数字助手」后：长按电源键 / 侧滑手势呼出助手，就是开始语音记一条，
 * 同时系统把当前屏幕交过来（只留在内存里，助手要读屏幕时才用，60 秒后作废）。
 */
class IdeashellVoiceInteractionService : VoiceInteractionService()

class IdeashellSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession = AssistSession(this)
}

/** 有的系统要求助手声明识别服务才肯列出：这里只是个占位，真正的识别在语音胶囊里做 */
class IdeashellRecognitionService : RecognitionService() {
    override fun onStartListening(recognizerIntent: Intent?, listener: Callback?) {
        runCatching { listener?.error(SpeechRecognizer.ERROR_CLIENT) }
    }

    override fun onCancel(listener: Callback?) = Unit
    override fun onStopListening(listener: Callback?) = Unit
}

private class AssistSession(context: Context) : VoiceInteractionSession(context) {
    private val handler = Handler(Looper.getMainLooper())
    private val closeLater = Runnable { finish() }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        // 没有自己的界面：直接起语音胶囊；屏幕快照随后由 onHandleAssist 送到，等一小会儿再收起会话
        runCatching { VoiceCapsuleService.startAssist(context) }
        handler.removeCallbacks(closeLater)
        handler.postDelayed(closeLater, 1500)
    }

    @Suppress("OVERRIDE_DEPRECATION")
    override fun onHandleAssist(data: Bundle?, structure: AssistStructure?, content: AssistContent?) {
        if (structure == null) return
        runCatching {
            val own = context.packageName
            val pkg = structure.activityComponent?.packageName.orEmpty()
            if (pkg == own || pkg.contains("bank", true) || pkg.contains("pay", true)) return
            val out = StringBuilder()
            val max = ScreenContext.MAX_CHARS
            fun walk(n: AssistStructure.ViewNode, depth: Int) {
                if (depth > 40 || out.length >= max || n.visibility != android.view.View.VISIBLE) return
                val password = n.inputType and InputType.TYPE_TEXT_VARIATION_PASSWORD != 0 ||
                    n.inputType and InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD != 0
                val text = n.text?.toString()?.trim()
                if (!password && !text.isNullOrEmpty()) {
                    if (out.isNotEmpty()) out.append('\n')
                    out.append(text)
                }
                for (i in 0 until n.childCount) walk(n.getChildAt(i), depth + 1)
            }
            for (w in 0 until structure.windowNodeCount) walk(structure.getWindowNodeAt(w).rootViewNode, 0)
            val label = runCatching {
                val pm = context.packageManager
                pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
            }.getOrDefault(pkg)
            if (out.isNotBlank()) ScreenContext.offer(pkg, label, out.toString())
        }
    }

    override fun onHide() {
        handler.removeCallbacks(closeLater)
        super.onHide()
    }
}
