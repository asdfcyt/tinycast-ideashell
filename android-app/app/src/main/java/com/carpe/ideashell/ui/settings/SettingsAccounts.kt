package com.carpe.ideashell.ui.settings

import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Search
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import com.carpe.ideashell.R
import com.carpe.ideashell.ui.components.AppTextField
import com.carpe.ideashell.ui.components.InputSheet
import com.carpe.ideashell.ui.components.ListGroup
import com.carpe.ideashell.ui.components.RowDivider

private enum class AccountDialog { Ocr, Llm }

/** 首页「账号与连接」那一行的状态摘要 */
internal fun SettingsEnv.accountsSummary(): String {
    val ok = buildList {
        if (ideashellConnected) add("闪念贝壳")
        if (didaConnected) add("滴答清单")
        if (ocrConfigured) add("腾讯云")
        if (llmConfigured) add("大模型")
    }
    val missing = buildList {
        if (!ideashellConnected) add("闪念贝壳")
        if (!didaConnected) add("滴答清单")
        if (!ocrConfigured) add("腾讯云")
        if (!llmConfigured) add("大模型")
    }
    return when {
        missing.isEmpty() -> ""
        ok.isEmpty() -> "未配置：${missing.joinToString("、")}"
        else -> "未配置：${missing.joinToString("、")}"
    }
}

/**
 * 账号与连接：所有凭证只在这里改，其他页面（语音、OCR、AI）只显示状态并跳到这里。
 */
@Composable
internal fun AccountsSection(env: SettingsEnv) {
    val container = env.container
    val settings = env.settings
    var dialog by remember { mutableStateOf<AccountDialog?>(null) }

    Group("记录与待办") {
        SettingsItem(
            icon = Icons.Filled.Lock,
            title = "闪念贝壳",
            summary = if (env.ideashellConnected) "" else "未连接",
            onClick = env.onOpenConnection,
        )
        SettingsItem(
            icon = Icons.Filled.CheckCircle,
            title = "滴答清单",
            summary = if (env.didaConnected) "" else "未连接",
            onClick = env.onOpenConnection,
        )
    }

    Group("识别与整理") {
        SettingsItem(
            icon = Icons.Filled.Search,
            title = "腾讯云密钥",
            summary = if (env.ocrConfigured) "" else "未配置",
            onClick = { dialog = AccountDialog.Ocr },
        )
        SettingsItem(
            iconRes = R.drawable.ic_sparkle,
            title = "大模型接口",
            summary = if (env.llmConfigured) "" else "未配置",
            onClick = { dialog = AccountDialog.Llm },
        )
    }


    when (dialog) {
        AccountDialog.Ocr -> OcrKeyDialog(
            initialId = container.credentials.tencentSecretId.orEmpty(),
            initialKey = container.credentials.tencentSecretKey.orEmpty(),
            onConfirm = { id, key -> container.credentials.setTencentOcr(id, key) },
            onDismiss = { dialog = null },
        )

        AccountDialog.Llm -> LlmConfigDialog(
            initialBaseUrl = settings.llmBaseUrl,
            initialModel = settings.llmModel,
            initialKey = container.credentials.llmKey.orEmpty(),
            onConfirm = { url, model, key ->
                container.settings.setLlm(url, model)
                container.credentials.llmKey = key
            },
            onDismiss = { dialog = null },
        )

        null -> Unit
    }
}

/** 大模型接口：任意 OpenAI 兼容服务（接口地址 + 模型名 + Key）。Key 留空保存即清除 */
@Composable
private fun LlmConfigDialog(
    initialBaseUrl: String,
    initialModel: String,
    initialKey: String,
    onConfirm: (String, String, String) -> Unit,
    onDismiss: () -> Unit,
) {
    var url by remember { mutableStateOf(initialBaseUrl) }
    var model by remember { mutableStateOf(initialModel) }
    var key by remember { mutableStateOf(initialKey) }
    InputSheet(
        title = "大模型接口",
        hint = "OpenAI 兼容接口，地址填到 /v1 为止",
        onDismiss = onDismiss,
        onConfirm = {
            onConfirm(url.trim(), model.trim(), key.trim())
            onDismiss()
        },
    ) {
        ListGroup {
            AppTextField(
                value = url,
                onValueChange = { url = it },
                label = "接口地址",
                placeholder = "https://dashscope.aliyuncs.com/compatible-mode/v1",
                autoFocus = true,
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
            )
            RowDivider()
            AppTextField(
                value = model,
                onValueChange = { model = it },
                label = "模型",
                placeholder = "qwen-plus",
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
            )
            RowDivider()
            AppTextField(
                value = key,
                onValueChange = { key = it },
                label = "API Key",
                placeholder = "sk-…",
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            )
        }
    }
}

/** 腾讯云密钥：到腾讯云控制台「访问管理 → API 密钥管理」创建，并开通「文字识别」「语音识别」 */
@Composable
private fun OcrKeyDialog(
    initialId: String,
    initialKey: String,
    onConfirm: (String, String) -> Unit,
    onDismiss: () -> Unit,
) {
    var id by remember { mutableStateOf(initialId) }
    var key by remember { mutableStateOf(initialKey) }
    InputSheet(
        title = "腾讯云密钥",
        hint = "文字识别、语音识别共用；两项留空保存即清除",
        onDismiss = onDismiss,
        onConfirm = {
            onConfirm(id, key)
            onDismiss()
        },
    ) {
        ListGroup {
            AppTextField(
                value = id,
                onValueChange = { id = it },
                label = "SecretId",
                placeholder = "AKID…",
                autoFocus = true,
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
            )
            RowDivider()
            AppTextField(
                value = key,
                onValueChange = { key = it },
                label = "SecretKey",
                placeholder = "点这里输入",
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            )
        }
    }
}
