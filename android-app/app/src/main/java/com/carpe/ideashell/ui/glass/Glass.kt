package com.carpe.ideashell.ui.glass

import android.os.Build
import android.view.View
import android.view.WindowManager
import androidx.annotation.DrawableRes
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.GraphicsLayerScope
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogWindowProvider
import com.carpe.ideashell.R
import com.carpe.ideashell.ui.theme.Brand
import com.kyant.backdrop.Backdrop
import com.kyant.backdrop.backdrops.LayerBackdrop
import com.kyant.backdrop.drawBackdrop
import com.kyant.backdrop.effects.blur
import com.kyant.backdrop.effects.colorControls
import com.kyant.backdrop.effects.lens
import com.kyant.backdrop.highlight.Highlight
import com.kyant.backdrop.shadow.Shadow

/*
 * 全应用共用的「面」与「玻璃」（设计系统「环」）。
 *
 * 分两层：
 * - 内容层：奶油底上的白色圆角块，没有描边、没有阴影、没有模糊——页面里成百上千的卡片都是这种实心面，保证滚动不掉帧；
 * - 浮动层（底部导航胶囊、「记一条」按钮、底部弹出面板）：液态玻璃。
 *   导航和按钮用 Kyant0 的 Backdrop 库做真折射：把「背景光晕 + 当前页面」录进一个 [LayerBackdrop]（[LocalGlassBackdrop]），
 *   玻璃元素把它取回来做 模糊 + 饱和度增强 + 透镜折射（API 33+，AGSL）+ 高光描边 + 投影。
 *   只有这两个小元素在每帧重新采样背景，内容卡片不参与，不会再出现早期 Haze 整页模糊的卡顿。
 *   API 31 以下没有 RenderEffect，[LocalGlassBackdrop] 为 null，浮动层退回半透明实心面。
 *   底部弹出面板是独立窗口，没法共享 backdrop，改用「窗口背后模糊 + 半透明面」（系统不允许跨窗口模糊时保持实心）。
 * - 背景：奶油底 + 三团静态光晕（只画一次，不随滚动重绘）。玻璃要折射的就是它们和页面卡片。
 * 为了不大面积改调用点，类名与包名沿用 Glass 前缀（GlassSurface / GlassBadge / AuroraBackground）。
 */

/** 底部导航占用的高度（含系统导航栏），各页面据此给列表留出底部空白 */
val LocalBottomBarPadding = compositionLocalOf { 24.dp }

/**
 * 玻璃要折射的「背后画面」。由根布局提供；为 null 表示当前系统不支持（API < 31），玻璃元素退回实心半透明面。
 * 注意：被录进 backdrop 的内容里不能再取这个 backdrop（会形成环路导致原生崩溃），所以只在根布局的「浮动层」里使用。
 */
val LocalGlassBackdrop = staticCompositionLocalOf<LayerBackdrop?> { null }

/** 系统是否支持玻璃所需的 RenderEffect 模糊（Android 12+）；折射（lens）另需 Android 13+，低一档时自动只有模糊 */
val GlassSupported: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

/** 全屏面板（比如日历里点一天弹出的任务面板）打开时要盖住底部导航：用它临时把导航收起来 */
object NavBarOverlay {
    var hidden: Boolean by androidx.compose.runtime.mutableStateOf(false)
}

@Composable
fun isDarkSurface(): Boolean = MaterialTheme.colorScheme.background.luminance() < 0.5f

/**
 * 「静态玻璃」小件：标题栏按钮、小胶囊这类放在页面内容里的小东西用它。
 * 它们在被 layerBackdrop 录制的页面里面，不能再去采样背景（会形成循环崩溃），
 * 所以这里不做实时折射，只用「半透明渐变 + 上亮下暗的细边」画出玻璃的质感；
 * 没有 RenderEffect、没有离屏层、也没有阴影，几乎没有绘制开销，滚动不会受影响。
 */
@Composable
fun Modifier.glassChip(shape: Shape = CircleShape, tint: Color = Color.Unspecified): Modifier {
    val dark = isDarkSurface()
    // tint 不为空：深色玻璃（如深棕横幅），用 tint 当底，细边是上亮下淡的白光
    val tinted = tint != Color.Unspecified
    val fill = Brush.verticalGradient(
        when {
            tinted -> listOf(tint.copy(alpha = 0.90f), tint.copy(alpha = 0.72f))
            dark -> listOf(Color.White.copy(alpha = 0.20f), Color.White.copy(alpha = 0.08f))
            else -> listOf(Color.White.copy(alpha = 0.78f), Color.White.copy(alpha = 0.44f))
        },
    )
    val rim = Brush.verticalGradient(
        when {
            tinted -> listOf(Color.White.copy(alpha = 0.34f), Color.White.copy(alpha = 0.05f))
            dark -> listOf(Color.White.copy(alpha = 0.40f), Color.White.copy(alpha = 0.06f))
            else -> listOf(Color.White.copy(alpha = 0.95f), Color(0x2E7A4A22))
        },
    )
    return this
        .clip(shape)
        .background(fill)
        .border(0.8.dp, rim, shape)
}

/**
 * 页面底色：奶油底 + 三团静态光晕（右上橙、左中琥珀、右下浅橙）。
 * 光晕在 drawWithCache 里只构建一次渐变，页面滚动不会重绘它；它的作用是给上面的玻璃「可折射的颜色」。
 */
@Composable
fun AuroraBackground(modifier: Modifier = Modifier.fillMaxSize()) {
    Box(modifier.aurora())
}

/**
 * 同 [AuroraBackground]，但是修饰符形式：给一块区域画上奶油底 + 光晕（不透明）。
 * 光晕的位置是按这块区域自己的大小算的，所以只适合铺满整个页面，不要用在页面的局部区域上（会和整页的光晕出现接缝）。
 */
@Composable
fun Modifier.aurora(): Modifier {
    val base = MaterialTheme.colorScheme.background
    val dark = isDarkSurface()
    val orange = Brand.Orange
    val amber = Brand.Amber
    val soft = Brand.OrangeMid
    return this
        .background(base)
        .drawWithCache {
            val w = size.width
            val h = size.height
            val strength = if (dark) 0.30f else 0.36f
            val top = Brush.radialGradient(
                listOf(orange.copy(alpha = strength), Color.Transparent),
                center = Offset(w * 0.95f, h * 0.04f),
                radius = w * 0.95f,
            )
            val mid = Brush.radialGradient(
                listOf(amber.copy(alpha = strength * 0.85f), Color.Transparent),
                center = Offset(w * 0.0f, h * 0.50f),
                radius = w * 0.85f,
            )
            val bottom = Brush.radialGradient(
                listOf(soft.copy(alpha = strength * 0.9f), Color.Transparent),
                center = Offset(w * 0.85f, h * 0.98f),
                radius = w * 1.0f,
            )
            onDrawBehind {
                drawRect(top)
                drawRect(mid)
                drawRect(bottom)
            }
        }
}

/**
 * 液态玻璃修饰符：折射 [LocalGlassBackdrop] 里的背后画面（模糊 + 饱和度 + 透镜 + 高光描边 + 投影），再叠 [onDrawSurface] 的表面色。
 * 没有 backdrop（API < 31）时退回 [fallback] 色的实心面。
 *
 * @param backdrop 指定要折射的背后画面；不传就用根布局提供的 [LocalGlassBackdrop]。
 *   被它录进去的内容里不能再取同一个 backdrop（环路 → 原生崩溃），所以局部浮层（日历面板）传自己的兄弟 backdrop
 * @param lensHeight 透镜边缘宽度，不能超过元素短边的一半
 * @param lensAmount 折射位移量
 * @param saturation 背后画面的饱和度（1 = 不变）。增强太多会把背后的橙色卡片染成发黄的荧光色
 * @param rim 玻璃边缘的高光描边；null 表示不画
 * @param layerBlock 会移动 / 缩放的玻璃要用它（graphicsLayer 的变换）而不是布局 offset：
 *   这样折射、高光、投影才会跟着一起动；用 offset 移动会在原位留下一圈高光「鬼影」
 */
@Composable
fun Modifier.liquidGlass(
    shape: Shape,
    fallback: Color,
    backdrop: Backdrop? = null,
    lensHeight: Dp = 16.dp,
    lensAmount: Dp = 32.dp,
    blurRadius: Dp = 4.dp,
    saturation: Float = 1.5f,
    dropShadow: Shadow? = Shadow.Default,
    rim: Highlight? = Highlight.Default,
    layerBlock: (GraphicsLayerScope.() -> Unit)? = null,
    onDrawSurface: DrawScope.() -> Unit,
): Modifier {
    val source = backdrop ?: LocalGlassBackdrop.current
    if (source == null) {
        return this
            .shadow(8.dp, shape, clip = false)
            .clip(shape)
            .background(fallback)
    }
    return this.drawBackdrop(
        backdrop = source,
        shape = { shape },
        effects = {
            colorControls(saturation = saturation)
            blur(blurRadius.toPx())
            lens(lensHeight.toPx(), lensAmount.toPx())
        },
        highlight = if (rim != null) ({ rim }) else null,
        shadow = if (dropShadow != null) ({ dropShadow }) else null,
        layerBlock = layerBlock,
        onDrawSurface = onDrawSurface,
    )
}

/**
 * 卡片面板（内容层，实心）。
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
 * 玻璃表面色：浅色下是偏白的乳白，深色下是偏暖的深棕。
 * 要透：背后是白色卡片 + 奶油底，白色叠得太多就成了一块实心白板，折射 / 模糊看不出来。
 * 图标和 11sp 小字靠 onSurface 的深色保证对比度，不靠表面不透明度。
 * 需要更不透明的大面板（日历面板）自己再 copy(alpha)。
 */
fun glassSurfaceColor(dark: Boolean): Color =
    if (dark) Color(0xFF33200F).copy(alpha = 0.44f) else Color.White.copy(alpha = 0.34f)

/**
 * 底部悬浮导航：左边一颗玻璃胶囊，右边是同一行的玻璃「记一条」圆钮（[fab]）。
 * 每项是图标 + 小字；选中项下面有一块贝壳橙的高光胶囊，切换时像水滴一样滑过去。
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
    val dark = isDarkSurface()
    val capsule = RoundedCornerShape(32.dp)
    val idle = scheme.onSurface.copy(alpha = 0.78f)
    // 选中项的强调色：浅色用加深的品牌橙（#A9441C，橙色当文字对比度够），深色用品牌橙
    val accent = if (dark) Brand.Orange else Brand.OrangeDeep
    val surface = glassSurfaceColor(dark)
    val itemShape = RoundedCornerShape(26.dp)
    Row(
        modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(start = 16.dp, end = 16.dp, bottom = NavBarGap),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BoxWithConstraints(
            Modifier
                .weight(1f)
                .height(NavBarHeight)
                .liquidGlass(
                    shape = capsule,
                    fallback = if (dark) scheme.surfaceContainerHigh else scheme.surfaceContainerLowest.copy(alpha = 0.96f),
                    // 折射集中在胶囊最外一圈；中间靠模糊 + 饱和度出「玻璃」的通透感
                    lensHeight = 12.dp,
                    lensAmount = 22.dp,
                    blurRadius = 10.dp,
                    saturation = 1.12f,
                    onDrawSurface = { drawRect(surface) },
                )
                .padding(horizontal = 6.dp),
        ) {
            val itemWidth = maxWidth / items.size.coerceAtLeast(1)
            val indicatorX by animateDpAsState(
                targetValue = itemWidth * selected,
                animationSpec = spring(dampingRatio = 0.72f, stiffness = Spring.StiffnessMediumLow),
                label = "navIndicator",
            )
            // 选中指示：一块更清晰的玻璃「透镜」——背后的画面只轻模糊、折射更强，带一圈很淡的高光轮廓和一点投影；
            // 比胶囊本体更透亮，也比它更暗一点，所以在任何背景（包括大块橙色卡片）上都能分出来。
            // 不用实色橙块：扁平的橙在橙色卡片上会发黄，也没有玻璃的感觉。强调色交给图标和文字。
            Box(
                Modifier
                    .align(Alignment.CenterStart)
                    .width(itemWidth)
                    .height(52.dp)
                    .liquidGlass(
                        shape = itemShape,
                        fallback = Brand.OrangeSoft,
                        lensHeight = 14.dp,
                        lensAmount = 26.dp,
                        blurRadius = 5.dp,
                        saturation = 1.0f,
                        dropShadow = Shadow(radius = 8.dp, color = Color.Black.copy(alpha = 0.10f)),
                        // 轮廓只是淡淡一圈：太亮会抢过图标和文字
                        rim = Highlight(width = 0.5.dp, blurRadius = 0.5.dp, alpha = 0.4f),
                        // 水平滑动用图形层平移（在绘制阶段读动画值，滑动时不触发重组）
                        layerBlock = { translationX = indicatorX.toPx() },
                        onDrawSurface = {
                            if (dark) {
                                drawRect(Color.White.copy(alpha = 0.14f))
                            } else {
                                drawRect(Color.White.copy(alpha = 0.30f))
                                drawRect(Brand.Brown.copy(alpha = 0.07f))
                            }
                        },
                    ),
            )
            Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
                items.forEachIndexed { index, item ->
                    val active = index == selected
                    val color = if (active) accent else idle
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .height(52.dp)
                            .clip(itemShape)
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
        }
        if (fab != null) {
            Spacer(Modifier.width(12.dp))
            fab()
        }
    }
}

/**
 * 底部导航右侧的玻璃「记一条」圆钮：全应用的万能输入入口。
 * 玻璃里染了贝壳橙（用 Hue 混合让背后的色相跟着橙色走），右上角带一颗星光（来自贝壳图标）。
 */
@Composable
fun AddFab(onClick: () -> Unit, modifier: Modifier = Modifier) {
    val orange = Brand.Orange
    Box(modifier = modifier.size(NavBarHeight)) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .liquidGlass(
                    shape = CircleShape,
                    fallback = orange,
                    lensHeight = 10.dp,
                    lensAmount = 18.dp,
                    blurRadius = 2.dp,
                    dropShadow = Shadow(
                        radius = 14.dp,
                        color = orange.copy(alpha = 0.40f),
                    ),
                    onDrawSurface = {
                        drawRect(orange, blendMode = BlendMode.Hue)
                        drawRect(orange.copy(alpha = 0.88f))
                    },
                )
                .clip(CircleShape)
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

// ───────────────────────── 底部弹出面板：毛玻璃 ─────────────────────────

/** 系统当前是否允许「窗口背后模糊」（Android 12+，且没开省电 / 厂商没关闭）。只在面板打开时读一次 */
@Composable
fun rememberCrossWindowBlur(): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
    val view = LocalView.current
    return remember(view) {
        runCatching {
            view.context.getSystemService(WindowManager::class.java)?.isCrossWindowBlurEnabled == true
        }.getOrDefault(false)
    }
}

/** 所有底部抽屉背后的磨砂强度（像素）：窗口级模糊和日历里的页面内模糊共用这一个值 */
const val SheetBlurPx = 24

/**
 * 给当前组合所在的窗口打开「背后模糊」：底下的页面变成磨砂。找不到窗口就什么也不做。
 * 三种窗口都认：对话框 / 底部面板（Dialog 窗口）、半透明 Activity（快速输入）、Popup（下拉菜单）。
 * Popup 的模糊范围是整个弹窗矩形（不跟随圆角），圆角外会有一小块模糊，所以菜单只适合用在浅色大面积背景上。
 */
@Composable
fun BlurBehindWindow(radiusPx: Int) {
    val view = LocalView.current
    // 窗口刚创建时，首次组合发生在它挂上 WindowManager 之前：这时改窗口参数会落空，
    // 如果半径之后不再变化就一直是清晰的（要等别的操作触发窗口刷新才变糊）。所以立即应用一次，再在挂载后补几次。
    androidx.compose.runtime.LaunchedEffect(view, radiusPx) {
        applyBlurBehind(view, radiusPx)
        for (wait in longArrayOf(16, 60, 150, 300)) {
            kotlinx.coroutines.delay(wait)
            applyBlurBehind(view, radiusPx)
        }
    }
}

private fun applyBlurBehind(view: View, radiusPx: Int) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
    runCatching {
        fun applyToWindow(window: android.view.Window) {
            window.addFlags(WindowManager.LayoutParams.FLAG_BLUR_BEHIND)
            val attrs = window.attributes
            if (attrs.blurBehindRadius != radiusPx) {
                attrs.blurBehindRadius = radiusPx
                window.attributes = attrs
            }
        }
        val root = view.rootView
        val dialogWindow = findDialogWindowProvider(view)?.window
        val activityWindow = view.context.findActivity()?.window
        when {
            dialogWindow != null -> applyToWindow(dialogWindow)
            activityWindow != null && activityWindow.decorView === root -> applyToWindow(activityWindow)
            else -> {
                // Popup / 底部面板等直接用 WindowManager 添加的窗口：改它的布局参数（还没挂上时 layoutParams 不是 WindowManager 的，下次再试）
                val params = root.layoutParams as? WindowManager.LayoutParams ?: return@runCatching
                if (root.isAttachedToWindow && params.blurBehindRadius != radiusPx) {
                    params.flags = params.flags or WindowManager.LayoutParams.FLAG_BLUR_BEHIND
                    params.blurBehindRadius = radiusPx
                    view.context.getSystemService(WindowManager::class.java)?.updateViewLayout(root, params)
                }
            }
        }
    }
}

private fun android.content.Context.findActivity(): android.app.Activity? {
    var c: android.content.Context? = this
    while (c is android.content.ContextWrapper) {
        if (c is android.app.Activity) return c
        c = c.baseContext
    }
    return null
}

private fun findDialogWindowProvider(view: View): DialogWindowProvider? {
    var current: Any? = view
    var depth = 0
    while (current != null && depth < 4) {
        if (current is DialogWindowProvider) return current
        current = (current as? View)?.parent
        depth++
    }
    return null
}

/**
 * 底部弹出面板（和任务详情同一套样式）的玻璃版：半透明的面 + 窗口背后模糊。
 * 面板是独立窗口，不能共享 backdrop 做折射，所以这里是「磨砂」而不是「折射」；
 * 系统不允许跨窗口模糊时，面保持实心，保证文字可读。
 * 面板里的输入行、白色圆角块仍然是实心的。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GlassSheet(
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    topRadius: Dp = 28.dp,
    /** 背后磨砂的常态强度（像素）；默认和其它抽屉一致，要更糊的抽屉（如专注选任务）传大一点 */
    blurPx: Int = SheetBlurPx,
    content: @Composable ColumnScope.() -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    val blurOk = rememberCrossWindowBlur()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    // 开始往下收（目标是 Hidden，但还没落到底）：磨砂跟着一起退，不等窗口被移除
    val closing = sheetState.targetValue == SheetValue.Hidden && sheetState.currentValue != SheetValue.Hidden
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        modifier = modifier,
        sheetState = sheetState,
        containerColor = if (blurOk) scheme.surface.copy(alpha = 0.82f) else scheme.surface,
        shape = RoundedCornerShape(topStart = topRadius, topEnd = topRadius),
        scrimColor = Color.Black.copy(alpha = if (blurOk) 0.22f else 0.32f),
    ) {
        if (blurOk) SheetBlurBehind(closing = closing, restPx = blurPx)
        content()
    }
}

/** 抽屉刚弹出时的磨砂峰值（像素）：一上来就够糊，然后回落到 [SheetBlurPx] */
const val SheetBlurPeakPx = 44

/**
 * 抽屉的背后磨砂，带起落节奏：弹出时从峰值回落到常态；开始收起时在 140ms 内迅速退到 0，
 * 这样磨砂不会比抽屉本身多停留一会儿（系统窗口模糊自己的淡出偏慢，所以主动先退掉）。
 */
@Composable
fun SheetBlurBehind(closing: Boolean = false, restPx: Int = SheetBlurPx, peakPx: Int = maxOf(SheetBlurPeakPx, restPx + 16)) {
    val radius = remember { androidx.compose.animation.core.Animatable(peakPx.toFloat()) }
    androidx.compose.runtime.LaunchedEffect(closing) {
        if (closing) {
            radius.animateTo(0f, androidx.compose.animation.core.tween(140))
        } else {
            radius.animateTo(
                restPx.toFloat(),
                androidx.compose.animation.core.tween(420, easing = androidx.compose.animation.core.FastOutSlowInEasing),
            )
        }
    }
    BlurBehindWindow(radiusPx = radius.value.toInt())
}

/**
 * 确认 / 选择对话框的玻璃版：和 [GlassSheet] 一样，窗口背后磨砂 + 半透明的面。
 * 只在弹出时生效一次，不影响页面滚动；系统不允许跨窗口模糊时保持实心。
 * 参数只保留项目里用到的几个，调用处用 `import ...GlassAlertDialog as AlertDialog` 直接替换。
 */
@Composable
fun GlassAlertDialog(
    onDismissRequest: () -> Unit,
    confirmButton: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    dismissButton: (@Composable () -> Unit)? = null,
    title: (@Composable () -> Unit)? = null,
    text: (@Composable () -> Unit)? = null,
) {
    val scheme = MaterialTheme.colorScheme
    val blurOk = rememberCrossWindowBlur()
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismissRequest,
        confirmButton = {
            if (blurOk) BlurBehindWindow(radiusPx = SheetBlurPx)
            confirmButton()
        },
        modifier = modifier,
        dismissButton = dismissButton,
        title = title,
        text = text,
        containerColor = if (blurOk) scheme.surfaceContainerHigh.copy(alpha = 0.86f) else scheme.surfaceContainerHigh,
    )
}

/**
 * 有颜色的玻璃按钮（开始 / 暂停 / 改到今天 / 追加 亮起…）：[tint] 色的半透明渐变底，
 * 上半部一层白色「天光」，再加上亮下淡的白色细边，看起来像一粒有色的玻璃。
 * 和 [glassChip] 一样是静态绘制：没有模糊、阴影和离屏层，开销可以忽略。
 */
@Composable
fun Modifier.glassButton(shape: Shape = CircleShape, tint: Color): Modifier {
    val fill = Brush.verticalGradient(listOf(tint.copy(alpha = tint.alpha * 0.96f), tint.copy(alpha = tint.alpha * 0.80f)))
    val sheen = Brush.verticalGradient(
        0f to Color.White.copy(alpha = 0.26f),
        0.55f to Color.White.copy(alpha = 0.02f),
        1f to Color.Transparent,
    )
    val rim = Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.50f), Color.White.copy(alpha = 0.08f)))
    return this
        .clip(shape)
        .background(fill)
        .background(sheen)
        .border(0.8.dp, rim, shape)
}

/** 提示条的玻璃版：半透明深色面 + 上亮下暗的细边（静态玻璃，不采样背景） */
@Composable
fun Modifier.glassSnackbar(shape: Shape): Modifier {
    val rim = Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.38f), Color.White.copy(alpha = 0.06f)))
    return this.border(0.8.dp, rim, shape)
}

/**
 * 玻璃实心按钮：Material [Button] 的行为（点击、禁用、无障碍）不变，外观换成有色玻璃（见 [glassButton]）。
 * [tint] 默认主题主色；品牌橙色的主按钮传 `Brand.Orange` + `Brand.Brown`。
 */
@Composable
fun GlassButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    tint: Color = MaterialTheme.colorScheme.primary,
    contentColor: Color = MaterialTheme.colorScheme.onPrimary,
    content: @Composable RowScope.() -> Unit,
) {
    // 不可用时不能沿用「品牌色 × 深棕字」：深色模式下是一块暗褐色上的暗字，几乎看不见。
    // 改成跟随主题的中性灰玻璃 + onSurface 的淡字（浅色 / 深色都清楚，且明显是「不可点」）
    val onSurface = MaterialTheme.colorScheme.onSurface
    Button(
        onClick = onClick,
        modifier = modifier.glassButton(CircleShape, if (enabled) tint.copy(alpha = 0.88f) else onSurface.copy(alpha = 0.16f)),
        enabled = enabled,
        shape = CircleShape,
        colors = ButtonDefaults.buttonColors(
            containerColor = Color.Transparent,
            contentColor = contentColor,
            disabledContainerColor = Color.Transparent,
            disabledContentColor = onSurface.copy(alpha = 0.45f),
        ),
        elevation = null,
        content = content,
    )
}

/** 玻璃描边按钮：通透的浅玻璃底 + 白色细边，替代 `OutlinedButton`（次要操作）。 */
@Composable
fun GlassOutlinedButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit,
) {
    val primary = MaterialTheme.colorScheme.primary
    Button(
        onClick = onClick,
        modifier = modifier.glassChip(CircleShape),
        enabled = enabled,
        shape = CircleShape,
        colors = ButtonDefaults.buttonColors(
            containerColor = Color.Transparent,
            contentColor = primary,
            disabledContainerColor = Color.Transparent,
            disabledContentColor = primary.copy(alpha = 0.4f),
        ),
        elevation = null,
        content = content,
    )
}
