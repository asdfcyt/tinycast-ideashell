package com.carpe.ideashell.ui.diagnostics

import com.carpe.ideashell.ui.glass.GlassButton
import com.carpe.ideashell.ui.glass.GlassOutlinedButton
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import com.carpe.ideashell.ui.glass.GlassAlertDialog as AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import com.carpe.ideashell.ui.components.AppTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.style.TextOverflow
import com.carpe.ideashell.data.db.CaptureEntity
import com.carpe.ideashell.data.db.CaptureStatus
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.carpe.ideashell.data.diagnostics.McpTarget
import com.carpe.ideashell.data.diagnostics.StepResult
import com.carpe.ideashell.ui.components.CircleIconButton
import com.carpe.ideashell.ui.components.ScreenHeader
import com.carpe.ideashell.ui.glass.GlassSurface
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding

/** 连接与诊断：填凭证 → 逐步检查两个 MCP 是否连通 → 可复制诊断报告 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DiagnosticsScreen(
    onBack: () -> Unit,
    viewModel: DiagnosticsViewModel = viewModel(factory = DiagnosticsViewModel.Factory),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val queue by viewModel.queue.collectAsStateWithLifecycle()
    val clipboard = LocalClipboardManager.current

    Scaffold(
        containerColor = Color.Transparent,
        contentWindowInsets = WindowInsets.statusBars,
    ) { padding ->
      Column(Modifier.padding(padding)) {
        ScreenHeader(
            title = "连接与诊断",
            action = { CircleIconButton(Icons.AutoMirrored.Filled.ArrowBack, "返回", onBack) },
        )
        Column(
            modifier = Modifier
                .weight(1f)
                .padding(horizontal = 16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                "填入凭证后点「测试连接」。凭证只保存在本机（Android Keystore 加密），不会上传到任何第三方。",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            QueueCard(
                items = queue,
                onRetry = viewModel::retry,
                onRetryAll = viewModel::retryAll,
                onSyncNow = viewModel::syncNow,
                onDiscard = viewModel::discard,
                onDiscardAllFailed = viewModel::discardAllFailed,
            )

            for (target in McpTarget.entries) {
                TargetCard(
                    target = target,
                    section = state.section(target),
                    onInputChange = { viewModel.onInputChange(target, it) },
                    onRun = { viewModel.runCheck(target) },
                    onClear = { viewModel.clearCredential(target) },
                )
            }

            GlassOutlinedButton(
                onClick = { clipboard.setText(AnnotatedString(viewModel.buildReport())) },
                modifier = Modifier.fillMaxWidth(),
            ) { Text("复制诊断报告（不含凭证）") }

            Text(
                "报告里会包含笔记 / 项目名称的一小段预览，粘贴给他人前请留意。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(LocalBottomBarPadding.current + 8.dp))
        }
      }
    }
}

/** 同步队列：没发出去的记录一目了然，失败的可以逐条 / 一键重试，也可以丢弃 */
@Composable
private fun QueueCard(
    items: List<CaptureEntity>,
    onRetry: (Long) -> Unit,
    onRetryAll: () -> Unit,
    onSyncNow: () -> Unit,
    onDiscard: (Long) -> Unit,
    onDiscardAllFailed: () -> Unit,
) {
    val failed = items.count { it.status == CaptureStatus.FAILED.name }
    val waiting = items.size - failed
    // 要二次确认的丢弃：某一条的 id；ALL 表示丢弃全部失败的
    var confirm by remember { mutableStateOf<Long?>(null) }

    GlassSurface(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("同步队列", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                Text(
                    when {
                        items.isEmpty() -> "全部已同步"
                        failed > 0 && waiting > 0 -> "待发送 $waiting 条 · 失败 $failed 条"
                        failed > 0 -> "失败 $failed 条"
                        else -> "待发送 $waiting 条"
                    },
                    style = MaterialTheme.typography.labelLarge,
                    color = if (failed > 0) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (items.isEmpty()) {
                Text(
                    "记录会先存在本机，再在后台同步到闪念贝壳 / 滴答清单。没同步成功的会出现在这里。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                items.take(QUEUE_SHOWN).forEach { item ->
                    QueueRow(item, onRetry = { onRetry(item.id) }, onDiscard = { confirm = item.id })
                }
                if (items.size > QUEUE_SHOWN) {
                    Text(
                        "还有 ${items.size - QUEUE_SHOWN} 条没有列出",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (failed > 0) {
                        GlassButton(onClick = onRetryAll) { Text("全部重试") }
                        TextButton(onClick = { confirm = ALL }) { Text("丢弃失败的") }
                    } else {
                        GlassOutlinedButton(onClick = onSyncNow) { Text("立即同步") }
                    }
                }
            }
        }
    }

    confirm?.let { target ->
        AlertDialog(
            onDismissRequest = { confirm = null },
            title = { Text(if (target == ALL) "丢弃所有失败的记录？" else "丢弃这条记录？") },
            text = { Text("丢弃后无法恢复，这些内容不会再同步到闪念贝壳 / 滴答清单。") },
            confirmButton = {
                TextButton(onClick = {
                    confirm = null
                    if (target == ALL) onDiscardAllFailed() else onDiscard(target)
                }) { Text("丢弃", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirm = null }) { Text("取消") } },
        )
    }
}

@Composable
private fun QueueRow(item: CaptureEntity, onRetry: () -> Unit, onDiscard: () -> Unit) {
    val failed = item.status == CaptureStatus.FAILED.name
    val sending = item.status == CaptureStatus.SENDING.name
    val statusText = when {
        failed -> "失败：${item.lastError ?: "未知原因"}"
        sending -> "发送中…"
        item.attempts > 0 -> "已重试 ${item.attempts} 次，稍后再试：${item.lastError ?: "网络异常"}"
        else -> "等待发送"
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(item.summary, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                statusText,
                style = MaterialTheme.typography.bodySmall,
                color = if (failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (failed) TextButton(onClick = onRetry) { Text("重试") }
        if (!sending) TextButton(onClick = onDiscard) { Text("丢弃") }
    }
}

private const val QUEUE_SHOWN = 20
private const val ALL = -1L

@Composable
private fun TargetCard(
    target: McpTarget,
    section: SectionState,
    onInputChange: (String) -> Unit,
    onRun: () -> Unit,
    onClear: () -> Unit,
) {
    val credentialName = if (target == McpTarget.IDEASHELL) "API Key" else "API 口令"
    val hint = if (target == McpTarget.IDEASHELL) "闪念贝壳 App：设置 → MCP" else "网页版滴答：头像 → 设置 → 账户与安全 → API 口令"

    GlassSurface(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(target.label, style = MaterialTheme.typography.titleMedium)

            AppTextField(
                value = section.input,
                onValueChange = onInputChange,
                label = if (section.saved) "$credentialName（已保存，留空则沿用）" else credentialName,
                placeholder = "粘贴$credentialName",
                supportingText = hint,
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions.Default,
                // 外面已经是一张白色块，不再额外缩进
                horizontalPadding = 0.dp,
            )

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                GlassButton(onClick = onRun, enabled = !section.running && (section.saved || section.input.isNotBlank())) {
                    Text("测试连接")
                }
                if (section.saved) {
                    TextButton(onClick = onClear, enabled = !section.running) { Text("清除凭证") }
                }
                if (section.running) CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
            }

            section.steps.forEach { StepRow(it) }
        }
    }
}

@Composable
private fun StepRow(step: StepResult) {
    val tint = if (step.ok) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(
            imageVector = if (step.ok) Icons.Filled.Check else Icons.Filled.Close,
            contentDescription = if (step.ok) "成功" else "失败",
            tint = tint,
            modifier = Modifier
                .padding(top = 2.dp)
                .size(20.dp),
        )
        Column(Modifier.weight(1f)) {
            Text("${step.title} · ${step.millis}ms", style = MaterialTheme.typography.titleSmall, color = tint)
            SelectionContainer {
                Text(step.detail, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}
