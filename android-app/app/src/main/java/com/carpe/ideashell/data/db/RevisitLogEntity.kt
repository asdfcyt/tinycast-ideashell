package com.carpe.ideashell.data.db

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * 一次重温的流水：哪一条（[itemKey] = 重温项的 dedupeKey，不用本机自增 id，换机导入后仍然对得上）、什么时候、评了什么分
 * （1 忘了 / 3 记得 / 4 太简单）。回顾页「间隔复习」的折线图由它按天汇总。
 */
@Entity(
    tableName = "revisit_logs",
    indices = [Index(value = ["reviewedAt"]), Index(value = ["itemKey"])],
)
data class RevisitLogEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val itemKey: String,
    val reviewedAt: Long,
    val rating: Int,
)
