package com.carpe.ideashell.core.capture

import com.carpe.ideashell.core.parse.CaptureParser

/** 摘录 / 收藏的原料：来自分享菜单或「选中文字」菜单 */
data class ClipInput(
    /** 选中的文字；纯收藏链接时为空 */
    val quote: String,
    val pageTitle: String?,
    val url: String?,
    /** 来源应用名（拿得到才有） */
    val appName: String?,
) {
    /** 有文字是「摘录」，只有链接是「收藏」 */
    val kindTag: String get() = if (quote.isBlank()) "收藏" else "摘录"
}

/** 摘录笔记的保存计划（格式与桌面 Clip Selection 保持一致） */
data class ClipPlan(
    val title: String,
    val body: String,
    val tags: List<String>,
    val folderName: String?,
    val kindTag: String,
)

object ClipBuilder {
    private val RE_URL = Regex("https?://[^\\s\\u3000]+", RegexOption.IGNORE_CASE)
    private val URL_TAIL = charArrayOf('.', ',', '，', '。', ')', '）', '"', '\'', '!', '?', '、', ';', '；')

    /** 分享菜单：文字里可能带链接；浏览器通常把页面标题放在 subject 里 */
    fun fromShare(text: String?, subject: String?, appName: String?): ClipInput? {
        val t = text.orEmpty().trim()
        val subj = subject.orEmpty().trim()
        if (t.isEmpty() && subj.isEmpty()) return null

        val match = RE_URL.find(t)
        if (match != null) {
            val url = match.value.trimEnd(*URL_TAIL)
            var rest = t.replaceFirst(match.value, " ").replace(Regex("\\s+"), " ").trim()
            var title = subj
            if (title.isEmpty() && rest.isNotEmpty() && rest.length <= 100 && !t.contains('\n')) {
                title = rest
                rest = ""
            } else if (rest == subj) {
                rest = ""
            }
            return ClipInput(quote = rest, pageTitle = title.ifEmpty { null }, url = url, appName = appName)
        }
        return ClipInput(
            quote = t.ifEmpty { subj },
            pageTitle = subj.takeIf { it.isNotEmpty() && it != t },
            url = null,
            appName = appName,
        )
    }

    /** 「选中文字」菜单：只有文字和来源应用 */
    fun fromSelection(text: String, appName: String?): ClipInput? {
        val t = text.trim()
        if (t.isEmpty()) return null
        return ClipInput(quote = t, pageTitle = null, url = null, appName = appName)
    }

    fun plan(clip: ClipInput, annotation: String): ClipPlan {
        val extra = CaptureParser.analyze(annotation)
        val app = clip.appName?.takeIf { it.isNotBlank() }

        val source = when {
            clip.url != null -> "来源：[${clip.pageTitle ?: clip.url}](${clip.url})${if (app != null) " · $app" else ""}"
            app != null -> "来源：$app"
            else -> ""
        }
        val quoted = if (clip.quote.isBlank()) "" else quote(clip.quote)
        val body = listOf(quoted, extra.body, source).filter { it.isNotBlank() }.joinToString("\n\n")

        val title = truncate(
            clip.pageTitle?.takeIf { it.isNotBlank() }
                ?: firstLine(clip.quote).ifEmpty { "${clip.kindTag} ${app.orEmpty()}".trim() },
            30,
        )
        return ClipPlan(
            title = title,
            body = body,
            tags = (listOf(clip.kindTag) + extra.tags).distinct(),
            folderName = extra.folderName,
            kindTag = clip.kindTag,
        )
    }

    private fun quote(s: String): String =
        s.trim().lines().joinToString("\n") { if (it.isBlank()) ">" else "> $it" }
}
