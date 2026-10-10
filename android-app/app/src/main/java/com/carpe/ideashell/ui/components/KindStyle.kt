package com.carpe.ideashell.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.core.parse.CaptureKind

/** 每种记录类型的配色：待办（主色）/ Daily Note（第三色）/ 笔记（第二色） */
data class KindColors(val container: Color, val onContainer: Color)

@Composable
fun kindColors(kind: CaptureKind): KindColors {
    val c = MaterialTheme.colorScheme
    return when (kind) {
        CaptureKind.TODO -> KindColors(c.primaryContainer, c.onPrimaryContainer)
        CaptureKind.DAILY -> KindColors(c.tertiaryContainer, c.onTertiaryContainer)
        CaptureKind.NOTE -> KindColors(c.secondaryContainer, c.onSecondaryContainer)
    }
}

fun kindIcon(kind: CaptureKind): ImageVector = when (kind) {
    CaptureKind.TODO -> Icons.Filled.CheckCircle
    CaptureKind.DAILY -> Icons.Filled.DateRange
    CaptureKind.NOTE -> Icons.Filled.Edit
}

/** 小胶囊：显示识别结果（类型 / 日期 / 标签 / 文件夹） */
@Composable
fun InfoPill(
    text: String,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    container: Color = MaterialTheme.colorScheme.surfaceContainerHigh,
    content: Color = MaterialTheme.colorScheme.onSurfaceVariant,
) {
    Surface(modifier = modifier, shape = CircleShape, color = container, contentColor = content) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (icon != null) Icon(icon, contentDescription = null, modifier = Modifier.size(14.dp))
            Text(text, style = MaterialTheme.typography.labelMedium, maxLines = 1)
        }
    }
}
