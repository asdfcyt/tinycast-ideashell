package com.carpe.ideashell.ui.glass

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.ui.draw.shadow
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/*
 * 全应用共用的「面」（Apple 分组列表风格）：灰底上的白色圆角卡片，没有描边、没有阴影、没有模糊。
 *
 * 早期版本这里是「液态玻璃」（Haze 实时模糊 + 光晕背景 + 渐变描边 + 投影 + 按压弹性缩放），
 * 切页签时整页内容都在模糊源里，每帧重算，低端和中端机上明显卡顿。现在改为：
 * - 背景：纯色（跟随主题），没有逐帧重绘的渐变；
 * - 卡片：surfaceContainerLowest 白 / #1C1C1E，靠与灰底的明度差分层；
 * - 底部导航：悬浮的白色胶囊，选中项带一块淡色高亮（对标滴答清单）。
 * 为了不大面积改调用点，类名与包名沿用 Glass 前缀（GlassSurface / GlassBadge / AuroraBackground）。
 */

/** 底部导航占用的高度（含系统导航栏），各页面据此给列表留出底部空白 */
val LocalBottomBarPadding = compositionLocalOf { 24.dp }

@Composable
fun isDarkSurface(): Boolean = MaterialTheme.colorScheme.background.luminance() < 0.5f

/** 页面底色：纯色。名字沿用旧的「光晕背景」，现在不再绘制渐变。 */
@Composable
fun AuroraBackground(modifier: Modifier = Modifier.fillMaxSize()) {
    Box(modifier.background(MaterialTheme.colorScheme.background))
}

/**
 * 卡片面板。
 * @param tint 给卡片染一点颜色（提示 / 警告用），仍然是不透明底 + 淡色叠加
 * @param onClick 不为空时可点击，带 Material 水波纹
 */
@Composable
fun GlassSurface(
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(16.dp),
    tint: Color = Color.Unspecified,
    @Suppress("UNUSED_PARAMETER") elevated: Boolean = false,
    onClick: (() -> Unit)? = null,
    content: @Composable BoxScope.() -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    val dark = isDarkSurface()
    Box(
        modifier = modifier
            .clip(shape)
            .background(scheme.surfaceContainerLowest)
            .then(
                if (tint != Color.Unspecified) Modifier.background(tint.copy(alpha = if (dark) 0.18f else 0.10f)) else Modifier,
            )
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
        content = content,
    )
}

/** 图标底座（设置项、最近记录等处）：像 iOS 设置里的彩色圆角方块，白色图标 */
@Composable
fun GlassBadge(
    icon: ImageVector,
    modifier: Modifier = Modifier,
    tint: Color = MaterialTheme.colorScheme.primary,
    size: Dp = 32.dp,
) {
    Box(
        modifier = modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.28f))
            .background(tint),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(size * 0.6f))
    }
}

/** [icon] 是未选中时的图标，[selectedIcon] 是选中时的图标（可以相同） */
data class NavItem(val label: String, val icon: ImageVector, val selectedIcon: ImageVector = icon)

/** 悬浮导航胶囊的高度、与屏幕底部的间距（不含系统导航栏） */
val NavBarHeight = 64.dp
val NavBarGap = 12.dp

/**
 * 底部悬浮导航（对标滴答清单）：左边一颗白色胶囊，右边是同一行的圆形「+」（[fab]），投影很淡。
 * 每项是粗体图标 + 粗体小字：选中项整体变主题色，没有底色块；其余项是深色。
 */
@Composable
fun AppNavBar(
    items: List<NavItem>,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    fab: (@Composable () -> Unit)? = null,
) {
    val scheme = MaterialTheme.colorScheme
    val capsule = RoundedCornerShape(32.dp)
    Row(
        modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(start = 16.dp, end = 16.dp, bottom = NavBarGap),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            Modifier
                .weight(1f)
                .height(NavBarHeight)
                .shadow(10.dp, capsule, ambientColor = Color.Black.copy(alpha = 0.12f), spotColor = Color.Black.copy(alpha = 0.12f))
                .clip(capsule)
                .background(scheme.surfaceContainerLowest)
                .padding(horizontal = 6.dp),
        ) {
            items.forEachIndexed { index, item ->
                val active = index == selected
                val color = if (active) scheme.primary else scheme.onSurface
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .selectable(
                            selected = active,
                            role = Role.Tab,
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            onClick = { onSelect(index) },
                        ),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Icon(
                        if (active) item.selectedIcon else item.icon,
                        contentDescription = null,
                        tint = color,
                        modifier = Modifier.size(26.dp),
                    )
                    Spacer(Modifier.height(2.dp))
                    Text(
                        item.label,
                        style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                        color = color,
                        maxLines = 1,
                    )
                }
            }
        }
        if (fab != null) {
            Spacer(Modifier.width(12.dp))
            fab()
        }
    }
}

/** 底部导航右侧的圆形悬浮「+」：全应用的万能输入入口 */
@Composable
fun AddFab(onClick: () -> Unit, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    Box(
        modifier = modifier
            .size(NavBarHeight)
            .shadow(8.dp, CircleShape, ambientColor = scheme.primary.copy(alpha = 0.35f), spotColor = scheme.primary.copy(alpha = 0.35f))
            .clip(CircleShape)
            .background(scheme.primary)
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Filled.Add, contentDescription = "记一条", tint = scheme.onPrimary, modifier = Modifier.size(32.dp))
    }
}
