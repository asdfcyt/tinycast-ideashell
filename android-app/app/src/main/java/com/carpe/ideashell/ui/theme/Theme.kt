package com.carpe.ideashell.ui.theme

import android.graphics.Color as AndroidColor
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.carpe.ideashell.data.settings.ThemeMode

// 品牌主题（青绿色，取自 Material 3 青绿色调色板）。
// 默认不用动态取色：部分国产系统对 Material You 取色支持不完整，
// 品牌主题能保证在荣耀等设备上外观稳定一致；动态取色作为后续可选项放进设置。
private val LightColors = lightColorScheme(
    primary = Color(0xFF006A6A),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFF9CF1F0),
    onPrimaryContainer = Color(0xFF002020),
    secondary = Color(0xFF4A6363),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFCCE8E7),
    onSecondaryContainer = Color(0xFF051F1F),
    tertiary = Color(0xFF4B607C),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFD3E4FF),
    onTertiaryContainer = Color(0xFF041C35),
    error = Color(0xFFBA1A1A),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF410002),
    background = Color(0xFFF4FBFA),
    onBackground = Color(0xFF161D1D),
    surface = Color(0xFFF4FBFA),
    onSurface = Color(0xFF161D1D),
    surfaceVariant = Color(0xFFDAE5E4),
    onSurfaceVariant = Color(0xFF3F4948),
    outline = Color(0xFF6F7979),
    outlineVariant = Color(0xFFBEC9C8),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFEEF5F4),
    surfaceContainer = Color(0xFFE8EFEE),
    surfaceContainerHigh = Color(0xFFE3E9E9),
    surfaceContainerHighest = Color(0xFFDDE4E3),
    inverseSurface = Color(0xFF2B3231),
    inverseOnSurface = Color(0xFFECF2F1),
    inversePrimary = Color(0xFF80D5D4),
    scrim = Color(0xFF000000),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFF80D5D4),
    onPrimary = Color(0xFF003737),
    primaryContainer = Color(0xFF004F4F),
    onPrimaryContainer = Color(0xFF9CF1F0),
    secondary = Color(0xFFB0CCCB),
    onSecondary = Color(0xFF1B3534),
    secondaryContainer = Color(0xFF324B4B),
    onSecondaryContainer = Color(0xFFCCE8E7),
    tertiary = Color(0xFFB3C8E8),
    onTertiary = Color(0xFF1C314B),
    tertiaryContainer = Color(0xFF334863),
    onTertiaryContainer = Color(0xFFD3E4FF),
    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),
    background = Color(0xFF0E1514),
    onBackground = Color(0xFFDDE4E3),
    surface = Color(0xFF0E1514),
    onSurface = Color(0xFFDDE4E3),
    surfaceVariant = Color(0xFF3F4948),
    onSurfaceVariant = Color(0xFFBEC9C8),
    outline = Color(0xFF899392),
    outlineVariant = Color(0xFF3F4948),
    surfaceContainerLowest = Color(0xFF090F0F),
    surfaceContainerLow = Color(0xFF161D1D),
    surfaceContainer = Color(0xFF1A2121),
    surfaceContainerHigh = Color(0xFF252B2B),
    surfaceContainerHighest = Color(0xFF303636),
    inverseSurface = Color(0xFFDDE4E3),
    inverseOnSurface = Color(0xFF2B3231),
    inversePrimary = Color(0xFF006A6A),
    scrim = Color(0xFF000000),
)

private val AppShapes = Shapes(
    extraSmall = androidx.compose.foundation.shape.RoundedCornerShape(8.dp),
    small = androidx.compose.foundation.shape.RoundedCornerShape(12.dp),
    medium = androidx.compose.foundation.shape.RoundedCornerShape(16.dp),
    large = androidx.compose.foundation.shape.RoundedCornerShape(24.dp),
    extraLarge = androidx.compose.foundation.shape.RoundedCornerShape(32.dp),
)

private val base = Typography()
private val AppTypography = Typography(
    headlineMedium = base.headlineMedium.copy(fontWeight = FontWeight.Bold, letterSpacing = 0.sp),
    titleLarge = base.titleLarge.copy(fontWeight = FontWeight.SemiBold),
    titleMedium = base.titleMedium.copy(fontWeight = FontWeight.SemiBold),
    titleSmall = base.titleSmall.copy(fontWeight = FontWeight.SemiBold),
    bodyLarge = TextStyle(fontSize = 17.sp, lineHeight = 26.sp, letterSpacing = 0.sp),
    labelMedium = base.labelMedium.copy(fontWeight = FontWeight.Medium),
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
    MaterialTheme(
        colorScheme = if (isDark(themeMode)) DarkColors else LightColors,
        typography = AppTypography,
        shapes = AppShapes,
        content = content,
    )
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
