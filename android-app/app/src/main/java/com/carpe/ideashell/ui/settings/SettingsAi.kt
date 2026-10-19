package com.carpe.ideashell.ui.settings

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Send
import androidx.compose.runtime.Composable
import com.carpe.ideashell.R
import com.carpe.ideashell.system.ExcerptService

/** 首页「AI 与大模型」那一行的状态摘要 */
internal fun SettingsEnv.aiSummary(): String =
    (if (llmConfigured) "大模型已配置 · ${settings.llmModel}" else "大模型未配置") +
        " · 问 AI 自动发送${if (settings.aiAutoSend) "已开" else "已关"}"

@Composable
internal fun AiSection(env: SettingsEnv) {
    val settings = env.settings
    val container = env.container
    val context = env.context

    Group("大模型") {
        SettingsItem(
            iconRes = R.drawable.ic_sparkle,
            title = "大模型接口",
            summary = (if (env.llmConfigured) "已配置" else "未配置 · 点这里去「账号与连接」填 API Key") +
                " · ${settings.llmModel} · ${settings.llmBaseUrl}",
            onClick = { env.go(SEC_ACCOUNTS) },
            trailing = { Chevron() },
        )
    }
    Group("闪念贝壳 AI") {
        SettingsSwitchItem(
            icon = Icons.Filled.Send,
            title = "问 AI 自动发送",
            summary = when {
                !settings.aiAutoSend -> "关闭 · 从拾忆转交问题到闪念贝壳 AI 时，只把问题填进输入框，需要自己点发送"
                env.excerptServiceOn -> "已开启 · 转交问题后自动点发送键。仅在转交后几秒内、且前台是闪念贝壳时动作"
                else -> "还差一步 · 请在「无障碍」里打开「拾忆」（点此前往，一个开关管摘录、自动发送、音量键说话）"
            },
            checked = settings.aiAutoSend,
            onChange = {
                container.settings.setAiAutoSend(it)
                if (it && !env.excerptServiceOn) ExcerptService.openAccessibilitySettings(context)
            },
        )
    }
    SettingsNote(
        "大模型使用 OpenAI 兼容接口，默认通义千问（DashScope）；用于语音整理（判断待办 / 日记 / 笔记、推算日期时间、修改待办）和专注记录润色。「问 AI 自动发送」是把问题转交到闪念贝壳 AI 后帮你点发送键。",
    )
}
