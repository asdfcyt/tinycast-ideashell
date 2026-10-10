package com.carpe.ideashell.ui.glass

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.HazeStyle
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeEffect

/*
 * 「液态玻璃」视觉：
 * - 背景是一层柔和的彩色光晕（Aurora），玻璃要有东西可透；
 * - 玻璃面板 = 半透明高光填充 + 渐变描边（左上亮、右下暗，像光从左上方打来）+ 柔和投影；
 * - 底部导航等悬浮元素用 Haze 做真实的背景模糊（Android 12+，低版本自动退化为半透明）；
 * - 按压时轻微缩放并带弹性回弹，选中指示器像一滴液体在导航栏里滑动。
 * MagicOS 11 没有给第三方应用开放液态玻璃接口，这里全部自绘；以后想换更强的折射实现，只需改本文件。
 */

/** 底部悬浮导航栏占用的高度（含系统导航栏），各页面据此给列表留出底部空白 */
val LocalBottomBarPadding = compositionLocalOf { 24.dp }

@Composable
fun isDarkSurface(): Boolean = MaterialTheme.colorScheme.background.luminance() < 0.5f

/** 彩色光晕背景：几团模糊的色块叠在渐变底色上，给玻璃提供可透的内容 */
@Composable
fun AuroraBackground(modifier: Modifier = Modifier.fillMaxSize()) {
    val dark = isDarkSurface()
    val base = if (dark) {
        listOf(Color(0xFF08100F), Color(0xFF0B0E1B))
    } else {
        listOf(Color(0xFFE4F5F4), Color(0xFFF1EEFA))
    }
    val blobs = remember(dark) {
        if (dark) {
            listOf(
                Blob(0.08f, 0.06f, 0.95f, Color(0xFF14B8A6), 0.30f),
                Blob(0.98f, 0.24f, 0.80f, Color(0xFF6D5BFF), 0.26f),
                Blob(0.12f, 0.62f, 0.85f, Color(0xFF2563EB), 0.18f),
                Blob(0.90f, 0.96f, 0.90f, Color(0xFFC2417A), 0.16f),
            )
        } else {
            listOf(
                Blob(0.08f, 0.06f, 0.95f, Color(0xFF4FD1C5), 0.34f),
                Blob(0.98f, 0.24f, 0.80f, Color(0xFF9AA8FF), 0.30f),
                Blob(0.12f, 0.64f, 0.85f, Color(0xFFFFC3A0), 0.26f),
                Blob(0.90f, 0.96f, 0.90f, Color(0xFF8BEBC2), 0.24f),
            )
        }
    }
    Box(
        modifier
            .background(Brush.verticalGradient(base))
            .drawBehind {
                blobs.forEach { b ->
                    drawRect(
                        brush = Brush.radialGradient(
                            colors = listOf(b.color.copy(alpha = b.alpha), Color.Transparent),
                            center = Offset(size.width * b.x, size.height * b.y),
                            radius = size.width * b.radius,
                        ),
                    )
                }
            },
    )
}

private class Blob(val x: Float, val y: Float, val radius: Float, val color: Color, val alpha: Float)

/**
 * 玻璃面板。
 * @param blur 传入后用 Haze 对面板下方的内容做真实背景模糊；不传就是纯半透明（列表里的卡片用这种，省电）
 * @param tint 给玻璃染一点颜色（如逾期用红色）
 * @param onClick 不为空时可点击，按压有弹性缩放
 */
@Composable
fun GlassSurface(
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(26.dp),
    blur: HazeState? = null,
    tint: Color = Color.Unspecified,
    elevated: Boolean = false,
    onClick: (() -> Unit)? = null,
    content: @Composable BoxScope.() -> Unit,
) {
    val dark = isDarkSurface()
    val scheme = MaterialTheme.colorScheme

    val fill = remember(dark, blur != null) {
        val (top, bottom) = when {
            dark && blur != null -> 0.10f to 0.04f
            dark -> 0.12f to 0.05f
            blur != null -> 0.52f to 0.30f
            else -> 0.74f to 0.50f
        }
        Brush.verticalGradient(listOf(Color.White.copy(alpha = top), Color.White.copy(alpha = bottom)))
    }
    val rim = remember(dark) {
        Brush.linearGradient(
            0f to Color.White.copy(alpha = if (dark) 0.50f else 1f),
            0.5f to Color.White.copy(alpha = if (dark) 0.06f else 0.20f),
            1f to Color.White.copy(alpha = if (dark) 0.22f else 0.65f),
        )
    }
    val hazeStyle = remember(dark, scheme.background) {
        HazeStyle(
            backgroundColor = scheme.background,
            tint = HazeTint(if (dark) Color.Black.copy(alpha = 0.22f) else Color.White.copy(alpha = 0.30f)),
            blurRadius = 26.dp,
            noiseFactor = 0.04f,
        )
    }

    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (onClick != null && pressed) 0.97f else 1f,
        animationSpec = spring(dampingRatio = 0.55f, stiffness = Spring.StiffnessMediumLow),
        label = "glass-press",
    )

    Box(
        modifier = modifier
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .then(
                if (elevated && !dark) {
                    Modifier.shadow(
                        elevation = 14.dp,
                        shape = shape,
                        clip = false,
                        ambientColor = scheme.primary.copy(alpha = 0.10f),
                        spotColor = scheme.primary.copy(alpha = 0.22f),
                    )
                } else {
                    Modifier
                },
            )
            .clip(shape)
            .then(if (blur != null) Modifier.hazeEffect(blur, hazeStyle) else Modifier)
            .background(fill)
            .then(
                if (tint != Color.Unspecified) {
                    Modifier.background(tint.copy(alpha = if (dark) 0.18f else 0.14f))
                } else {
                    Modifier
                },
            )
            .border(1.dp, rim, shape)
            .then(
                if (onClick != null) {
                    Modifier.clickable(interactionSource = interaction, indication = LocalIndication.current, onClick = onClick)
                } else {
                    Modifier
                },
            ),
        content = content,
    )
}

/** 圆形图标底座（设置项、待办分组等处使用），同样是微型玻璃 */
@Composable
fun GlassBadge(
    icon: ImageVector,
    modifier: Modifier = Modifier,
    tint: Color = MaterialTheme.colorScheme.primary,
    size: Dp = 40.dp,
) {
    Box(
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            .background(Brush.verticalGradient(listOf(tint.copy(alpha = 0.30f), tint.copy(alpha = 0.14f))))
            .border(
                1.dp,
                Brush.linearGradient(listOf(Color.White.copy(alpha = 0.7f), Color.White.copy(alpha = 0.05f))),
                CircleShape,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(size * 0.5f))
    }
}

data class GlassNavItem(val label: String, val icon: ImageVector)

/** 底部悬浮玻璃导航：胶囊形，选中指示器是一块会弹性滑动的液体 */
@Composable
fun GlassNavBar(
    items: List<GlassNavItem>,
    selected: Int,
    onSelect: (Int) -> Unit,
    hazeState: HazeState,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    val dark = isDarkSurface()

    GlassSurface(
        modifier = modifier
            .navigationBarsPadding()
            .padding(horizontal = 16.dp, vertical = 14.dp)
            .fillMaxWidth()
            .height(66.dp),
        shape = CircleShape,
        blur = hazeState,
        elevated = true,
    ) {
        BoxWithConstraints(
            Modifier
                .fillMaxSize()
                .padding(5.dp),
        ) {
            val itemWidth = maxWidth / items.size
            val offset by animateDpAsState(
                targetValue = itemWidth * selected,
                animationSpec = spring(dampingRatio = 0.62f, stiffness = 260f),
                label = "nav-indicator",
            )
            Box(
                Modifier
                    .offset(x = offset)
                    .width(itemWidth)
                    .fillMaxHeight()
                    .clip(CircleShape)
                    .background(
                        Brush.verticalGradient(
                            listOf(
                                scheme.primary.copy(alpha = if (dark) 0.34f else 0.22f),
                                scheme.primary.copy(alpha = if (dark) 0.18f else 0.10f),
                            ),
                        ),
                    )
                    .border(
                        1.dp,
                        Brush.linearGradient(listOf(Color.White.copy(alpha = if (dark) 0.5f else 0.9f), Color.White.copy(alpha = 0.08f))),
                        CircleShape,
                    ),
            )
            Row(Modifier.fillMaxSize()) {
                items.forEachIndexed { index, item ->
                    val active = index == selected
                    val color = if (active) scheme.primary else scheme.onSurfaceVariant
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxHeight()
                            .clip(CircleShape)
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                            ) { onSelect(index) },
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
                    ) {
                        Icon(item.icon, contentDescription = null, tint = color, modifier = Modifier.size(22.dp))
                        Text(item.label, style = MaterialTheme.typography.labelSmall, color = color)
                    }
                }
            }
        }
    }
}
