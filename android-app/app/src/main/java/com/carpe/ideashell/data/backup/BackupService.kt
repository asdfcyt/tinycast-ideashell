package com.carpe.ideashell.data.backup

import com.carpe.ideashell.core.template.Template
import com.carpe.ideashell.data.db.RevisitEntity
import com.carpe.ideashell.data.db.RevisitLogEntity
import com.carpe.ideashell.data.ideashell.IdeashellApi
import com.carpe.ideashell.data.ideashell.NoteInfo
import com.carpe.ideashell.data.mcp.McpException
import com.carpe.ideashell.data.project.Workspace
import com.carpe.ideashell.data.project.WorkspaceStore
import com.carpe.ideashell.data.revisit.RevisitRepository
import com.carpe.ideashell.data.settings.AppSettings
import com.carpe.ideashell.data.settings.SettingsStore
import com.carpe.ideashell.data.settings.ThemeMode
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 备份文件里的设置（只放偏好；不含任何凭证，也不含需要系统授权的开关，如常驻通知） */
@Serializable
data class SettingsBackup(
    val defaultTagsText: String = "",
    val dailyFolder: String = AppSettings.DEFAULT_DAILY_FOLDER,
    val themeMode: String = ThemeMode.SYSTEM.name,
    val focusGoalMin: Int = AppSettings.DEFAULT_FOCUS_GOAL_MIN,
    val ocrEnabled: Boolean = false,
    val ocrFrameMode: Boolean = false,
    val autoDaySummary: Boolean = true,
    val revisitRetention: Int = AppSettings.DEFAULT_REVISIT_RETENTION,
    val revisitDailyLimit: Int = AppSettings.DEFAULT_REVISIT_LIMIT,
    val revisitReminder: Boolean = true,
    val revisitReminderMinutes: Int = AppSettings.DEFAULT_REVISIT_MINUTES,
    val revisitSkipWeekends: Boolean = false,
)

/** 备份文件里的一条重温项（和数据库表一一对应，不带本机自增 id） */
@Serializable
data class RevisitItemBackup(
    val dedupeKey: String,
    val kind: String,
    val noteId: String? = null,
    val title: String,
    val text: String,
    val sourceLabel: String,
    val recordedAt: Long,
    val addedAt: Long,
    val stability: Double,
    val difficulty: Double,
    val due: Long,
    val reps: Int,
    val lapses: Int,
    val lastRating: Int,
    val lastReviewAt: Long,
    val skippedUntil: Long,
    val archived: Boolean,
    val topicNoteId: String? = null,
)

@Serializable
data class RevisitLogBackup(val itemKey: String, val reviewedAt: Long, val rating: Int)

/** 整份备份：项目 / 任务笔记 / 模板 / 专注记录（都在 [Workspace] 里）+ 设置 + 重温库与流水 */
@Serializable
data class BackupFile(
    val format: String = FORMAT,
    val version: Int = VERSION,
    val appVersion: String = "",
    val exportedAt: Long = System.currentTimeMillis(),
    val settings: SettingsBackup = SettingsBackup(),
    val workspace: Workspace = Workspace(),
    val revisitItems: List<RevisitItemBackup> = emptyList(),
    val revisitLogs: List<RevisitLogBackup> = emptyList(),
) {
    /** 界面上的一句话概要 */
    fun summary(): String = buildList {
        add("项目 ${workspace.projects.size} 个")
        add("模板 ${workspace.templates.count { !it.builtin }} 个")
        add("专注记录 ${workspace.focusLog.size} 条")
        add("重温 ${revisitItems.size} 条")
    }.joinToString(" · ") + "\n导出于 " + SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.CHINA).format(Date(exportedAt))

    companion object {
        const val FORMAT = "shiyi-backup"
        const val VERSION = 1
    }
}

/** 导入后的结果，界面据此提示 */
data class RestoreResult(
    val projects: Int,
    val templates: Int,
    val revisitAdded: Int,
    val revisitUpdated: Int,
) {
    fun text(): String = "已恢复：项目 $projects 个、模板 $templates 个，重温新增 $revisitAdded 条、更新 $revisitUpdated 条"
}

/**
 * 备份与迁移：把只存在本机的东西（项目 / 任务笔记 / 模板 / 专注记录 / 设置 / 重温库）写成一个 JSON 文件，
 * 或者写进闪念贝壳里一篇专门的备份笔记（换手机时从那里一键恢复）。
 * 凭证（API Key / 口令 / 腾讯云密钥）不会进备份，换机后需要重新填写。
 * 恢复是「合并」：同一个项目 / 模板以备份为准，本机多出来的不删；重温库按条目合并，进度更新的一份生效。
 */
class BackupService(
    private val workspace: WorkspaceStore,
    private val settings: SettingsStore,
    private val revisit: RevisitRepository,
    private val ideashell: IdeashellApi,
    private val appVersion: String,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    suspend fun build(): BackupFile {
        val (items, logs) = revisit.exportAll()
        val s = settings.current
        return BackupFile(
            appVersion = appVersion,
            settings = SettingsBackup(
                defaultTagsText = s.defaultTagsText,
                dailyFolder = s.dailyFolder,
                themeMode = s.themeMode.name,
                focusGoalMin = s.focusGoalMin,
                ocrEnabled = s.ocrEnabled,
                ocrFrameMode = s.ocrFrameMode,
                autoDaySummary = s.autoDaySummary,
                revisitRetention = s.revisitRetention,
                revisitDailyLimit = s.revisitDailyLimit,
                revisitReminder = s.revisitReminder,
                revisitReminderMinutes = s.revisitReminderMinutes,
                revisitSkipWeekends = s.revisitSkipWeekends,
            ),
            workspace = workspace.current,
            revisitItems = items.map { it.toBackup() },
            revisitLogs = logs.map { RevisitLogBackup(it.itemKey, it.reviewedAt, it.rating) },
        )
    }

    fun encode(file: BackupFile, pretty: Boolean = true): String =
        (if (pretty) Json(json) { prettyPrint = true } else json).encodeToString(BackupFile.serializer(), file)

    /** 解析备份；不是本应用的备份、或来自更新的版本时抛 [IllegalArgumentException]（文案可直接给用户看） */
    fun decode(text: String): BackupFile {
        val file = try {
            json.decodeFromString(BackupFile.serializer(), text)
        } catch (e: Exception) {
            throw IllegalArgumentException("这不是拾忆的备份文件")
        }
        require(file.format == BackupFile.FORMAT) { "这不是拾忆的备份文件" }
        require(file.version <= BackupFile.VERSION) { "备份来自更新版本的拾忆（v${file.version}），请先升级应用" }
        return file
    }

    suspend fun restore(file: BackupFile): RestoreResult {
        val incoming = file.workspace
        workspace.update { local ->
            local.copy(
                projects = mergeBy(local.projects, incoming.projects) { it.keyword.lowercase() },
                taskNotes = local.taskNotes + incoming.taskNotes,
                homes = local.homes + incoming.homes,
                templates = mergeBy(local.templates, incoming.templates) { it.name.lowercase() },
                focusLog = (local.focusLog + incoming.focusLog)
                    .distinctBy { Triple(it.project, it.startMs, it.endMs) }
                    .sortedBy { it.startMs }
                    .takeLast(FOCUS_LOG_LIMIT),
            )
        }
        applySettings(file.settings)
        val (added, updated, _) = revisit.importAll(
            file.revisitItems.map { it.toEntity() },
            file.revisitLogs.map { RevisitLogEntity(itemKey = it.itemKey, reviewedAt = it.reviewedAt, rating = it.rating) },
        )
        return RestoreResult(
            projects = incoming.projects.size,
            templates = incoming.templates.count { !it.builtin },
            revisitAdded = added,
            revisitUpdated = updated,
        )
    }

    // ───────────────────────── 闪念贝壳里的备份笔记 ─────────────────────────

    /** 写进（或更新）闪念贝壳里的备份笔记，返回笔记 id；失败抛异常（断网、凭证无效等） */
    suspend fun pushToIdeashell(): String {
        val body = NOTE_HEAD + "\n\n```json\n" + encode(build(), pretty = false) + "\n```"
        settings.backupNoteId()?.let { id ->
            try {
                ideashell.updateNoteBody(id, body)
                settings.setCloudBackupAt(System.currentTimeMillis())
                return id
            } catch (e: CancellationException) {
                throw e
            } catch (_: McpException) {
                // 备份笔记被删了：往下重新建一篇
            }
        }
        val created = ideashell.createNote(title = TITLE, body = body, tags = listOf(TAG), inlineTags = false)
        val id = (RE_NOTE_ID_JSON.find(created) ?: RE_NOTE_ID_TEXT.find(created) ?: RE_NOTE_ID_HEX.find(created))
            ?.groupValues?.get(1)
            ?: error("没有从创建结果里取到笔记 id")
        settings.setBackupNoteId(id)
        settings.setCloudBackupAt(System.currentTimeMillis())
        return id
    }

    /** 从闪念贝壳读回备份笔记（本机没记着它的 id 时按标题搜）；没找到抛异常 */
    suspend fun pullFromIdeashell(): BackupFile {
        val id = settings.backupNoteId()
            ?: ideashell.searchNotes(TITLE, 20).firstOrNull { isBackupNote(it) }?.id
            ?: throw IllegalStateException("闪念贝壳里没有找到备份笔记，请先在旧手机上点「备份到闪念贝壳」")
        val content = ideashell.noteFull(id).content
        val start = content.indexOf("```json")
        val end = content.lastIndexOf("```")
        require(start >= 0 && end > start) { "备份笔记的内容不完整" }
        val text = content.substring(start + "```json".length, end).trim()
        return decode(text).also { settings.setBackupNoteId(id) }
    }

    fun lastCloudBackupAt(): Long = settings.cloudBackupAt()

    private fun applySettings(b: SettingsBackup) {
        settings.setDefaultTags(b.defaultTagsText)
        settings.setDailyFolder(b.dailyFolder)
        runCatching { ThemeMode.valueOf(b.themeMode) }.getOrNull()?.let(settings::setThemeMode)
        settings.setFocusGoalMin(b.focusGoalMin)
        settings.setOcrEnabled(b.ocrEnabled)
        settings.setOcrFrameMode(b.ocrFrameMode)
        settings.setAutoDaySummary(b.autoDaySummary)
        settings.setRevisitRetention(b.revisitRetention)
        settings.setRevisitDailyLimit(b.revisitDailyLimit)
        settings.setRevisitReminder(b.revisitReminder)
        settings.setRevisitReminderMinutes(b.revisitReminderMinutes)
        settings.setRevisitSkipWeekends(b.revisitSkipWeekends)
    }

    companion object {
        const val TITLE = "拾忆备份（请勿删除）"
        const val TAG = "拾忆备份"
        private const val NOTE_HEAD = "这是「拾忆」App 自动生成的备份，换手机时用它一键恢复。请不要手动编辑或删除。"
        private const val FOCUS_LOG_LIMIT = 500

        private val RE_NOTE_ID_JSON = Regex("\"note_id\"\\s*:\\s*\"([^\"]+)\"")
        private val RE_NOTE_ID_TEXT = Regex("note_id[:\\s]+([0-9a-f]{16,})", RegexOption.IGNORE_CASE)
        private val RE_NOTE_ID_HEX = Regex("([a-f0-9]{32})", RegexOption.IGNORE_CASE)

        /** 备份笔记：回顾的时间河、往日回顾里不显示它，免得它混进用户自己的笔记 */
        fun isBackupNote(note: NoteInfo): Boolean =
            note.title == TITLE || note.tags.any { it.removePrefix("#") == TAG }

        /** 以 [incoming] 为准合并：同一个 key 用备份里的，本机独有的保留；顺序是本机在前、新增在后 */
        private fun <T> mergeBy(local: List<T>, incoming: List<T>, key: (T) -> String): List<T> {
            val byKey = incoming.associateBy(key)
            val replaced = local.map { byKey[key(it)] ?: it }
            val have = local.map(key).toSet()
            return replaced + incoming.filter { key(it) !in have }
        }
    }
}

private fun RevisitEntity.toBackup() = RevisitItemBackup(
    dedupeKey = dedupeKey, kind = kind, noteId = noteId, title = title, text = text, sourceLabel = sourceLabel,
    recordedAt = recordedAt, addedAt = addedAt, stability = stability, difficulty = difficulty, due = due,
    reps = reps, lapses = lapses, lastRating = lastRating, lastReviewAt = lastReviewAt, skippedUntil = skippedUntil,
    archived = archived, topicNoteId = topicNoteId,
)

private fun RevisitItemBackup.toEntity() = RevisitEntity(
    dedupeKey = dedupeKey, kind = kind, noteId = noteId, title = title, text = text, sourceLabel = sourceLabel,
    recordedAt = recordedAt, addedAt = addedAt, stability = stability, difficulty = difficulty, due = due,
    reps = reps, lapses = lapses, lastRating = lastRating, lastReviewAt = lastReviewAt, skippedUntil = skippedUntil,
    archived = archived, topicNoteId = topicNoteId,
)
