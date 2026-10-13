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
    /** 相机页上「识别文字」开关的上次状态 */
    val ocrEnabled: Boolean = false,
    /** 识别页的选择方式：false = 划选识别，true = 选择框（先框出识别区域再识别） */
    val ocrFrameMode: Boolean = false,
    /** 每晚 23:20 自动生成今日小结 */
    val autoDaySummary: Boolean = true,
) {
    val defaultTags: List<String>
        get() = defaultTagsText.split(',', '，').map { it.trim().removePrefix("#") }.filter { it.isNotEmpty() }

    companion object {
        const val DEFAULT_DAILY_FOLDER = "Daily Notes"
        const val DEFAULT_FOCUS_GOAL_MIN = 120
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

    fun setOcrEnabled(enabled: Boolean) = update { it.copy(ocrEnabled = enabled) }

    fun setOcrFrameMode(frame: Boolean) = update { it.copy(ocrFrameMode = frame) }

    fun setAutoDaySummary(enabled: Boolean) = update { it.copy(autoDaySummary = enabled) }

    private fun update(transform: (AppSettings) -> AppSettings) {
        val next = transform(_state.value)
        prefs.edit()
            .putString(KEY_TAGS, next.defaultTagsText)
            .putString(KEY_DAILY_FOLDER, next.dailyFolder)
            .putString(KEY_THEME, next.themeMode.name)
            .putBoolean(KEY_PERSISTENT_NOTIFICATION, next.persistentNotification)
            .putInt(KEY_FOCUS_GOAL, next.focusGoalMin)
            .putBoolean(KEY_OCR_ENABLED, next.ocrEnabled)
            .putBoolean(KEY_OCR_FRAME, next.ocrFrameMode)
            .putBoolean(KEY_AUTO_SUMMARY, next.autoDaySummary)
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
        ocrEnabled = prefs.getBoolean(KEY_OCR_ENABLED, false),
        ocrFrameMode = prefs.getBoolean(KEY_OCR_FRAME, false),
        autoDaySummary = prefs.getBoolean(KEY_AUTO_SUMMARY, true),
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

    private companion object {
        const val KEY_AUTO_SUMMARY = "auto_day_summary"
        const val KEY_AUTO_SUMMARY_DATE = "auto_summary_date"
        const val KEY_FOCUS_GOAL = "focus_goal_min"
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
