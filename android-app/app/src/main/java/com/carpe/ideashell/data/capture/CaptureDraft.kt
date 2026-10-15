package com.carpe.ideashell.data.capture

import android.content.Context

/**
 * 快记面板里写到一半的文字：面板被点到外面 / 返回键关掉时存下来，下次打开自动放回输入框；
 * 提交成功后清掉。存在本机，进程被杀也不丢。
 */
class CaptureDraft(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("capture_draft", Context.MODE_PRIVATE)

    fun load(): String = prefs.getString(KEY, "").orEmpty()

    fun save(text: String) {
        if (text.isBlank()) clear() else prefs.edit().putString(KEY, text).apply()
    }

    fun clear() {
        prefs.edit().remove(KEY).apply()
    }

    private companion object {
        const val KEY = "text"
    }
}
