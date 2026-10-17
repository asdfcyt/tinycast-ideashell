package com.carpe.ideashell.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.ui.glass.GlassSurface
import com.carpe.ideashell.ui.glass.glassChip

/*
 * 全应用共用的积木（设计系统「环」）：
 * - 一屏只有三级文字：页面标题（ExtraBold）/ 分组标题（Bold）/ 行内容；
 * - 任务和最近记录是「一条一个胶囊」，分组标题直接写在奶油底上；
 *   设置、笔记这类成组的信息，放进同一张白色圆角块，行与行之间只用一条细分隔线；
 * - 选中态统一是深色反白（分段控件、筛选胶囊），橙色只留给填充和强调；
 * - 次要操作收进菜单或详情，一屏只留一个主操作。
 */

/** 页面标题：大标题 + 一行弱化的说明，右侧可放一个主操作 */
@Composable
fun ScreenHeader(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    action: (@Composable () -> Unit)? = null,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 12.dp, top = 16.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.headlineSmall)
            if (!subtitle.isNullOrBlank()) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        action?.invoke()
    }
}

/** 分组标题：粗体，位于一组行的上方；右侧可放一个文字按钮 */
@Composable
fun GroupLabel(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = MaterialTheme.colorScheme.onSurface,
    count: Int? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 40.dp)
            .padding(start = 8.dp, end = 0.dp, top = 10.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, style = MaterialTheme.typography.titleSmall, color = color)
        if (count != null) {
            Text(
                "  $count",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Box(Modifier.weight(1f))
        trailing?.invoke()
    }
}

/** 一组相关的行：一张白色圆角块，里面的行用 [RowDivider] 分隔 */
@Composable
fun ListGroup(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    GlassSurface(modifier.fillMaxWidth(), shape = RoundedCornerShape(24.dp)) {
        Column(content = content)
    }
}

/**
 * 带标题的分组：标题直接写在奶油底上——左边粗体的标题，右边是数量和折叠箭头；
 * 下面是分组里的行，每一行自己是一个胶囊（行与行之间留 8dp 的空隙）。
 * [onToggle] 不为空时点标题栏可以折叠 / 展开（[expanded] 为 false 时只剩标题栏）。
 */
@Composable
fun GroupCard(
    title: String,
    modifier: Modifier = Modifier,
    count: Int? = null,
    titleColor: Color = MaterialTheme.colorScheme.onSurface,
    expanded: Boolean = true,
    onToggle: (() -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
    content: (@Composable ColumnScope.() -> Unit)? = null,
) {
    Column(modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 44.dp)
                .clip(RoundedCornerShape(12.dp))
                .then(if (onToggle != null) Modifier.clickable(onClick = onToggle) else Modifier)
                .padding(start = 8.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(title, style = MaterialTheme.typography.titleSmall, color = titleColor)
            if (count != null) {
                Text(
                    "  $count",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Box(Modifier.weight(1f))
            trailing?.invoke()
            if (onToggle != null) {
                Icon(
                    if (expanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                    contentDescription = if (expanded) "收起" else "展开",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 4.dp),
                )
            }
        }
        if (expanded && content != null) {
            Column(
                modifier = Modifier.padding(top = 2.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                content = content,
            )
        }
    }
}

/**
 * 一条胶囊：白底（深色模式是深棕）、24dp 圆角，是任务行、最近记录行的外壳。
 * [dark] 为 true 时反白成深棕胶囊（逾期任务），是页面上最重的一块。
 */
@Composable
fun RowPill(
    modifier: Modifier = Modifier,
    dark: Boolean = false,
    onClick: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) = RowPill(modifier, dark, onClick, glass = false, content = content)

/** [glass] 为 true：横幅类（今日重温、下一件）用静态玻璃；列表里成排的行保持实心 */
@Composable
fun RowPill(
    modifier: Modifier = Modifier,
    dark: Boolean = false,
    onClick: (() -> Unit)? = null,
    glass: Boolean,
    content: @Composable () -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    val shape = RoundedCornerShape(24.dp)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .then(
                if (glass) Modifier.glassChip(shape, tint = if (dark) scheme.inverseSurface else Color.Unspecified)
                else Modifier.clip(shape).background(if (dark) scheme.inverseSurface else scheme.surfaceContainerLowest),
            )
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
    ) {
        content()
    }
}

/** 页面顶部的圆形图标按钮（默认是静态玻璃；放在橙色色场上时传 [container] 换成半透明深棕） */
@Composable
fun CircleIconButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    container: Color = Color.Unspecified,
    content: Color = MaterialTheme.colorScheme.onSurface,
) {
    Box(
        modifier = modifier
            .size(44.dp)
            .then(
                if (container == Color.Unspecified) Modifier.glassChip(CircleShape)
                else Modifier.clip(CircleShape).background(container),
            )
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = contentDescription, tint = content, modifier = Modifier.size(22.dp))
    }
}

/** 标题栏右侧的搜索按钮：各主页签统一用它进入搜索页 */
@Composable
fun SearchButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    container: Color = Color.Unspecified,
    content: Color = MaterialTheme.colorScheme.onSurface,
) {
    CircleIconButton(Icons.Filled.Search, "搜索", onClick, modifier, container, content)
}

/** 行与行之间的细分隔线（左侧缩进，与文字对齐） */
@Composable
fun RowDivider(inset: Dp = 16.dp) {
    HorizontalDivider(
        modifier = Modifier.padding(start = inset),
        thickness = 0.5.dp,
        color = MaterialTheme.colorScheme.outline.copy(alpha = 0.35f),
    )
}

/** 把一组数据逐行摆出来，行间自动加分隔线 */
@Composable
fun <T> ColumnScope.DividedRows(items: List<T>, inset: Dp = 16.dp, row: @Composable (T) -> Unit) {
    items.forEachIndexed { i, item ->
        if (i > 0) RowDivider(inset)
        row(item)
    }
}

/**
 * 完成状态的小标记：没完成是一圈细环，完成是实心橙底 + 深棕对勾。
 * 取代用「✓ / ○」文字字符充当图标的写法，在时间线、搜索结果、档案里共用。
 */
@Composable
fun DoneMark(done: Boolean, modifier: Modifier = Modifier, size: Dp = 20.dp) {
    val scheme = MaterialTheme.colorScheme
    if (done) {
        Box(
            modifier = modifier
                .size(size)
                .clip(CircleShape)
                .background(com.carpe.ideashell.ui.theme.Brand.Orange),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Filled.Check,
                contentDescription = "已完成",
                tint = com.carpe.ideashell.ui.theme.Brand.Brown,
                modifier = Modifier.size(size * 0.66f),
            )
        }
    } else {
        Box(
            modifier = modifier
                .size(size)
                .clip(CircleShape)
                .border(2.dp, scheme.outline, CircleShape),
        )
    }
}

/** 「名称 ……… 当前值」的一行；点击后改这一项 */
@Composable
fun PropertyRow(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    valueColor: Color = MaterialTheme.colorScheme.onSurfaceVariant,
    labelColor: Color = MaterialTheme.colorScheme.onSurface,
    onClick: (() -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 18.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(label, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium, color = labelColor, modifier = Modifier.weight(1f))
        if (value.isNotEmpty()) {
            Text(
                value,
                style = MaterialTheme.typography.bodyMedium,
                color = valueColor,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.End,
                modifier = Modifier.weight(1f, fill = false),
            )
        }
        trailing?.invoke()
    }
}

/** 点一下弹出菜单的 [PropertyRow]；[menu] 里用 [AppMenuItem]，调用 dismiss 关闭菜单 */
@Composable
fun MenuPropertyRow(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    valueColor: Color = MaterialTheme.colorScheme.onSurfaceVariant,
    menu: @Composable ColumnScope.(dismiss: () -> Unit) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Box(modifier) {
        PropertyRow(label, value, valueColor = valueColor, onClick = { open = true })
        AppMenu(expanded = open, onDismissRequest = { open = false }) {
            menu { open = false }
        }
    }
}

/**
 * 分段控件：浅色轨道 + 深色反白的滑块（浅色模式是深棕底奶油字，深色模式反过来），全圆角。
 * 页面内的视图切换、输入框里的「自动 / 待办 / 日记 / 笔记」都用它；每一项高度默认 44dp，满足触控下限，
 * 用 [outerPadding] 控制外边距（放在页面里时有左右边距，放在卡片里时设为 0）。
 */
@Composable
fun SegmentedTabs(
    labels: List<String>,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    outerPadding: PaddingValues = PaddingValues(horizontal = 16.dp, vertical = 6.dp),
    height: Dp = 44.dp,
) {
    val scheme = MaterialTheme.colorScheme
    Row(
        modifier = modifier
            .padding(outerPadding)
            .height(height)
            .clip(CircleShape)
            .background(scheme.surfaceContainerHigh)
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        labels.forEachIndexed { i, label ->
            val active = i == selected
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .clip(CircleShape)
                    .background(if (active) scheme.inverseSurface else Color.Transparent)
                    .selectable(selected = active, role = Role.Tab, onClick = { onSelect(i) }),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = if (active) FontWeight.Bold else FontWeight.Medium,
                    color = if (active) scheme.inverseOnSurface else scheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/**
 * 胶囊筛选项：未选中是白底，选中是深色反白（和分段控件同一套逻辑），没有描边。
 * [leading] 可以放一个色点或小图标。高度 40dp，行内间距 8dp 时整体触控区域满足要求。
 */
@Composable
fun PillChip(
    text: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    leading: (@Composable () -> Unit)? = null,
) {
    val scheme = MaterialTheme.colorScheme
    Row(
        modifier = modifier
            .height(40.dp)
            .clip(CircleShape)
            .background(if (selected) scheme.inverseSurface else scheme.surfaceContainerLowest)
            .selectable(selected = selected, role = Role.Button, onClick = onClick)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        leading?.invoke()
        Text(
            text,
            style = MaterialTheme.typography.labelLarge,
            fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
            color = if (selected) scheme.inverseOnSurface else scheme.onSurface,
            maxLines = 1,
        )
    }
}

/** 没有数据时的提示：不套卡片，居中的两行字（可带一个文字按钮） */
@Composable
fun EmptyNote(
    title: String,
    text: String,
    modifier: Modifier = Modifier,
    action: (@Composable () -> Unit)? = null,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp, vertical = 40.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(title, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        action?.invoke()
    }
}

/** 一行警示（加载失败 / 部分数据没取全）：图标 + 文字，不套卡片 */
@Composable
fun NoticeLine(text: String, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            Icons.Filled.Warning,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.error,
            modifier = Modifier.padding(top = 2.dp).size(16.dp),
        )
        Text(
            text,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 4,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
