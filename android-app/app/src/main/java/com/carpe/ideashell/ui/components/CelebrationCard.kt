package com.carpe.ideashell.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.data.focus.Celebration
import com.carpe.ideashell.data.focus.CelebrationCenter
import com.carpe.ideashell.ui.theme.Brand
import kotlinx.coroutines.delay

/**
 * 完成番茄 / 任务时顶部滑下来的反馈卡：做了什么、过程中记录了哪些内容、一句鼓励。
 * 不挡操作（不是弹窗），点一下收起，也会自己消失：记录越多停留越久。
 */
@Composable
fun CelebrationHost(center: CelebrationCenter, modifier: Modifier = Modifier) {
    val current by center.current.collectAsStateWithLifecycle()
    // 退出动画期间 current 已经是 null，留一份最后显示的内容
    var last by remember { mutableStateOf<Celebration?>(null) }
    if (current != null) last = current

    LaunchedEffect(current?.id) {
        val c = current ?: return@LaunchedEffect
        // 很久以前（比如应用不在前台时完成的）的反馈不再补显示
        if (System.currentTimeMillis() - c.postedAt > 90_000L) {
            center.dismiss(c.id)
            return@LaunchedEffect
        }
        delay((8_000L + c.records.size.coerceAtMost(5) * 1_500L))
        center.dismiss(c.id)
    }

    Box(modifier.fillMaxWidth().statusBarsPadding(), contentAlignment = Alignment.TopCenter) {
        AnimatedVisibility(
            visible = current != null,
            enter = slideInVertically(tween(280)) { -it } + fadeIn(tween(220)),
            exit = slideOutVertically(tween(220)) { -it } + fadeOut(tween(160)),
        ) {
            last?.let { CelebrationCard(it) { center.dismiss(it.id) } }
        }
    }
}

@Composable
private fun CelebrationCard(c: Celebration, onDismiss: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val shown = c.records.takeLast(5)
    val hidden = c.records.size - shown.size
    Column(
        modifier = Modifier
            .padding(horizontal = 14.dp, vertical = 8.dp)
            .fillMaxWidth()
            .shadow(10.dp, RoundedCornerShape(24.dp), clip = false)
            .clip(RoundedCornerShape(24.dp))
            .background(scheme.surfaceContainerHighest)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(
                Modifier.size(30.dp).clip(CircleShape).background(Brand.Orange),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.Check, contentDescription = null, tint = Brand.Brown, modifier = Modifier.size(18.dp))
            }
            Column(Modifier.weight(1f)) {
                Text(c.headline, fontSize = 17.sp, fontWeight = FontWeight.Black, color = scheme.onSurface)
                if (c.title.isNotBlank()) {
                    Text(c.title, fontSize = 12.sp, color = scheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        if (c.stats.isNotEmpty()) {
            Text(
                c.stats.joinToString("  ·  "),
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                color = Brand.OrangeDeep,
            )
        }
        Text(c.message, style = MaterialTheme.typography.bodyMedium, color = scheme.onSurface)
        if (shown.isNotEmpty()) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(scheme.onSurface.copy(alpha = 0.06f))
                    .padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    if (c.kind == Celebration.Kind.POMODORO) "这个番茄里你记录了" else "这个任务一路记下的",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = scheme.onSurfaceVariant,
                )
                shown.forEach { e ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(e.tag, fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Brand.OrangeDeep, modifier = Modifier.padding(top = 2.dp))
                        Text(
                            e.text.replace(Regex("\\s+"), " "),
                            style = MaterialTheme.typography.bodySmall,
                            color = scheme.onSurface,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
                if (hidden > 0) {
                    Text("还有更早的 $hidden 条", fontSize = 11.sp, color = scheme.onSurfaceVariant)
                }
            }
        }
    }
}
