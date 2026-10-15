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

/** 正文上方的一行：已揭开几个、全部显示 / 再遮住、自动挑词时可以换一批 */
@Composable
internal fun ClozeBar(
    total: Int,
    shown: Int,
    auto: Boolean,
    onToggleAll: () -> Unit,
    onReroll: () -> Unit,
    onEdit: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(bottom = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "填空 $shown/$total",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
            maxLines = 1,
        )
        ClozePill(if (shown >= total) "再遮住" else "全部显示", onToggleAll)
        if (auto) ClozePill("换一批", onReroll)
        ClozePill("手动挖空", onEdit)
    }
}

/** 手动挖空时正文上方的操作条：说明怎么选，以及清空 / 恢复自动 / 完成 */
@Composable
internal fun ClozeEditBar(
    count: Int,
    manualSaved: Boolean,
    onClear: () -> Unit,
    onRestoreAuto: () -> Unit,
    onDone: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            "手动挖空 · 已挖 $count 处：点一个词挖空 / 取消，长按后拖动可整段挖空，改动自动保存",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            ClozePill("清空", onClear)
            if (manualSaved) ClozePill("恢复自动", onRestoreAuto)
            Spacer(Modifier.weight(1f))
            ClozePill("完成", onDone)
        }
    }
}

@Composable
private fun ClozePill(text: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .height(30.dp)
            .clip(CircleShape)
            .background(Brand.Orange.copy(alpha = 0.18f))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.Bold,
            color = Brand.OrangeDeep,
            maxLines = 1,
        )
    }
}
