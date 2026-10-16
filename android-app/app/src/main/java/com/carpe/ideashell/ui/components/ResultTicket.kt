package com.carpe.ideashell.ui.components

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.os.Build
import android.provider.MediaStore
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import com.carpe.ideashell.data.focus.Celebration
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import kotlin.math.floor
import kotlin.math.max

/**
 * 成果小票：把一次番茄 / 一个任务的成果画成一张可以保存的图片（深色底上一张奶白小票）。
 * 直接用 Canvas 画（不依赖界面），尺寸 390 逻辑单位宽、3 倍像素。
 */
object ResultTicket {
    private const val S = 3f
    private const val W = 390f

    private val paper1 = Color.parseColor("#FCF9F1")
    private val paper2 = Color.parseColor("#F6F1E4")
    private val ink = Color.parseColor("#1F1610")
    private val mute = Color.parseColor("#6A5E53")
    private val line = Color.parseColor("#DDD2C0")
    private val deep = Color.parseColor("#B2441B")
    private val green = Color.parseColor("#2F8F5B")
    private val greenInk = Color.parseColor("#1F6A40")
    private val greenSoft = Color.parseColor("#D9EFE0")
    private val boxBg = Color.parseColor("#EFE8D9")
    private val recBg = Color.parseColor("#F2ECDF")

    private class Cell(val caption: String, val value: String, val color: Int)

    /** [todayMin]：今天累计专注分钟数（取不到传 0） */
    fun render(
        c: Celebration,
        todayMin: Int,
        now: LocalDateTime = LocalDateTime.now(),
        /** true：深色渐变底（保存到相册用）；false：透明底，只有小票和阴影（界面里直接显示用） */
        background: Boolean = true,
    ): Bitmap {
        val isPomo = c.kind == Celebration.Kind.POMODORO
        val brand = if (isPomo) "拾忆 · 专注小票" else "拾忆 · 完成小票"
        val status = if (c.completed) "已完成" else "已记录"
        val what = when {
            !isPomo -> "已完成任务"
            c.completed -> "已完成番茄"
            else -> "专注已记录"
        }
        val serial = (c.id.toString(16).takeLast(6)).uppercase().padStart(6, '0')
        val stamp = now.format(DateTimeFormatter.ofPattern("MM-dd HH:mm"))
        val stampSmall = "${now.monthValue}·${now.dayOfMonth}"

        // 标题区右下的一行小字（数字加粗感靠分隔留白）
        val today = max(todayMin, c.minutes)
        val metaText = if (isPomo) {
            listOfNotNull(
                if (c.round > 0) "第 ${c.round} 个番茄" else null,
                "记录 ${c.records.size} 条",
                if (today > 0) "今日累计 ${fmtMin(today)}" else null,
            ).joinToString("   ")
        } else {
            listOfNotNull(
                if (c.weekMinutes > 0) "近 7 天专注 ${fmtMin(c.weekMinutes)}" else null,
                if (c.records.isNotEmpty()) "记录 ${c.records.size} 条" else null,
            ).joinToString("   ")
        }
        val bigNum = if (isPomo) (if (c.minutes > 0) c.minutes.toString() else "—") else null
        val numColor = Color.parseColor("#B8650A")
        val numPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = numColor; textSize = 54f; typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val capPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { color = mute; textSize = 12f }
        val leftW = if (bigNum != null) max(numPaint.measureText(bigNum), capPaint.measureText("分钟")) else 44f
        val records = c.records.takeLast(3)

        // ── 先量高度（逻辑单位）
        val innerW = 302f
        val titlePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ink; textSize = 16f * S; typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val titleText = c.title.ifBlank { c.headline }
        val rightW = innerW - leftW - 16f
        val titleLayout = StaticLayout.Builder.obtain(titleText, 0, titleText.length, titlePaint, (rightW * S).toInt())
            .setMaxLines(2).setEllipsize(TextUtils.TruncateAt.END).setLineSpacing(0f, 1.15f)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL).build()
        val titleH = titleLayout.height / S
        val metaPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = mute; textSize = 11f * S; typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val metaLayout = StaticLayout.Builder.obtain(metaText, 0, metaText.length, metaPaint, (rightW * S).toInt())
            .setMaxLines(2).setEllipsize(TextUtils.TruncateAt.END).setLineSpacing(0f, 1.1f)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL).build()
        val metaH = if (metaText.isBlank()) 0f else metaLayout.height / S
        val blockH = max(64f, titleH + (if (metaH > 0) 7f + metaH else 0f))

        var h = 20f + 14f + 12f + blockH + 10f
        if (records.isNotEmpty()) h += 12f + 14f + 4f + records.size * 25f + 2f
        h += 12f + 28f + 5f + 13f + 16f
        val top = if (background) 34f else 6f
        val bottomPad = if (background) 36f else 30f
        val totalH = top + h + bottomPad

        val bmp = Bitmap.createBitmap((W * S).toInt(), (totalH * S).toInt(), Bitmap.Config.ARGB_8888)
        val cv = Canvas(bmp)
        cv.scale(S, S)

        // 背景：深色渐变 + 中间一团暖光
        if (background) {
            val bg = Paint().apply { shader = LinearGradient(0f, 0f, 0f, totalH, Color.parseColor("#1A1410"), Color.parseColor("#0B0908"), Shader.TileMode.CLAMP) }
            cv.drawRect(0f, 0f, W, totalH, bg)
            val glow = Paint().apply {
                shader = RadialGradient(W / 2, top + h * 0.5f, W * 0.62f, Color.parseColor("#55331F"), Color.TRANSPARENT, Shader.TileMode.CLAMP)
            }
            cv.drawRect(0f, 0f, W, totalH, glow)
        }

        val left = 24f
        val right = W - 24f
        val ticket = RectF(left, top, right, top + h)

        // 阴影
        val shadow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(150, 0, 0, 0)
            maskFilter = BlurMaskFilter(22f, BlurMaskFilter.Blur.NORMAL)
        }
        cv.drawRoundRect(RectF(left + 6, top + 18, right - 6, top + h + 14), 12f, 12f, shadow)

        // 纸：奶白渐变，两侧各挖一排半圆缺口
        val layer = cv.saveLayer(0f, 0f, W, totalH, null)
        val paperPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(0f, top, 0f, top + h, paper1, paper2, Shader.TileMode.CLAMP)
        }
        cv.drawRoundRect(ticket, 12f, 12f, paperPaint)
        val clear = Paint(Paint.ANTI_ALIAS_FLAG).apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR) }
        var cy = top + 7f
        while (cy < top + h) {
            cv.drawCircle(left, cy, 4.5f, clear)
            cv.drawCircle(right, cy, 4.5f, clear)
            cy += 14f
        }
        cv.restoreToCount(layer)

        val x0 = left + 20f
        val x1 = x0 + innerW
        var y = top + 20f

        // 品牌行 + 状态
        val brandPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = ink; textSize = 14f; typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
        }
        cv.drawText(brand, x0, y + 12f, brandPaint)
        val statusPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = greenInk; textSize = 12f; typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val sw = statusPaint.measureText(status)
        cv.drawText(status, x1 - sw, y + 12f, statusPaint)
        cv.drawCircle(x1 - sw - 8f, y + 8.5f, 3f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = greenInk })
        y += 14f + 12f

        // 左：大号数字 + 单位（任务完成时是一个大勾）；右：标题 + 一行小字
        val blockTop = y
        if (bigNum != null) {
            val nx = x0 + (leftW - numPaint.measureText(bigNum)) / 2
            cv.drawText(bigNum, nx, blockTop + 43f, numPaint)
            val cap = "分钟"
            cv.drawText(cap, x0 + (leftW - capPaint.measureText(cap)) / 2, blockTop + 62f, capPaint)
        } else {
            val ccx = x0 + leftW / 2
            val ccy = blockTop + 26f
            cv.drawCircle(ccx, ccy, 21f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = greenSoft })
            val tk = Path().apply { moveTo(ccx - 9f, ccy + 1f); lineTo(ccx - 2.5f, ccy + 8f); lineTo(ccx + 10f, ccy - 7f) }
            cv.drawPath(tk, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = green; style = Paint.Style.STROKE; strokeWidth = 4f; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
            })
        }
        val rx = x0 + leftW + 16f
        cv.save()
        cv.translate(rx, blockTop)
        cv.scale(1f / S, 1f / S)
        titleLayout.draw(cv)
        cv.restore()
        if (metaH > 0) {
            cv.save()
            cv.translate(rx, blockTop + titleH + 7f)
            cv.scale(1f / S, 1f / S)
            metaLayout.draw(cv)
            cv.restore()
        }
        y += blockH + 10f
        // 虚线：撕票口
        cv.drawLine(x0, y - 4f, x1, y - 4f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = line; strokeWidth = 1.2f; style = Paint.Style.STROKE
            pathEffect = android.graphics.DashPathEffect(floatArrayOf(3f, 3f), 0f)
        })

        // 期间记录：像收银小票的明细——虚线抬头、编号 + 一行内容 + 右侧类别，行与行之间一道点线
        if (records.isNotEmpty()) {
            y += 12f
            val secPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { color = mute; textSize = 11f; typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD) }
            val label = (if (isPomo) "期间记录" else "一路记录") + " · ${c.records.size}"
            val lw = secPaint.measureText(label)
            val mid = (x0 + x1) / 2
            val ly = y + 6f
            val dashed = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = line; strokeWidth = 1.2f; style = Paint.Style.STROKE
                pathEffect = android.graphics.DashPathEffect(floatArrayOf(3f, 3f), 0f)
            }
            cv.drawLine(x0, ly, mid - lw / 2 - 8f, ly, dashed)
            cv.drawLine(mid + lw / 2 + 8f, ly, x1, ly, dashed)
            cv.drawText(label, mid - lw / 2, y + 10f, secPaint)
            y += 14f + 4f
            val numPaint2 = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { color = numColor; textSize = 11f; typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD) }
            val body = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { color = ink; textSize = 13f }
            val tagPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { color = mute; textSize = 10f; typeface = Typeface.create(Typeface.MONOSPACE, Typeface.NORMAL) }
            val dotted = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = line; strokeWidth = 1f; style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND
                pathEffect = android.graphics.DashPathEffect(floatArrayOf(0.1f, 3.2f), 0f)
            }
            val firstIndex = c.records.size - records.size
            records.forEachIndexed { i, e ->
                val base = y + 17f
                // 编号
                cv.drawText("%02d".format(firstIndex + i + 1), x0, base, numPaint2)
                // 右侧类别
                val tagW = tagPaint.measureText(e.tag)
                cv.drawText(e.tag, x1 - tagW, base, tagPaint)
                // 正文：一行，放不下截断
                val textLeft = x0 + 24f
                val avail = x1 - tagW - 10f - textLeft
                val oneLine = e.text.replace(Regex("\\s+"), " ")
                val shown = TextUtils.ellipsize(oneLine, body, avail * 1f, TextUtils.TruncateAt.END).toString()
                cv.drawText(shown, textLeft, base, body)
                y += 25f
                if (i < records.size - 1) cv.drawLine(x0, y - 4f, x1, y - 4f, dotted)
            }
            y += 2f
        }

        // 条形码 + 合并信息行
        y += 12f
        var seed = serial.hashCode().toLong().let { if (it < 0) -it else it } % 233280L
        fun rnd(): Double {
            seed = (seed * 9301 + 49297) % 233280
            return seed / 233280.0
        }
        val barPaint = Paint().apply { color = ink }
        var bx = x0
        while (bx < x0 + 150f) {
            val k = 1 + floor(rnd() * 3).toInt()
            val g = 1 + floor(rnd() * 2.4).toInt()
            cv.drawRect(bx, y, bx + k, y + 28f, barPaint)
            bx += k + g
        }
        y += 28f + 5f
        val sn = "◆ $what · $stamp · $serial ◆"
        val snPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = mute; textSize = 9.5f; typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
        }
        while (snPaint.measureText(sn) > innerW - 56f && snPaint.textSize > 7f) snPaint.textSize -= 0.25f
        cv.drawText(sn, x0, y + 9.5f, snPaint)

        // 印章
        val scx = right - 16f - 26f
        val scy = top + h - 24f - 26f
        cv.save()
        cv.rotate(-12f, scx, scy)
        val sp = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = deep; style = Paint.Style.STROKE; strokeWidth = 2.5f; alpha = 235 }
        cv.drawCircle(scx, scy, 25f, sp)
        val dash = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = deep; style = Paint.Style.STROKE; strokeWidth = 1f; alpha = 235
            pathEffect = android.graphics.DashPathEffect(floatArrayOf(2.5f, 2f), 0f)
        }
        cv.drawCircle(scx, scy, 21.5f, dash)
        val stampPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = deep; textSize = 12f; typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD); alpha = 235
        }
        cv.drawText(status, scx - stampPaint.measureText(status) / 2, scy + 1f, stampPaint)
        val smallPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = deep; textSize = 9f; typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD); alpha = 235
        }
        cv.drawText(stampSmall, scx - smallPaint.measureText(stampSmall) / 2, scy + 12f, smallPaint)
        cv.restore()
        return bmp
    }

    private fun fmtMin(m: Int): String = if (m >= 60) "${m / 60} 时 ${m % 60} 分" else "$m 分"

    /** 存到相册（Pictures/拾忆）；成功返回 true */
    fun saveToGallery(context: Context, bitmap: Bitmap, now: LocalDateTime = LocalDateTime.now()): Boolean {
        val name = "拾忆成果_" + now.format(DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss")) + ".png"
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            if (Build.VERSION.SDK_INT >= 29) {
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/拾忆")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
        }
        val resolver = context.contentResolver
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: return false
        return try {
            resolver.openOutputStream(uri)?.use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) } ?: error("no stream")
            if (Build.VERSION.SDK_INT >= 29) {
                resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
            }
            true
        } catch (e: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            false
        }
    }
}
