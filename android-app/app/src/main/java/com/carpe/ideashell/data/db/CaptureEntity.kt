package com.carpe.ideashell.data.db

import androidx.room.Entity
import androidx.room.PrimaryKey

enum class CaptureStatus { PENDING, SENDING, DONE, FAILED }

/**
 * 离线队列里的一条记录。保存时只写入这一行（毫秒级，永不因网络失败），
 * 之后由后台同步到闪念贝壳 / 滴答。tags 以换行分隔存储。
 */
@Entity(tableName = "captures")
data class CaptureEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    /** CaptureKind 的名字：TODO / DAILY / NOTE */
    val kind: String,
    /** 笔记标题；Daily Note / 待办为 null */
    val noteTitle: String?,
    /** 笔记正文 / Daily Note 条目正文 / 待办标题 */
    val body: String,
    val todoDate: String?,
    val todoTime: String?,
    val important: Boolean,
    val tags: String,
    val folderName: String?,
    /** 列表里展示的标题 */
    val summary: String,
    /** 列表里展示的副标题（类型 · 时间 / 标签 …） */
    val detail: String,
    /** 来源：app / quick / share / selection */
    val origin: String,
    val createdAt: Long,
    /** 最早可同步时间（给「撤销」留出缓冲；重试时用作下次尝试时间） */
    val readyAt: Long,
    val status: String = CaptureStatus.PENDING.name,
    val attempts: Int = 0,
    /** 同步成功后的说明（存到了哪里） */
    val resultText: String? = null,
    val lastError: String? = null,
    val updatedAt: Long = createdAt,
)

fun CaptureEntity.tagList(): List<String> = if (tags.isEmpty()) emptyList() else tags.split('\n')
