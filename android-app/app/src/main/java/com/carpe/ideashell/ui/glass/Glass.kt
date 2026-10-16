package com.carpe.ideashell.ui.glass

import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.R
import com.carpe.ideashell.ui.theme.Brand

/*
 * 全应用共用的「面」（设计系统「环」）：奶油底上的白色圆角块，没有描边、没有阴影、没有模糊。
 *
 * 早期版本这里是「液态玻璃」（Haze 实时模糊 + 光晕背景 + 渐变描边 + 投影 + 按压弹性缩放），
 * 切页签时整页内容都在模糊源里，每帧重算，低端和中端机上明显卡顿。现在是：
 * - 背景：纯色（跟随主题），没有逐帧重绘的渐变；
 * - 卡片：surfaceContainerLowest 白 / 深棕，靠与奶油底的明度差分层，圆角 24dp；
 * - 底部导航：深棕悬浮胶囊，选中项是一块贝壳橙，右边是同一行的橙色「记一条」圆钮。
 * 为了不大面积改调用点，类名与包名沿用 Glass 前缀（GlassSurface / GlassBadge / AuroraBackground）。
 */

/** 底部导航占用的高度（含系统导航栏），各页面据此给列表留出底部空白 */
val LocalBottomBarPadding = compositionLocalOf { 24.dp }

/** 全屏面板（比如日历里点一天弹出的任务面板）打开时要盖住底部导航：用它临时把导航收起来 */
object NavBarOverlay {
    var hidden: Boolean by androidx.compose.runtime.mutableStateOf(false)
}

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
    shape: Shape = RoundedCornerShape(24.dp),
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

/**
 * 图标底座（设置项等处）：深棕圆底 + 橙色图标，是页面上唯一的橙色小点缀。
 * [tint] 不指定时用默认配色；指定了就用它做底、白色图标（给需要按类型着色的地方留的口子）。
 */
@Composable
fun GlassBadge(
    icon: ImageVector,
    modifier: Modifier = Modifier,
    tint: Color = Color.Unspecified,
    size: Dp = 36.dp,
) {
    val dark = isDarkSurface()
    val bg = if (tint == Color.Unspecified) (if (dark) MaterialTheme.colorScheme.surfaceContainerHigh else Brand.Brown) else tint
    val fg = if (tint == Color.Unspecified) Brand.Orange else Color.White
    Box(
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            .background(bg),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = fg, modifier = Modifier.size(size * 0.56f))
    }
}

/** [icon] 是未选中时的图标，[selectedIcon] 是选中时的图标（可以相同）；都是 drawable 资源 */
data class NavItem(
    val label: String,
    @DrawableRes val icon: Int,
    @DrawableRes val selectedIcon: Int = icon,
)

/** 悬浮导航胶囊的高度、与屏幕底部的间距（不含系统导航栏） */
val NavBarHeight = 64.dp
val NavBarGap = 12.dp

/**
 * 底部悬浮导航：左边一颗深棕胶囊，右边是同一行的橙色圆形「记一条」（[fab]）。
 * 每项是图标 + 12sp 粗体小字：选中项整块变贝壳橙、内容是深棕；其余项是奶油色。
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
    val container = if (isDarkSurface()) scheme.surfaceContainerHigh else Brand.Brown
    val idle = if (isDarkSurface()) scheme.onSurface else Brand.Cream
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
                .clip(capsule)
                .background(container)
                .padding(horizontal = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            items.forEachIndexed { index, item ->
                val active = index == selected
                val color = if (active) Brand.Brown else idle
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .height(52.dp)
                        .clip(RoundedCornerShape(26.dp))
                        .background(if (active) Brand.Orange else Color.Transparent)
                        .selectable(
                            selected = active,
                            role = Role.Tab,
                            onClick = { onSelect(index) },
                        ),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Icon(
                        painterResource(if (active) item.selectedIcon else item.icon),
                        contentDescription = null,
                        tint = color,
                        modifier = Modifier.size(22.dp),
                    )
                    Spacer(Modifier.height(2.dp))
                    Text(
                        item.label,
                        style = MaterialTheme.typography.labelSmall,
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

/** 底部导航右侧的橙色圆钮「记一条」：全应用的万能输入入口，右上角带一颗星光（来自贝壳图标） */
@Composable
fun AddFab(onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier = modifier.size(NavBarHeight)) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .shadow(
                    8.dp,
                    CircleShape,
                    ambientColor = Brand.Orange.copy(alpha = 0.35f),
                    spotColor = Brand.Orange.copy(alpha = 0.35f),
                )
                .clip(CircleShape)
                .background(Brand.Orange)
                .clickable(role = Role.Button, onClick = onClick),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.Add, contentDescription = "记一条", tint = Brand.Brown, modifier = Modifier.size(34.dp))
        }
        Icon(
            painterResource(R.drawable.ic_sparkle),
            contentDescription = null,
            tint = if (isDarkSurface()) Brand.Orange else Brand.Brown,
            modifier = Modifier
                .align(Alignment.TopEnd)
                .offset(x = 4.dp, y = (-8).dp)
                .size(20.dp),
        )
    }
}
