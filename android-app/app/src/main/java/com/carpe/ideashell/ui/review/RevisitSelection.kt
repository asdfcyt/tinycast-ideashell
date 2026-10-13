package com.carpe.ideashell.ui.review

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalTextToolbar
import androidx.compose.ui.platform.TextToolbar
import androidx.compose.ui.platform.TextToolbarStatus
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.R

/**
 * 旁听「正文里有没有选中文字」：把它作为 [LocalTextToolbar] 提供给正文，
 * 系统自己的选择菜单（复制 / 全选）照常显示，我们只是记下「复制」的回调——
 * 有选中的文字时，页面底部出现一枚「加入重温」，点它就复制选中的这一段并加入重温。
 */
@Stable
class SelectionProbe(private val base: TextToolbar) {
    /** 有选中文字时不为空：调用它会把选中的文字复制到剪贴板 */
    var copy by mutableStateOf<(() -> Unit)?>(null)

    val toolbar: TextToolbar = object : TextToolbar {
        override val status: TextToolbarStatus get() = base.status

        override fun hide() {
            copy = null
            base.hide()
        }

        override fun showMenu(
            rect: Rect,
            onCopyRequested: (() -> Unit)?,
            onPasteRequested: (() -> Unit)?,
            onCutRequested: (() -> Unit)?,
            onSelectAllRequested: (() -> Unit)?,
        ) {
            copy = onCopyRequested
            base.showMenu(rect, onCopyRequested, onPasteRequested, onCutRequested, onSelectAllRequested)
        }
    }
}

@Composable
fun rememberSelectionProbe(): SelectionProbe {
    val base = LocalTextToolbar.current
    return remember(base) { SelectionProbe(base) }
}

/** 底部的「加入重温」胶囊：有选中文字时才出现 */
@Composable
fun BoxScope.RevisitSelectionPill(
    visible: Boolean,
    bottomPadding: Dp,
    onClick: () -> Unit,
) {
    AnimatedVisibility(
        visible = visible,
        modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = bottomPadding),
        enter = slideInVertically { it / 2 } + fadeIn(),
        exit = slideOutVertically { it / 2 } + fadeOut(),
    ) {
        val scheme = MaterialTheme.colorScheme
        Row(
            modifier = Modifier
                .height(48.dp)
                .clip(CircleShape)
                .background(scheme.inverseSurface)
                .clickable(role = Role.Button, onClick = onClick)
                .padding(horizontal = 20.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                painterResource(R.drawable.ic_revisit),
                contentDescription = null,
                tint = scheme.inverseOnSurface,
                modifier = Modifier.size(18.dp),
            )
            Text(
                "加入重温",
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.ExtraBold,
                color = scheme.inverseOnSurface,
                modifier = Modifier.padding(start = 8.dp),
            )
        }
    }
}
