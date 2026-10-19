package com.carpe.ideashell.ui.settings

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.carpe.ideashell.R
import com.carpe.ideashell.ui.glass.GlassAlertDialog as AlertDialog

private enum class TodoDialog { FocusGoal, ShortBreak, LongBreak }

private val FOCUS_GOAL_PRESETS = listOf(30, 60, 90, 120, 180, 240, 300, 360)
private val SHORT_BREAK_PRESETS = listOf(3, 5, 8, 10, 15)
private val LONG_BREAK_PRESETS = listOf(10, 15, 20, 25, 30)

internal fun formatGoal(min: Int): String = when {
    min < 60 -> "$min 分钟"
    min % 60 == 0 -> "${min / 60} 小时"
    else -> "${min / 60} 小时 ${min % 60} 分钟"
}

/** 首页「待办与专注」那一行的状态摘要 */
internal fun SettingsEnv.todoSummary(): String =
    "专注目标 ${formatGoal(settings.focusGoalMin)} · 常驻通知${if (settings.persistentNotification) "已开" else "已关"}"

@Composable
internal fun TodoFocusSection(env: SettingsEnv) {
    val context = env.context
    val container = env.container
    val settings = env.settings
    var dialog by remember { mutableStateOf<TodoDialog?>(null) }

    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) {
            container.settings.setPersistentNotification(true)
        } else {
            settingsToast(context, "没有通知权限，无法显示常驻通知")
        }
    }
    fun setPersistentNotification(enable: Boolean) {
        when {
            !enable -> container.settings.setPersistentNotification(false)
            !env.didaConnected -> settingsToast(context, "请先连接滴答清单")
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED ->
                notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)

            else -> container.settings.setPersistentNotification(true)
        }
    }

    Group(null) {
        SettingsItem(
            icon = Icons.Filled.Star,
            title = "每日专注目标",
            summary = "${formatGoal(settings.focusGoalMin)} · 「今天」页的专注环以它为满环",
            onClick = { dialog = TodoDialog.FocusGoal },
        )
        SettingsSwitchItem(
            iconRes = R.drawable.ic_tile_focus,
            title = "专注完成后自动休息",
            summary = "番茄走完立刻开始休息倒计时；关闭时只在通知和专注页上提供「开始休息」",
            checked = settings.autoBreak,
            onChange = { container.settings.setAutoBreak(it) },
        )
        SettingsSwitchItem(
            icon = Icons.Filled.Notifications,
            title = "常驻通知",
            summary = "通知栏显示「今天 N · 逾期 M」，可直接回复快记、点完成。系统可能允许你划掉它，下次刷新会重新出现",
            checked = settings.persistentNotification,
            onChange = { setPersistentNotification(it) },
        )
        SettingsSwitchItem(
            icon = Icons.Filled.DateRange,
            title = "每晚自动生成今日小结",
            summary = "每晚 23:20 把今天完成的任务和专注时长插到今天 Daily Note 最前面（需要连接滴答清单）",
            checked = settings.autoDaySummary,
            onChange = { container.settings.setAutoDaySummary(it) },
        )
    }

    AdvancedGroup(key = "todo", summary = "短休息时长 · 长休息时长") {
        SettingsItem(
            icon = Icons.Filled.Check,
            title = "短休息时长",
            summary = "${settings.shortBreakMin} 分钟 · 每个番茄之后",
            onClick = { dialog = TodoDialog.ShortBreak },
        )
        SettingsItem(
            icon = Icons.Filled.DateRange,
            title = "长休息时长",
            summary = "${settings.longBreakMin} 分钟 · 每完成 4 个番茄之后",
            onClick = { dialog = TodoDialog.LongBreak },
        )
    }

    when (dialog) {
        TodoDialog.FocusGoal -> FocusGoalDialog(
            current = settings.focusGoalMin,
            onSelect = { container.settings.setFocusGoalMin(it) },
            onDismiss = { dialog = null },
        )

        TodoDialog.ShortBreak -> ChoiceDialog(
            title = "短休息时长",
            options = (SHORT_BREAK_PRESETS + settings.shortBreakMin).distinct().sorted(),
            current = settings.shortBreakMin,
            label = { "$it 分钟" + if (it == 5) "（默认）" else "" },
            onSelect = { container.settings.setShortBreakMin(it) },
            onDismiss = { dialog = null },
        )

        TodoDialog.LongBreak -> ChoiceDialog(
            title = "长休息时长",
            options = (LONG_BREAK_PRESETS + settings.longBreakMin).distinct().sorted(),
            current = settings.longBreakMin,
            label = { "$it 分钟" + if (it == 15) "（默认）" else "" },
            onSelect = { container.settings.setLongBreakMin(it) },
            onDismiss = { dialog = null },
        )

        null -> Unit
    }
}

@Composable
private fun FocusGoalDialog(current: Int, onSelect: (Int) -> Unit, onDismiss: () -> Unit) {
    val options = (FOCUS_GOAL_PRESETS + current).distinct().sorted()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("每日专注目标") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                options.forEach { min ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .selectable(
                                selected = min == current,
                                role = Role.RadioButton,
                                onClick = {
                                    onSelect(min)
                                    onDismiss()
                                },
                            )
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = min == current, onClick = null)
                        Text(formatGoal(min), modifier = Modifier.padding(start = 12.dp))
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}
