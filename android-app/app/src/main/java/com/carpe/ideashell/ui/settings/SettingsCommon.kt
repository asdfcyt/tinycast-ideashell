package com.carpe.ideashell.ui.settings

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.widget.Toast
import androidx.annotation.DrawableRes
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.AppContainer
import com.carpe.ideashell.data.settings.AppSettings
import com.carpe.ideashell.ui.components.AppTextField
import com.carpe.ideashell.ui.components.CircleIconButton
import com.carpe.ideashell.ui.components.InputSheet
import com.carpe.ideashell.ui.components.ListGroup
import com.carpe.ideashell.ui.glass.GlassAlertDialog as AlertDialog
import com.carpe.ideashell.ui.glass.GlassBadge
import com.carpe.ideashell.ui.glass.GlassSurface

// ───────────────────────── 页面标识 ─────────────────────────

internal const val SEC_ACCOUNTS = "accounts"
internal const val SEC_RECORD = "record"
internal const val SEC_REVISIT = "revisit"
internal const val SEC_TODO = "todo"
internal const val SEC_QUICK = "quick"
internal const val SEC_BACKGROUND = "background"
internal const val SEC_BACKUP = "backup"
internal const val SEC_VOICE = "voice"
internal const val SEC_OCR = "ocr"
internal const val SEC_AI = "ai"
internal const val SEC_LEXICON = "lexicon"
internal const val SEC_VOICE_HISTORY = "voice_history"

internal fun sectionTitle(section: String?): String? = when (section) {
    SEC_ACCOUNTS -> "账号与连接"
    SEC_RECORD -> "文字记录"
    SEC_REVISIT -> "重温"
    SEC_TODO -> "待办与专注"
    SEC_QUICK -> "入口一览"
    SEC_BACKGROUND -> "后台同步"
    SEC_BACKUP -> "备份与迁移"
    SEC_VOICE -> "语音输入"
    SEC_OCR -> "OCR 输入"
    SEC_AI -> "AI 与大模型"
    SEC_LEXICON -> "语音词库"
    SEC_VOICE_HISTORY -> "语音历史"
    else -> null
}

/**
 * 各个设置页共用的环境：当前设置、各项连接状态、跳转回调。
 * 每个设置页自己维护只和自己有关的状态（弹窗、权限请求、下载进度等）。
 */
@Stable
internal class SettingsEnv(
    val context: Context,
    val container: AppContainer,
    val settings: AppSettings,
    val ideashellConnected: Boolean,
    val didaConnected: Boolean,
    val ocrConfigured: Boolean,
    val llmConfigured: Boolean,
    val excerptServiceOn: Boolean,
    val overlayOn: Boolean,
    val batteryIgnored: Boolean,
    /** 跳到另一个设置页（null = 设置首页） */
    val go: (String?) -> Unit,
    val onOpenConnection: () -> Unit,
    val onOpenRevisit: () -> Unit,
)

// ───────────────────────── 通用组件 ─────────────────────────

@Composable
internal fun Group(title: String?, content: @Composable ColumnScope.() -> Unit) {
    Column {
        if (title != null) {
            Text(
                title,
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(start = 8.dp, bottom = 8.dp),
            )
        }
        GlassSurface(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.fillMaxWidth(), content = content)
        }
    }
}

/** 二级页面的标题栏：返回 + 页面名 */
@Composable
internal fun SubPageHeader(title: String, onBack: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        CircleIconButton(Icons.AutoMirrored.Filled.ArrowBack, "返回", onBack)
        Text(title, style = MaterialTheme.typography.headlineSmall)
    }
}

/** 一级页面里「点进去还有更多」的右箭头 */
@Composable
internal fun Chevron() {
    Icon(
        Icons.AutoMirrored.Filled.KeyboardArrowRight,
        contentDescription = null,
        tint = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

/** [icon]（Material 图标）和 [iconRes]（应用自带线性图标）二选一 */
@Composable
internal fun SettingsItem(
    title: String,
    summary: String,
    onClick: (() -> Unit)?,
    icon: ImageVector? = null,
    @DrawableRes iconRes: Int = 0,
    trailing: (@Composable () -> Unit)? = null,
) {
    ListItem(
        modifier = if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier,
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        leadingContent = {
            when {
                icon != null -> GlassBadge(icon)
                iconRes != 0 -> GlassBadge(iconRes)
            }
        },
        headlineContent = { Text(title, style = MaterialTheme.typography.titleMedium) },
        supportingContent = { Text(summary, style = MaterialTheme.typography.bodyMedium) },
        trailingContent = trailing,
    )
}

/** 带开关的设置项：整行可点 */
@Composable
internal fun SettingsSwitchItem(
    title: String,
    summary: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
    icon: ImageVector? = null,
    @DrawableRes iconRes: Int = 0,
) {
    SettingsItem(
        title = title,
        summary = summary,
        icon = icon,
        iconRes = iconRes,
        onClick = { onChange(!checked) },
        trailing = { Switch(checked = checked, onCheckedChange = onChange) },
    )
}

/** 页面底部的灰色说明文字 */
@Composable
internal fun SettingsNote(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 8.dp),
    )
}

/**
 * 「高级选项」折叠组：默认收起，把不常改的参数收在里面。
 * [key] 用来区分页面，展开状态随页面保存。
 */
@Composable
internal fun AdvancedGroup(key: String, summary: String, content: @Composable ColumnScope.() -> Unit) {
    var open by rememberSaveable(key) { mutableStateOf(false) }
    Group(null) {
        SettingsItem(
            icon = Icons.Filled.Build,
            title = "高级选项",
            summary = if (open) "点一下收起" else summary,
            onClick = { open = !open },
            trailing = {
                Icon(
                    if (open) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            },
        )
        if (open) content()
    }
}

// ───────────────────────── 通用弹窗 ─────────────────────────

@Composable
internal fun <T> ChoiceDialog(
    title: String,
    options: List<T>,
    current: T,
    label: (T) -> String,
    onSelect: (T) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                options.forEach { option ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .selectable(
                                selected = option == current,
                                role = Role.RadioButton,
                                onClick = {
                                    onSelect(option)
                                    onDismiss()
                                },
                            )
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = option == current, onClick = null)
                        Text(label(option), modifier = Modifier.padding(start = 12.dp))
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

@Composable
internal fun TextInputDialog(
    title: String,
    label: String,
    initial: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var value by remember { mutableStateOf(initial) }
    InputSheet(
        title = title,
        onDismiss = onDismiss,
        onConfirm = {
            onConfirm(value)
            onDismiss()
        },
    ) {
        ListGroup {
            AppTextField(
                value = value,
                onValueChange = { value = it },
                label = null,
                placeholder = "点这里输入",
                autoFocus = true,
                singleLine = true,
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = ImeAction.Done),
            )
        }
    }
}

// ───────────────────────── 工具函数 ─────────────────────────

internal fun settingsToast(context: Context, text: String) {
    Toast.makeText(context, text, Toast.LENGTH_LONG).show()
}

internal fun formatDateTime(ms: Long): String =
    java.time.Instant.ofEpochMilli(ms).atZone(java.time.ZoneId.systemDefault())
        .format(java.time.format.DateTimeFormatter.ofPattern("M月d日 HH:mm"))

internal fun formatClock(minutes: Int): String = "%02d:%02d".format(minutes / 60, minutes % 60)

internal fun isIgnoringBatteryOptimizations(context: Context): Boolean =
    context.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(context.packageName) == true

internal fun requestIgnoreBattery(context: Context) {
    try {
        context.startActivity(
            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    } catch (_: Exception) {
        openAppDetails(context)
    }
}

internal fun openAppDetails(context: Context) {
    try {
        context.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    } catch (_: Exception) {
        settingsToast(context, "无法打开系统设置，请手动进入「设置 → 应用」")
    }
}
