package com.carpe.ideashell.ui.review

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.core.parse.TimeRanges
import com.carpe.ideashell.data.ideashell.NoteInfo
import com.carpe.ideashell.ui.components.EmptyNote

/**
 * 笔记行：标题 + 时间，下面一行摘要，再下面是标签。没有自己的卡片，成组放进 [com.carpe.ideashell.ui.components.ListGroup]。
 * [showDate] 为 false 时只显示 HH:mm（时间线里已经按天分组）。
 */
@Composable
fun NoteRow(
    note: NoteInfo,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    showDate: Boolean = true,
    /** 用来覆盖摘要的文字（搜索 / 档案里显示命中片段） */
    snippet: String? = null,
) {
    val scheme = MaterialTheme.colorScheme
    val whenText = listOfNotNull(
        if (showDate) note.localDate?.let { "${it.monthValue}月${it.dayOfMonth}日" } else null,
        note.localClock,
    ).joinToString(" ")
    val body = snippet ?: note.summary

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Text(
                note.title,
                style = MaterialTheme.typography.bodyLarge,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            if (whenText.isNotEmpty()) {
                Text(
                    whenText,
                    style = MaterialTheme.typography.labelMedium,
                    color = scheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 10.dp, top = 3.dp),
                )
            }
        }
        if (!body.isNullOrBlank()) {
            Text(
                body,
                style = MaterialTheme.typography.bodyMedium,
                color = scheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (note.tags.isNotEmpty()) {
            Text(
                note.tags.take(4).joinToString("  ") { "#$it" },
                style = MaterialTheme.typography.labelMedium,
                color = scheme.primary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
fun ConnectIdeashellCard(onOpenConnection: () -> Unit) {
    EmptyNote(
        title = "先连接闪念贝壳",
        text = "笔记来自闪念贝壳。填入 API Key 后，这里会出现时间线、Daily Note、搜索和往日回顾。",
        action = { Button(onClick = onOpenConnection) { Text("去连接") } },
    )
}

/** 带「重试」的失败 / 空状态（不套卡片） */
@Composable
fun InfoCard(title: String, text: String, action: String? = null, onAction: () -> Unit = {}) {
    EmptyNote(
        title = title,
        text = text,
        action = if (action != null) ({ OutlinedButton(onClick = onAction) { Text(action) } }) else null,
    )
}

@Composable
fun LoadingBlock() {
    Box(Modifier.fillMaxWidth().padding(vertical = 48.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
    }
}

/** 搜索框：圆角胶囊，回车搜索，带清空 */
@Composable
fun GlassSearchField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    onSearch: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // iOS 搜索框：浅灰底圆角矩形，没有描边
    Box(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerHigh),
    ) {
        TextField(
            value = value,
            onValueChange = onValueChange,
            modifier = Modifier.fillMaxWidth(),
            placeholder = { Text(placeholder, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            trailingIcon = {
                if (value.isNotEmpty()) {
                    IconButton(onClick = { onValueChange("") }) { Icon(Icons.Filled.Clear, contentDescription = "清空") }
                }
            },
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { onSearch() }),
            colors = TextFieldDefaults.colors(
                focusedContainerColor = Color.Transparent,
                unfocusedContainerColor = Color.Transparent,
                disabledContainerColor = Color.Transparent,
                focusedIndicatorColor = Color.Transparent,
                unfocusedIndicatorColor = Color.Transparent,
            ),
        )
    }
}

/** 「10月9日 周五」 */
fun dayTitle(date: java.time.LocalDate): String =
    "${date.monthValue}月${date.dayOfMonth}日 ${TimeRanges.weekdayName(date)}"
