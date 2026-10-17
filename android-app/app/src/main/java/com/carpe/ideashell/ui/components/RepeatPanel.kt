package com.carpe.ideashell.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import com.carpe.ideashell.ui.glass.GlassAlertDialog as AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.core.parse.RepeatPreset
import com.carpe.ideashell.core.parse.RepeatRule
import java.time.DayOfWeek
import java.time.LocalDate

/**
 * 日期面板里「重复」的子菜单（对标滴答）：不重复 / 每天 / 每个工作日 / 每周 / 每月 / 每年 / 自定义…。
 * 每周、每月的具体星期、几号跟着当前选的日期走；选「自定义…」弹出对话框，可以设「每 N 天 / 周 / 月 / 年」，每周还能多选星期。
 * 菜单要放在「重复」那一行的同一个 Box 里，才会贴着那一行弹出。
 *
 * @param preset 当前选中的常用选项；[custom] 非空表示正在用自定义规则；两者都为空 = 不重复
 */
@Composable
internal fun RepeatMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    date: LocalDate,
    preset: RepeatPreset?,
    custom: RepeatRule?,
    onPreset: (RepeatPreset?) -> Unit,
    onCustom: (RepeatRule) -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    var customOpen by remember { mutableStateOf(false) }
    AppMenu(expanded = expanded, onDismissRequest = onDismiss) {
        AppMenuItem(
            text = { Text("不重复") },
            selected = preset == null && custom == null,
            onClick = { onPreset(null); onDismiss() },
        )
        RepeatPreset.entries.forEach { p ->
            val hint = p.hint(date)
            AppMenuItem(
                text = {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(p.label)
                        if (hint.isNotEmpty()) {
                            Text(hint, style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant, maxLines = 1)
                        }
                    }
                },
                selected = custom == null && preset == p,
                onClick = { onPreset(p); onDismiss() },
            )
        }
        AppMenuDivider()
        AppMenuItem(
            text = {
                Column {
                    Text("自定义…")
                    custom?.resolved(date)?.label()?.let {
                        Text(it, style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant, maxLines = 1)
                    }
                }
            },
            selected = custom != null,
            onClick = { onDismiss(); customOpen = true },
        )
    }
    if (customOpen) {
        var draft by remember { mutableStateOf(custom ?: preset?.rule(date) ?: RepeatRule(RepeatRule.Freq.DAILY)) }
        AlertDialog(
            onDismissRequest = { customOpen = false },
            title = { Text("自定义重复") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    CustomEditor(date, draft) { draft = it }
                    Text(
                        draft.resolved(date).label(),
                        style = MaterialTheme.typography.bodyMedium,
                        color = scheme.onSurfaceVariant,
                    )
                }
            },
            confirmButton = { TextButton(onClick = { onCustom(draft); customOpen = false }) { Text("确定") } },
            dismissButton = { TextButton(onClick = { customOpen = false }) { Text("取消") } },
        )
    }
}

@Composable
private fun CustomEditor(date: LocalDate, rule: RepeatRule, onChange: (RepeatRule) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(scheme.onSurface.copy(alpha = 0.05f))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("每", style = MaterialTheme.typography.titleSmall)
            Stepper(rule.interval) { onChange(rule.copy(interval = it.coerceIn(1, 99))) }
            Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                RepeatRule.Freq.entries.forEach { f ->
                    Chip(
                        label = f.unit.removePrefix("个"),
                        selected = rule.freq == f,
                        modifier = Modifier.weight(1f),
                    ) {
                        onChange(
                            when (f) {
                                RepeatRule.Freq.WEEKLY -> rule.copy(freq = f, weekdays = rule.weekdays.ifEmpty { setOf(date.dayOfWeek) }, monthDay = null)
                                RepeatRule.Freq.MONTHLY -> rule.copy(freq = f, weekdays = emptySet(), monthDay = date.dayOfMonth)
                                else -> rule.copy(freq = f, weekdays = emptySet(), monthDay = null)
                            },
                        )
                    }
                }
            }
        }
        when (rule.freq) {
            RepeatRule.Freq.WEEKLY -> Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                WEEK_ORDER.forEach { d ->
                    val on = d in rule.weekdays
                    Chip(RepeatRule.weekdayName(d).removePrefix("周"), selected = on, modifier = Modifier.weight(1f)) {
                        // 至少留一天，全部取消没有意义
                        val next = if (on) rule.weekdays - d else rule.weekdays + d
                        if (next.isNotEmpty()) onChange(rule.copy(weekdays = next))
                    }
                }
            }

            RepeatRule.Freq.MONTHLY -> Text(
                if (rule.monthDay == -1) "每月最后一天" else "每月 ${rule.monthDay ?: date.dayOfMonth} 日（跟随所选日期）",
                style = MaterialTheme.typography.bodySmall,
                color = scheme.onSurfaceVariant,
            )

            else -> Unit
        }
    }
}

@Composable
private fun Stepper(value: Int, onChange: (Int) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Row(
        modifier = Modifier.clip(CircleShape).background(scheme.onSurface.copy(alpha = 0.08f)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "−",
            modifier = Modifier.clickable(role = Role.Button) { onChange(value - 1) }.padding(horizontal = 12.dp, vertical = 6.dp),
            style = MaterialTheme.typography.titleMedium,
        )
        Text(
            "$value",
            modifier = Modifier.width(26.dp),
            textAlign = TextAlign.Center,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.Bold,
        )
        Text(
            "+",
            modifier = Modifier.clickable(role = Role.Button) { onChange(value + 1) }.padding(horizontal = 12.dp, vertical = 6.dp),
            style = MaterialTheme.typography.titleMedium,
        )
    }
}

@Composable
private fun Chip(label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Box(
        modifier = modifier
            .height(34.dp)
            .clip(CircleShape)
            .background(if (selected) scheme.primary else scheme.onSurface.copy(alpha = 0.08f))
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = MaterialTheme.typography.labelLarge,
            fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
            color = if (selected) scheme.onPrimary else scheme.onSurface,
            maxLines = 1,
        )
    }
}

private val WEEK_ORDER = listOf(
    DayOfWeek.MONDAY, DayOfWeek.TUESDAY, DayOfWeek.WEDNESDAY, DayOfWeek.THURSDAY,
    DayOfWeek.FRIDAY, DayOfWeek.SATURDAY, DayOfWeek.SUNDAY,
)
