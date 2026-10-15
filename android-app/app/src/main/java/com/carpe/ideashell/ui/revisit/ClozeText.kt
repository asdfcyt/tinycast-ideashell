package com.carpe.ideashell.ui.revisit

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.core.revisit.Cloze
import com.carpe.ideashell.ui.theme.Brand

/**
 * 填空卡片的正文：没揭开的空是一块和原词一样宽的灰底（文字透明），点一下揭开 / 再点遮回去；
 * 揭开的词用主题橙加粗显示，一眼能看出刚才挖的是哪些。
 */
@Composable
internal fun ClozeText(
    plain: Cloze.Plain,
    revealed: Set<Int>,
    onToggle: (Int) -> Unit,
    modifier: Modifier = Modifier,
    /** 手动挖空模式：点一个词挖空 / 取消，长按后拖选一段整段挖空；空都以橙色标出 */
    editing: Boolean = false,
    onPickWord: (Int) -> Unit = {},
    onPickRange: (Int, Int) -> Unit = { _, _ -> },
) {
    val scheme = MaterialTheme.colorScheme
    val hiddenBg = scheme.onSurface.copy(alpha = 0.16f)
    var preview by remember { mutableStateOf<IntRange?>(null) }
    val annotated = remember(plain, revealed, hiddenBg, preview) {
        buildAnnotatedString {
            var pos = 0
            plain.blanks.forEachIndexed { i, r ->
                if (r.first < pos || r.last >= plain.text.length) return@forEachIndexed
                append(plain.text.substring(pos, r.first))
                val word = plain.text.substring(r.first, r.last + 1)
                if (i in revealed) {
                    withStyle(SpanStyle(color = Brand.OrangeDeep, fontWeight = FontWeight.Bold, background = Brand.Orange.copy(alpha = 0.18f))) {
                        append(word)
                    }
                } else {
                    withStyle(SpanStyle(color = Color.Transparent, background = hiddenBg)) { append(word) }
                }
                pos = r.last + 1
            }
            append(plain.text.substring(pos))
            preview?.let { r ->
                if (r.first >= 0 && r.last < plain.text.length) {
                    addStyle(SpanStyle(background = Brand.Orange.copy(alpha = 0.45f)), r.first, r.last + 1)
                }
            }
        }
    }
    var layout by remember { mutableStateOf<TextLayoutResult?>(null) }
    Text(
        text = annotated,
        style = MaterialTheme.typography.bodyLarge,
        color = scheme.onSurface,
        onTextLayout = { layout = it },
        modifier = modifier
            .fillMaxWidth()
            .pointerInput(plain, editing) {
                detectTapGestures { position ->
                    val l = layout ?: return@detectTapGestures
                    val offset = l.getOffsetForPosition(position)
                    if (editing) onPickWord(offset) else {
                        val index = plain.blankAt(offset)
                        if (index >= 0) onToggle(index)
                    }
                }
            }
            .pointerInput(plain, editing) {
                if (!editing) return@pointerInput
                var anchor = 0
                var current = 0
                fun span() = minOf(anchor, current)..maxOf(anchor, current)
                detectDragGesturesAfterLongPress(
                    onDragStart = { position ->
                        val l = layout ?: return@detectDragGesturesAfterLongPress
                        anchor = l.getOffsetForPosition(position)
                        current = anchor
                        preview = span()
                    },
                    onDrag = { change, _ ->
                        val l = layout ?: return@detectDragGesturesAfterLongPress
                        current = l.getOffsetForPosition(change.position)
                        preview = span()
                        change.consume()
                    },
                    onDragEnd = {
                        preview = null
                        onPickRange(anchor, current)
                    },
                    onDragCancel = { preview = null },
                )
            },
    )
}

/** 正文上方的一条操作栏：左边「填空 已揭开/总数」，右边是文字操作（全部显示 / 换一批 / 手动挖空），之间用细竖线隔开 */
@Composable
internal fun ClozeBar(
    total: Int,
    shown: Int,
    auto: Boolean,
    onToggleAll: () -> Unit,
    onReroll: () -> Unit,
    onEdit: () -> Unit,
) {
    ClozeStrip {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("填空", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("$shown/$total", fontSize = 13.sp, fontWeight = FontWeight.ExtraBold, color = Brand.OrangeDeep)
        }
        Spacer(Modifier.weight(1f))
        ClozeAction(if (shown >= total) "再遮住" else "全部显示", onToggleAll)
        if (auto) {
            ClozeDivider()
            ClozeAction("换一批", onReroll)
        }
        ClozeDivider()
        ClozeAction("手动挖空", onEdit)
    }
}

/** 手动挖空时正文上方的操作栏：说明怎么选，以及清空 / 恢复自动 / 完成 */
@Composable
internal fun ClozeEditBar(
    count: Int,
    manualSaved: Boolean,
    onClear: () -> Unit,
    onRestoreAuto: () -> Unit,
    onDone: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(bottom = 10.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("手动挖空", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("已挖 $count 处", fontSize = 13.sp, fontWeight = FontWeight.ExtraBold, color = Brand.OrangeDeep)
        }
        Text(
            "点一个词挖空 / 取消；长按后拖动可整段挖空；改动自动保存",
            fontSize = 12.sp,
            lineHeight = 17.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            ClozeAction("清空", onClear, startPadding = 0.dp)
            if (manualSaved) {
                ClozeDivider()
                ClozeAction("恢复自动", onRestoreAuto)
            }
            Spacer(Modifier.weight(1f))
            ClozeAction("完成", onDone, bold = true, endPadding = 0.dp)
        }
    }
}

/** 操作栏的底：一条淡淡的圆角带，不抢正文的视线 */
@Composable
private fun ClozeStrip(content: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 10.dp)
            .height(42.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f))
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

@Composable
private fun ClozeAction(
    text: String,
    onClick: () -> Unit,
    bold: Boolean = false,
    startPadding: androidx.compose.ui.unit.Dp = 10.dp,
    endPadding: androidx.compose.ui.unit.Dp = 10.dp,
) {
    Box(
        modifier = Modifier
            .height(42.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(start = startPadding, end = endPadding),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text,
            fontSize = 13.sp,
            fontWeight = if (bold) FontWeight.ExtraBold else FontWeight.Bold,
            color = Brand.OrangeDeep,
            maxLines = 1,
            softWrap = false,
        )
    }
}

@Composable
private fun ClozeDivider() {
    Box(
        Modifier
            .width(1.dp)
            .height(14.dp)
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.14f)),
    )
}
