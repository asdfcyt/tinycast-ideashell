package com.carpe.ideashell.core.parse

import kotlinx.serialization.Serializable
import java.time.LocalDateTime

enum class CaptureKind(val label: String) {
    TODO("待办"),
    DAILY("Daily Note"),
    NOTE("笔记"),
}

@Serializable
data class FolderInfo(
    val id: String,
    val name: String,
    val emoji: String? = null,
)

data class CaptureAnalysis(
    /** 去掉强制前缀后的原文（保留 #标签 / @文件夹），追加到 Daily Note 时使用 */
    val text: String,
    /** 再去掉 #标签 / @文件夹 后的正文，笔记和待办使用 */
    val body: String,
    val tags: List<String>,
    val folderName: String?,
    val todo: ParsedTodo,
    /** 用户用前缀明确指定的类型 */
    val forced: CaptureKind?,
    /** 自动判断的类型 */
    val recommended: CaptureKind,
)

/**
 * 万能输入解析，行为与桌面插件 `capture-parse.ts` 保持一致：
 * - 前缀强制类型：`待办 …` / `todo …` / `提醒我 …`、`日记 …` / `daily …`、`笔记 …` / `note …`
 * - `#标签`、`@文件夹` 会被抽出（要求前面是行首或空白，避免误伤 C#、邮箱）
 * - 自动判断：
 *   待办 = 含「今天及以后的明确时间」或「明天及以后的日期」
 *   笔记 = 带标签 / 文件夹（有意归类的才是笔记）
 *   其余 = 追加到 Daily Note，长文字、多行也是：想存成笔记就用「笔记 …」前缀、#标签 / @文件夹，或在输入框下面直接选「笔记」
 */
object CaptureParser {
    private const val SEP = "(?:\\s*[:：,，]\\s*|\\s+)"
    private val PREFIXES: List<Pair<Regex, CaptureKind>> = listOf(
        Regex("^(?:待办|todo|提醒我?)$SEP", RegexOption.IGNORE_CASE) to CaptureKind.TODO,
        Regex("^(?:日记|daily)$SEP", RegexOption.IGNORE_CASE) to CaptureKind.DAILY,
        Regex("^(?:笔记|note)$SEP", RegexOption.IGNORE_CASE) to CaptureKind.NOTE,
    )

    private val RE_TAG = Regex("(^|[\\s\\u3000])#([^\\s#@]+)")
    private val RE_FOLDER = Regex("(^|[\\s\\u3000])@([^\\s#@]+)")
    private val RE_MULTI_SPACE = Regex("[ \\t]{2,}")

    fun analyze(input: String, now: LocalDateTime = LocalDateTime.now()): CaptureAnalysis {
        var text = input.trim()
        var forced: CaptureKind? = null
        for ((re, kind) in PREFIXES) {
            if (re.containsMatchIn(text)) {
                forced = kind
                text = text.replaceFirst(re, "").trim()
                break
            }
        }

        val tags = mutableListOf<String>()
        var folderName: String? = null

        val body = text
            .replace(RE_TAG) { m ->
                tags += m.groupValues[2]
                m.groupValues[1]
            }
            .replace(RE_FOLDER) { m ->
                if (folderName == null) folderName = m.groupValues[2]
                m.groupValues[1]
            }
            .replace(RE_MULTI_SPACE, " ")
            .trim()

        val todo = TodoParser.parse(body, now)

        val today = now.toLocalDate().toString()
        val todoDate = todo.date
        val futureCue = todoDate != null && todoDate >= today && (todo.time != null || todoDate > today)

        // 「每周一」这类带具体星期 / 几号的重复说法，也当成待办
        val repeatCue = todo.repeat != null && todo.repeatAnchored

        val recommended = when {
            futureCue || repeatCue -> CaptureKind.TODO
            tags.isNotEmpty() || folderName != null -> CaptureKind.NOTE
            else -> CaptureKind.DAILY
        }

        return CaptureAnalysis(
            text = text,
            body = body,
            tags = tags.distinct(),
            folderName = folderName,
            todo = todo,
            forced = forced,
            recommended = recommended,
        )
    }

    private val RE_NORM_INFER = Regex("[\\s_\\-·]+")
    private val RE_TRAILING_S = Regex("s\$")

    private fun normInfer(s: String) = s.lowercase().replace(RE_NORM_INFER, "")
    private fun normMatch(s: String) = normInfer(s).replace(RE_TRAILING_S, "")

    /** 智能推断文件夹：正文里出现了某个已有文件夹的名字（取最长匹配，排除 Daily Note 文件夹） */
    fun inferFolder(body: String, folders: List<FolderInfo>): FolderInfo? {
        val lower = body.lowercase()
        var best: FolderInfo? = null
        var bestLen = 0
        for (f in folders) {
            val n = normInfer(f.name)
            if (n.length < 2 || n.replace(RE_TRAILING_S, "") == "dailynote") continue
            if (lower.contains(n) && n.length > bestLen) {
                best = f
                bestLen = n.length
            }
        }
        return best
    }

    /** 按名称找文件夹：完全相同 → 忽略大小写 / 空格 / 末尾 s → 包含 */
    fun matchFolder(name: String?, folders: List<FolderInfo>): FolderInfo? {
        if (name.isNullOrBlank()) return null
        val n = normMatch(name)
        return folders.firstOrNull { it.name.equals(name, ignoreCase = true) }
            ?: folders.firstOrNull { normMatch(it.name) == n }
            ?: folders.firstOrNull { normMatch(it.name).contains(n) }
    }
}
