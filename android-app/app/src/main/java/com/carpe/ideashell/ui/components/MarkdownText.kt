package com.carpe.ideashell.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp

/*
 * 轻量 Markdown 渲染（只读）：标题、列表（含待办勾选）、引用、代码块、分隔线，
 * 行内的粗体 / 斜体 / 删除线 / 行内代码 / 链接 / `#标签`。笔记里常见的写法够用，不引入第三方库。
 */

private sealed interface MdBlock {
    data class Heading(val level: Int, val text: String) : MdBlock
    data class Paragraph(val text: String) : MdBlock
    data class Item(val marker: String, val text: String, val indent: Int) : MdBlock
    data class Quote(val text: String) : MdBlock
    data class Code(val text: String) : MdBlock
    data object Rule : MdBlock
    data class Image(val url: String) : MdBlock
}

/** 单独占一行的图片：`![说明](地址)` */
private val RE_IMAGE_LINE = Regex("^\\s*!\\[[^\\]]*]\\(\\s*<?([^)\\s>]+)>?[^)]*\\)\\s*$")

private val RE_HEADING = Regex("^(#{1,6})\\s+(.+?)\\s*#*\\s*$")
private val RE_BULLET = Regex("^(\\s*)[-*+]\\s+(.*)$")
private val RE_NUMBERED = Regex("^(\\s*)(\\d+)[.)]\\s+(.*)$")
private val RE_TASK = Regex("^\\[([ xX])]\\s+(.*)$")
private val RE_RULE = Regex("^\\s*([-*_])(\\s*\\1){2,}\\s*$")
private val RE_QUOTE = Regex("^\\s*>\\s?(.*)$")

private fun parseBlocks(markdown: String): List<MdBlock> {
    val out = mutableListOf<MdBlock>()
    val para = mutableListOf<String>()
    var code: MutableList<String>? = null

    fun flushPara() {
        if (para.isNotEmpty()) {
            out += MdBlock.Paragraph(para.joinToString("\n"))
            para.clear()
        }
    }

    for (raw in markdown.replace("\r\n", "\n").lines()) {
        val open = code
        if (raw.trimStart().startsWith("```")) {
            if (open == null) {
                flushPara()
                code = mutableListOf()
            } else {
                out += MdBlock.Code(open.joinToString("\n"))
                code = null
            }
            continue
        }
        if (open != null) {
            open += raw
            continue
        }

        val line = raw.trimEnd()
        when {
            line.isBlank() -> flushPara()
            RE_IMAGE_LINE.matches(line) -> {
                flushPara()
                out += MdBlock.Image(RE_IMAGE_LINE.matchEntire(line)!!.groupValues[1])
            }
            RE_RULE.matches(line) -> {
                flushPara()
                out += MdBlock.Rule
            }
            RE_HEADING.matches(line) -> {
                flushPara()
                val m = RE_HEADING.matchEntire(line)!!
                out += MdBlock.Heading(m.groupValues[1].length, m.groupValues[2])
            }
            RE_QUOTE.matches(line) -> {
                flushPara()
                out += MdBlock.Quote(RE_QUOTE.matchEntire(line)!!.groupValues[1])
            }
            RE_BULLET.matches(line) -> {
                flushPara()
                val m = RE_BULLET.matchEntire(line)!!
                val task = RE_TASK.matchEntire(m.groupValues[2])
                out += if (task != null) {
                    MdBlock.Item(if (task.groupValues[1] == " ") "☐" else "☑", task.groupValues[2], m.groupValues[1].length / 2)
                } else {
                    MdBlock.Item("•", m.groupValues[2], m.groupValues[1].length / 2)
                }
            }
            RE_NUMBERED.matches(line) -> {
                flushPara()
                val m = RE_NUMBERED.matchEntire(line)!!
                out += MdBlock.Item("${m.groupValues[2]}.", m.groupValues[3], m.groupValues[1].length / 2)
            }
            else -> para += line
        }
    }
    code?.let { out += MdBlock.Code(it.joinToString("\n")) }
    flushPara()
    return out
}

/** group: 1 分隔符 2 粗体 3 删除线 4 行内代码 5 链接文字 6 链接地址 7 #标签 8 斜体；图片没有分组，直接换成「[图片]」 */
private val RE_INLINE = Regex(
    "(\\*\\*|__)(.+?)\\1" +
        "|~~(.+?)~~" +
        "|`([^`]+)`" +
        "|!\\[[^\\]]*]\\([^)]*\\)" +
        "|\\[([^\\]]+)]\\(([^)\\s]+)[^)]*\\)" +
        "|(?<![\\p{L}\\p{N}_])#([\\p{L}\\p{N}_-]+)" +
        "|(?<![*\\w])\\*([^*\\n]+?)\\*(?![*\\w])",
)

private fun inline(text: String, accent: Color, codeBg: Color): AnnotatedString = buildAnnotatedString {
    var last = 0
    for (m in RE_INLINE.findAll(text)) {
        if (m.range.first > last) append(text.substring(last, m.range.first))
        val g = m.groups
        when {
            g[2] != null -> withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(g[2]!!.value) }
            g[3] != null -> withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) { append(g[3]!!.value) }
            g[4] != null -> withStyle(SpanStyle(fontFamily = FontFamily.Monospace, background = codeBg)) { append(g[4]!!.value) }
            g[5] != null -> {
                val styles = TextLinkStyles(SpanStyle(color = accent, textDecoration = TextDecoration.Underline))
                withLink(LinkAnnotation.Url(g[6]!!.value, styles)) { append(g[5]!!.value) }
            }
            g[7] != null -> withStyle(SpanStyle(color = accent)) { append("#${g[7]!!.value}") }
            g[8] != null -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(g[8]!!.value) }
            else -> append("[图片]")
        }
        last = m.range.last + 1
    }
    if (last < text.length) append(text.substring(last))
}

@Composable
fun MarkdownText(markdown: String, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    val type = MaterialTheme.typography
    val blocks = remember(markdown) { parseBlocks(markdown) }
    val accent = scheme.primary
    val codeBg = scheme.onSurface.copy(alpha = 0.08f)

    SelectionContainer {
        Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            blocks.forEach { block ->
                when (block) {
                    is MdBlock.Heading -> Text(
                        inline(block.text, accent, codeBg),
                        style = when (block.level) {
                            1 -> type.headlineSmall
                            2 -> type.titleLarge
                            3 -> type.titleMedium
                            else -> type.titleSmall
                        }.copy(fontWeight = FontWeight.SemiBold),
                        modifier = Modifier.padding(top = 6.dp),
                    )

                    is MdBlock.Paragraph -> Text(inline(block.text, accent, codeBg), style = type.bodyLarge.withReading())

                    is MdBlock.Item -> Row(Modifier.padding(start = (block.indent * 16).dp)) {
                        Text(
                            block.marker,
                            style = type.bodyLarge,
                            color = if (block.marker == "☑") scheme.primary else scheme.onSurfaceVariant,
                            modifier = Modifier.width(26.dp),
                        )
                        Text(
                            inline(block.text, accent, codeBg),
                            style = type.bodyLarge.withReading(),
                            modifier = Modifier.weight(1f),
                        )
                    }

                    is MdBlock.Quote -> Row(Modifier.height(IntrinsicSize.Min)) {
                        Box(
                            Modifier
                                .width(3.dp)
                                .fillMaxHeight()
                                .clip(RoundedCornerShape(2.dp))
                                .background(accent.copy(alpha = 0.55f)),
                        )
                        Text(
                            inline(block.text, accent, codeBg),
                            style = type.bodyMedium.withReading(),
                            color = scheme.onSurfaceVariant,
                            modifier = Modifier.padding(start = 10.dp),
                        )
                    }

                    is MdBlock.Code -> Box(
                        Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(codeBg)
                            .horizontalScroll(rememberScrollState())
                            .padding(12.dp),
                    ) {
                        Text(block.text, style = type.bodySmall.copy(fontFamily = FontFamily.Monospace))
                    }

                    is MdBlock.Image -> NoteImage(block.url)

                    MdBlock.Rule -> Box(
                        Modifier
                            .fillMaxWidth()
                            .height(1.dp)
                            .background(scheme.onSurface.copy(alpha = 0.12f)),
                    )
                }
            }
        }
    }
}

/** 阅读用的行高：中文笔记行距稍松一点更舒服 */
private fun TextStyle.withReading(): TextStyle = copy(lineHeight = fontSize * 1.65f)
