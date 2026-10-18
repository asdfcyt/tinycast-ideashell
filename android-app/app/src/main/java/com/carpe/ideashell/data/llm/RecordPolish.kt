package com.carpe.ideashell.data.llm

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

private const val SYSTEM = """你是笔记整理助手。用户在专注做某件事的过程中，随手写下了一段记录（想法、进展、卡点，可能是口语、零散、有错别字，或者是拍照识别出来的文字）。请只输出一个 JSON 对象，不要输出任何别的文字：{"text":"整理后的记录"}。
规则：
- 保留原意和第一人称，去掉口语赘词和重复，修正明显的错别字，补上标点，条理清楚；内容较长或有几层意思时，可以分成几句，或用「- 」开头的几个要点。
- 不要扩写，不要加入用户没说过的事实、观点或建议，不要回答问题，不要加标题。
- 拍照识别出的文字：只修正断行和明显的识别错字，保持原文意思。
- 任务名只是上下文，帮你理解专有名词，不要写进结果里。
- 用中文输出，保持简洁。"""

/**
 * 专注「记录」面板里的「AI 整理」：把写下的内容整理通顺。
 * 失败（没填 Key、网络、解析）抛 [LlmException]，由调用方提示并保持原文不变。
 */
suspend fun LlmClient.polishRecord(taskTitle: String, text: String): String {
    val user = buildString {
        if (taskTitle.isNotBlank()) append("正在做：").append(taskTitle.trim().take(200)).append("\n\n")
        append("我写的记录：\n").append(text.trim().take(3000))
    }
    val reply = chatJson(SYSTEM, user)
    val polished = try {
        Json.parseToJsonElement(reply).jsonObject["text"]?.jsonPrimitive?.contentOrNull
    } catch (_: Exception) {
        null
    }
    return polished?.trim().takeUnless { it.isNullOrEmpty() } ?: throw LlmException("AI 整理的结果无法解析")
}
