package com.carpe.ideashell.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

@Dao
interface RevisitDao {
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insert(item: RevisitEntity): Long

    @Update
    suspend fun update(item: RevisitEntity)

    @Update
    suspend fun updateAll(items: List<RevisitEntity>)

    @Query("SELECT * FROM revisit_items WHERE id = :id")
    suspend fun get(id: Long): RevisitEntity?

    @Query("SELECT * FROM revisit_items WHERE dedupeKey = :key")
    suspend fun byKey(key: String): RevisitEntity?

    /** 还在重温的（没点「不再重温」的），数量不会很大，筛选排序在内存里做 */
    @Query("SELECT * FROM revisit_items WHERE archived = 0")
    fun observeActive(): Flow<List<RevisitEntity>>

    @Query("SELECT * FROM revisit_items WHERE archived = 0")
    suspend fun active(): List<RevisitEntity>

    /** 整个重温库（含「不再重温」的），备份 / 迁移用 */
    @Query("SELECT * FROM revisit_items ORDER BY id")
    suspend fun all(): List<RevisitEntity>

    @Query("DELETE FROM revisit_items WHERE id = :id")
    suspend fun delete(id: Long)

    // ───────────── 重温流水（折线图 / 备份用） ─────────────

    @Insert
    suspend fun insertLog(log: RevisitLogEntity): Long

    @Insert
    suspend fun insertLogs(logs: List<RevisitLogEntity>)

    /** 撤销一次评分：删掉那一刻的流水 */
    @Query("DELETE FROM revisit_logs WHERE itemKey = :key AND reviewedAt = :at")
    suspend fun deleteLog(key: String, at: Long)

    /** [from, to) 内的流水；有新评分或撤销时折线图自动刷新 */
    @Query("SELECT * FROM revisit_logs WHERE reviewedAt >= :from AND reviewedAt < :to ORDER BY reviewedAt")
    fun observeLogs(from: Long, to: Long): Flow<List<RevisitLogEntity>>

    @Query("SELECT * FROM revisit_logs ORDER BY id")
    suspend fun allLogs(): List<RevisitLogEntity>
}
