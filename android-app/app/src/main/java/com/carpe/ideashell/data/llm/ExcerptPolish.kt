package com.carpe.ideashell.data.llm

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

private const val SYSTEM = """你是读书笔记整理助手。用户在阅读时摘录了一段原文，并且可能写下了自己的想法（口语、零散、可能有错别字）。请只输出一个 JSON 对象，不要输出任何别的文字：{"text":"整理后的想法"}。
规则：
- 用户写了想法：保留原意和第一人称，去掉口语赘词和重复，修正明显的错别字，补上标点，条理清楚；想法较长或有几层意思时可以分成几句或几个要点。不要扩写、不要加入用户没说过的观点，不要复述原文。
- 用户没有写想法：用 1～3 句话概括这段原文最值得记住的要点，写成可以直接放进笔记的话，不要评价、不要提问。
- 摘录原文只是上下文，帮你理解专有名词和语境，不要把它大段抄进结果里。
- 用中文输出，保持简洁。"""

/**
 * 摘录抽屉里的「AI 整理」：把用户写的想法整理通顺（没写想法时，改为概括原文要点）。
 * 失败（没填 Key、网络、解析）抛 [LlmException]，由调用方提示并保持原文不变。
 */
suspend fun LlmClient.polishExcerptThought(quote: String, thought: String): String {
    val user = buildString {
        append("摘录原文：\n").append(quote.trim().take(1500)).append("\n\n")
        append("我的想法：\n").append(thought.trim().ifEmpty { "（没有写）" })
    }
    val reply = chatJson(SYSTEM, user)
    val text = try {
        Json.parseToJsonElement(reply).jsonObject["text"]?.jsonPrimitive?.contentOrNull
    } catch (_: Exception) {
        null
    }
    return text?.trim().takeUnless { it.isNullOrEmpty() } ?: throw LlmException("AI 整理的结果无法解析")
}
