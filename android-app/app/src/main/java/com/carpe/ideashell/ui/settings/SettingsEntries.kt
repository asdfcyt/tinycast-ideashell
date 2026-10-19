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
    "磁贴 · 小部件 · 分享菜单 · 摘录" + if (settings.excerptMode) "（摘录中）" else ""

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
                summary = "下拉通知栏，一点就能弹出输入框 · 点一下添加",
                onClick = { requestAddTile(context) },
            )
        }
        SettingsItem(
            iconRes = R.drawable.ic_widget_add,
            title = "桌面小部件",
            summary = "待办、专注、记录（时间河）三种，选一个放到桌面。也可以长按桌面空白处 → 小组件 → 拾忆 · 点一下添加",
            onClick = { showWidgets = true },
        )
        SettingsItem(
            icon = Icons.Filled.Share,
            title = "分享菜单与选中文字菜单",
            summary = "任何 App 里点「分享 → 拾忆」；选中文字后点菜单里的「记到拾忆」；长按桌面图标可直达「记一条」「记待办」（无需设置）",
            onClick = null,
        )
    }

    Group("摘录") {
        SettingsSwitchItem(
            iconRes = R.drawable.ic_bolt,
            title = "摘录模式",
            summary = when {
                !settings.excerptMode -> "关闭 · 开启后屏幕边缘出现闪电小胶囊，选中文字后点它，就存成摘录笔记。也可从下拉磁贴「摘录」、长按桌面图标「摘录模式」开启"
                env.excerptServiceOn -> "摘录中 · 在任何 App 选中文字，点屏幕边缘的闪电胶囊。只读取你选中的文字"
                else -> "还差一步 · 请先开启下面的「无障碍服务」"
            },
            checked = settings.excerptMode,
            onChange = {
                container.settings.setExcerptMode(it)
                if (it && !env.excerptServiceOn) ExcerptService.openAccessibilitySettings(context)
            },
        )
        SettingsSwitchItem(
            icon = Icons.Filled.Create,
            title = "摘录后写想法",
            summary = if (settings.excerptWriteNote) "开启 · 摘录后从底部升起抽屉，写下想法、填书名或文章标题和标签；同一个 App 里标题和标签自动延续，连续摘录写进同一篇笔记"
            else "关闭 · 不弹抽屉，摘录直接存进笔记（原文 + 来源），同样追加进同一篇",
            checked = settings.excerptWriteNote,
            onChange = { container.settings.setExcerptWriteNote(it) },
        )
    }

    Group("依赖的权限（只显示状态）") {
        SettingsItem(
            icon = Icons.Filled.Lock,
            title = "无障碍服务",
            summary = if (env.excerptServiceOn) "已开启 · 摘录、音量键说话、问 AI 自动发送共用这一个开关 · 点一下可去系统里管理"
            else "未开启 · 点这里去系统「无障碍」里打开「拾忆」；一个开关管摘录、自动发送、音量键说话",
            onClick = { ExcerptService.openAccessibilitySettings(context) },
        )
        if (!env.excerptServiceOn) {
            SettingsItem(
                icon = Icons.Filled.Warning,
                title = "打不开无障碍开关？",
                summary = "手动安装的应用，系统可能把它标成「受限制」：点这里进应用信息页，右上角菜单 → 「允许受限制的设置」，再回去打开无障碍",
                onClick = { openAppDetails(context) },
            )
        }
        SettingsItem(
            iconRes = R.drawable.ic_tile_voice,
            title = "语音悬浮胶囊",
            summary = if (env.overlayOn) "已开启 · 点磁贴 / 快捷方式「语音记一条」直接浮出录音胶囊" else "未开启 · 需要「显示在其他应用上层」· 点这里去语音输入页设置",
            onClick = { env.go(SEC_VOICE) },
            trailing = { Chevron() },
        )
        SettingsItem(
            icon = Icons.Filled.Info,
            title = "音量键按住说话",
            summary = if (settings.voiceKey == com.carpe.ideashell.data.settings.VoiceKey.OFF) "关闭 · 点这里去语音输入页选一个音量键"
            else "${settings.voiceKey.label} · " + if (env.excerptServiceOn) "已生效" else "还需要开启无障碍服务",
            onClick = { env.go(SEC_VOICE) },
            trailing = { Chevron() },
        )
    }

    SettingsNote(
        "「记一条」面板里：从待办页点「＋」、或长按桌面图标选「记待办」，会直接预设为待办（面板里有提示，点「自动」可改回自动识别；待办页选了某天时还会排在那一天）；磁贴、小部件、分享等入口则由输入内容自动判断类型。",
    )

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

