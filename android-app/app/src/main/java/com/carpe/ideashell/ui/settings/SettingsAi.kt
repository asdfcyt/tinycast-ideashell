package com.carpe.ideashell.ui.settings

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Send
import androidx.compose.runtime.Composable
import com.carpe.ideashell.R
import com.carpe.ideashell.system.ExcerptService

/** 首页「AI 与大模型」那一行的状态摘要 */
internal fun SettingsEnv.aiSummary(): String =
    if (llmConfigured) "" else "大模型未配置"

@Composable
internal fun AiSection(env: SettingsEnv) {
    val settings = env.settings
    val container = env.container
    val context = env.context

    Group("大模型") {
        SettingsItem(
            iconRes = R.drawable.ic_sparkle,
            title = "大模型接口",
            summary = if (env.llmConfigured) "" else "未配置",
            onClick = { env.go(SEC_ACCOUNTS) },
            trailing = { Chevron() },
        )
    }
    Group("闪念贝壳 AI") {
        SettingsSwitchItem(
            icon = Icons.Filled.Send,
            title = "问 AI 自动发送",
            summary = if (settings.aiAutoSend && !env.excerptServiceOn) "还差无障碍服务 · 点此前往" else "",
            checked = settings.aiAutoSend,
            onChange = {
                container.settings.setAiAutoSend(it)
                if (it && !env.excerptServiceOn) ExcerptService.openAccessibilitySettings(context)
            },
        )
    }
}
