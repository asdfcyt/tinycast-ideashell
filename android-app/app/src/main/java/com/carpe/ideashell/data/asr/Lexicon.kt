package com.carpe.ideashell.data.asr

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject

/** 语音词库：热词（专有名词，识别时优先、也告诉大模型）+ 替换规则（总是被听错的词 → 正确写法） */
data class LexiconData(
    val hotwords: List<String> = emptyList(),
    val replacements: List<Pair<String, String>> = emptyList(),
)

/**
 * 本机的语音词库，存在 SharedPreferences 里（不含任何凭证）。
 * - [apply]：语音识别出文字后先按替换规则改一遍；
 * - [hotwordsFor]：热词 + 额外词（项目 / 文件夹名），给腾讯云和大模型；
 * - [addReplacement]：快记面板里点「纠错」时记下一条，下次自动改对。
 */
class Lexicon(context: Context) {
    private val prefs = context.getSharedPreferences("voice_lexicon", Context.MODE_PRIVATE)
    private val _state = MutableStateFlow(load())
    val state: StateFlow<LexiconData> = _state.asStateFlow()
    val current: LexiconData get() = _state.value

    fun save(hotwords: List<String>, replacements: List<Pair<String, String>>) {
        val data = LexiconData(
            hotwords = hotwords.map(String::trim).filter { it.isNotEmpty() }.distinct(),
            replacements = replacements
                .map { it.first.trim() to it.second.trim() }
                .filter { (from, to) -> from.isNotEmpty() && from != to }
                .distinctBy { it.first },
        )
        _state.value = data
        prefs.edit().putString(KEY, encode(data)).apply()
    }

    /** 纠错学习：同一个错字再记一次就覆盖旧的；正确写法如果是个像样的词，也顺手加进热词 */
    fun addReplacement(from: String, to: String) {
        val f = from.trim()
        val t = to.trim()
        if (f.isEmpty() || t.isEmpty() || f == t) return
        val data = current
        val hot = if (t.length in 2..MAX_HOTWORD_LEN && t !in data.hotwords) data.hotwords + t else data.hotwords
        save(hot, data.replacements.filterNot { it.first == f } + (f to t))
    }

    /** 按替换规则改一遍（长的先换，避免短词把长词拆坏） */
    fun apply(text: String): String {
        var out = text
        current.replacements.sortedByDescending { it.first.length }.forEach { (from, to) ->
            if (from.isNotEmpty()) out = out.replace(from, to)
        }
        return out
    }

    /** 热词 + 额外词，去重、过滤掉不适合当热词的，最多 [MAX_HOTWORDS] 个 */
    fun hotwordsFor(extra: List<String>): List<String> =
        (current.hotwords + extra).map(String::trim).filter(::isValidHotword).distinct().take(MAX_HOTWORDS)

    private fun load(): LexiconData {
        val raw = prefs.getString(KEY, null) ?: return LexiconData()
        return try {
            val obj = Json.parseToJsonElement(raw).jsonObject
            LexiconData(
                hotwords = (obj["hot"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull },
                replacements = (obj["rep"] as? JsonArray).orEmpty().mapNotNull { item ->
                    val pair = item as? JsonArray ?: return@mapNotNull null
                    val from = (pair.getOrNull(0) as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
                    val to = (pair.getOrNull(1) as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
                    from to to
                },
            )
        } catch (_: Exception) {
            LexiconData()
        }
    }

    private fun encode(data: LexiconData): String = buildJsonObject {
        put("hot", buildJsonArray { data.hotwords.forEach { add(JsonPrimitive(it)) } })
        put("rep", buildJsonArray {
            data.replacements.forEach { (from, to) -> add(buildJsonArray { add(JsonPrimitive(from)); add(JsonPrimitive(to)) }) }
        })
    }.toString()

    companion object {
        private const val KEY = "lexicon"
        const val MAX_HOTWORDS = 100
        private const val MAX_HOTWORD_LEN = 10

        /** 腾讯云热词只收文字和数字，2–10 个字 */
        fun isValidHotword(word: String): Boolean =
            word.length in 2..MAX_HOTWORD_LEN && word.all { it.isLetterOrDigit() }

        /** 设置里的文本框 ↔ 数据：热词用换行 / 逗号 / 顿号分隔 */
        fun parseHotwords(text: String): List<String> =
            text.split('\n', ',', '，', '、', ';', '；').map(String::trim).filter { it.isNotEmpty() }

        /** 每行一条：「错字=正确」，也认 → 和 -> */
        fun parseReplacements(text: String): List<Pair<String, String>> =
            text.lines().mapNotNull { line ->
                val parts = line.split("->", "→", "=", "＝", limit = 2)
                if (parts.size < 2) null else parts[0].trim() to parts[1].trim()
            }.filter { it.first.isNotEmpty() && it.second.isNotEmpty() }

        fun formatReplacements(list: List<Pair<String, String>>): String =
            list.joinToString("\n") { "${it.first}=${it.second}" }
    }
}
