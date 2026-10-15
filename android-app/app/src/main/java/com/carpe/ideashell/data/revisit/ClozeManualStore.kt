package com.carpe.ideashell.data.revisit

import android.content.Context

/**
 * 重温时手动挖的空：按卡片（dedupeKey）存「正文哈希 + 区间」。正文变了（哈希对不上）就作废，退回自动挖空。
 * 只存在本机（不在备份里）。
 */
class ClozeManualStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("cloze_manual", Context.MODE_PRIVATE)

    fun get(key: String, text: String): List<IntRange>? {
        val raw = prefs.getString(key, null) ?: return null
        val head = raw.substringBefore('|')
        if (head != text.hashCode().toString()) return null
        val list = raw.substringAfter('|', "").split(',').mapNotNull { part ->
            val a = part.substringBefore('-').toIntOrNull() ?: return@mapNotNull null
            val b = part.substringAfter('-', "").toIntOrNull() ?: return@mapNotNull null
            if (a in 0..b) a..b else null
        }
        return list.takeIf { it.isNotEmpty() }
    }

    fun put(key: String, text: String, ranges: List<IntRange>) {
        if (ranges.isEmpty()) return clear(key)
        prefs.edit().putString(key, "${text.hashCode()}|${ranges.joinToString(",") { "${it.first}-${it.last}" }}").apply()
    }

    fun clear(key: String) {
        prefs.edit().remove(key).apply()
    }
}
