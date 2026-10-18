package com.carpe.ideashell.data.settings

import android.content.Context
import com.carpe.ideashell.core.parse.FolderInfo
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

enum class ThemeMode(val label: String) {
    SYSTEM("跟随系统"),
    LIGHT("浅色"),
    DARK("深色"),
}

data class AppSettings(
    /** 创建笔记时默认附加的标签（逗号分隔的原始文本） */
    val defaultTagsText: String = "",
    val dailyFolder: String = DEFAULT_DAILY_FOLDER,
    val themeMode: ThemeMode = ThemeMode.SYSTEM,
    /** 通知栏常驻「今天 N · 逾期 M」，可直接回复快记、点完成 */
    val persistentNotification: Boolean = false,
    /** 每日专注目标（分钟）：「今天」页专注环以它为满环 */
    val focusGoalMin: Int = DEFAULT_FOCUS_GOAL_MIN,
    /** 专注（番茄）自然走完后自动开始休息倒计时；关闭时只在通知 / 专注页上给出「开始休息」 */
    val autoBreak: Boolean = false,
    /** 短休息 / 长休息的默认时长（分钟） */
    val shortBreakMin: Int = DEFAULT_SHORT_BREAK_MIN,
    val longBreakMin: Int = DEFAULT_LONG_BREAK_MIN,
    /** 相机页上「识别文字」开关的上次状态 */
    val ocrEnabled: Boolean = false,
    /** 识别页的选择方式：false = 划选识别，true = 选择框（先框出识别区域再识别） */
    val ocrFrameMode: Boolean = false,
    /** 每晚 23:20 自动生成今日小结 */
    val autoDaySummary: Boolean = true,
    /** 笔记重温：目标记忆率（百分比，80–95） */
    val revisitRetention: Int = DEFAULT_REVISIT_RETENTION,
    /** 笔记重温：每天最多出现几条 */
    val revisitDailyLimit: Int = DEFAULT_REVISIT_LIMIT,
    /** 笔记重温：每天固定时间提醒 */
    val revisitReminder: Boolean = true,
    /** 笔记重温：提醒时刻（当天 0 点起的分钟数） */
    val revisitReminderMinutes: Int = DEFAULT_REVISIT_MINUTES,
    /** 笔记重温：周六、周日不提醒（今天页的卡片仍然会出现） */
    val revisitSkipWeekends: Boolean = false,
    /** 笔记重温：填空模式，把正文里的关键词挖空，先回忆再看答案 */
    val revisitCloze: Boolean = false,
    /** 自动挖空的比例范围（挖掉的字数占正文的百分比）：每次重温在 min–max 之间随机取一个目标 */
    val clozeMinPercent: Int = DEFAULT_CLOZE_MIN,
    val clozeMaxPercent: Int = DEFAULT_CLOZE_MAX,
    /** 每周自动把备份写进闪念贝壳（需要已连接闪念贝壳、有网络） */
    val autoCloudBackup: Boolean = false,
    /** 转交问题到闪念贝壳 AI 后自动点发送（需要开启无障碍服务） */
    val aiAutoSend: Boolean = false,
    /** 摘录模式：开启后屏幕边缘有闪电小胶囊，选中文字后点一下就摘录（需要开启「拾忆 · 快速摘录」无障碍服务） */
    val excerptMode: Boolean = false,
    /** 摘录后是否弹出抽屉写想法（来源 / 标签在同一个 App 里延续）；关闭则直接存原文 + 来源 */
    val excerptWriteNote: Boolean = true,
    /** 快记面板的「按住说话」（需要腾讯云密钥，并开通语音识别） */
    val voiceEnabled: Boolean = true,
    /** 语音识别后用大模型去口语、判断类型、推算日期时间（需要填大模型 Key；失败自动退回原始转写） */
    val voicePolish: Boolean = true,
    /** 松手识别完直接保存，不再等你确认（语音误识别比打字风险高，默认关） */
    val voiceAutoSend: Boolean = false,
    /** 本地 SenseVoice 识别（断网 / 云端识别失败时兜底；需要先下载模型） */
    val voiceLocal: Boolean = false,
    /** 大模型接口（OpenAI 兼容）：地址和模型名；Key 在 CredentialStore 里 */
    val llmBaseUrl: String = DEFAULT_LLM_BASE_URL,
    val llmModel: String = DEFAULT_LLM_MODEL,
) {
    val defaultTags: List<String>
        get() = defaultTagsText.split(',', '，').map { it.trim().removePrefix("#") }.filter { it.isNotEmpty() }

    companion object {
        const val DEFAULT_DAILY_FOLDER = "Daily Notes"
        const val DEFAULT_FOCUS_GOAL_MIN = 120
        const val DEFAULT_SHORT_BREAK_MIN = 5
        const val DEFAULT_LONG_BREAK_MIN = 15
        const val DEFAULT_REVISIT_RETENTION = 90
        const val DEFAULT_CLOZE_MIN = 10
        const val DEFAULT_CLOZE_MAX = 25
        const val DEFAULT_REVISIT_LIMIT = 5
        const val DEFAULT_REVISIT_MINUTES = 20 * 60
        /** 通义千问（阿里云百炼）的 OpenAI 兼容接口；换成 DeepSeek 等只需改地址和模型名 */
        const val DEFAULT_LLM_BASE_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
        const val DEFAULT_LLM_MODEL = "qwen-plus"
    }
}

/** 普通偏好 + 本地缓存（文件夹列表、今日 Daily Note 的 id）。凭证不放这里，见 SecureStore。 */
class SettingsStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }

    private val _state = MutableStateFlow(load())
    val state: StateFlow<AppSettings> = _state.asStateFlow()

    val current: AppSettings get() = _state.value

    fun setDefaultTags(text: String) = update { it.copy(defaultTagsText = text.trim()) }

    fun setDailyFolder(name: String) =
        update { it.copy(dailyFolder = name.trim().ifEmpty { AppSettings.DEFAULT_DAILY_FOLDER }) }

    fun setThemeMode(mode: ThemeMode) = update { it.copy(themeMode = mode) }

    fun setPersistentNotification(enabled: Boolean) = update { it.copy(persistentNotification = enabled) }

    fun setFocusGoalMin(minutes: Int) = update { it.copy(focusGoalMin = minutes.coerceIn(10, 720)) }

    fun setAutoBreak(enabled: Boolean) = update { it.copy(autoBreak = enabled) }

    fun setShortBreakMin(minutes: Int) = update { it.copy(shortBreakMin = minutes.coerceIn(1, 60)) }

    fun setLongBreakMin(minutes: Int) = update { it.copy(longBreakMin = minutes.coerceIn(1, 60)) }

    fun setOcrEnabled(enabled: Boolean) = update { it.copy(ocrEnabled = enabled) }

    fun setOcrFrameMode(frame: Boolean) = update { it.copy(ocrFrameMode = frame) }

    fun setAutoDaySummary(enabled: Boolean) = update { it.copy(autoDaySummary = enabled) }

    fun setRevisitRetention(percent: Int) = update { it.copy(revisitRetention = percent.coerceIn(80, 95)) }

    fun setRevisitDailyLimit(count: Int) = update { it.copy(revisitDailyLimit = count.coerceIn(1, 50)) }

    fun setRevisitReminder(enabled: Boolean) = update { it.copy(revisitReminder = enabled) }

    fun setRevisitReminderMinutes(minutes: Int) = update { it.copy(revisitReminderMinutes = minutes.coerceIn(0, 24 * 60 - 1)) }

    fun setRevisitSkipWeekends(skip: Boolean) = update { it.copy(revisitSkipWeekends = skip) }

    fun setRevisitCloze(enabled: Boolean) = update { it.copy(revisitCloze = enabled) }

    fun setClozeRange(minPercent: Int, maxPercent: Int) = update {
        val lo = minPercent.coerceIn(3, 80)
        it.copy(clozeMinPercent = lo, clozeMaxPercent = maxPercent.coerceIn(lo, 80))
    }

    fun setAiAutoSend(enabled: Boolean) = update { it.copy(aiAutoSend = enabled) }

    fun setExcerptMode(enabled: Boolean) = update { it.copy(excerptMode = enabled) }

    fun setExcerptWriteNote(enabled: Boolean) = update { it.copy(excerptWriteNote = enabled) }

    fun setAutoCloudBackup(enabled: Boolean) = update { it.copy(autoCloudBackup = enabled) }

    fun setVoiceEnabled(enabled: Boolean) = update { it.copy(voiceEnabled = enabled) }

    fun setVoicePolish(enabled: Boolean) = update { it.copy(voicePolish = enabled) }

    fun setVoiceAutoSend(enabled: Boolean) = update { it.copy(voiceAutoSend = enabled) }

    fun setVoiceLocal(enabled: Boolean) = update { it.copy(voiceLocal = enabled) }

    fun setLlm(baseUrl: String, model: String) = update {
        it.copy(
            llmBaseUrl = baseUrl.trim().trimEnd('/').ifEmpty { AppSettings.DEFAULT_LLM_BASE_URL },
            llmModel = model.trim().ifEmpty { AppSettings.DEFAULT_LLM_MODEL },
        )
    }

    private fun update(transform: (AppSettings) -> AppSettings) {
        val next = transform(_state.value)
        prefs.edit()
            .putString(KEY_TAGS, next.defaultTagsText)
            .putString(KEY_DAILY_FOLDER, next.dailyFolder)
            .putString(KEY_THEME, next.themeMode.name)
            .putBoolean(KEY_PERSISTENT_NOTIFICATION, next.persistentNotification)
            .putInt(KEY_FOCUS_GOAL, next.focusGoalMin)
            .putBoolean(KEY_AUTO_BREAK, next.autoBreak)
            .putInt(KEY_SHORT_BREAK, next.shortBreakMin)
            .putInt(KEY_LONG_BREAK, next.longBreakMin)
            .putBoolean(KEY_OCR_ENABLED, next.ocrEnabled)
            .putBoolean(KEY_OCR_FRAME, next.ocrFrameMode)
            .putBoolean(KEY_AUTO_SUMMARY, next.autoDaySummary)
            .putInt(KEY_REVISIT_RETENTION, next.revisitRetention)
            .putInt(KEY_REVISIT_LIMIT, next.revisitDailyLimit)
            .putBoolean(KEY_REVISIT_REMINDER, next.revisitReminder)
            .putInt(KEY_REVISIT_MINUTES, next.revisitReminderMinutes)
            .putBoolean(KEY_REVISIT_SKIP_WEEKENDS, next.revisitSkipWeekends)
            .putBoolean(KEY_AUTO_CLOUD_BACKUP, next.autoCloudBackup)
            .putBoolean(KEY_REVISIT_CLOZE, next.revisitCloze)
            .putInt(KEY_CLOZE_MIN, next.clozeMinPercent)
            .putInt(KEY_CLOZE_MAX, next.clozeMaxPercent)
            .putBoolean(KEY_AI_AUTO_SEND, next.aiAutoSend)
            .putBoolean(KEY_EXCERPT_MODE, next.excerptMode)
            .putBoolean(KEY_EXCERPT_WRITE_NOTE, next.excerptWriteNote)
            .putBoolean(KEY_VOICE_ENABLED, next.voiceEnabled)
            .putBoolean(KEY_VOICE_POLISH, next.voicePolish)
            .putBoolean(KEY_VOICE_AUTO_SEND, next.voiceAutoSend)
            .putBoolean(KEY_VOICE_LOCAL, next.voiceLocal)
            .putString(KEY_LLM_BASE_URL, next.llmBaseUrl)
            .putString(KEY_LLM_MODEL, next.llmModel)
            .apply()
        _state.value = next
    }

    private fun load(): AppSettings = AppSettings(
        defaultTagsText = prefs.getString(KEY_TAGS, "").orEmpty(),
        dailyFolder = prefs.getString(KEY_DAILY_FOLDER, null)?.ifBlank { null } ?: AppSettings.DEFAULT_DAILY_FOLDER,
        themeMode = runCatching { ThemeMode.valueOf(prefs.getString(KEY_THEME, null).orEmpty()) }
            .getOrDefault(ThemeMode.SYSTEM),
        persistentNotification = prefs.getBoolean(KEY_PERSISTENT_NOTIFICATION, false),
        focusGoalMin = prefs.getInt(KEY_FOCUS_GOAL, AppSettings.DEFAULT_FOCUS_GOAL_MIN),
        autoBreak = prefs.getBoolean(KEY_AUTO_BREAK, false),
        shortBreakMin = prefs.getInt(KEY_SHORT_BREAK, AppSettings.DEFAULT_SHORT_BREAK_MIN),
        longBreakMin = prefs.getInt(KEY_LONG_BREAK, AppSettings.DEFAULT_LONG_BREAK_MIN),
        ocrEnabled = prefs.getBoolean(KEY_OCR_ENABLED, false),
        ocrFrameMode = prefs.getBoolean(KEY_OCR_FRAME, false),
        autoDaySummary = prefs.getBoolean(KEY_AUTO_SUMMARY, true),
        revisitRetention = prefs.getInt(KEY_REVISIT_RETENTION, AppSettings.DEFAULT_REVISIT_RETENTION).coerceIn(80, 95),
        revisitDailyLimit = prefs.getInt(KEY_REVISIT_LIMIT, AppSettings.DEFAULT_REVISIT_LIMIT).coerceIn(1, 50),
        revisitReminder = prefs.getBoolean(KEY_REVISIT_REMINDER, true),
        revisitReminderMinutes = prefs.getInt(KEY_REVISIT_MINUTES, AppSettings.DEFAULT_REVISIT_MINUTES).coerceIn(0, 24 * 60 - 1),
        revisitSkipWeekends = prefs.getBoolean(KEY_REVISIT_SKIP_WEEKENDS, false),
        autoCloudBackup = prefs.getBoolean(KEY_AUTO_CLOUD_BACKUP, false),
        revisitCloze = prefs.getBoolean(KEY_REVISIT_CLOZE, false),
        clozeMinPercent = prefs.getInt(KEY_CLOZE_MIN, AppSettings.DEFAULT_CLOZE_MIN).coerceIn(3, 80),
        clozeMaxPercent = prefs.getInt(KEY_CLOZE_MAX, AppSettings.DEFAULT_CLOZE_MAX).coerceIn(3, 80),
        aiAutoSend = prefs.getBoolean(KEY_AI_AUTO_SEND, false),
        excerptMode = prefs.getBoolean(KEY_EXCERPT_MODE, false),
        excerptWriteNote = prefs.getBoolean(KEY_EXCERPT_WRITE_NOTE, true),
        voiceEnabled = prefs.getBoolean(KEY_VOICE_ENABLED, true),
        voicePolish = prefs.getBoolean(KEY_VOICE_POLISH, true),
        voiceAutoSend = prefs.getBoolean(KEY_VOICE_AUTO_SEND, false),
        voiceLocal = prefs.getBoolean(KEY_VOICE_LOCAL, false),
        llmBaseUrl = prefs.getString(KEY_LLM_BASE_URL, null)?.ifBlank { null } ?: AppSettings.DEFAULT_LLM_BASE_URL,
        llmModel = prefs.getString(KEY_LLM_MODEL, null)?.ifBlank { null } ?: AppSettings.DEFAULT_LLM_MODEL,
    )

    // ── 文件夹缓存 ──

    fun loadFolders(): List<FolderInfo> =
        try {
            prefs.getString(KEY_FOLDERS, null)
                ?.let { json.decodeFromString(ListSerializer(FolderInfo.serializer()), it) }
                .orEmpty()
        } catch (_: Exception) {
            emptyList()
        }

    fun saveFolders(list: List<FolderInfo>) {
        prefs.edit()
            .putString(KEY_FOLDERS, json.encodeToString(ListSerializer(FolderInfo.serializer()), list))
            .putLong(KEY_FOLDERS_AT, System.currentTimeMillis())
            .apply()
    }

    fun foldersCachedAt(): Long = prefs.getLong(KEY_FOLDERS_AT, 0L)

    // ── 今天 Daily Note 的 note_id 缓存（按日期） ──

    fun dailyNoteId(date: String): String? = prefs.getString("$KEY_DAILY_ID_PREFIX$date", null)

    fun setDailyNoteId(date: String, noteId: String) {
        prefs.edit().putString("$KEY_DAILY_ID_PREFIX$date", noteId).apply()
    }

    fun clearDailyNoteId(date: String) {
        prefs.edit().remove("$KEY_DAILY_ID_PREFIX$date").apply()
    }

    // ── 过去某天 Daily Note 的条目数缓存（热力图用；过去的日子基本不会再变） ──

    fun dailyEntryCount(date: String): Int? =
        prefs.getInt("$KEY_DAILY_COUNT_PREFIX$date", -1).takeIf { it >= 0 }

    fun setDailyEntryCount(date: String, count: Int) {
        prefs.edit().putInt("$KEY_DAILY_COUNT_PREFIX$date", count).apply()
    }

    // ── 自动今日小结：最近一次自动生成的日期（yyyy-MM-dd），一天只自动生成一次 ──

    fun lastAutoSummaryDate(): String? = prefs.getString(KEY_AUTO_SUMMARY_DATE, null)

    fun setLastAutoSummaryDate(date: String) {
        prefs.edit().putString(KEY_AUTO_SUMMARY_DATE, date).apply()
    }

    // ── 闪念贝壳里的备份笔记：id 和最近一次备份的时间 ──

    fun backupNoteId(): String? = prefs.getString(KEY_BACKUP_NOTE_ID, null)

    fun setBackupNoteId(id: String) {
        prefs.edit().putString(KEY_BACKUP_NOTE_ID, id).apply()
    }

    fun cloudBackupAt(): Long = prefs.getLong(KEY_CLOUD_BACKUP_AT, 0L)

    fun setCloudBackupAt(ms: Long) {
        prefs.edit().putLong(KEY_CLOUD_BACKUP_AT, ms).apply()
    }

    /** 最近一次自动备份失败的原因；成功后清空（设置页里显示，方便知道为什么没备份上） */
    fun autoBackupError(): String? = prefs.getString(KEY_AUTO_BACKUP_ERROR, null)?.ifBlank { null }

    fun setAutoBackupError(message: String?) {
        prefs.edit().putString(KEY_AUTO_BACKUP_ERROR, message.orEmpty()).apply()
    }

    /** 最近搜索：最新的在前，换行分隔存一份，退出应用后还在 */
    fun recentSearches(): List<String> =
        prefs.getString(KEY_RECENT_SEARCHES, null)?.split('\n')?.filter { it.isNotBlank() }.orEmpty()

    fun setRecentSearches(list: List<String>) {
        prefs.edit().putString(KEY_RECENT_SEARCHES, list.joinToString("\n")).apply()
    }

    /** 同步异常的提示只发一次：发过之后记着，等队列恢复正常再清掉 */
    fun syncAlerted(): Boolean = prefs.getBoolean(KEY_SYNC_ALERTED, false)

    fun setSyncAlerted(alerted: Boolean) {
        prefs.edit().putBoolean(KEY_SYNC_ALERTED, alerted).apply()
    }

    private companion object {
        const val KEY_RECENT_SEARCHES = "recent_searches"
        const val KEY_REVISIT_CLOZE = "revisit_cloze"
        const val KEY_CLOZE_MIN = "cloze_min_percent"
        const val KEY_CLOZE_MAX = "cloze_max_percent"
        const val KEY_AI_AUTO_SEND = "ai_auto_send"
        const val KEY_EXCERPT_MODE = "excerpt_mode"
        const val KEY_EXCERPT_WRITE_NOTE = "excerpt_write_note"
        const val KEY_VOICE_ENABLED = "voice_enabled"
        const val KEY_VOICE_POLISH = "voice_polish"
        const val KEY_VOICE_AUTO_SEND = "voice_auto_send"
        const val KEY_VOICE_LOCAL = "voice_local"
        const val KEY_LLM_BASE_URL = "llm_base_url"
        const val KEY_LLM_MODEL = "llm_model"
        const val KEY_AUTO_CLOUD_BACKUP = "auto_cloud_backup"
        const val KEY_AUTO_BACKUP_ERROR = "auto_backup_error"
        const val KEY_SYNC_ALERTED = "sync_alerted"
        const val KEY_BACKUP_NOTE_ID = "backup_note_id"
        const val KEY_CLOUD_BACKUP_AT = "cloud_backup_at"
        const val KEY_REVISIT_RETENTION = "revisit_retention"
        const val KEY_REVISIT_LIMIT = "revisit_daily_limit"
        const val KEY_REVISIT_REMINDER = "revisit_reminder"
        const val KEY_REVISIT_MINUTES = "revisit_reminder_minutes"
        const val KEY_REVISIT_SKIP_WEEKENDS = "revisit_skip_weekends"
        const val KEY_AUTO_SUMMARY = "auto_day_summary"
        const val KEY_AUTO_SUMMARY_DATE = "auto_summary_date"
        const val KEY_FOCUS_GOAL = "focus_goal_min"
        const val KEY_AUTO_BREAK = "focus_auto_break"
        const val KEY_SHORT_BREAK = "focus_short_break_min"
        const val KEY_LONG_BREAK = "focus_long_break_min"
        const val KEY_OCR_ENABLED = "ocr_enabled"
        const val KEY_OCR_FRAME = "ocr_frame_mode"
        const val KEY_DAILY_COUNT_PREFIX = "daily_count_"
        const val KEY_TAGS = "default_tags"
        const val KEY_DAILY_FOLDER = "daily_folder"
        const val KEY_THEME = "theme_mode"
        const val KEY_PERSISTENT_NOTIFICATION = "persistent_notification"
        const val KEY_FOLDERS = "folders_cache"
        const val KEY_FOLDERS_AT = "folders_cache_at"
        const val KEY_DAILY_ID_PREFIX = "daily_note_id_"
    }
}
