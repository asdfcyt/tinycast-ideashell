package com.carpe.ideashell.ui.settings

import android.app.StatusBarManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.os.Build
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Create
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.R
import com.carpe.ideashell.system.ExcerptService
import com.carpe.ideashell.system.FocusWidgetProvider
import com.carpe.ideashell.system.QuickCaptureTileService
import com.carpe.ideashell.system.RiverWidgetProvider
import com.carpe.ideashell.system.TodoWidgetProvider
import com.carpe.ideashell.ui.glass.GlassAlertDialog as AlertDialog

/** 首页「入口一览」那一行的状态摘要 */
internal fun SettingsEnv.entriesSummary(): String =
    ""

/**
 * 入口一览：把所有「怎么把东西记进拾忆」的入口放在一页，每个都带上现在能不能用。
 * 语音相关的开关只在「语音输入」里改，这里只显示状态并跳过去。
 */
@Composable
internal fun EntriesSection(env: SettingsEnv) {
    val context = env.context
    val container = env.container
    val settings = env.settings
    var showWidgets by remember { mutableStateOf(false) }

    Group("添加到系统") {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            SettingsItem(
                iconRes = R.drawable.ic_tile,
                title = "快速设置磁贴",
                summary = "",
                onClick = { requestAddTile(context) },
            )
        }
        SettingsItem(
            iconRes = R.drawable.ic_widget_add,
            title = "桌面小部件",
            summary = "",
            onClick = { showWidgets = true },
        )
        SettingsItem(
            icon = Icons.Filled.Share,
            title = "分享菜单与选中文字菜单",
            summary = "",
            onClick = null,
        )
    }

    Group("摘录") {
        SettingsSwitchItem(
            iconRes = R.drawable.ic_bolt,
            title = "摘录模式",
            summary = if (settings.excerptMode && !env.excerptServiceOn) "还差无障碍服务" else "",
            checked = settings.excerptMode,
            onChange = {
                container.settings.setExcerptMode(it)
                if (it && !env.excerptServiceOn) ExcerptService.openAccessibilitySettings(context)
            },
        )
        SettingsSwitchItem(
            icon = Icons.Filled.Create,
            title = "摘录后写想法",
            summary = "",
            checked = settings.excerptWriteNote,
            onChange = { container.settings.setExcerptWriteNote(it) },
        )
    }

    Group("依赖的权限（只显示状态）") {
        SettingsItem(
            icon = Icons.Filled.Lock,
            title = "无障碍服务",
            summary = if (env.excerptServiceOn) "" else "未开启",
            onClick = { ExcerptService.openAccessibilitySettings(context) },
        )
        if (!env.excerptServiceOn) {
            SettingsItem(
                icon = Icons.Filled.Warning,
                title = "打不开无障碍开关？",
                summary = "",
                onClick = { openAppDetails(context) },
            )
        }
        SettingsItem(
            iconRes = R.drawable.ic_tile_voice,
            title = "语音悬浮胶囊",
            summary = if (env.overlayOn) "" else "未开启",
            onClick = { env.go(SEC_VOICE) },
            trailing = { Chevron() },
        )
        SettingsItem(
            icon = Icons.Filled.Info,
            title = "音量键按住说话",
            summary = if (settings.voiceKey == com.carpe.ideashell.data.settings.VoiceKey.OFF) "" else settings.voiceKey.label,
            onClick = { env.go(SEC_VOICE) },
            trailing = { Chevron() },
        )
    }


    if (showWidgets) AddWidgetDialog(context = context, onDismiss = { showWidgets = false })
}

private fun requestAddTile(context: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
    val manager = context.getSystemService(StatusBarManager::class.java)
    if (manager == null) {
        settingsToast(context, "当前系统不支持一键添加，请在通知栏编辑里手动添加「拾忆」磁贴")
        return
    }
    manager.requestAddTileService(
        ComponentName(context, QuickCaptureTileService::class.java),
        context.getString(R.string.tile_label),
        android.graphics.drawable.Icon.createWithResource(context, R.drawable.ic_tile),
        context.mainExecutor,
    ) { result ->
        val message = when (result) {
            StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> "已添加到快速设置"
            StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> "磁贴已经在快速设置里了"
            StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED -> null
            else -> "系统没有响应，请在通知栏编辑里手动添加「拾忆」磁贴"
        }
        if (message != null) settingsToast(context, message)
    }
}

/** 可以放到桌面的小部件 */
private enum class PinnableWidget(val title: String, val summary: String, val provider: Class<*>) {
    Todo("待办", "逾期和今天的待办一眼可见，点圆圈直接完成", TodoWidgetProvider::class.java),
    Focus("专注", "今日专注进度；一键开始、暂停、结束，计入滴答清单", FocusWidgetProvider::class.java),
    River("记录", "最近的日记、笔记和完成的待办，按时间排成一条线", RiverWidgetProvider::class.java),
}

/** 添加小部件的弹窗 */
@Composable
private fun AddWidgetDialog(context: Context, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("添加小部件") },
        text = {
            Column {
                PinnableWidget.entries.forEach { widget ->
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(role = Role.Button) {
                                requestPinWidget(context, widget)
                                onDismiss()
                            }
                            .padding(vertical = 10.dp),
                    ) {
                        Text(widget.title, style = MaterialTheme.typography.titleMedium)
                        Text(
                            widget.summary,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

/** 请求把小部件固定到桌面；启动器不支持时给出手动添加的提示 */
private fun requestPinWidget(context: Context, widget: PinnableWidget) {
    val manager = AppWidgetManager.getInstance(context)
    if (manager.isRequestPinAppWidgetSupported) {
        manager.requestPinAppWidget(ComponentName(context, widget.provider), null, null)
    } else {
        settingsToast(context, "请长按桌面空白处 → 小组件 → 拾忆 → ${widget.title}")
    }
}

