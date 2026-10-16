package com.carpe.ideashell.data.capture

import android.content.Context

/**
 * 快记面板最近一次保存成的那篇笔记（同步成功后记下）：面板上的「追加」按钮把新内容接到它后面。
 * 存在本机，进程被杀也不丢。
 */
class LastNoteStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("last_note", Context.MODE_PRIVATE)

    data class Note(val id: String, val title: String)

    fun get(): Note? {
        val id = prefs.getString(KEY_ID, null)?.takeIf { it.isNotBlank() } ?: return null
        return Note(id, prefs.getString(KEY_TITLE, "").orEmpty())
    }

    fun set(id: String, title: String) {
        prefs.edit().putString(KEY_ID, id).putString(KEY_TITLE, title).apply()
    }

    private companion object {
        const val KEY_ID = "id"
        const val KEY_TITLE = "title"
    }
}
