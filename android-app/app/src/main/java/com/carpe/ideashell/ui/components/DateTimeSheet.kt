package com.carpe.ideashell.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.input.ImeAction
import com.carpe.ideashell.core.parse.RepeatPreset
import com.carpe.ideashell.core.parse.RepeatRule
import com.carpe.ideashell.core.parse.TodoParser
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.R
import com.carpe.ideashell.ui.glass.isDarkSurface
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.LocalTime
import java.time.YearMonth
import java.time.format.TextStyle
import java.time.temporal.TemporalAdjusters
import java.util.Locale

/**
 * 日期与时间选择（对标滴答清单的「日期」面板）：
 * 顶部是当前选择；下面几个常用日期一点即选；再下面是整月日历（有待办的日子下面有一个点，
 * 选中某天时一行小字写着那天有几个任务）；最后是「添加时间」。点「保存」才生效。
 *
 * 时间下面是「重复」（每天 / 每个工作日 / 每周 / 每月 / 每年 / 自定义，需要先有日期）。
 *
 * @param initialDate 当前日期；null = 没有日期
 * @param initialRepeat 当前的重复规则；null = 不重复
 * @param onConfirm 保存：日期为 null 表示没有日期（此时时间、重复一定是 null）
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DateTimeSheet(
    initialDate: LocalDate?,
    initialTime: LocalTime?,
    onConfirm: (LocalDate?, LocalTime?, RepeatRule?) -> Unit,
    onDismiss: () -> Unit,
    initialRepeat: RepeatRule? = null,
) {
    val context = LocalContext.current
    val today = remember { LocalDate.now() }
    var date by remember { mutableStateOf(initialDate ?: today) }
    var hasDate by remember { mutableStateOf(true) }
    var time by remember { mutableStateOf(initialTime) }
    var month by remember { mutableStateOf(YearMonth.from(initialDate ?: today)) }
    var pickTime by remember { mutableStateOf(false) }
    // 重复：选了常用选项（跟着日期走）就是 preset，否则是自定义规则 custom；两个都空 = 不重复
    val initialPreset = remember { initialRepeat?.let { r -> RepeatPreset.of(r, initialDate ?: today) } }
    var preset by remember { mutableStateOf(initialPreset) }
    var custom by remember { mutableStateOf(if (initialPreset == null) initialRepeat else null) }
    var repeatOpen by remember { mutableStateOf(false) }
    val repeat: RepeatRule? = if (hasDate) (custom ?: preset?.rule(date))?.resolved(date) else null
    // 日历默认只显示两周（本周 + 下周），点右上角可展开整月
    var expanded by remember { mutableStateOf(false) }
    var weekStart by remember { mutableStateOf((initialDate ?: today).with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))) }
    var editing by remember { mutableStateOf(false) }
    val goto = { d: LocalDate ->
        hasDate = true
        date = d
        month = YearMonth.from(d)
        weekStart = d.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
    }

    // 每天有几个未完成任务（读待办的本地缓存，不发请求）
    val counts = remember {
        val container = (context.applicationContext as IdeashellApp).container
        val ov = container.todos.state.value.overview
        val map = HashMap<String, Int>()
        if (ov != null) (ov.overdue + ov.upcoming + ov.undated).forEach { t -> t.date?.let { d -> map[d] = (map[d] ?: 0) + 1 } }
        map
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
    ) {
        Column(
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("日期", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(start = 4.dp))

            // 当前选择：自动识别出来的日期时间，点一下可以手动输入（「2026-10-14 15:00」「明天 下午3点」「10月20日」都行）
            if (editing) {
                var input by remember { mutableStateOf(if (hasDate) date.toString() + (time?.let { " %02d:%02d".format(it.hour, it.minute) } ?: "") else "") }
                val focus = remember { FocusRequester() }
                LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
                val commit = {
                    val parsed = TodoParser.parse(input.trim())
                    parsed.date?.let { d ->
                        goto(LocalDate.parse(d))
                        time = parsed.time?.let { LocalTime.parse(it) }
                    }
                    editing = false
                }
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(48.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f))
                        .padding(horizontal = 18.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(painterResource(R.drawable.ic_calendar), contentDescription = null, modifier = Modifier.size(20.dp))
                    BasicTextField(
                        value = input,
                        onValueChange = { input = it.replace("\n", "") },
                        singleLine = true,
                        textStyle = MaterialTheme.typography.titleMedium.copy(color = MaterialTheme.colorScheme.onSurface),
                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { commit() }),
                        modifier = Modifier.weight(1f).focusRequester(focus),
                    )
                    Text(
                        "确定",
                        modifier = Modifier.clickable(role = Role.Button) { commit() }.padding(6.dp),
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
            } else {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(48.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f))
                        .clickable(role = Role.Button, onClickLabel = "手动输入日期") { editing = true }
                        .padding(horizontal = 18.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(painterResource(R.drawable.ic_calendar), contentDescription = null, modifier = Modifier.size(20.dp))
                    Text(
                        if (hasDate) date.toString() + (time?.let { " " + "%02d:%02d".format(it.hour, it.minute) } ?: "") else "没有日期",
                        style = MaterialTheme.typography.titleMedium,
                    )
                }
            }

            // 常用日期
            val scheme = MaterialTheme.colorScheme
            val sat = today.with(TemporalAdjusters.nextOrSame(DayOfWeek.SATURDAY))
            val laterThisWeek = today.plusDays(2)
            val nextMonday = today.with(TemporalAdjusters.next(DayOfWeek.MONDAY))
            val quick = buildList {
                add(QuickDate("明天", R.drawable.ic_dt_sun, today.plusDays(1), weekday(today.plusDays(1))))
                if (!laterThisWeek.isAfter(nextMonday.minusDays(1))) {
                    add(QuickDate("本周稍后", R.drawable.ic_dt_week, laterThisWeek, weekday(laterThisWeek)))
                }
                if (sat.isAfter(today.plusDays(1)) && sat != laterThisWeek) {
                    add(QuickDate("本周周末", R.drawable.ic_dt_couch, sat, weekday(sat)))
                }
                add(QuickDate("下周一", R.drawable.ic_dt_next, nextMonday, ""))
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                quick.forEach { q ->
                    QuickDateItem(
                        icon = q.icon,
                        label = q.label,
                        selected = hasDate && date == q.date,
                        modifier = Modifier.weight(1f),
                    ) { goto(q.date) }
                }
                QuickDateItem(
                    icon = R.drawable.ic_dt_ban,
                    label = "没有日期",
                    selected = !hasDate,
                    modifier = Modifier.weight(1f),
                ) {
                    hasDate = false
                    time = null
                    repeatOpen = false
                }
            }

            // 日历：默认两周，紧凑；右上角「展开」看整月
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(scheme.onSurface.copy(alpha = 0.05f))
                    .padding(bottom = 6.dp),
            ) {
                val shownMonth = if (expanded) month else YearMonth.from(weekStart.plusDays(3))
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TextButton(
                        onClick = { if (expanded) month = month.minusMonths(1) else weekStart = weekStart.minusWeeks(1) },
                        contentPadding = PaddingValues(horizontal = 12.dp),
                    ) { Text("‹", fontSize = 20.sp) }
                    Text(
                        "${shownMonth.year}年${shownMonth.monthValue}月",
                        modifier = Modifier.weight(1f),
                        textAlign = TextAlign.Center,
                        style = MaterialTheme.typography.titleSmall,
                    )
                    TextButton(
                        onClick = { if (expanded) month = month.plusMonths(1) else weekStart = weekStart.plusWeeks(1) },
                        contentPadding = PaddingValues(horizontal = 12.dp),
                    ) { Text("›", fontSize = 20.sp) }
                    TextButton(
                        onClick = {
                            expanded = !expanded
                            if (expanded) month = YearMonth.from(weekStart.plusDays(3))
                            else weekStart = (if (YearMonth.from(date) == month && hasDate) date else month.atDay(1))
                                .with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
                        },
                        contentPadding = PaddingValues(horizontal = 10.dp),
                    ) { Text(if (expanded) "收起" else "展开", fontSize = 13.sp) }
                }
                Row(Modifier.fillMaxWidth()) {
                    listOf("一", "二", "三", "四", "五", "六", "日").forEach {
                        Text(
                            it,
                            modifier = Modifier.weight(1f),
                            textAlign = TextAlign.Center,
                            style = MaterialTheme.typography.labelSmall,
                            color = scheme.onSurfaceVariant,
                        )
                    }
                }
                if (hasDate) {
                    val n = counts[date.toString()] ?: 0
                    Text(
                        "${date.monthValue}月${date.dayOfMonth}日 ${weekday(date)} · ${n}个任务",
                        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
                        textAlign = TextAlign.Center,
                        style = MaterialTheme.typography.labelSmall,
                        color = scheme.onSurfaceVariant,
                    )
                }
                // 每一行 7 天；两周模式 = 2 行，展开 = 整月（含前后补位）
                val rows: List<LocalDate> = if (expanded) {
                    val first = month.atDay(1)
                    val start = first.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
                    val n = ((first.dayOfWeek.value - 1) + month.lengthOfMonth() + 6) / 7
                    List(n) { start.plusWeeks(it.toLong()) }
                } else {
                    listOf(weekStart, weekStart.plusWeeks(1))
                }
                rows.forEach { rowStart ->
                    Row(Modifier.fillMaxWidth()) {
                        for (c in 0 until 7) {
                            val d = rowStart.plusDays(c.toLong())
                            Box(Modifier.weight(1f).height(38.dp), contentAlignment = Alignment.Center) {
                                // 展开时，不属于当月的日期留空，只显示当月
                                if (!expanded || YearMonth.from(d) == month) {
                                    DayCell(
                                        day = d.dayOfMonth,
                                        selected = hasDate && d == date,
                                        isToday = d == today,
                                        past = d.isBefore(today),
                                        hasTasks = (counts[d.toString()] ?: 0) > 0,
                                    ) {
                                        hasDate = true
                                        date = d
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // 时间
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                OptionRow(
                    icon = R.drawable.ic_dt_clock,
                    label = time?.let { "%02d:%02d".format(it.hour, it.minute) } ?: "添加时间",
                    trailing = if (time != null) "清除" else "",
                    selected = false,
                    enabled = hasDate,
                    muted = time == null,
                    onTrailingClick = { time = null },
                ) { pickTime = true }
                Box {
                    OptionRow(
                        icon = R.drawable.ic_dt_repeat,
                        label = repeat?.label() ?: "重复",
                        trailing = if (repeat != null) "清除" else "",
                        selected = false,
                        enabled = hasDate,
                        muted = repeat == null,
                        onTrailingClick = {
                            preset = null
                            custom = null
                            repeatOpen = false
                        },
                    ) { repeatOpen = true }
                    RepeatMenu(
                        expanded = repeatOpen && hasDate,
                        onDismiss = { repeatOpen = false },
                        date = date,
                        preset = preset,
                        custom = custom,
                        onPreset = { p ->
                            preset = p
                            custom = null
                        },
                        onCustom = { r ->
                            custom = r
                            preset = null
                        },
                    )
                }
            }

            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                Box(
                    modifier = Modifier
                        .height(48.dp)
                        .clip(CircleShape)
                        .background(com.carpe.ideashell.ui.theme.Brand.Orange)
                        .clickable(role = Role.Button) { onConfirm(if (hasDate) date else null, if (hasDate) time else null, repeat) }
                        .padding(horizontal = 28.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("保存", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, color = com.carpe.ideashell.ui.theme.Brand.Brown)
                }
            }
            Spacer(Modifier.height(4.dp))
        }
    }

    if (pickTime) {
        val base = time ?: LocalTime.of(9, 0)
        val state = rememberTimePickerState(initialHour = base.hour, initialMinute = base.minute, is24Hour = true)
        AlertDialog(
            onDismissRequest = { pickTime = false },
            text = { TimePicker(state = state) },
            confirmButton = {
                TextButton(onClick = {
                    time = LocalTime.of(state.hour, state.minute)
                    pickTime = false
                }) { Text("确定") }
            },
            dismissButton = { TextButton(onClick = { pickTime = false }) { Text("取消") } },
        )
    }
}

private data class QuickDate(val label: String, val icon: Int, val date: LocalDate, val trailing: String)

private fun weekday(d: LocalDate): String = "(" + d.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.CHINA).replace("星期", "周") + ")"

/** 常用日期：图标在上、名字在下的一小格，五格排成一行；选中的那格涂一层浅色底 */
@Composable
private fun QuickDateItem(icon: Int, label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val accent = if (isDarkSurface()) Color(0xFFE8856B) else scheme.primary
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(14.dp))
            .background(if (selected) scheme.primary.copy(alpha = 0.16f) else Color.Transparent)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(vertical = 10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(painterResource(icon), contentDescription = null, tint = accent, modifier = Modifier.size(28.dp))
        Text(
            label,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
            color = if (selected) scheme.onSurface else scheme.onSurfaceVariant,
            maxLines = 1,
        )
    }
}

@Composable
private fun OptionRow(
    icon: Int,
    label: String,
    trailing: String,
    selected: Boolean,
    enabled: Boolean = true,
    muted: Boolean = false,
    onTrailingClick: (() -> Unit)? = null,
    onClick: () -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    val accent = if (isDarkSurface()) Color(0xFFE8856B) else scheme.primary
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(if (selected) scheme.primary.copy(alpha = 0.16f) else scheme.onSurface.copy(alpha = 0.05f))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .height(52.dp)
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Icon(
            painterResource(icon),
            contentDescription = null,
            tint = if (enabled && !muted) accent else scheme.onSurfaceVariant.copy(alpha = if (enabled) 1f else 0.4f),
            modifier = Modifier.size(22.dp),
        )
        Text(
            label,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.titleSmall,
            fontWeight = if (muted) FontWeight.Normal else FontWeight.SemiBold,
            color = if (muted || !enabled) scheme.onSurfaceVariant.copy(alpha = if (enabled) 1f else 0.5f) else scheme.onSurface,
        )
        if (trailing.isNotEmpty()) {
            Text(
                trailing,
                style = MaterialTheme.typography.bodyMedium,
                color = scheme.onSurfaceVariant,
                modifier = if (onTrailingClick != null) Modifier.clickable(onClick = onTrailingClick).padding(8.dp) else Modifier,
            )
        }
    }
}

@Composable
private fun DayCell(day: Int, selected: Boolean, isToday: Boolean, past: Boolean, hasTasks: Boolean, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            modifier = Modifier
                .size(30.dp)
                .clip(CircleShape)
                .background(if (selected) scheme.primary else Color.Transparent)
                .clickable(role = Role.Button, onClick = onClick),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                "$day",
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = if (selected || isToday) FontWeight.Bold else FontWeight.Normal,
                color = when {
                    selected -> scheme.onPrimary
                    isToday -> scheme.primary
                    past -> scheme.onSurface.copy(alpha = 0.4f)
                    else -> scheme.onSurface
                },
            )
        }
        Box(
            Modifier
                .padding(top = 1.dp)
                .size(3.dp)
                .clip(CircleShape)
                .background(if (hasTasks && !selected) scheme.onSurfaceVariant else Color.Transparent),
        )
    }
}
