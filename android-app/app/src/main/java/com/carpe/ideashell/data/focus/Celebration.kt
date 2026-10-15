package com.carpe.ideashell.data.focus

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.random.Random

/** 完成一个番茄 / 一个任务时给用户的反馈：数据、过程中记下的内容、一句鼓励 */
data class Celebration(
    val kind: Kind,
    /** 任务名（没有就空） */
    val title: String,
    val headline: String,
    val message: String,
    /** 小标签：时长、第几个番茄、累计专注… */
    val stats: List<String>,
    /** 过程中记录的内容：（来源标签, 内容） */
    val records: List<Entry>,
    val postedAt: Long = System.currentTimeMillis(),
    val id: Long = System.nanoTime(),
) {
    enum class Kind { POMODORO, TASK }

    data class Entry(val tag: String, val text: String)
}

/** 全局只有一条「当前反馈」：新的来了就顶掉旧的；界面（根布局）显示它，点掉或自动消失后清空 */
class CelebrationCenter {
    private val _current = MutableStateFlow<Celebration?>(null)
    val current: StateFlow<Celebration?> = _current.asStateFlow()

    fun post(c: Celebration) {
        _current.value = c
    }

    fun dismiss(id: Long) {
        if (_current.value?.id == id) _current.value = null
    }
}

/** 鼓励的话：按场景随机挑一句 */
object Cheer {
    private val POMODORO = listOf(
        "稳稳地把这一段时间交给了重要的事，漂亮。",
        "又一个番茄入账，节奏很棒！",
        "专注是会复利的，今天的你比刚才更接近目标。",
        "不被打断地做完一整段，本身就值得夸一下。",
        "先休息一会儿，回来继续发光。",
    )
    private val POMODORO_WITH_RECORDS = listOf(
        "不只是坐了一段时间，还留下了实实在在的记录，这就是进展。",
        "边做边记，以后的你会感谢现在的你。",
        "这些记录就是这个番茄的成果，继续保持！",
    )
    private val EARLY = listOf(
        "没走完也算数，已经记下这段专注了。",
        "做了就有收获，下次再来一个完整的番茄。",
    )
    private val TASK = listOf(
        "又划掉一项，干得漂亮！",
        "完成就是最好的反馈，给自己一点掌声。",
        "一步一步，事情就是这样被做完的。",
        "这件事告一段落，轻松一点，再出发。",
    )
    private val TASK_WITH_RECORDS = listOf(
        "回头看看这一路留下的记录，每一步都算数。",
        "过程都有迹可循，这件事做得扎实。",
        "有记录、有复盘，这样的完成才真正沉淀下来。",
    )

    fun pomodoro(hasRecords: Boolean, completed: Boolean): String =
        pick(if (!completed) EARLY else if (hasRecords) POMODORO_WITH_RECORDS else POMODORO)

    fun task(hasRecords: Boolean): String = pick(if (hasRecords) TASK_WITH_RECORDS else TASK)

    private fun pick(list: List<String>): String = list[Random.nextInt(list.size)]
}
