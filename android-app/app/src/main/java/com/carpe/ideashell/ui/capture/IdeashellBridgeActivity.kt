package com.carpe.ideashell.ui.capture

import android.app.Activity
import android.os.Bundle
import com.carpe.ideashell.system.IdeashellBridge

/**
 * 透明跳板：把「语音录音 / 新建文字笔记 / 闪念贝壳 AI」转给闪念贝壳 App（见 [IdeashellBridge]）。
 * 桌面快捷方式、其他应用 / 自动化工具（Tasker、荣耀任意门等）都从这里进：
 *
 * - `com.carpe.ideashell.action.IDEASHELL_VOICE`
 * - `com.carpe.ideashell.action.IDEASHELL_TEXT`
 * - `com.carpe.ideashell.action.IDEASHELL_ASK_AI`，可带字符串 extra `query`（填进 AI 输入框）
 */
class IdeashellBridgeActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        when (intent?.action) {
            ACTION_VOICE -> IdeashellBridge.startVoiceRecording(this)
            ACTION_TEXT -> IdeashellBridge.newTextNote(this)
            ACTION_ASK_AI -> IdeashellBridge.askAi(this, intent.getStringExtra(EXTRA_QUERY))
        }
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    companion object {
        const val ACTION_VOICE = "com.carpe.ideashell.action.IDEASHELL_VOICE"
        const val ACTION_TEXT = "com.carpe.ideashell.action.IDEASHELL_TEXT"
        const val ACTION_ASK_AI = "com.carpe.ideashell.action.IDEASHELL_ASK_AI"
        const val EXTRA_QUERY = "query"
    }
}
