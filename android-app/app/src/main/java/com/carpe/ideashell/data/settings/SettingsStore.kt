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
) {
    val defaultTags: List<String>
        get() = defaultTagsText.split(',', '，').map { it.trim().removePrefix("#") }.filter { it.isNotEmpty() }

    companion object {
        const val DEFAULT_DAILY_FOLDER = "Daily Notes"
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

    private fun update(transform: (AppSettings) -> AppSettings) {
        val next = transform(_state.value)
        prefs.edit()
            .putString(KEY_TAGS, next.defaultTagsText)
            .putString(KEY_DAILY_FOLDER, next.dailyFolder)
            .putString(KEY_THEME, next.themeMode.name)
            .putBoolean(KEY_PERSISTENT_NOTIFICATION, next.persistentNotification)
            .apply()
        _state.value = next
    }

    private fun load(): AppSettings = AppSettings(
        defaultTagsText = prefs.getString(KEY_TAGS, "").orEmpty(),
        dailyFolder = prefs.getString(KEY_DAILY_FOLDER, null)?.ifBlank { null } ?: AppSettings.DEFAULT_DAILY_FOLDER,
        themeMode = runCatching { ThemeMode.valueOf(prefs.getString(KEY_THEME, null).orEmpty()) }
            .getOrDefault(ThemeMode.SYSTEM),
        persistentNotification = prefs.getBoolean(KEY_PERSISTENT_NOTIFICATION, false),
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

    private companion object {
        const val KEY_TAGS = "default_tags"
        const val KEY_DAILY_FOLDER = "daily_folder"
        const val KEY_THEME = "theme_mode"
        const val KEY_PERSISTENT_NOTIFICATION = "persistent_notification"
        const val KEY_FOLDERS = "folders_cache"
        const val KEY_FOLDERS_AT = "folders_cache_at"
        const val KEY_DAILY_ID_PREFIX = "daily_note_id_"
    }
}
