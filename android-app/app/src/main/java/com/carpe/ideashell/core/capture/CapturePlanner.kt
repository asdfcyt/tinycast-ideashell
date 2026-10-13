package com.carpe.ideashell.core.capture

import com.carpe.ideashell.core.parse.CaptureAnalysis
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.core.parse.CaptureParser
import com.carpe.ideashell.core.parse.FolderInfo
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.format.TextStyle
import java.util.Locale

/**
 * 一次输入的保存计划。输入框里的实时预览和真正保存用的是同一份计划，保证「所见即所存」。
 */
data class CapturePlan(
    val kind: CaptureKind,
    /** 自动判断出来的类型（用于界面显示「自动 · 待办」） */
    val autoKind: CaptureKind,
    /** 类型是否由前缀或手动选择决定 */
    val isForced: Boolean,
    /** 列表 / 提示里展示的标题 */
    val title: String,
    /** 笔记正文 / Daily Note 条目正文 / 待办标题 */
    val body: String,
    val todoDate: String?,
    val todoTime: String?,
    val important: Boolean,
    val tags: List<String>,
    /** 目标文件夹名（用户写的 @文件夹，或根据正文推断出的已有文件夹） */
    val folderName: String?,
    val folderInferred: Boolean,
    /** 待办优先级（与滴答一致）：0 无 / 1 低 / 3 中 / 5 高；写在文字里的 `!高` `!中` `!低`（`!重要` 等同于高） */
    val priority: Int = 0,
)

object CapturePlanner {
    private val RE_HIGH = Regex("[!！](?:重要|高(?![\\p{L}\\p{N}]))")
    private val RE_MID = Regex("[!！]中(?![\\p{L}\\p{N}])")
    private val RE_LOW = Regex("[!！]低(?![\\p{L}\\p{N}])")
    private val RE_MARKS = Regex("\\s*[!！](?:重要|紧急|[高中低](?![\\p{L}\\p{N}]))")

    /** 文字里写的优先级标记；没有为 0，写了几个取最高的 */
    fun priorityOf(content: String): Int = when {
        RE_HIGH.containsMatchIn(content) -> 5
        RE_MID.containsMatchIn(content) -> 3
        RE_LOW.containsMatchIn(content) -> 1
        else -> 0
    }

    /** 去掉文字里所有的优先级标记（`!重要` `!紧急` `!高` `!中` `!低`） */
    fun stripPriority(content: String): String = content.replace(RE_MARKS, "").trimEnd()

    fun priorityName(p: Int): String = when {
        p >= 5 -> "高"
        p >= 3 -> "中"
        p >= 1 -> "低"
        else -> "无"
    }

    private val CLIPBOARD_WORDS = Regex("^(?:剪贴板|剪切板|clip|clipboard|paste)$", RegexOption.IGNORE_CASE)

    /** 正文是不是「剪贴板」之类的关键词（需要调用方换成剪贴板里的文字） */
    fun wantsClipboard(input: String): Boolean = CLIPBOARD_WORDS.matches(CaptureParser.analyze(input).body)

    private val CLIPBOARD_TAIL = Regex("(?:剪贴板|剪切板|clip|clipboard|paste)\\s*\$", RegexOption.IGNORE_CASE)

    /** 把「剪贴板」关键词换成剪贴板里的文字（写了前缀时只替换末尾的关键词，如「日记 剪贴板」） */
    data class ClipboardResolution(val input: String, val fromClipboard: Boolean)

    /**
     * 输入不是「剪贴板」关键词时原样返回；是关键词时用 [readClipboard] 取文字。
     * 剪贴板为空返回 null（调用方提示「剪贴板里没有文字」）。
     */
    fun resolveClipboard(input: String, readClipboard: () -> String?): ClipboardResolution? {
        if (!wantsClipboard(input)) return ClipboardResolution(input, false)
        val clip = readClipboard()?.trim().orEmpty()
        if (clip.isEmpty()) return null
        val resolved = if (CaptureParser.analyze(input).forced != null) input.replace(CLIPBOARD_TAIL) { clip } else clip
        return ClipboardResolution(resolved, true)
    }

    /** 返回 null 表示没有可保存的内容 */
    fun plan(
        input: String,
        override: CaptureKind?,
        folders: List<FolderInfo>,
        now: LocalDateTime = LocalDateTime.now(),
    ): CapturePlan? {
        val a: CaptureAnalysis = CaptureParser.analyze(input, now)
        if (a.body.isBlank()) return null

        val kind = a.forced ?: override ?: a.recommended
        val isForced = a.forced != null || override != null

        return when (kind) {
            CaptureKind.TODO -> {
                val content = a.todo.content
                val priority = priorityOf(content)
                val important = priority >= 5
                val title = content.replace(RE_MARKS, "").trim().ifEmpty { content }
                CapturePlan(
                    kind = kind, autoKind = a.recommended, isForced = isForced,
                    title = title, body = title,
                    todoDate = a.todo.date, todoTime = a.todo.time, important = important,
                    tags = a.tags, folderName = null, folderInferred = false,
                    priority = priority,
                )
            }

            CaptureKind.DAILY -> CapturePlan(
                kind = kind, autoKind = a.recommended, isForced = isForced,
                title = truncate(firstLine(a.body), 30), body = a.body,
                todoDate = null, todoTime = null, important = false,
                tags = a.tags, folderName = null, folderInferred = false,
            )

            CaptureKind.NOTE -> {
                val explicit = a.folderName
                val inferred = if (explicit == null) CaptureParser.inferFolder(a.body, folders)?.name else null
                CapturePlan(
                    kind = kind, autoKind = a.recommended, isForced = isForced,
                    title = truncate(firstLine(a.body), 30), body = a.body,
                    todoDate = null, todoTime = null, important = false,
                    tags = a.tags, folderName = explicit ?: inferred, folderInferred = inferred != null,
                )
            }
        }
    }

    /** 待办的「何时」展示：今天 15:00 / 明天 / 10月12日 周日 15:00 / 无日期 */
    fun describeWhen(date: String?, time: String?, today: LocalDate = LocalDate.now()): String {
        if (date == null) return "无日期"
        val d = try {
            LocalDate.parse(date)
        } catch (_: Exception) {
            return listOfNotNull(date, time).joinToString(" ")
        }
        val days = d.toEpochDay() - today.toEpochDay()
        val day = when (days) {
            0L -> "今天"
            1L -> "明天"
            2L -> "后天"
            -1L -> "昨天"
            else -> {
                val weekday = d.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.CHINA)
                if (d.year == today.year) "${d.monthValue}月${d.dayOfMonth}日 $weekday" else "${d.year}年${d.monthValue}月${d.dayOfMonth}日"
            }
        }
        return if (time != null) "$day $time" else day
    }
}

fun firstLine(s: String): String = s.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() } ?: ""

fun truncate(text: String, maxLen: Int): String =
    if (text.length <= maxLen) text else text.take(maxLen - 1) + "…"
