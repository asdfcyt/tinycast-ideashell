package com.carpe.ideashell.system

import com.carpe.ideashell.core.voice.TodoOp
import com.carpe.ideashell.core.voice.VoiceIntent
import com.carpe.ideashell.data.dida.DidaTask
import com.carpe.ideashell.data.dida.TodoEditor
import java.time.LocalDate
import java.time.LocalTime

/** 语音胶囊的数据模型：确认卡片里的草稿、类型、当前显示的面板、配色，以及和界面无关的小函数。 */
// 确认卡片
internal enum class CapsuleMode(val label: String) {
    AUTO("自动"), TODO("待办"), DAILY("日记"), NOTE("笔记"), APPEND("追加"), ASK("问 AI"), EDIT("改待办"),
}

/** [task]：对已有待办的操作（[CapsuleMode.EDIT]，具体是改 / 完成 / 删除见 [VoiceIntent.op]）找到的那条滴答待办，没找到为 null；改待办时 [text] 是要追加到备注的说明 */
internal class CapsuleDraft(var mode: CapsuleMode, var text: String, val intent: VoiceIntent?, var task: DidaTask? = null) {
    /** 整理出来的原文：保存时和用户手改后的文字比一比，学习近音错字 */
    val original: String = text
}

internal fun CapsuleDraft.isValid(): Boolean = text.isNotBlank() || mode == CapsuleMode.EDIT

internal fun CapsuleDraft.op(): TodoOp = intent?.op ?: TodoOp.EDIT

internal fun CapsuleDraft.editOf() = TodoEditor.Edit(intent?.date, intent?.time, text, intent?.priority ?: 0)

/** 卡片 / 小胶囊上的类型标签：待办操作按具体动作显示（改待办 / 完成待办 / 删除待办） */
internal fun draftLabel(draft: CapsuleDraft, saved: Boolean = false): String =
    if (draft.mode == CapsuleMode.EDIT) draft.op().label else modeLabel(draft.mode, saved)

internal enum class CapsuleShown { NONE, RECORDING, PROCESSING, CONFIRM, PENDING, MESSAGE }

internal class CapsulePalette(dark: Boolean) {
    val bg = if (dark) 0xF01C1C1E.toInt() else 0xF7FFFFFF.toInt()
    val stroke = if (dark) 0x26FFFFFF else 0x1F000000
    val text = if (dark) 0xFFFFFFFF.toInt() else 0xFF1C1C1E.toInt()
    val accentSoft = if (dark) 0xFFFFB48A.toInt() else 0xFFC4561F.toInt()
    val chipBg = if (dark) 0x33E8794A else 0x1FE8794A
    val green = if (dark) 0xFF7BE0A0.toInt() else 0xFF1E9E57.toInt()
    val error = if (dark) 0xFFFFB4B4.toInt() else 0xFFC62828.toInt()
}

/** [undo] 不为空：保存后的小胶囊上带「撤销」（语音完成 / 修改待办时给一次反悔的机会） */
internal class CapsuleSaved(val tag: String, val text: String, val undo: (suspend () -> Result<String>)? = null)

internal fun modeLabel(mode: CapsuleMode, saved: Boolean = false): String =
    if (saved && mode == CapsuleMode.AUTO) "已保存" else mode.label

internal fun scheduleText(date: LocalDate?, time: LocalTime?): String {
    if (date == null) return ""
    val today = LocalDate.now()
    val day = when (date) {
        today -> "今天"
        today.plusDays(1) -> "明天"
        today.plusDays(2) -> "后天"
        else -> "${date.monthValue}月${date.dayOfMonth}日"
    }
    return if (time != null) day + " %02d:%02d".format(time.hour, time.minute) else day
}

internal fun nextMode(mode: CapsuleMode, hasIntent: Boolean): CapsuleMode {
    val order = if (hasIntent) listOf(CapsuleMode.TODO, CapsuleMode.DAILY, CapsuleMode.NOTE, CapsuleMode.APPEND, CapsuleMode.ASK)
    else listOf(CapsuleMode.AUTO, CapsuleMode.TODO, CapsuleMode.DAILY, CapsuleMode.NOTE, CapsuleMode.APPEND, CapsuleMode.ASK)
    val i = order.indexOf(mode)
    return order[(i + 1) % order.size]
}
