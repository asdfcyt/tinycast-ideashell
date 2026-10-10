package com.carpe.ideashell.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.DropdownMenu
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.ui.glass.GlassSurface

/*
 * 全应用共用的「扁平列表」积木（遵循 Material 3 的列表规范）：
 * - 一屏只有三级文字：页面标题 / 分组标题 / 行内容；
 * - 同一类内容放进同一张容器卡片，行与行之间只用一条细分隔线，不再给每一行单独套卡片；
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
            .padding(start = 20.dp, end = 12.dp, top = 12.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.headlineMedium)
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

/** 分组标题：小号、弱化，位于一组行的上方；右侧可放一个文字按钮 */
@Composable
fun GroupLabel(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = MaterialTheme.colorScheme.onSurfaceVariant,
    count: Int? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 32.dp)
            .padding(start = 8.dp, end = 0.dp, top = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, style = MaterialTheme.typography.titleSmall, color = color)
        if (count != null) {
            Text(
                "  $count",
                style = MaterialTheme.typography.labelMedium,
                color = color.copy(alpha = 0.7f),
            )
        }
        Box(Modifier.weight(1f))
        trailing?.invoke()
    }
}

/** 一组相关的行：一张容器卡片，里面的行用 [RowDivider] 分隔 */
@Composable
fun ListGroup(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    GlassSurface(modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp)) {
        Column(content = content)
    }
}

/** 行与行之间的细分隔线（左侧缩进，与文字对齐） */
@Composable
fun RowDivider(inset: Dp = 16.dp) {
    HorizontalDivider(
        modifier = Modifier.padding(start = inset),
        thickness = 0.5.dp,
        color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.7f),
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
            .heightIn(min = 52.dp)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 16.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(label, style = MaterialTheme.typography.bodyLarge, color = labelColor, modifier = Modifier.weight(1f))
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

/** 点一下弹出菜单的 [PropertyRow]；[menu] 里用 [androidx.compose.material3.DropdownMenuItem]，调用 dismiss 关闭菜单 */
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
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            menu { open = false }
        }
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
