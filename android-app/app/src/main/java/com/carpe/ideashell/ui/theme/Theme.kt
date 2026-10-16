package com.carpe.ideashell.ui.theme

import android.graphics.Color as AndroidColor
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.carpe.ideashell.data.settings.ThemeMode

/*
 * 设计系统「环」：来自闪念贝壳图标——一个带缺口的圆环和几颗星光。
 * - 色彩：深色模式用压低亮度的暗橙 #E0703F（纯品牌橙 #FF5A00 在深色底上太刺眼）；浅色模式用降饱和的柔橙 #E8794A，只用在「填充」上（圆环、导航选中、记一条按钮），
 *   上面的文字一律用深棕。橙色当文字、链接用时对比度不够，所以 [MaterialTheme.colorScheme.primary] 是加深的 #A9441C（浅色）/ 橙色（深色）。
 *   浅色底色是偏灰的燕麦米色 #F7F2EA，文字是暖灰深棕 #2A2118，不用纯黑纯白。
 * - 分层：奶油底 + 白色圆角块（任务是一条一条的胶囊，不是一整张大卡片）；逾期任务反白成深棕胶囊，是页面上最重的东西。
 * - 字体：系统字体（中文是系统黑体），靠字重拉开层级：大数字 Black、标题 ExtraBold / Bold、说明 Medium；
 *   最小字号 11sp，正文 15sp，页面标题 20sp。
 * - 形状：胶囊 24dp、抽屉 / 弹层顶部 32dp、按钮和分段控件全圆角。
 * - 动效：按下缩到 0.96、完成时星光飞入；内容卡片没有实时模糊，切页不掉帧。
 * - 玻璃：只有浮动层（底部导航、「记一条」、底部弹出面板）是液态玻璃，见 ui/glass/Glass.kt。
 * 默认不用动态取色：部分国产系统对 Material You 取色支持不完整，固定配色能保证在荣耀等设备上外观一致。
 */

/**
 * 品牌的三个颜色，用在「填充」上（色块、圆环、导航、记一条按钮）。
 * 深色模式用暗橙 #E0703F（#FF5A00 在深色底上发光刺眼）；浅色模式用降饱和的柔橙 #E8794A，底色是偏灰的燕麦米色，墨色略带暖灰。
 * 读的是 Compose 状态，主题切换时由 [IdeashellTheme] 同步，用到它的界面会自动重组。
 */
object Brand {
    private var dark by mutableStateOf(false)

    internal fun sync(isDark: Boolean) {
        if (dark != isDark) dark = isDark
    }

    val Orange: Color get() = if (dark) Color(0xFFE0703F) else Color(0xFFE8794A)
    val Brown: Color get() = if (dark) Color(0xFF24150C) else Color(0xFF2A2118)
    val Cream: Color get() = if (dark) Color(0xFFFFF8F0) else Color(0xFFF7F2EA)

    /** 橙色的两个浅阶（热力图 / 随机漫步卡背面），以及再深一档（文字、最深的格子） */
    val OrangeSoft: Color get() = if (dark) Color(0xFFFFD9BF) else Color(0xFFF6DCCB)
    val OrangeMid: Color get() = if (dark) Color(0xFFE8956B) else Color(0xFFEFA67F)
    val OrangeDeep: Color get() = if (dark) Color(0xFFB4532C) else Color(0xFFA9441C)

    /** 环的第三层：琥珀 */
    val Amber: Color get() = if (dark) Color(0xFFFFB020) else Color(0xFFD9A441)
}

private val LightColors = lightColorScheme(
    primary = Color(0xFFA9441C),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFF6DCCB),
    onPrimaryContainer = Color(0xFF4F200D),
    secondary = Color(0xFF6E5C4E),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFEBDFD2),
    onSecondaryContainer = Color(0xFF3A2C20),
    tertiary = Color(0xFF7A5A12),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFF3E3B8),
    onTertiaryContainer = Color(0xFF3F2E00),
    error = Color(0xFFB3261E),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF410002),
    background = Color(0xFFF7F2EA),
    onBackground = Color(0xFF2A2118),
    surface = Color(0xFFF7F2EA),
    onSurface = Color(0xFF2A2118),
    surfaceVariant = Color(0xFFEDE4D8),
    onSurfaceVariant = Color(0xFF6E5C4E),
    outline = Color(0xFF8C7B6C),
    outlineVariant = Color(0xFFE4D9CB),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFF3EBDF),
    surfaceContainer = Color(0xFFEFE5D8),
    surfaceContainerHigh = Color(0xFFE9DECF),
    surfaceContainerHighest = Color(0xFFE2D5C4),
    inverseSurface = Color(0xFF2A2118),
    inverseOnSurface = Color(0xFFF7F2EA),
    inversePrimary = Color(0xFFEFA67F),
    scrim = Color(0xFF000000),
)

private val DarkColors = darkColorScheme(
    primary = Brand.Orange,
    onPrimary = Brand.Brown,
    primaryContainer = Color(0xFF5C2200),
    onPrimaryContainer = Color(0xFFFFD9C2),
    secondary = Color(0xFFC9B3A3),
    onSecondary = Brand.Brown,
    secondaryContainer = Color(0xFF4A352A),
    onSecondaryContainer = Color(0xFFFFE8D6),
    tertiary = Color(0xFFFFC043),
    onTertiary = Color(0xFF3A2600),
    tertiaryContainer = Color(0xFF4D3A00),
    onTertiaryContainer = Color(0xFFFFE8A8),
    error = Color(0xFFFF8A80),
    onError = Color(0xFF410002),
    errorContainer = Color(0xFF5C1A14),
    onErrorContainer = Color(0xFFFFDAD6),
    background = Color(0xFF1A0F08),
    onBackground = Color(0xFFFFF1E4),
    surface = Color(0xFF1A0F08),
    onSurface = Color(0xFFFFF1E4),
    surfaceVariant = Color(0xFF3D2A1F),
    onSurfaceVariant = Color(0xFFC9B3A3),
    outline = Color(0xFF9C8574),
    outlineVariant = Color(0xFF3F2C21),
    surfaceContainerLowest = Color(0xFF2A1A10),
    surfaceContainerLow = Color(0xFF231610),
    surfaceContainer = Color(0xFF33211A),
    surfaceContainerHigh = Color(0xFF3D2A1F),
    surfaceContainerHighest = Color(0xFF4A352A),
    inverseSurface = Color(0xFFFFF1E4),
    inverseOnSurface = Brand.Brown,
    inversePrimary = Color(0xFFB4532C),
    scrim = Color(0xFF000000),
)

private val AppShapes = Shapes(
    extraSmall = RoundedCornerShape(10.dp),
    small = RoundedCornerShape(14.dp),
    medium = RoundedCornerShape(20.dp),
    large = RoundedCornerShape(24.dp),
    extraLarge = RoundedCornerShape(32.dp),
)

private val base = Typography()
private val AppTypography = Typography(
    // 页面大标题：ExtraBold，靠字重而不是字号拉开层级
    headlineMedium = TextStyle(fontSize = 24.sp, lineHeight = 30.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = 0.sp),
    headlineSmall = TextStyle(fontSize = 20.sp, lineHeight = 26.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = 0.sp),
    titleLarge = base.titleLarge.copy(fontSize = 18.sp, lineHeight = 24.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.sp),
    // 标题 / 行标题
    titleMedium = base.titleMedium.copy(fontSize = 15.sp, lineHeight = 21.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.sp),
    titleSmall = base.titleSmall.copy(fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.sp),
    // 正文 / 副标题 / 脚注
    bodyLarge = TextStyle(fontSize = 15.sp, lineHeight = 22.sp, letterSpacing = 0.sp),
    bodyMedium = TextStyle(fontSize = 14.sp, lineHeight = 20.sp, letterSpacing = 0.sp),
    bodySmall = TextStyle(fontSize = 12.sp, lineHeight = 17.sp, letterSpacing = 0.sp),
    labelLarge = base.labelLarge.copy(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.sp),
    labelMedium = base.labelMedium.copy(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.sp),
    labelSmall = base.labelSmall.copy(fontSize = 11.sp, lineHeight = 15.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.sp),
)

@Composable
fun isDark(themeMode: ThemeMode): Boolean = when (themeMode) {
    ThemeMode.SYSTEM -> isSystemInDarkTheme()
    ThemeMode.LIGHT -> false
    ThemeMode.DARK -> true
}

@Composable
fun IdeashellTheme(
    themeMode: ThemeMode = ThemeMode.SYSTEM,
    content: @Composable () -> Unit,
) {
    val dark = isDark(themeMode)
    Brand.sync(dark)
    val scheme = if (dark) DarkColors else LightColors
    MaterialTheme(
        colorScheme = scheme,
        typography = AppTypography,
        shapes = AppShapes,
    ) {
        // 默认的内容色是黑色，只有 Surface / Scaffold 会按主题重设它。
        // 我们的页面是自己画的 Box 和卡片，没有 Surface，没写颜色的文字和图标在深色模式下会一直是黑的，所以在最外层统一设成 onSurface
        CompositionLocalProvider(LocalContentColor provides scheme.onSurface, content = content)
    }
}

/** 边到边显示，并让状态栏 / 导航栏图标颜色跟随应用主题（而不只是系统深浅色） */
@Composable
fun ComponentActivity.ApplyEdgeToEdge(dark: Boolean) {
    DisposableEffect(dark) {
        val style = SystemBarStyle.auto(AndroidColor.TRANSPARENT, AndroidColor.TRANSPARENT) { dark }
        enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
        onDispose { }
    }
}
