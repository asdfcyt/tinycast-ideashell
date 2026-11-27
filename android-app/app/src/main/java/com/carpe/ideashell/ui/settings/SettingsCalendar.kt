package com.carpe.ideashell.ui.settings

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material3.Checkbox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.data.calendar.DeviceCalendar
import com.carpe.ideashell.data.calendar.SystemCalendarRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** 首页「日历同步」那一行的状态摘要 */
internal fun SettingsEnv.calendarSummary(): String {
    val st = container.calendar.state.value
    return when {
        !settings.calendarSync -> "未开启"
        !container.calendar.hasPermission() -> "未授权读取日历"
        st.names.keys.none { !it.startsWith("cal:t:") } && !settings.calendarTasks -> "还没选日历"
        else -> ""
    }
}

@Composable
internal fun CalendarSection(env: SettingsEnv) {
    val context = env.context
    val container = env.container
    val settings = env.settings
    val calendarState by container.calendar.state.collectAsStateWithLifecycle()
    var hasPermission by remember { mutableStateOf(container.calendar.hasPermission()) }
    var hasWrite by remember { mutableStateOf(container.calendar.hasWritePermission()) }
    var calendars by remember { mutableStateOf<List<DeviceCalendar>>(emptyList()) }

    // 从系统设置里改了权限再回来，要重新判断
    LifecycleResumeEffect(Unit) {
        hasPermission = container.calendar.hasPermission()
        hasWrite = container.calendar.hasWritePermission()
        onPauseOrDispose { }
    }
    LaunchedEffect(hasPermission, settings.calendarSync, calendarState.updatedAt) {
        calendars = if (hasPermission) withContext(Dispatchers.IO) { container.calendar.calendars() } else emptyList()
    }

    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        hasPermission = granted
        if (granted) {
            container.settings.setCalendarSync(true)
            container.calendar.refresh()
        } else {
            settingsToast(context, "没有日历权限，无法同步系统日历")
        }
    }

    val writeLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        hasWrite = granted
        if (granted) container.settings.setCalendarWriteback(true) else settingsToast(context, "没有写入日历的权限，无法把完成状态同步回系统待办")
    }

    fun setSync(enable: Boolean) {
        when {
            !enable -> container.settings.setCalendarSync(false)
            container.calendar.hasPermission() -> container.settings.setCalendarSync(true)
            else -> permissionLauncher.launch(Manifest.permission.READ_CALENDAR)
        }
    }

    Group(null) {
        SettingsSwitchItem(
            icon = Icons.Filled.DateRange,
            title = "同步系统日历",
            summary = "",
            checked = settings.calendarSync && hasPermission,
            onChange = { setSync(it) },
        )
    }

    if (settings.calendarSync && hasPermission) {
        val selected = container.calendar.selectedIds(calendars)
        Group("要同步的日历") {
            if (calendars.isEmpty()) {
                SettingsItem(title = "没有找到日历", summary = "系统里没有日历", onClick = null)
            }
            calendars.forEach { c ->
                val on = c.id in selected
                SettingsItem(
                    title = c.name,
                    summary = c.account.ifBlank { "本机" },
                    onClick = { container.settings.setCalendarIds(if (on) selected - c.id else selected + c.id) },
                    trailing = {
                        Checkbox(
                            checked = on,
                            onCheckedChange = { container.settings.setCalendarIds(if (on) selected - c.id else selected + c.id) },
                        )
                    },
                )
            }
        }
        calendarState.error?.let { SettingsNote(it) }
        Group(null) {
            SettingsSwitchItem(
                icon = Icons.Filled.Check,
                title = "同时读取系统待办",
                summary = "",
                checked = settings.calendarTasks,
                onChange = { container.settings.setCalendarTasks(it) },
            )
            if (settings.calendarTasks) {
                SettingsSwitchItem(
                    icon = Icons.Filled.Check,
                    title = "完成状态同步回系统待办",
                    summary = "",
                    checked = settings.calendarWriteback && hasWrite,
                    onChange = { on ->
                        when {
                            !on -> container.settings.setCalendarWriteback(false)
                            container.calendar.hasWritePermission() -> container.settings.setCalendarWriteback(true)
                            else -> writeLauncher.launch(Manifest.permission.WRITE_CALENDAR)
                        }
                    },
                )
            }
        }
    }

}
