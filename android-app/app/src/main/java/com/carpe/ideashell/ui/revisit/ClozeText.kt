package com.carpe.ideashell.ui.revisit

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
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
) {
    val scheme = MaterialTheme.colorScheme
    val hiddenBg = scheme.onSurface.copy(alpha = 0.16f)
    val annotated = remember(plain, revealed, hiddenBg) {
        buildAnnotatedString {
            var pos = 0
            plain.blanks.forEachIndexed { i, r ->
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
            .pointerInput(plain) {
                detectTapGestures { position ->
                    val l = layout ?: return@detectTapGestures
                    val index = plain.blankAt(l.getOffsetForPosition(position))
                    if (index >= 0) onToggle(index)
                }
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
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(bottom = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "填空 $shown/$total · 点空白处查看",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
            maxLines = 1,
        )
        ClozePill(if (shown >= total) "再遮住" else "全部显示", onToggleAll)
        if (auto) ClozePill("换一批", onReroll)
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
