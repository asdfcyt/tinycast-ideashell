package com.carpe.ideashell.system

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.graphics.ColorUtils
import com.carpe.ideashell.data.voice.VoiceSearch

/**
 * 助手回答 / 搜索结果的卡片（贴右边缘的侧边卡）：
 * 顶部一行「助手」小标签 + 复制 / 关闭；正文第一行是结论（大一号加粗），后面的条目带圆点或序号，
 * 控制家里设备的结果是「✓ 名称 + 结果」逐行；出处 / 笔记 / 待办是下面一排带标签的可点行。内容多了可以滚动。
 */
private val BULLET = Regex("""^\s*(?:[·•\-*]\s+|(\d{1,2})[.、)）]\s*)(.+)$""")
private val DEVICE_LINE = Regex("""^(.{1,28}?)：(已.+)$""")

/** 内容太高时限制高度、可滚动 */
internal class MaxHeightScroll(context: Context, private val maxPx: Int) : ScrollView(context) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        super.onMeasure(widthMeasureSpec, MeasureSpec.makeMeasureSpec(maxPx, MeasureSpec.AT_MOST))
    }
}

private fun VoiceCapsuleService.subColor(): Int = ColorUtils.setAlphaComponent(pal.text, 150)

private fun VoiceCapsuleService.text(value: CharSequence, sp: Float, bold: Boolean = false, color: Int = pal.text): TextView =
    TextView(this).apply {
        text = value
        setTextColor(color)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        setLineSpacing(dp(3).toFloat(), 1f)
        if (bold) typeface = Typeface.DEFAULT_BOLD
    }

private fun VoiceCapsuleService.chip(value: String, color: Int = pal.accentSoft): TextView = TextView(this).apply {
    text = value
    setTextColor(color)
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
    typeface = Typeface.DEFAULT_BOLD
    setPadding(dp(8), dp(2), dp(8), dp(2))
    background = GradientDrawable().apply {
        setColor(pal.chipBg)
        cornerRadius = dp(9).toFloat()
    }
}

private fun VoiceCapsuleService.dot(color: Int): View = View(this).apply {
    background = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(color)
    }
}

/** 正文：把回答拆成「结论 + 条目」 */
private fun VoiceCapsuleService.buildBody(raw: String): LinearLayout {
    val body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    val lines = raw.lines().map { it.trim() }.filter { it.isNotEmpty() }
    if (lines.isEmpty()) return body
    val maxText = dp(262)
    fun add(v: View, top: Int = 6) = body.addView(v, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
        if (body.childCount > 0) topMargin = dp(top)
    })

    // 控制设备的结果：每行「名称：已…」→ ✓ 名称 + 结果
    if (lines.all { DEVICE_LINE.matches(it) } && lines.size <= 8) {
        for (l in lines) {
            val m = DEVICE_LINE.find(l)!!
            val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.TOP }
            row.addView(text("✓", 14f, bold = true, color = pal.green).apply { setPadding(0, 0, dp(8), 0) })
            val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
            col.addView(text(m.groupValues[1], 15f, bold = true).apply { maxWidth = maxText - dp(24) })
            col.addView(text(m.groupValues[2], 13f, color = subColor()).apply { maxWidth = maxText - dp(24) })
            row.addView(col)
            add(row, 8)
        }
        return body
    }

    var rest = lines
    val first = lines.first()
    val isHead = BULLET.matches(first).not() && (lines.size > 1 || first.length <= 60)
    if (isHead) {
        add(text(first, if (lines.size > 1) 16f else 15.5f, bold = lines.size > 1).apply { maxWidth = maxText })
        rest = lines.drop(1)
    }
    for (l in rest) {
        val m = BULLET.find(l)
        if (m != null) {
            val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.TOP }
            val number = m.groupValues[1]
            if (number.isNotEmpty()) {
                row.addView(text(number, 13f, bold = true, color = pal.accentSoft).apply {
                    gravity = Gravity.CENTER_HORIZONTAL
                    minWidth = dp(16)
                    setPadding(0, 0, dp(6), 0)
                })
            } else {
                // 圆点和第一行文字的中线对齐
                row.addView(dot(pal.accentSoft), LinearLayout.LayoutParams(dp(5), dp(5)).apply { topMargin = dp(9); marginEnd = dp(10); marginStart = dp(2) })
            }
            row.addView(text(m.groupValues[2], 14f).apply { maxWidth = maxText - dp(22) })
            add(row, 5)
        } else {
            add(text(l, 14f, color = ColorUtils.setAlphaComponent(pal.text, 225)).apply { maxWidth = maxText }, if (isHead && rest.first() === l) 8 else 5)
        }
    }
    return body
}

/** 一行可点的条目：左边小标签，中间标题，右边副文字 */
private fun VoiceCapsuleService.hitRow(tag: String, title: String, sub: String, onClick: () -> Unit): LinearLayout =
    LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(0, dp(8), dp(4), dp(8))
        pressable()
        setOnClickListener { onClick() }
        addView(chip(tag).apply { minWidth = dp(34); gravity = Gravity.CENTER }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginEnd = dp(10) })
        addView(text(title, 14f).apply {
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        if (sub.isNotBlank()) addView(text(sub, 12f, color = subColor()).apply {
            maxLines = 1
            maxWidth = dp(84)
            ellipsize = TextUtils.TruncateAt.END
            setPadding(dp(8), 0, 0, 0)
        })
    }

internal fun VoiceCapsuleService.showAnswerCard(res: VoiceSearch.Result) {
    stopTick()
    dotAnimator?.cancel()
    cancelCountdown()
    exitEditMode()
    shown = CapsuleShown.MESSAGE
    val col = ensureColumn()
    col.removeAllViews()
    surface = null
    handler.removeCallbacksAndMessages(null)

    val card = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background = capsuleBackground(24)
        setPadding(dp(16), dp(10), dp(8), dp(10))
        elevation = dp(10).toFloat()
        minimumWidth = dp(232)
    }

    // 顶部：标签 + 复制 / 关闭
    val head = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
    head.addView(chip(if (res.isAnswer) "助手" else "搜索结果"))
    head.addView(View(this), LinearLayout.LayoutParams(0, 1, 1f))
    val copy = text("复制", 12f, color = subColor()).apply {
        gravity = Gravity.CENTER
        setPadding(dp(10), dp(6), dp(8), dp(6))
        pressable()
    }
    copy.setOnClickListener {
        val plain = (res.text + res.hits.filter { it.url != null }.joinToString("") { "\n" + it.title + " " + it.url }).trim()
        (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("助手回答", plain))
        copy.text = "已复制"
        copy.setTextColor(pal.green)
    }
    head.addView(copy)
    head.addView(text("✕", 15f, color = subColor()).apply {
        gravity = Gravity.CENTER
        setPadding(dp(8), dp(6), dp(10), dp(6))
        contentDescription = "关闭"
        pressable()
        setOnClickListener { dismissWithSlide() }
    })
    card.addView(head, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

    // 正文 + 条目放进可滚动区域（长回答最多占屏幕一半多一点）
    val inner = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(0, dp(2), dp(10), 0) }
    inner.addView(buildBody(res.text))

    fun open(extra: String, value: String) {
        startActivity(
            Intent(this, com.carpe.ideashell.ui.MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra(extra, value),
        )
        dismissWithSlide()
    }

    val sources = res.hits.filter { it.url != null }
    val records = res.hits.filter { it.url == null }
    fun section(title: String?) {
        inner.addView(View(this).apply { setBackgroundColor(pal.stroke) }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(1)).apply { topMargin = dp(10) })
        if (title != null) inner.addView(text(title, 11f, color = subColor()).apply { setPadding(0, dp(8), 0, 0) })
    }
    if (sources.isNotEmpty()) {
        section("出处")
        sources.take(4).forEach { hit ->
            inner.addView(hitRow("来源", hit.title, hit.sub) {
                runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(hit.url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                dismissWithSlide()
            })
        }
    }
    if (records.isNotEmpty()) {
        section(if (res.isAnswer) "相关记录" else null)
        records.take(VoiceSearch.MAX_LINES).forEach { hit ->
            inner.addView(hitRow(if (hit.isNote) "笔记" else "待办", hit.title, hit.sub) {
                if (hit.isNote) open(com.carpe.ideashell.ui.MainActivity.EXTRA_OPEN_NOTE, hit.id)
                else open(com.carpe.ideashell.ui.MainActivity.EXTRA_OPEN_TASK, hit.id)
            })
        }
        if (res.keyword.isNotBlank() && records.size > VoiceSearch.MAX_LINES) {
            inner.addView(text("查看全部 ${records.size} 条 ›", 13f, bold = true, color = pal.accentSoft).apply {
                setPadding(0, dp(8), dp(4), dp(4))
                pressable()
                setOnClickListener { open(com.carpe.ideashell.ui.MainActivity.EXTRA_OPEN_SEARCH, res.keyword) }
            })
        }
    }
    val maxH = (resources.displayMetrics.heightPixels * 0.55f).toInt()
    card.addView(MaxHeightScroll(this, maxH).apply {
        isVerticalScrollBarEnabled = false
        overScrollMode = View.OVER_SCROLL_NEVER
        addView(inner)
    }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))

    addSmall(card)
    recenter()
    // 回答越长留得越久；有可点的条目至少一分钟
    val stay = if (res.hits.isNotEmpty()) 60_000L else (12_000L + res.text.length * 120L).coerceIn(15_000L, 60_000L)
    handler.postDelayed({ dismissWithSlide() }, stay)
}
