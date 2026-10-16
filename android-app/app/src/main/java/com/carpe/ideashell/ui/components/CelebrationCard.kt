package com.carpe.ideashell.ui.components

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Spacer
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.TextUnit
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import android.widget.Toast
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.foundation.Image
import androidx.compose.ui.layout.ContentScale
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.zIndex
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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
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
        delay(14_000L)
        center.dismiss(c.id)
    }

    Box(modifier.fillMaxWidth().statusBarsPadding(), contentAlignment = Alignment.TopCenter) {
        AnimatedVisibility(
            visible = current != null,
            enter = slideInVertically(tween(280)) { -it } + fadeIn(tween(220)),
            exit = slideOutVertically(tween(220)) { -it } + fadeOut(tween(160)),
        ) {
            last?.let { c ->
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    // 终端压在上层，小票从它底部的出纸口里「打」出来
                    CelebrationCard(c, Modifier.zIndex(1f)) { center.dismiss(c.id) }
                    CelebrationTicket(c, center.todayMinutes, Modifier.offset(y = (-18).dp)) { center.dismiss(c.id) }
                }
            }
        }
    }
}

private val TermTop = Color(0xFF1F1915)
private val TermBottom = Color(0xFF0E0B09)
private val TermEdge = Color(0xFF2C241D)
private val LedAmber = Color(0xFFFFB14A)
private val TermGreen = Color(0xFF6FDC9A)
private val TermMute = Color(0xFFA39382)
private val TermCream = Color(0xFFF3E7D7)

/**
 * 完成番茄 / 任务时顶部弹出的「专注终端」：深色小面板，琥珀色点阵屏显示时长（任务完成显示「任务完成」）。
 * 具体的成果在下面「打印」出来的小票上。
 */
@Composable
private fun CelebrationCard(c: Celebration, modifier: Modifier = Modifier, onDismiss: () -> Unit) {
    val isPomo = c.kind == Celebration.Kind.POMODORO
    val led = when {
        !isPomo -> "任务完成"
        c.minutes in 1..99 -> "%02d:00".format(c.minutes)
        c.minutes > 99 -> "${c.minutes}′"
        else -> "00:00"
    }
    val status = if (c.completed) "已完成" else "已记录"
    val shape = RoundedCornerShape(24.dp)
    Column(
        modifier = modifier
            .padding(horizontal = 14.dp, vertical = 6.dp)
            .fillMaxWidth()
            .shadow(12.dp, shape, clip = false)
            .clip(shape)
            .background(Brush.verticalGradient(listOf(TermTop, TermBottom)))
            .border(1.dp, TermEdge, shape)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss)
            .padding(start = 18.dp, end = 18.dp, top = 12.dp, bottom = 10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "拾忆 × 专注终端",
                modifier = Modifier.weight(1f),
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold,
                color = TermMute,
            )
            Box(Modifier.size(6.dp).clip(CircleShape).background(TermGreen))
            Text(status, modifier = Modifier.padding(start = 6.dp), fontSize = 12.sp, fontWeight = FontWeight.Bold, color = TermGreen)
        }
        Box(Modifier.fillMaxWidth().padding(top = 8.dp), contentAlignment = Alignment.Center) {
            DotMatrixText(led, if (isPomo) 34.sp else 26.sp, scanlines = !isPomo)
        }
        // 出纸口
        Box(
            Modifier
                .fillMaxWidth()
                .padding(top = 8.dp, start = 6.dp, end = 6.dp)
                .height(6.dp)
                .clip(CircleShape)
                .background(Color(0xFF030202))
                .border(0.5.dp, Color(0xFF3A3028), CircleShape),
        )
    }
}

/**
 * 终端下面「打印」出来的成果小票：纸从出纸口一点点推出来——先露出纸的下沿，整张慢慢往下滑，
 * 最后停稳。上沿始终藏在终端出纸口后面。
 */
@Composable
private fun CelebrationTicket(c: Celebration, todayMinutes: () -> Int, modifier: Modifier = Modifier, onDismiss: () -> Unit) {
    val today = remember(c.id) { maxOf(todayMinutes(), c.todayMin, c.minutes) }
    val bmp = rememberTicketBitmap(c, today)
    // 终端先亮起来，停一下再开始出纸
    var print by remember(c.id) { mutableStateOf(false) }
    LaunchedEffect(c.id) {
        delay(450)
        print = true
    }
    AnimatedVisibility(
        visible = bmp != null && print,
        modifier = modifier,
        enter = expandVertically(tween(1100, easing = LinearOutSlowInEasing), expandFrom = Alignment.Bottom),
    ) {
        bmp?.let {
            Image(
                it,
                contentDescription = "成果小票",
                contentScale = ContentScale.FillWidth,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss),
            )
        }
    }
}

/** 点阵屏文字：先画琥珀色的字，再把「点与点之间的缝」擦掉，剩下一颗颗发光的点 */
@Composable
private fun DotMatrixText(text: String, size: TextUnit, scanlines: Boolean = false) {
    Text(
        text,
        style = TextStyle(
            color = LedAmber,
            fontSize = size,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Black,
            letterSpacing = 2.sp,
            shadow = Shadow(LedAmber.copy(alpha = 0.55f), Offset.Zero, 18f),
        ),
        modifier = Modifier
            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
            .drawWithCache {
                val step = 3.4.dp.toPx()
                val r = 1.15.dp.toPx()
                val gaps = Path().apply {
                    if (scanlines) {
                        // 汉字笔画细，点阵会把字擦碎：改成一道道细扫描线，仍有屏幕的感觉但字是实的
                        val lineStep = 3.dp.toPx()
                        val lineH = 0.7.dp.toPx()
                        var y = lineStep - lineH
                        while (y < this@drawWithCache.size.height) {
                            addRect(androidx.compose.ui.geometry.Rect(0f, y, this@drawWithCache.size.width, y + lineH))
                            y += lineStep
                        }
                    } else {
                        fillType = PathFillType.EvenOdd
                        addRect(androidx.compose.ui.geometry.Rect(0f, 0f, this@drawWithCache.size.width, this@drawWithCache.size.height))
                        var y = step / 2
                        while (y < this@drawWithCache.size.height) {
                            var x = step / 2
                            while (x < this@drawWithCache.size.width) {
                                addOval(androidx.compose.ui.geometry.Rect(x - r, y - r, x + r, y + r))
                                x += step
                            }
                            y += step
                        }
                    }
                }
                onDrawWithContent {
                    drawContent()
                    drawPath(gaps, Color.Black, blendMode = BlendMode.DstOut)
                }
            },
    )
}
