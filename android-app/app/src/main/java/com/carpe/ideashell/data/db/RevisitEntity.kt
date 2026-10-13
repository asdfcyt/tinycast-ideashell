package com.carpe.ideashell.data.db

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/** 重温项的来源：整篇笔记，或笔记 / Daily Note 里选中的一段 */
enum class RevisitKind { NOTE, SNIPPET }

/**
 * 一条要间隔重温的东西：笔记（整篇）或一段摘录，加上 FSRS 的记忆状态。
 * 正文是加入时的快照，之后笔记被改了也不影响这里；本机的小数据，随数据库一起备份 / 迁移。
 *
 * [dedupeKey]：整篇笔记是 `n:<noteId>`，摘录是 `s:<noteId>:<正文哈希>`，用来避免重复加入。
 * [archived]：「不再重温」。行保留下来，是为了 `#重温` 标签不会又把它加回来。
 */
@Entity(tableName = "revisit_items", indices = [Index(value = ["dedupeKey"], unique = true)])
data class RevisitEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val dedupeKey: String,
    /** RevisitKind 的名字 */
    val kind: String,
    /** 来源笔记；摘录也记着它，方便回到原笔记 */
    val noteId: String?,
    val title: String,
    /** 正文快照（Markdown） */
    val text: String,
    /** 出处，例如「笔记」「Daily Note」 */
    val sourceLabel: String,
    /** 这段内容是哪天记下的（毫秒） */
    val recordedAt: Long,
    val addedAt: Long,
    /** FSRS：稳定性 S / 难度 D；还没复习过时为 0 */
    val stability: Double,
    val difficulty: Double,
    /** 下次出现的时间（当天 0 点，毫秒） */
    val due: Long,
    val reps: Int,
    val lapses: Int,
    /** 上次评分：0 无 / 1 忘了 / 3 记得 / 4 太简单 */
    val lastRating: Int,
    /** 上次复习的时间（毫秒）；从没复习过为 0 */
    val lastReviewAt: Long,
    /** 「今天跳过」：这之前不再出现（毫秒），不影响记忆曲线 */
    val skippedUntil: Long,
    val archived: Boolean,
)

val RevisitEntity.isNew: Boolean get() = reps == 0
