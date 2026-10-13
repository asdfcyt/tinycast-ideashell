package com.carpe.ideashell.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.PopupProperties
import com.carpe.ideashell.ui.theme.Brand

/*
 * 全应用统一的弹出菜单。
 *
 * 设计方向「浮起的白色块」：菜单就是页面上那些白色圆角块飞起来的一小块——
 * 纯白底、20dp 圆角、一圈极淡的暖灰描边加柔和投影，和奶油底之间靠白与影分开，不再是一块发灰的矩形。
 * 当前选中的一项：整行涂一层浅橙（Brand.OrangeSoft）的圆角底，文字变深橙、加粗，右侧一个对勾——
 * 浅橙底是全应用「选中」的同一种说法（和热力图、选中的日期一致），一眼看出当前值，不用再靠字重猜。
 * 危险操作（移除、删除）只改文字颜色，不另加底色，放在最后并用细线与其他项隔开。
 * 分组小标题是不可点的小号灰字，行间距比普通项更紧凑。
 */

/** 弹出菜单：用法同 [DropdownMenu]，内容里用 [AppMenuItem] / [AppMenuDivider] */
@Composable
fun AppMenu(
    expanded: Boolean,
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    keepKeyboard: Boolean = false,
    content: @Composable ColumnScope.() -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismissRequest,
        modifier = modifier.widthIn(min = 176.dp, max = 280.dp),
        // 输入框正在输入时弹菜单：菜单不抢焦点，键盘就不会收起（代价是点菜单外不会自动关，由调用方负责）
        properties = PopupProperties(focusable = !keepKeyboard),
        offset = DpOffset(0.dp, 6.dp),
        shape = RoundedCornerShape(20.dp),
        containerColor = scheme.surfaceContainerLowest,
        tonalElevation = 0.dp,
        shadowElevation = 14.dp,
        border = BorderStroke(0.5.dp, scheme.outlineVariant),
        content = content,
    )
}

/**
 * 菜单里的一项。[selected] 表示「当前值」（浅橙底 + 对勾）；[destructive] 是危险操作；
 * [header] 为 true 时当作分组小标题显示（小号灰字，不可点）；[enabled] 为 false 是置灰、不可点的普通项。
 */
@Composable
fun AppMenuItem(
    text: @Composable () -> Unit,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    leadingIcon: (@Composable () -> Unit)? = null,
    trailingIcon: (@Composable () -> Unit)? = null,
    enabled: Boolean = true,
    selected: Boolean = false,
    destructive: Boolean = false,
    header: Boolean = false,
) {
    val scheme = MaterialTheme.colorScheme

    if (header) {
        // 分组小标题
        Box(modifier.fillMaxWidth().padding(start = 18.dp, end = 18.dp, top = 8.dp, bottom = 4.dp)) {
            CompositionLocalProvider(LocalContentColor provides scheme.onSurfaceVariant) {
                ProvideTextStyle(MaterialTheme.typography.labelMedium) { text() }
            }
        }
        return
    }

    val base = when {
        destructive -> scheme.error
        selected -> Brand.OrangeDeep
        else -> scheme.onSurface
    }
    val fg = if (enabled) base else base.copy(alpha = 0.38f)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 6.dp, vertical = 1.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(if (selected) Brand.OrangeSoft.copy(alpha = 0.75f) else Color.Transparent)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .heightIn(min = 46.dp)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CompositionLocalProvider(LocalContentColor provides fg) {
            if (leadingIcon != null) {
                Box(Modifier.padding(end = 12.dp).size(20.dp), contentAlignment = Alignment.Center) { leadingIcon() }
            }
            Box(Modifier.weight(1f).defaultMinSize(minWidth = 96.dp)) {
                ProvideTextStyle(
                    MaterialTheme.typography.bodyLarge.copy(
                        fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                    ),
                ) { text() }
            }
            if (trailingIcon != null) {
                Box(Modifier.padding(start = 12.dp), contentAlignment = Alignment.Center) { trailingIcon() }
            } else if (selected) {
                Icon(Icons.Filled.Check, contentDescription = "当前", modifier = Modifier.padding(start = 12.dp).size(18.dp))
            }
        }
    }
}

/** 菜单里的分隔线：两侧缩进，比整行分隔线更轻 */
@Composable
fun AppMenuDivider() {
    HorizontalDivider(
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
        thickness = 0.5.dp,
        color = MaterialTheme.colorScheme.outlineVariant,
    )
}
