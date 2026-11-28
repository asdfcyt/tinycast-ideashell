package com.carpe.ideashell.system

import android.content.Context
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.content.Intent
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.InputType
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import com.carpe.ideashell.core.voice.TodoOp
import com.carpe.ideashell.data.voice.VoiceSearch
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/** 语音胶囊的各个面板：录音、整理中、确认卡片、倒计时小胶囊、保存结果、搜索 / 回答结果、提示。 */
/** 松手自动保存：小胶囊倒计时多久后保存 */
private const val PENDING_MS = 3000L


internal fun VoiceCapsuleService.renderRecording() {
    shown = CapsuleShown.RECORDING
    dotAnimator?.cancel()
    column?.layoutTransition = newTransition()
    // 进入录音面板的过渡做完后关掉布局动画：录音时波形区域每帧都在微微变宽，不能再套动画
    handler.postDelayed({ if (shown == CapsuleShown.RECORDING) column?.layoutTransition = null }, 420)
    val row = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(18), dp(9), dp(12), dp(9))
    }
    val redDot = View(this).apply {
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(CAPSULE_RED)
        }
    }
    row.addView(redDot, LinearLayout.LayoutParams(dp(10), dp(10)).apply { marginEnd = dp(10) })
    // 红点慢慢「呼吸」
    dotAnimator = ObjectAnimator.ofFloat(redDot, View.ALPHA, 1f, 0.3f).apply {
        duration = 700
        repeatMode = ObjectAnimator.REVERSE
        repeatCount = ObjectAnimator.INFINITE
        start()
    }
    val timer = label("0:00", 18f, bold = true)
    timer.typeface = Typeface.create(Typeface.DEFAULT_BOLD, Typeface.NORMAL)
    row.addView(timer, LinearLayout.LayoutParams(dp(46), LinearLayout.LayoutParams.WRAP_CONTENT))
    timerText = timer
    val w = WaveView(this, pal.text)
    row.addView(w, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(30)).apply {
        marginStart = dp(4)
        marginEnd = dp(12)
    })
    wave = w
    row.addView(stopButton(), LinearLayout.LayoutParams(dp(38), dp(38)))
    row.addView(
        label("×", 22f).apply {
            gravity = Gravity.CENTER
            alpha = 0.65f
            contentDescription = "取消"
            pressable()
            setOnClickListener {
                voice?.cancel()
                dismissWithSlide()
            }
        },
        LinearLayout.LayoutParams(dp(38), dp(38)).apply { marginStart = dp(2) },
    )
    val live = label("", 13f).apply {
        alpha = 0.7f
        visibility = View.GONE
        maxLines = 2
        maxWidth = dp(200)
        ellipsize = TextUtils.TruncateAt.END
        setPadding(dp(18), 0, dp(14), dp(10))
    }
    liveText = live
    liveShown = ""
    val box = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        addView(row)
        addView(live)
    }
    swap(box)
}

internal fun VoiceCapsuleService.renderProcessing() {
    shown = CapsuleShown.PROCESSING
    dotAnimator?.cancel()
    column?.layoutTransition = newTransition()
    wave = null
    timerText = null
    val row = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(18), dp(11), dp(14), dp(11))
    }
    row.addView(
        ProgressBar(this).apply {
            isIndeterminate = true
            indeterminateTintList = android.content.res.ColorStateList.valueOf(CAPSULE_ACCENT)
        },
        LinearLayout.LayoutParams(dp(20), dp(20)).apply { marginEnd = dp(10) },
    )
    val status = label("正在识别整理…", 15f)
    processingText = status
    liveText = null
    row.addView(status, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
        marginEnd = dp(14)
    })
    row.addView(
        label("放弃", 14f).apply {
            alpha = 0.65f
            setPadding(dp(8), dp(8), dp(8), dp(8))
            pressable()
            setOnClickListener {
                voice?.cancel()
                dismissWithSlide()
            }
        },
    )
    swap(row)
}

/** 确认卡片：整理后的文字可直接改，类型可点着切换，底部 放弃 / 重新说 / 保存 */
internal fun VoiceCapsuleService.renderConfirm(note: String?) {
    // 从「正在整理」或倒计时小胶囊点开：记下它现在在屏幕上的位置，等卡片排好版后从这里原地张开
    val from = if (shown == CapsuleShown.PENDING || shown == CapsuleShown.PROCESSING) surfaceScreenRect() else null
    val fromPending = shown == CapsuleShown.PENDING
    shown = CapsuleShown.CONFIRM
    dotAnimator?.cancel()
    cancelCountdown()
    val keep = surface
    if (fromPending) {
        keep?.apply {
            setOnClickListener(null)
            setOnTouchListener(null)
            isClickable = true // 变成卡片后吃掉点击，不再触发「展开」
            scaleX = 1f
            scaleY = 1f
        }
        // 其余的小胶囊淡出，卡片排好版时再移除
        column?.let { col ->
            (0 until col.childCount).map { col.getChildAt(it) }.filter { it !== keep }
                .forEach { it.animate().alpha(0f).setDuration(90).start() }
        }
    }
    // 张开用裁剪框动画，期间不再套布局过渡
    column?.layoutTransition = if (from != null) null else newTransition()
    wave = null
    timerText = null
    stopTick()
    val maxWidth = minOf(dp(330), resources.displayMetrics.widthPixels - dp(20))
    val card = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(18), dp(14), dp(14), dp(10))
        minimumWidth = maxWidth
    }
    val head = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
    head.addView(label("确认记录", 13f, bold = true).apply { alpha = 0.6f })
    if (!note.isNullOrBlank()) {
        head.addView(
            label(note, 11f).apply {
                alpha = 0.45f
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
                setPadding(dp(8), 0, 0, 0)
            },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
        )
    }
    card.addView(head)

    val list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    fun rebuildRows() {
        list.removeAllViews()
        drafts.forEachIndexed { index, draft -> list.addView(draftRow(draft, index) { rebuildRows() }) }
    }
    rebuildRows()
    val scroll = ScrollView(this).apply {
        isVerticalScrollBarEnabled = false
        overScrollMode = View.OVER_SCROLL_NEVER
        addView(list)
    }
    card.addView(
        scroll,
        LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) },
    )

    val buttons = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL or Gravity.END }
    buttons.addView(textButton("放弃") { exitEditMode(); dismissWithSlide() })
    buttons.addView(textButton("重新说") {
        exitEditMode()
        drafts.clear()
        begin(false)
    })
    buttons.addView(
        label("保存", 15f, bold = true).apply {
            setTextColor(CAPSULE_ON_ACCENT)
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                setColor(CAPSULE_ACCENT)
                cornerRadius = dp(20).toFloat()
            }
            setPadding(dp(22), dp(9), dp(22), dp(9))
            pressable()
            setOnClickListener {
                exitEditMode()
                val snapshot = drafts.toList()
                scope.launch { saveAll(snapshot, note) }
            }
        },
        LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginStart = dp(6) },
    )
    card.addView(
        buttons,
        LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8) },
    )
    swap(card) {
        column?.let { col ->
            (0 until col.childCount).map { col.getChildAt(it) }.filter { it !== surface }.forEach { col.removeView(it) }
        }
        recenter()
        if (from != null) expandFrom(from) else column?.layoutTransition = newTransition()
    }
}

/** 确认卡片里的一件事：类型小标签 + 可编辑的文字 + 待办的日期 + 删除 */
internal fun VoiceCapsuleService.draftRow(draft: CapsuleDraft, index: Int, onChanged: () -> Unit): View {
    val row = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        setPadding(0, dp(6), 0, dp(6))
    }
    val chip = label(draftLabel(draft), 12f, bold = true).apply {
        setTextColor(pal.accentSoft)
        gravity = Gravity.CENTER
        background = GradientDrawable().apply {
            setColor(pal.chipBg)
            cornerRadius = dp(12).toFloat()
        }
        setPadding(dp(10), dp(4), dp(10), dp(4))
        pressable()
        setOnClickListener {
            if (draft.mode == CapsuleMode.EDIT) return@setOnClickListener // 改待办的类型不能换
            draft.mode = nextMode(draft.mode, draft.intent != null)
            text = draftLabel(draft)
            onChanged()
        }
    }
    row.addView(chip, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
        topMargin = dp(2)
        marginEnd = dp(10)
    })
    val body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    val edit = EditText(this).apply {
        setText(draft.text)
        setTextColor(pal.text)
        setHintTextColor((pal.text and 0x00FFFFFF) or 0x66000000)
        hint = if (draft.mode == CapsuleMode.EDIT) "补充到待办备注（可留空）" else "说的内容"
        // 完成 / 删除待办没有可补充的文字，不显示输入框
        if (draft.mode == CapsuleMode.EDIT && draft.op() != TodoOp.EDIT) visibility = View.GONE
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        background = null
        setPadding(0, dp(2), 0, dp(2))
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        imeOptions = EditorInfo.IME_ACTION_DONE
        setHorizontallyScrolling(false)
        maxLines = 5
        setOnTouchListener { v, event ->
            if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                imeTarget = v
                enterEditMode()
                v.post {
                    v.requestFocus()
                    (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(v, InputMethodManager.SHOW_IMPLICIT)
                }
            }
            false
        }
        setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_DONE) {
                exitEditMode()
                true
            } else {
                false
            }
        }
        addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: android.text.Editable?) {
                draft.text = s?.toString().orEmpty()
            }
        })
    }
    if (draft.mode == CapsuleMode.EDIT) {
        // 先说清楚改的是哪一条、改成什么；找不到就用红字提醒
        body.addView(
            label(editSummary(draft), 15f, bold = true).apply {
                if (draft.task == null || draft.op() == TodoOp.DELETE) setTextColor(pal.error)
            },
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT),
        )
    }
    body.addView(edit, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
    val intent = draft.intent
    if (draft.mode == CapsuleMode.TODO && intent != null) {
        val whenText = scheduleText(intent.date, intent.time) + (intent.repeat?.let { " · $it" } ?: "")
        if (whenText.isNotBlank()) body.addView(label(whenText, 12f).apply { setTextColor(pal.accentSoft) })
    }
    row.addView(body, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
    if (drafts.size > 1) {
        row.addView(
            label("×", 20f).apply {
                gravity = Gravity.CENTER
                alpha = 0.55f
                contentDescription = "去掉这一项"
                pressable()
                setOnClickListener {
                    drafts.removeAt(index)
                    onChanged()
                }
            },
            LinearLayout.LayoutParams(dp(34), dp(34)).apply { marginStart = dp(4) },
        )
    }
    return row
}

/** 松手自动保存：不弹确认卡片，每条一个小胶囊 + 倒计时细线；点任意一个展开确认卡片，倒计时走完才真正保存 */
internal fun VoiceCapsuleService.renderPending(note: String?) {
    shown = CapsuleShown.PENDING
    stopTick()
    dotAnimator?.cancel()
    wave = null
    timerText = null
    val col = ensureColumn()
    col.layoutTransition = newTransition()
    col.removeAllViews()
    surface = null
    val lines = ArrayList<View>()
    drafts.filter { it.isValid() }.forEachIndexed { index, draft ->
        val intent = draft.intent
        val whenText = if (draft.mode == CapsuleMode.TODO && intent != null) scheduleText(intent.date, intent.time) else ""
        val box = FrameLayout(this).apply {
            background = capsuleBackground(26)
            elevation = dp(8).toFloat()
            isClickable = true
            pressable()
            setOnClickListener { renderConfirm(note) }
        }
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(9), dp(14), dp(13))
        }
        row.addView(label(draftLabel(draft, saved = true).let { if (draft.mode == CapsuleMode.AUTO) "记录" else it }, 12f, bold = true).apply {
            setTextColor(pal.accentSoft)
            setPadding(0, 0, dp(8), 0)
        })
        row.addView(
            label(
                if (draft.mode == CapsuleMode.EDIT) editSummary(draft)
                else (if (whenText.isNotEmpty()) "$whenText · " else "") + draft.text.trim().take(60),
                15f,
            ).apply {
                maxWidth = dp(230)
                maxLines = 2
                ellipsize = TextUtils.TruncateAt.END
            },
        )
        box.addView(row, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT))
        val line = View(this).apply {
            setBackgroundColor(CAPSULE_ACCENT)
            alpha = 0.75f
            pivotX = 0f
        }
        box.addView(line, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, dp(2), Gravity.BOTTOM).apply {
            marginStart = dp(16)
            marginEnd = dp(14)
            bottomMargin = dp(6)
        })
        lines += line
        addSmall(box, index * 120L)
        // 第一条小胶囊同时是「主面板」：点开时它原地长成确认卡片
        if (index == 0) surface = box
    }
    if (!note.isNullOrBlank()) {
        val box = smallPill()
        box.addView(label(note, 12f).apply { maxWidth = dp(260); alpha = 0.8f })
        addSmall(box, lines.size * 120L)
    }
    recenter()
    val snapshot = drafts.toList()
    countdown = ValueAnimator.ofFloat(0f, 1f).apply {
        duration = PENDING_MS
        interpolator = android.view.animation.LinearInterpolator()
        addUpdateListener { a ->
            val f = a.animatedValue as Float
            lines.forEach { it.scaleX = 1f - f }
        }
        addListener(object : AnimatorListenerAdapter() {
            private var cancelled = false
            override fun onAnimationCancel(animation: Animator) {
                cancelled = true
            }

            override fun onAnimationEnd(animation: Animator) {
                if (!cancelled && !stopping) scope.launch { saveAll(snapshot, note, quiet = true) }
            }
        })
        startDelay = 300
        start()
    }
}

/** 保存成功：每条记录一个小胶囊，依次从右侧滑出；整理出几条就是几个 */
internal fun VoiceCapsuleService.showSaved(items: List<CapsuleSaved>, note: String?, quiet: Boolean = false) {
    if (stopping) return
    if (headless) {
        val text = items.joinToString("\n") { "${it.tag}：${it.text}" }.take(400)
        headlessDone(true, if (note.isNullOrBlank()) text else "$text\n$note")
        return
    }
    stopTick()
    dotAnimator?.cancel()
    cancelCountdown()
    shown = CapsuleShown.MESSAGE
    val col = ensureColumn()
    col.removeAllViews()
    surface = null
    items.forEachIndexed { index, item ->
        val box = smallPill()
        box.addView(label("✓", 15f, bold = true).apply { setTextColor(pal.green) }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { marginEnd = dp(8) })
        box.addView(label(item.tag, 12f, bold = true).apply {
            setTextColor(pal.accentSoft)
            setPadding(0, 0, dp(8), 0)
        })
        box.addView(
            label(item.text.take(60), 15f).apply {
                maxWidth = dp(220)
                maxLines = 2
                ellipsize = TextUtils.TruncateAt.END
            },
        )
        val undo = item.undo
        if (undo != null) {
            box.addView(
                textButton("撤销") {
                    // 点过一次就不再响应；旧的「自动收起」计时作废，由结果提示自己收起
                    handler.removeCallbacksAndMessages(null)
                    scope.launch {
                        val r = undo()
                        showMessage(r.fold(onSuccess = { it }, onFailure = { "撤销失败：" + (it.message ?: "未知错误") }), error = r.isFailure)
                    }
                }.apply { setTextColor(pal.accentSoft); alpha = 1f },
            )
        }
        addSmall(box, if (quiet) 0L else index * 140L, animate = !quiet)
    }
    if (!note.isNullOrBlank() && !quiet) {
        val box = smallPill()
        box.addView(label(note, 12f).apply { maxWidth = dp(260); alpha = 0.8f })
        addSmall(box, items.size * 140L)
    }
    recenter()
    col.setOnClickListener { dismissWithSlide() }
    // 带「撤销」的多停留一会儿，给用户反悔的时间
    val hasUndo = items.any { it.undo != null }
    handler.postDelayed({ dismissWithSlide() }, if (hasUndo) 7000L else if (quiet) 1100L else 2800L + items.size * 400L)
}

/** 搜索 / 查询结果：不自动消失的卡片，每条可点（笔记 → 拾忆里的笔记页，待办 → 待办页），最后一行去搜索页看全部 */
internal fun VoiceCapsuleService.showResults(res: VoiceSearch.Result) {
    if (stopping) return
    // 助手的回答：设置里开了「语音回答」就念出来（念之前会先停掉上一段）
    if (res.isAnswer && !res.text.startsWith("没能回答")) (application as com.carpe.ideashell.IdeashellApp).container.speech.speak(res.text)
    if (headless) {
        // 没有画面：结果放进通知（点开进搜索页）
        val lines = res.hits.take(VoiceSearch.MAX_LINES).joinToString("\n") { "· ${it.title}" }
        val text = if (lines.isBlank()) res.text else res.text + "\n" + lines
        headlessDone(true, text, searchQuery = res.keyword.takeIf { res.hits.isNotEmpty() }, title = if (res.isAnswer) "语音回答" else "语音搜索")
        return
    }
    if (res.isAnswer && res.text.startsWith("没能回答")) {
        showMessage(res.text, error = true, durationMs = 6000L)
        return
    }
    if (res.hits.isEmpty() && !res.isAnswer) {
        showMessage(res.text, error = false, durationMs = 3500L)
        return
    }
    // 助手的回答 / 搜索结果：侧边卡片（见 CapsuleAnswerCard.kt）
    showAnswerCard(res)
}

internal fun VoiceCapsuleService.showMessage(message: String, error: Boolean, durationMs: Long = if (error) 4000L else 2500L) {
    if (stopping) return
    if (headless) {
        // 没听到声音：这类手机熄屏 / 锁屏时系统吃掉了「按下」，要先轻按、震动后再说话，提示里带上用法
        val hint = if (error && message.contains("没有听到声音")) "没有听到声音：先轻按一下音量键，震动后再说话（不要按着说）" else message
        headlessDone(!error, hint)
        return
    }
    stopTick()
    dotAnimator?.cancel()
    cancelCountdown()
    exitEditMode()
    shown = CapsuleShown.MESSAGE
    val col = ensureColumn()
    col.removeAllViews()
    surface = null
    val box = smallPill()
    box.addView(label(message, 15f).apply {
        maxWidth = dp(260)
        if (error) setTextColor(pal.error)
    })
    addSmall(box)
    recenter()
    col.setOnClickListener { dismissWithSlide() }
    handler.postDelayed({ dismissWithSlide() }, durationMs)
}

/** 「正在整理」胶囊里换文字（助手回答生成中，边生成边显示）；不在整理阶段就忽略 */
internal fun VoiceCapsuleService.setProcessingText(text: String) {
    if (shown != CapsuleShown.PROCESSING) return
    val tv = processingText ?: return
    tv.maxWidth = dp(250)
    tv.maxLines = 8
    tv.text = text
    recenter()
}
