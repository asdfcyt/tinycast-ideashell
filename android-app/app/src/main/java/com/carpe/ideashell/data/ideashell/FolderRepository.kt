package com.carpe.ideashell.data.ideashell

import com.carpe.ideashell.core.parse.CaptureParser
import com.carpe.ideashell.core.parse.FolderInfo
import com.carpe.ideashell.data.settings.SettingsStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * 文件夹列表：优先用本地缓存（保存时不等网络），过期时后台刷新；没有缓存才同步拉取。
 * 文件夹很少变动，输入框里的「@文件夹」预览和保存都只读缓存。
 */
class FolderRepository(
    private val api: IdeashellApi,
    private val settings: SettingsStore,
    private val scope: CoroutineScope,
    private val hasCredential: () -> Boolean,
) {
    private val fetchLock = Mutex()
    private val _folders = MutableStateFlow(settings.loadFolders())

    /** 当前缓存的文件夹，界面实时预览用 */
    val folders: StateFlow<List<FolderInfo>> = _folders.asStateFlow()

    /** 后台刷新（缓存过期且已填凭证时）；失败静默 */
    fun refreshIfStale(maxAgeMs: Long = STALE_MS) {
        if (!hasCredential()) return
        if (System.currentTimeMillis() - settings.foldersCachedAt() < maxAgeMs && _folders.value.isNotEmpty()) return
        scope.launch { runCatching { refresh() } }
    }

    suspend fun refresh(): List<FolderInfo> = fetchLock.withLock {
        val list = api.listFolders()
        settings.saveFolders(list)
        _folders.value = list
        list
    }

    /** 保存时用：有缓存就直接用，没有才拉取 */
    suspend fun fast(): List<FolderInfo> = _folders.value.ifEmpty { refresh() }

    /** 按名字找文件夹；缓存里没有时拉一次最新的再判断（可能是刚新建的） */
    suspend fun resolve(name: String): FolderInfo? =
        CaptureParser.matchFolder(name, fast()) ?: CaptureParser.matchFolder(name, refresh())

    private companion object {
        const val STALE_MS = 10 * 60 * 1000L
    }
}
