package com.carpe.ideashell.ui.settings

import android.Manifest
import android.app.StatusBarManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Create
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.BuildConfig
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.R
import com.carpe.ideashell.data.settings.ThemeMode
import com.carpe.ideashell.ui.components.AppTextField
import com.carpe.ideashell.ui.components.CircleIconButton
import com.carpe.ideashell.ui.components.InputSheet
import com.carpe.ideashell.ui.components.ListGroup
import com.carpe.ideashell.ui.components.RowDivider
import com.carpe.ideashell.system.QuickCaptureTileService
import com.carpe.ideashell.system.FocusWidgetProvider
import com.carpe.ideashell.system.RiverWidgetProvider
import com.carpe.ideashell.system.TodoWidgetProvider
import com.carpe.ideashell.ui.glass.GlassBadge
import com.carpe.ideashell.ui.glass.GlassSurface
import com.carpe.ideashell.ui.glass.LocalBottomBarPadding
import kotlinx.coroutines.launch

private const val SEC_RECORD = "record"
private const val SEC_REVISIT = "revisit"
private const val SEC_TODO = "todo"
private const val SEC_QUICK = "quick"
private const val SEC_BACKGROUND = "background"

private sealed interface Dialog {
    data object Tags : Dialog
    data object DailyFolder : Dialog
    data object Theme : Dialog
    data object FocusGoal : Dialog
    data object AddWidget : Dialog
    data object Ocr : Dialog
    data object RevisitLimit : Dialog
    data object RevisitRetention : Dialog
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(onOpenConnection: () -> Unit, onOpenRevisit: () -> Unit) {
    val context = LocalContext.current
    val container = (context.applicationContext as IdeashellApp).container
    val settings by container.settings.state.collectAsStateWithLifecycle()
    val ideashellConnected by container.credentials.ideashellConnected.collectAsStateWithLifecycle()
    val didaConnected by container.credentials.didaConnected.collectAsStateWithLifecycle()
    val ocrConfigured by container.credentials.ocrConfigured.collectAsStateWithLifecycle()
    val revisitToday by container.revisit.today.collectAsStateWithLifecycle()

    var dialog by remember { mutableStateOf<Dialog?>(null) }
    var batteryIgnored by remember { mutableStateOf(isIgnoringBatteryOptimizations(context)) }
    LifecycleResumeEffect(Unit) {
        batteryIgnored = isIgnoringBatteryOptimizations(context)
        onPauseOrDispose { }
    }

    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) {
            container.settings.setPersistentNotification(true)
        } else {
            Toast.makeText(context, "没有通知权限，无法显示常驻通知", Toast.LENGTH_SHORT).show()
        }
    }
    val scope = rememberCoroutineScope()
    val revisitPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) {
            container.settings.setRevisitReminder(true)
        } else {
            Toast.makeText(context, "没有通知权限，无法发出重温提醒", Toast.LENGTH_SHORT).show()
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
            Toast.makeText(
                context,
                if (before.isEmpty()) "现在没有到期的内容" else "已把到期的 ${before.size} 条推后 7 天",
                Toast.LENGTH_SHORT,
            ).show()
        }
    }

    fun setPersistentNotification(enable: Boolean) {
        when {
            !enable -> container.settings.setPersistentNotification(false)
            !didaConnected -> Toast.makeText(context, "请先连接滴答清单", Toast.LENGTH_SHORT).show()
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED ->
                notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)

            else -> container.settings.setPersistentNotification(true)
        }
    }

    var section by rememberSaveable { mutableStateOf<String?>(null) }
    BackHandler(enabled = section != null) { section = null }

    Scaffold(
        containerColor = Color.Transparent,
        contentWindowInsets = WindowInsets.statusBars,
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = LocalBottomBarPadding.current + 8.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            val sectionTitle = when (section) {
                SEC_RECORD -> "记录"
                SEC_REVISIT -> "重温"
                SEC_TODO -> "待办"
                SEC_QUICK -> "快速入口"
                SEC_BACKGROUND -> "后台同步"
                else -> null
            }
            if (sectionTitle == null) {
                Text(
                    "设置",
                    style = MaterialTheme.typography.headlineSmall,
                    modifier = Modifier.padding(start = 4.dp, top = 16.dp),
                )
            } else {
                SubPageHeader(sectionTitle, onBack = { section = null })
            }

            when (section) {
                null -> {
                    Group("连接") {
                        SettingsItem(
                            icon = Icons.Filled.Lock,
                            title = "闪念贝壳",
                            summary = if (ideashellConnected) "已连接 · 点击可更换或检查连接" else "未连接 · 填入 API Key",
                            onClick = onOpenConnection,
                        )
                        SettingsItem(
                            icon = Icons.Filled.Refresh,
                            title = "滴答清单",
                            summary = if (didaConnected) "已连接 · 待办直接建到滴答" else "未连接 · 待办会先建到闪念贝壳",
                            onClick = onOpenConnection,
                        )
                    }

                    Group("功能") {
                        SettingsItem(
                            icon = Icons.Filled.Star,
                            title = "记录",
                            summary = "${settings.defaultTagsText.ifEmpty { "无默认标签" }} · ${settings.dailyFolder}",
                            onClick = { section = SEC_RECORD },
                            trailing = { Chevron() },
                        )
                        SettingsItem(
                            icon = Icons.Filled.Refresh,
                            title = "重温",
                            summary = when {
                                revisitToday.remaining > 0 -> "今天有 ${revisitToday.remaining} 条待重温"
                                revisitToday.total == 0 -> "还没有加入的内容"
                                revisitToday.doneToday > 0 -> "今天已完成 · 共 ${revisitToday.total} 条"
                                else -> "今天没有待重温的 · 共 ${revisitToday.total} 条"
                            } + if (settings.revisitReminder) " · 每天 ${formatClock(settings.revisitReminderMinutes)} 提醒" else "",
                            onClick = { section = SEC_REVISIT },
                            trailing = { Chevron() },
                        )
                        SettingsItem(
                            icon = Icons.Filled.DateRange,
                            title = "待办",
                            summary = "专注目标 ${formatGoal(settings.focusGoalMin)} · 常驻通知${if (settings.persistentNotification) "已开" else "已关"}",
                            onClick = { section = SEC_TODO },
                            trailing = { Chevron() },
                        )
                        SettingsItem(
                            icon = Icons.Filled.Create,
                            title = "腾讯云文字识别",
                            summary = if (ocrConfigured) "已配置 · 记一条里点相机，开启「识别文字」后拍照录入笔记" else "未配置 · 填入腾讯云 SecretId / SecretKey 后，可拍照识别文字快速录入",
                            onClick = { dialog = Dialog.Ocr },
                        )
                    }

                    Group("系统") {
                        SettingsItem(
                            icon = Icons.Filled.Settings,
                            title = "主题",
                            summary = settings.themeMode.label,
                            onClick = { dialog = Dialog.Theme },
                        )
                        SettingsItem(
                            icon = Icons.Filled.Add,
                            title = "快速入口",
                            summary = "快速设置磁贴 · 分享菜单 · 桌面图标长按",
                            onClick = { section = SEC_QUICK },
                            trailing = { Chevron() },
                        )
                        SettingsItem(
                            icon = Icons.Filled.Notifications,
                            title = "后台同步（荣耀 MagicOS）",
                            summary = if (batteryIgnored) "电池优化已忽略" else "建议开启，离线记下的内容才能及时同步",
                            onClick = { section = SEC_BACKGROUND },
                            trailing = { Chevron() },
                        )
                    }

                    Group("关于") {
                        SettingsItem(
                            icon = Icons.Filled.Info,
                            title = "拾忆",
                            summary = "版本 ${BuildConfig.VERSION_NAME} · 记录自动同步到闪念贝壳与滴答清单",
                            onClick = null,
                        )
                    }
                }

                SEC_RECORD -> Group(null) {
                    SettingsItem(
                        icon = Icons.Filled.Star,
                        title = "默认标签",
                        summary = settings.defaultTagsText.ifEmpty { "无（创建笔记时自动附加，逗号分隔）" },
                        onClick = { dialog = Dialog.Tags },
                    )
                    SettingsItem(
                        icon = Icons.Filled.DateRange,
                        title = "Daily Note 文件夹",
                        summary = settings.dailyFolder,
                        onClick = { dialog = Dialog.DailyFolder },
                    )
                }

                SEC_REVISIT -> Group(null) {
                    SettingsItem(
                        icon = Icons.Filled.Refresh,
                        title = "开始重温",
                        summary = when {
                            revisitToday.remaining > 0 -> "今天有 ${revisitToday.remaining} 条待重温 · 点击开始"
                            revisitToday.total == 0 -> "还没有加入的内容 · 在笔记页点右上角的循环图标，或选中文字加入"
                            revisitToday.doneToday > 0 -> "今天的重温完成了 · 共 ${revisitToday.total} 条在重温"
                            else -> "今天没有待重温的 · 共 ${revisitToday.total} 条在重温"
                        },
                        onClick = onOpenRevisit,
                    )
                    SettingsItem(
                        icon = Icons.Filled.Star,
                        title = "每天最多重温",
                        summary = "${settings.revisitDailyLimit} 条 · 超出的顺延到后面几天，不会一次性全抛出来",
                        onClick = { dialog = Dialog.RevisitLimit },
                    )
                    SettingsItem(
                        icon = Icons.Filled.Refresh,
                        title = "目标记忆率",
                        summary = "${settings.revisitRetention}% · 越高出现得越频繁（范围 80%–95%）",
                        onClick = { dialog = Dialog.RevisitRetention },
                    )
                    SettingsItem(
                        icon = Icons.Filled.Notifications,
                        title = "每天提醒",
                        summary = if (settings.revisitReminder) "每天 ${formatClock(settings.revisitReminderMinutes)} 一条通知「今天有 N 条待重温」" else "已关闭 · 「今天」页仍会显示今日重温",
                        onClick = { setRevisitReminder(!settings.revisitReminder) },
                        trailing = {
                            Switch(checked = settings.revisitReminder, onCheckedChange = { setRevisitReminder(it) })
                        },
                    )
                    if (settings.revisitReminder) {
                        SettingsItem(
                            icon = Icons.Filled.DateRange,
                            title = "提醒时间",
                            summary = formatClock(settings.revisitReminderMinutes),
                            onClick = { pickReminderTime() },
                        )
                        SettingsItem(
                            icon = Icons.Filled.Notifications,
                            title = "周末不提醒",
                            summary = "周六、周日不发通知",
                            onClick = { container.settings.setRevisitSkipWeekends(!settings.revisitSkipWeekends) },
                            trailing = {
                                Switch(
                                    checked = settings.revisitSkipWeekends,
                                    onCheckedChange = { container.settings.setRevisitSkipWeekends(it) },
                                )
                            },
                        )
                    }
                    SettingsItem(
                        icon = Icons.Filled.Refresh,
                        title = "全部推后 7 天",
                        summary = "积压太多、一时看不过来时，把现在到期的都往后挪一周",
                        onClick = { postponeRevisit() },
                    )
                }

                SEC_TODO -> Group(null) {
                    SettingsItem(
                        icon = Icons.Filled.Star,
                        title = "每日专注目标",
                        summary = "${formatGoal(settings.focusGoalMin)} · 「今天」页的专注环以它为满环",
                        onClick = { dialog = Dialog.FocusGoal },
                    )
                    SettingsItem(
                        icon = Icons.Filled.Notifications,
                        title = "常驻通知",
                        summary = "通知栏显示「今天 N · 逾期 M」，可直接回复快记、点完成。系统可能允许你划掉它，下次刷新会重新出现",
                        onClick = { setPersistentNotification(!settings.persistentNotification) },
                        trailing = {
                            Switch(
                                checked = settings.persistentNotification,
                                onCheckedChange = { setPersistentNotification(it) },
                            )
                        },
                    )
                    SettingsItem(
                        icon = Icons.Filled.Notifications,
                        title = "每晚自动生成今日小结",
                        summary = "每晚 23:20 把今天完成的任务和专注时长插到今天 Daily Note 最前面（需要连接滴答清单）",
                        onClick = { container.settings.setAutoDaySummary(!settings.autoDaySummary) },
                        trailing = {
                            Switch(
                                checked = settings.autoDaySummary,
                                onCheckedChange = { container.settings.setAutoDaySummary(it) },
                            )
                        },
                    )
                    SettingsItem(
                        icon = Icons.Filled.Add,
                        title = "添加小部件",
                        summary = "待办、专注、记录（时间河）三种，选一个放到桌面。也可以长按桌面空白处 → 小组件 → 拾忆",
                        onClick = { dialog = Dialog.AddWidget },
                    )
                }

                SEC_QUICK -> Group(null) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        SettingsItem(
                            icon = Icons.Filled.Add,
                            title = "添加快速设置磁贴",
                            summary = "下拉通知栏，一点就能弹出输入框",
                            onClick = { requestAddTile(context) },
                        )
                    }
                    SettingsItem(
                        icon = Icons.Filled.Create,
                        title = "其他入口",
                        summary = "任何 App 里点「分享 → 拾忆」；选中文字后点菜单里的「记到拾忆」；长按桌面图标可直达「记一条」「记待办」",
                        onClick = null,
                    )
                }

                SEC_BACKGROUND -> Group(null) {
                    SettingsItem(
                        icon = Icons.Filled.Notifications,
                        title = "忽略电池优化",
                        summary = if (batteryIgnored) "已允许" else "未允许 · 建议开启，离线记下的内容才能及时同步",
                        onClick = { if (!batteryIgnored) requestIgnoreBattery(context) },
                    )
                    SettingsItem(
                        icon = Icons.Filled.Info,
                        title = "应用启动管理",
                        summary = "打开系统的应用信息页。在「应用启动管理」里把「拾忆」改为手动管理，打开「自启动」「关联启动」「后台活动」；再到多任务界面锁定「拾忆」卡片。不同系统版本入口略有差异。",
                        onClick = { openAppDetails(context) },
                    )
                }

                else -> Unit
            }
        }
    }

    when (dialog) {
        Dialog.Tags -> TextInputDialog(
            title = "默认标签",
            label = "标签（逗号分隔）",
            initial = settings.defaultTagsText,
            onConfirm = { container.settings.setDefaultTags(it) },
            onDismiss = { dialog = null },
        )

        Dialog.DailyFolder -> TextInputDialog(
            title = "Daily Note 文件夹",
            label = "文件夹名",
            initial = settings.dailyFolder,
            onConfirm = { container.settings.setDailyFolder(it) },
            onDismiss = { dialog = null },
        )

        Dialog.Theme -> ThemeDialog(
            current = settings.themeMode,
            onSelect = { container.settings.setThemeMode(it) },
            onDismiss = { dialog = null },
        )

        Dialog.FocusGoal -> FocusGoalDialog(
            current = settings.focusGoalMin,
            onSelect = { container.settings.setFocusGoalMin(it) },
            onDismiss = { dialog = null },
        )

        Dialog.RevisitLimit -> ChoiceDialog(
            title = "每天最多重温",
            options = (REVISIT_LIMIT_PRESETS + settings.revisitDailyLimit).distinct().sorted(),
            current = settings.revisitDailyLimit,
            label = { "$it 条" },
            onSelect = { container.settings.setRevisitDailyLimit(it) },
            onDismiss = { dialog = null },
        )

        Dialog.RevisitRetention -> ChoiceDialog(
            title = "目标记忆率",
            options = REVISIT_RETENTION_PRESETS,
            current = settings.revisitRetention,
            label = { "$it%" + if (it == 90) "（默认）" else "" },
            onSelect = { container.settings.setRevisitRetention(it) },
            onDismiss = { dialog = null },
        )

        Dialog.AddWidget -> AddWidgetDialog(
            onPick = { widget -> requestPinWidget(context, widget) },
            onDismiss = { dialog = null },
        )

        Dialog.Ocr -> OcrKeyDialog(
            initialId = container.credentials.tencentSecretId.orEmpty(),
            initialKey = container.credentials.tencentSecretKey.orEmpty(),
            onConfirm = { id, key -> container.credentials.setTencentOcr(id, key) },
            onDismiss = { dialog = null },
        )

        null -> Unit
    }
}

/** 腾讯云文字识别密钥：到腾讯云控制台「访问管理 → API 密钥管理」创建，并在「文字识别」控制台开通服务 */
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
        title = "腾讯云文字识别",
        hint = "在腾讯云控制台开通「文字识别」，并在「访问管理 → API 密钥管理」创建密钥。密钥只保存在本机（加密）。两项都留空并保存即可清除。",
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
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = ImeAction.Next),
            )
            RowDivider()
            AppTextField(
                value = key,
                onValueChange = { key = it },
                label = "SecretKey",
                placeholder = "点这里输入",
                singleLine = true,
                visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = ImeAction.Done),
            )
        }
    }
}

/** 可以放到桌面的小部件 */
private enum class PinnableWidget(val title: String, val summary: String, val provider: Class<*>) {
    Todo("待办", "逾期和今天的待办一眼可见，点圆圈直接完成", TodoWidgetProvider::class.java),
    Focus("专注", "今日专注进度；一键开始、暂停、结束，计入滴答清单", FocusWidgetProvider::class.java),
    River("记录", "最近的日记、笔记和完成的待办，按时间排成一条线", RiverWidgetProvider::class.java),
}

@Composable
private fun AddWidgetDialog(onPick: (PinnableWidget) -> Unit, onDismiss: () -> Unit) {
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
                                onPick(widget)
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

private val REVISIT_LIMIT_PRESETS = listOf(3, 5, 8, 10, 15, 20)
private val REVISIT_RETENTION_PRESETS = listOf(80, 85, 90, 95)

private fun formatClock(minutes: Int): String = "%02d:%02d".format(minutes / 60, minutes % 60)

@Composable
private fun <T> ChoiceDialog(
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

private val FOCUS_GOAL_PRESETS = listOf(30, 60, 90, 120, 180, 240, 300, 360)

private fun formatGoal(min: Int): String = when {
    min < 60 -> "$min 分钟"
    min % 60 == 0 -> "${min / 60} 小时"
    else -> "${min / 60} 小时 ${min % 60} 分钟"
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

@Composable
private fun Group(title: String?, content: @Composable ColumnScope.() -> Unit) {
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
private fun SubPageHeader(title: String, onBack: () -> Unit) {
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
private fun Chevron() {
    Icon(
        Icons.AutoMirrored.Filled.KeyboardArrowRight,
        contentDescription = null,
        tint = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun SettingsItem(
    icon: ImageVector,
    title: String,
    summary: String,
    onClick: (() -> Unit)?,
    trailing: (@Composable () -> Unit)? = null,
) {
    ListItem(
        modifier = if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier,
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        leadingContent = { GlassBadge(icon) },
        headlineContent = { Text(title, style = MaterialTheme.typography.titleMedium) },
        supportingContent = { Text(summary, style = MaterialTheme.typography.bodyMedium) },
        trailingContent = trailing,
    )
}

@Composable
private fun TextInputDialog(
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

@Composable
private fun ThemeDialog(current: ThemeMode, onSelect: (ThemeMode) -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("主题") },
        text = {
            Column {
                ThemeMode.entries.forEach { mode ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .selectable(
                                selected = mode == current,
                                role = Role.RadioButton,
                                onClick = {
                                    onSelect(mode)
                                    onDismiss()
                                },
                            )
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = mode == current, onClick = null)
                        Text(mode.label, modifier = Modifier.padding(start = 12.dp))
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

private fun requestAddTile(context: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
    val manager = context.getSystemService(StatusBarManager::class.java)
    if (manager == null) {
        toast(context, "当前系统不支持一键添加，请在通知栏编辑里手动添加「拾忆」磁贴")
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
        if (message != null) toast(context, message)
    }
}

private fun isIgnoringBatteryOptimizations(context: Context): Boolean =
    context.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(context.packageName) == true

private fun requestIgnoreBattery(context: Context) {
    try {
        context.startActivity(
            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    } catch (_: Exception) {
        openAppDetails(context)
    }
}

private fun openAppDetails(context: Context) {
    try {
        context.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    } catch (_: Exception) {
        toast(context, "无法打开系统设置，请手动进入「设置 → 应用」")
    }
}

private fun toast(context: Context, text: String) {
    Toast.makeText(context, text, Toast.LENGTH_LONG).show()
}

/** 请求把小部件固定到桌面；启动器不支持时给出手动添加的提示 */
private fun requestPinWidget(context: Context, widget: PinnableWidget) {
    val manager = AppWidgetManager.getInstance(context)
    if (manager.isRequestPinAppWidgetSupported) {
        manager.requestPinAppWidget(ComponentName(context, widget.provider), null, null)
    } else {
        Toast.makeText(context, "请长按桌面空白处 → 小组件 → 拾忆 → ${widget.title}", Toast.LENGTH_LONG).show()
    }
}
