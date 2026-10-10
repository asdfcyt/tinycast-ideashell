package com.carpe.ideashell.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface CaptureDao {
    @Insert
    suspend fun insert(item: CaptureEntity): Long

    @Query("SELECT * FROM captures ORDER BY createdAt DESC LIMIT :limit")
    fun observeRecent(limit: Int): Flow<List<CaptureEntity>>

    @Query("SELECT * FROM captures WHERE id = :id")
    suspend fun get(id: Long): CaptureEntity?

    /** 下一条可以同步的记录（按记录时间先后，保证 Daily Note 条目顺序） */
    @Query("SELECT * FROM captures WHERE status = 'PENDING' AND readyAt <= :now ORDER BY createdAt ASC LIMIT 1")
    suspend fun nextReady(now: Long): CaptureEntity?

    @Query("SELECT COUNT(*) FROM captures WHERE status = 'PENDING' OR status = 'SENDING'")
    suspend fun countUnsent(): Int

    /** 原子占用：只有仍是 PENDING 才会成功，返回受影响行数 */
    @Query("UPDATE captures SET status = 'SENDING', updatedAt = :now WHERE id = :id AND status = 'PENDING'")
    suspend fun claim(id: Long, now: Long): Int

    /** 原子撤销：只有还没开始发送才会删除，返回受影响行数 */
    @Query("DELETE FROM captures WHERE id = :id AND status = 'PENDING'")
    suspend fun deletePending(id: Long): Int

    @Query("UPDATE captures SET status = 'DONE', resultText = :result, lastError = NULL, updatedAt = :now WHERE id = :id")
    suspend fun markDone(id: Long, result: String, now: Long)

    @Query("UPDATE captures SET status = 'FAILED', lastError = :error, updatedAt = :now WHERE id = :id")
    suspend fun markFailed(id: Long, error: String, now: Long)

    /** 暂时失败（如断网）：回到待发送，稍后重试 */
    @Query("UPDATE captures SET status = 'PENDING', attempts = :attempts, readyAt = :nextAt, lastError = :error, updatedAt = :now WHERE id = :id")
    suspend fun markRetry(id: Long, attempts: Int, nextAt: Long, error: String, now: Long)

    /** 手动重试失败的记录 */
    @Query("UPDATE captures SET status = 'PENDING', attempts = 0, readyAt = :now, lastError = NULL, updatedAt = :now WHERE id = :id AND status = 'FAILED'")
    suspend fun requeue(id: Long, now: Long): Int

    /** 进程在发送中途被杀：长时间停在 SENDING 的记录放回队列 */
    @Query("UPDATE captures SET status = 'PENDING' WHERE status = 'SENDING' AND updatedAt < :before")
    suspend fun resetStale(before: Long)

    @Query("DELETE FROM captures WHERE status = 'DONE'")
    suspend fun clearDone()

    /** 只保留最近一批已完成的记录，避免无限增长 */
    @Query("DELETE FROM captures WHERE status = 'DONE' AND id NOT IN (SELECT id FROM captures ORDER BY createdAt DESC LIMIT :keep)")
    suspend fun pruneDone(keep: Int)
}
