package com.carpe.ideashell.ui.settings

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.data.voice.IntentKinds
import com.carpe.ideashell.data.voice.IntentRegression
import com.carpe.ideashell.ui.components.RowDivider
import com.carpe.ideashell.ui.glass.GlassAlertDialog as AlertDialog
import kotlinx.coroutines.launch

/**
 * 语音历史页里的「意图回归集」：内置样本 + 自己攒的样本，一键让当前的大模型整理一遍，列出判错的。
 * 改完提示词跑一遍，就知道有没有改好一个坏一个。
 */
@Composable
internal fun IntentRegressionSection() {
    val context = LocalContext.current
    val container = (context.applicationContext as IdeashellApp).container
    val mine by container.intentCases.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var running by remember { mutableStateOf(false) }
    var progress by remember { mutableStateOf(0 to 0) }
    var outcomes by remember { mutableStateOf<List<IntentRegression.Outcome>?>(null) }
    val total = container.intentCases.all().size

    Group(null) {
        SettingsItem(
            icon = Icons.Filled.Star,
            title = if (running) "回归中 ${progress.first} / ${progress.second}" else "跑意图回归",
            summary = "$total 条",
            onClick = if (running) null else {
                {
                    if (!container.llm.configured) {
                        toastText(context, "还没有填写大模型 API Key")
                    } else {
                        running = true
                        scope.launch {
                            outcomes = try {
                                IntentRegression.run(container, container.intentCases.all()) { d, t -> progress = d to t }
                            } finally {
                                running = false
                            }
                        }
                    }
                }
            },
        )
        if (mine.isNotEmpty()) {
            RowDivider()
            SettingsItem(
                icon = Icons.Filled.Info,
                title = "复制我加的样本",
                summary = "${mine.size} 条",
                onClick = {
                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    cm.setPrimaryClip(ClipData.newPlainText("意图回归样本", container.intentCases.exportJson()))
                    toastText(context, "已复制")
                },
            )
            RowDivider()
            SettingsItem(
                icon = Icons.Filled.Close,
                title = "清空我加的样本",
                summary = "",
                onClick = { container.intentCases.clear() },
            )
        }
    }

    outcomes?.let { list ->
        val bad = list.filterNot { it.ok }
        Group(if (bad.isEmpty()) "全部通过 ${list.size} / ${list.size}" else "通过 ${list.size - bad.size} / ${list.size}") {
            bad.forEachIndexed { index, o ->
                if (index > 0) RowDivider()
                Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(o.case.raw, style = MaterialTheme.typography.bodyLarge)
                    if (o.case.ctxRaw != null) {
                        Text("接在「${o.case.ctxRaw}」之后", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Text("应为：" + IntentKinds.labels(o.case.expect), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
                    Text(
                        if (o.error != null && o.actual == null) o.error else "实际：" + IntentKinds.labels(o.actual.orEmpty()),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                    )
                    if (mine.any { it.raw == o.case.raw }) {
                        TextButton(onClick = { container.intentCases.remove(o.case.raw) }) { Text("删除这条样本") }
                    }
                }
            }
        }
    }
}

/** 把一句语音加进回归集：挑它应该被整理成哪几类（默认是当时 AI 判断的结果） */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun AddIntentCaseDialog(raw: String, kinds: String?, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val container = (context.applicationContext as IdeashellApp).container
    val initial = kinds.orEmpty().split(',').filter { it.isNotBlank() }
    var picked by remember { mutableStateOf(initial.toSet()) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("这句话应该是") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(raw, style = MaterialTheme.typography.bodyMedium)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    IntentKinds.ALL.forEach { (token, label) ->
                        FilterChip(
                            selected = token in picked,
                            onClick = { picked = if (token in picked) picked - token else picked + token },
                            label = { Text(label) },
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = picked.isNotEmpty(),
                onClick = {
                    // 没改动：沿用原来的（保留「两个待办」这种重复项）；改过了就按挑的来
                    val expect = if (picked == initial.toSet()) initial.sorted().joinToString(",") else picked.sorted().joinToString(",")
                    container.intentCases.add(raw, expect)
                    toastText(context, "已加入回归集")
                    onDismiss()
                },
            ) { Text("加入") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

private fun toastText(context: Context, text: String) = Toast.makeText(context, text, Toast.LENGTH_SHORT).show()
