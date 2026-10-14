package com.carpe.ideashell.data.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(entities = [CaptureEntity::class, RevisitEntity::class, RevisitLogEntity::class], version = 6, exportSchema = false)
abstract class AppDatabase : RoomDatabase() {
    abstract fun captureDao(): CaptureDao
    abstract fun revisitDao(): RevisitDao

    companion object {
        fun create(context: Context): AppDatabase =
            Room.databaseBuilder(context.applicationContext, AppDatabase::class.java, "ideashell.db")
                .addMigrations(MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4, MIGRATION_4_5, MIGRATION_5_6)
                .build()

        /**
         * v6：新增「重温流水」表（每次评分一行，间隔复习的折线图用）；
         * 已有条目的上一次评分补成一行，图上至少有「最近一次」的数据
         */
        private val MIGRATION_5_6 = object : Migration(5, 6) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `revisit_logs` (" +
                        "`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, " +
                        "`itemKey` TEXT NOT NULL, " +
                        "`reviewedAt` INTEGER NOT NULL, " +
                        "`rating` INTEGER NOT NULL)",
                )
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_revisit_logs_reviewedAt` ON `revisit_logs` (`reviewedAt`)")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_revisit_logs_itemKey` ON `revisit_logs` (`itemKey`)")
                db.execSQL(
                    "INSERT INTO revisit_logs (itemKey, reviewedAt, rating) " +
                        "SELECT dedupeKey, lastReviewAt, lastRating FROM revisit_items WHERE lastReviewAt > 0",
                )
            }
        }

        /**
         * v5：重温项增加「专题笔记」列（重温页记一笔时，由 Daily Note 的一句话新建的笔记）；
         * 记录增加「重复规则」列（待办的滴答 repeatFlag）
         */
        private val MIGRATION_4_5 = object : Migration(4, 5) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE revisit_items ADD COLUMN topicNoteId TEXT")
                db.execSQL("ALTER TABLE captures ADD COLUMN repeatRule TEXT")
            }
        }

        /** v4：新增「重温项」表（笔记 / 摘录的 FSRS 间隔重温） */
        private val MIGRATION_3_4 = object : Migration(3, 4) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `revisit_items` (" +
                        "`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, " +
                        "`dedupeKey` TEXT NOT NULL, " +
                        "`kind` TEXT NOT NULL, " +
                        "`noteId` TEXT, " +
                        "`title` TEXT NOT NULL, " +
                        "`text` TEXT NOT NULL, " +
                        "`sourceLabel` TEXT NOT NULL, " +
                        "`recordedAt` INTEGER NOT NULL, " +
                        "`addedAt` INTEGER NOT NULL, " +
                        "`stability` REAL NOT NULL, " +
                        "`difficulty` REAL NOT NULL, " +
                        "`due` INTEGER NOT NULL, " +
                        "`reps` INTEGER NOT NULL, " +
                        "`lapses` INTEGER NOT NULL, " +
                        "`lastRating` INTEGER NOT NULL, " +
                        "`lastReviewAt` INTEGER NOT NULL, " +
                        "`skippedUntil` INTEGER NOT NULL, " +
                        "`archived` INTEGER NOT NULL)",
                )
                db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS `index_revisit_items_dedupeKey` ON `revisit_items` (`dedupeKey`)")
            }
        }

        /** v3：记录增加「待办优先级」列 */
        private val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE captures ADD COLUMN priority INTEGER NOT NULL DEFAULT 0")
            }
        }

        /** v2：记录增加「图片」列 */
        private val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE captures ADD COLUMN images TEXT NOT NULL DEFAULT ''")
            }
        }
    }
}
