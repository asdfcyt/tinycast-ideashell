package com.carpe.ideashell.ui.capture

import com.carpe.ideashell.core.capture.CaptureSchedule
import com.carpe.ideashell.core.parse.RepeatParser
import com.carpe.ideashell.core.voice.VoiceIntent

/** 一件事的正文：整理后的内容 + 标签 + 优先级标记（和手打的写法一致，保存时再解析） */
internal fun voiceIntentBody(intent: VoiceIntent): String = buildString {
    append(intent.content)
    intent.tags.forEach { append(" #").append(it) }
    when {
        intent.priority >= 5 -> append(" !高")
        intent.priority >= 3 -> append(" !中")
        intent.priority >= 1 -> append(" !低")
    }
}

/** 待办的日期 / 时间 / 重复（都是大模型推算的）；没有日期就是 null */
internal fun voiceIntentSchedule(intent: VoiceIntent): CaptureSchedule? {
    val date = intent.date ?: return null
    return CaptureSchedule(
        date = date,
        time = intent.time,
        repeat = intent.repeat?.let { RepeatParser.find(it)?.rule },
    )
}
