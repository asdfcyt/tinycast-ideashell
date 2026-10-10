package com.carpe.ideashell.ui.diagnostics

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
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
    val clipboard = LocalClipboardManager.current

    Scaffold(
        containerColor = Color.Transparent,
        topBar = {
            TopAppBar(
                title = { Text("连接与诊断") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .padding(horizontal = 16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                "填入凭证后点「测试连接」。凭证只保存在本机（Android Keystore 加密），不会上传到任何第三方。",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
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

            OutlinedButton(
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

            OutlinedTextField(
                value = section.input,
                onValueChange = onInputChange,
                modifier = Modifier.fillMaxWidth(),
                label = { Text(if (section.saved) "$credentialName（已保存，留空则沿用）" else credentialName) },
                supportingText = { Text(hint) },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
            )

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Button(onClick = onRun, enabled = !section.running && (section.saved || section.input.isNotBlank())) {
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
