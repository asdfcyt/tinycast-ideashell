package com.carpe.ideashell.data.assistant

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

@Serializable
data class MemoryItem(val id: String, val text: String, val at: Long)

/**
 * 助手记忆：用户明确说「记住……」才记，一条一句话，只存在本机。
 * 设置里可以查看 / 删除；密码、验证码、卡号这类敏感信息一律不记。
 * 每次让助手回答时，把记忆（最多 [PROMPT_MAX] 条）放进提示词。
 */
class AssistantMemory(context: Context) {
    private val file = File(context.filesDir, "assistant_memory.json")
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true }
    private val _state = MutableStateFlow(load())
    val state: StateFlow<List<MemoryItem>> = _state.asStateFlow()

    /** 记一条；敏感内容 / 空内容返回失败原因 */
    @Synchronized
    fun add(text: String): Result<MemoryItem> {
        val t = text.trim().take(MAX_LEN)
        if (t.isEmpty()) return Result.failure(IllegalArgumentException("没有要记的内容"))
        if (SENSITIVE.containsMatchIn(t)) return Result.failure(IllegalArgumentException("这像是密码 / 验证码 / 卡号之类的敏感信息，我不记"))
        _state.value.firstOrNull { it.text == t }?.let { return Result.success(it) }
        val item = MemoryItem(System.currentTimeMillis().toString(), t, System.currentTimeMillis())
        publish((_state.value + item).takeLast(MAX_ITEMS))
        return Result.success(item)
    }

    @Synchronized
    fun remove(id: String) = publish(_state.value.filterNot { it.id == id })

    /** 删掉包含 [keyword] 的记忆；返回删了几条 */
    @Synchronized
    fun removeMatching(keyword: String): List<MemoryItem> {
        val k = keyword.trim()
        if (k.isEmpty()) return emptyList()
        val gone = _state.value.filter { it.text.contains(k, ignoreCase = true) }
        if (gone.isNotEmpty()) publish(_state.value - gone.toSet())
        return gone
    }

    @Synchronized
    fun clear() = publish(emptyList())

    /** 放进提示词的记忆；没有就是 null */
    fun promptBlock(): String? {
        val list = _state.value.takeLast(PROMPT_MAX)
        if (list.isEmpty()) return null
        return list.joinToString("\n") { "· ${it.text}" }
    }

    private fun publish(list: List<MemoryItem>) {
        _state.value = list
        runCatching { file.writeText(json.encodeToString(list)) }
    }

    private fun load(): List<MemoryItem> = runCatching {
        if (!file.isFile) emptyList() else json.decodeFromString<List<MemoryItem>>(file.readText())
    }.getOrDefault(emptyList())

    private companion object {
        const val MAX_ITEMS = 100
        const val PROMPT_MAX = 40
        const val MAX_LEN = 120
        val SENSITIVE = Regex("密码|口令|验证码|银行卡|卡号|身份证号|cvv|secret|api[ _-]?key|token|密钥|\\d{15,}", RegexOption.IGNORE_CASE)
    }
}
