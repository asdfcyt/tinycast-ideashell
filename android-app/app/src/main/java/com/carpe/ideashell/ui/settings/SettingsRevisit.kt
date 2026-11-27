package com.carpe.ideashell.ui.settings

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Create
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RangeSlider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.R
import com.carpe.ideashell.data.revisit.RevisitToday
import com.carpe.ideashell.ui.glass.GlassAlertDialog as AlertDialog
import kotlinx.coroutines.launch

private enum class RevisitDialog { Limit, Retention, ClozeRange }

private val REVISIT_LIMIT_PRESETS = listOf(3, 5, 8, 10, 15, 20)
private val REVISIT_RETENTION_PRESETS = listOf(80, 85, 90, 95)

/** 首页「重温」那一行的状态摘要 */
internal fun SettingsEnv.revisitSummary(today: RevisitToday): String = when {
    today.remaining > 0 -> "今天有 ${today.remaining} 条待重温"
    today.total == 0 -> "还没有加入的内容"
    today.doneToday > 0 -> "今天已完成 · 共 ${today.total} 条"
    else -> "今天没有待重温的 · 共 ${today.total} 条"
} + if (settings.revisitReminder) " · 每天 ${formatClock(settings.revisitReminderMinutes)} 提醒" else ""

@Composable
internal fun RevisitSection(env: SettingsEnv) {
    val context = env.context
    val container = env.container
    val settings = env.settings
    val scope = rememberCoroutineScope()
    val revisitToday by container.revisit.today.collectAsStateWithLifecycle()
    var dialog by remember { mutableStateOf<RevisitDialog?>(null) }

    val revisitPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) {
            container.settings.setRevisitReminder(true)
        } else {
            settingsToast(context, "没有通知权限，无法发出重温提醒")
        }
    }
    fun setRevisitReminder(enable: Boolean) {
        if (enable && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            revisitPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            container.settings.setRevisitReminder(enable)
        }
    }
    fun pickReminderTime() {
        val minutes = settings.revisitReminderMinutes
        android.app.TimePickerDialog(
            context,
            { _, hour, minute -> container.settings.setRevisitReminderMinutes(hour * 60 + minute) },
            minutes / 60,
            minutes % 60,
            true,
        ).show()
    }
    fun postponeRevisit() {
        scope.launch {
            val before = container.revisit.postponeAll(7)
            settingsToast(
                context,
                if (before.isEmpty()) "现在没有到期的内容" else "已把到期的 ${before.size} 条推后 7 天",
            )
        }
    }

    Group(null) {
        SettingsItem(
            iconRes = R.drawable.ic_revisit,
            title = "开始重温",
            summary = when {
                revisitToday.remaining > 0 -> "今天 ${revisitToday.remaining} 条待重温"
                revisitToday.total == 0 -> "还没有内容"
                revisitToday.doneToday > 0 -> "今天已完成 · 共 ${revisitToday.total} 条"
                else -> "今天没有待重温 · 共 ${revisitToday.total} 条"
            },
            onClick = env.onOpenRevisit,
        )
        SettingsItem(
            icon = Icons.Filled.Star,
            title = "每天最多重温",
            summary = "${settings.revisitDailyLimit} 条",
            onClick = { dialog = RevisitDialog.Limit },
        )
        SettingsSwitchItem(
            icon = Icons.Filled.Notifications,
            title = "每天提醒",
            summary = "",
            checked = settings.revisitReminder,
            onChange = { setRevisitReminder(it) },
        )
        if (settings.revisitReminder) {
            SettingsItem(
                icon = Icons.Filled.DateRange,
                title = "提醒时间",
                summary = formatClock(settings.revisitReminderMinutes),
                onClick = { pickReminderTime() },
            )
            SettingsSwitchItem(
                icon = Icons.Filled.Favorite,
                title = "周末不提醒",
                summary = "",
                checked = settings.revisitSkipWeekends,
                onChange = { container.settings.setRevisitSkipWeekends(it) },
            )
        }
        SettingsSwitchItem(
            icon = Icons.Filled.Create,
            title = "填空模式",
            summary = "",
            checked = settings.revisitCloze,
            onChange = { container.settings.setRevisitCloze(it) },
        )
    }

    AdvancedGroup(key = "revisit", summary = "目标记忆率 · 自动挖空比例 · 全部推后 7 天") {
        SettingsItem(
            icon = Icons.Filled.Refresh,
            title = "目标记忆率",
            summary = "${settings.revisitRetention}%",
            onClick = { dialog = RevisitDialog.Retention },
        )
        if (settings.revisitCloze) {
            SettingsItem(
                icon = Icons.Filled.Create,
                title = "自动挖空比例",
                summary = "${settings.clozeMinPercent}% – ${settings.clozeMaxPercent}%",
                onClick = { dialog = RevisitDialog.ClozeRange },
            )
        }
        SettingsItem(
            icon = Icons.Filled.DateRange,
            title = "全部推后 7 天",
            summary = "",
            onClick = { postponeRevisit() },
        )
    }

    when (dialog) {
        RevisitDialog.Limit -> ChoiceDialog(
            title = "每天最多重温",
            options = (REVISIT_LIMIT_PRESETS + settings.revisitDailyLimit).distinct().sorted(),
            current = settings.revisitDailyLimit,
            label = { "$it 条" },
            onSelect = { container.settings.setRevisitDailyLimit(it) },
            onDismiss = { dialog = null },
        )

        RevisitDialog.Retention -> ChoiceDialog(
            title = "目标记忆率",
            options = REVISIT_RETENTION_PRESETS,
            current = settings.revisitRetention,
            label = { "$it%" + if (it == 90) "（默认）" else "" },
            onSelect = { container.settings.setRevisitRetention(it) },
            onDismiss = { dialog = null },
        )

        RevisitDialog.ClozeRange -> ClozeRangeDialog(
            minPercent = settings.clozeMinPercent,
            maxPercent = settings.clozeMaxPercent,
            onConfirm = { lo, hi -> container.settings.setClozeRange(lo, hi) },
            onDismiss = { dialog = null },
        )

        null -> Unit
    }
}

/** 自动挖空比例：拖两端的圆点定范围 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ClozeRangeDialog(minPercent: Int, maxPercent: Int, onConfirm: (Int, Int) -> Unit, onDismiss: () -> Unit) {
    var range by remember { mutableStateOf(minPercent.toFloat()..maxPercent.toFloat()) }
    val lo = range.start.toInt()
    val hi = range.endInclusive.toInt()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("自动挖空比例") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    if (lo == hi) "挖掉约 $lo% 的字" else "挖掉 $lo% – $hi% 的字",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                )
                RangeSlider(
                    value = range,
                    onValueChange = { range = it },
                    valueRange = 5f..60f,
                    steps = 54,
                )
                Text(
                    "比例小只挖关键词，比例大几乎每个词都要回忆",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = { TextButton(onClick = { onConfirm(lo, hi); onDismiss() }) { Text("确定") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}
