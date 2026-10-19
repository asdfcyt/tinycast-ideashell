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
        !settings.calendarSync -> "未开启 · 把系统日历的事件读进待办页"
        !container.calendar.hasPermission() -> "已开启，但还没授权读取日历"
        st.names.keys.none { !it.startsWith("cal:t:") } && !settings.calendarTasks -> "已开启 · 还没选日历"
        else -> "已同步 ${st.names.keys.count { !it.startsWith("cal:t:") }} 个日历${if (settings.calendarTasks) " + 系统待办" else ""} · 前 ${SystemCalendarRepository.PAST_DAYS} 天到后 ${SystemCalendarRepository.FUTURE_DAYS} 天"
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
            summary = "把日历里的事件读进待办页，和滴答任务一起显示；只读取，不会修改你的日历",
            checked = settings.calendarSync && hasPermission,
            onChange = { setSync(it) },
        )
    }

    if (settings.calendarSync && hasPermission) {
        val selected = container.calendar.selectedIds(calendars)
        Group("要同步的日历") {
            if (calendars.isEmpty()) {
                SettingsItem(title = "没有找到日历", summary = "系统里还没有日历账户，或日历 App 没有授权同步", onClick = null)
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
                summary = "荣耀日历 App 里的待办（带截止时间的任务）也读进来；逾期未完成的会进「逾期」",
                checked = settings.calendarTasks,
                onChange = { container.settings.setCalendarTasks(it) },
            )
            if (settings.calendarTasks) {
                SettingsSwitchItem(
                    icon = Icons.Filled.Check,
                    title = "完成状态同步回系统待办",
                    summary = "在拾忆里完成 / 恢复系统待办时，荣耀日历里的待办也跟着变；需要「写入日历」权限，重复待办只记在本机",
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

    SettingsNote(
        "同步范围（日历事件）：过去 ${SystemCalendarRepository.PAST_DAYS} 天到未来 ${SystemCalendarRepository.FUTURE_DAYS} 天（翻到更远的月份会自动读取），" +
            "含全天事件和重复事件的每一次。事件在待办页带「日历」标记，时间显示为起止时间；" +
            "点开可以「标记已处理」（日历事件只记在本机；系统待办开启同步后会写回系统）、归入项目、创建任务笔记；改时间、改标题、删除请到日历 App 里操作。" +
            "过去的事件不算逾期。小部件和常驻通知仍只统计滴答任务。",
    )
}
