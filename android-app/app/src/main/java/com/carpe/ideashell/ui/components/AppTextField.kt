package com.carpe.ideashell.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * 全应用统一的输入行，和任务详情里的属性行（日期 / 时间 / 优先级……）同一个样式：
 * 放在 [ListGroup]（白色圆角块）里，行与行之间用 [RowDivider] 分隔；
 * 单行输入是「名称 …… 输入内容」，名称在左（固定宽度，输入内容在右边对齐成一列）；
 * 多行输入或名称很长时，名称在上、输入区在下。没有描边、没有底色，空的时候显示淡色的 [placeholder]。
 */
@Composable
fun AppTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "",
    label: String? = null,
    supportingText: String? = null,
    singleLine: Boolean = false,
    minLines: Int = 1,
    maxLines: Int = if (singleLine) 1 else 8,
    keyboardOptions: KeyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    horizontalPadding: Dp = 18.dp,
) {
    val scheme = MaterialTheme.colorScheme
    val valueStyle = MaterialTheme.typography.bodyLarge.copy(color = scheme.onSurface)
    val labelStyle = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.Medium, color = scheme.onSurface)

    val input: @Composable (Modifier) -> Unit = { fieldModifier ->
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = fieldModifier,
            textStyle = valueStyle,
            singleLine = singleLine,
            minLines = if (singleLine) 1 else minLines,
            maxLines = maxLines,
            cursorBrush = SolidColor(scheme.primary),
            keyboardOptions = keyboardOptions,
            keyboardActions = keyboardActions,
            visualTransformation = visualTransformation,
            decorationBox = { inner ->
                Box {
                    if (value.isEmpty() && placeholder.isNotEmpty()) {
                        Text(placeholder, style = valueStyle, color = scheme.outline.copy(alpha = 0.6f))
                    }
                    inner()
                }
            },
        )
    }

    val stacked = label != null && (!singleLine || label.length > 8)
    Column(modifier.fillMaxWidth().padding(horizontal = horizontalPadding)) {
        when {
            label == null -> input(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(vertical = 16.dp))
            stacked -> Column(Modifier.padding(vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(label, style = labelStyle)
                input(Modifier.fillMaxWidth())
            }

            else -> Row(
                modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(label, style = labelStyle, modifier = Modifier.width(96.dp))
                input(Modifier.weight(1f))
            }
        }
        if (supportingText != null) {
            Text(
                supportingText,
                style = MaterialTheme.typography.bodySmall,
                color = scheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = 12.dp),
            )
        }
    }
}
