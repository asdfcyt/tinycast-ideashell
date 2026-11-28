package com.carpe.ideashell.data.assistant

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

/** [name] 是用户一句话就能叫出来的名字（「下班」「睡前」），[steps] 是要助手依次办的事（自然语言，脱离上下文也能照做） */
@Serializable
data class Skill(
    val id: String,
    val name: String,
    val steps: String,
    val createdAt: Long,
    val uses: Int = 0,
    val lastUsedAt: Long = 0L,
)

/**
 * 助手的「技能」（快捷指令）：把一件高频的多步任务存成一句话。
 * 说出名字，助手就按存好的步骤依次办完；也可以直接说「把刚才这些存成快捷指令，叫下班」让助手帮你存。
 * 只存在本机；存的是步骤的文字描述，不是录像，所以换了天气 / 日期也照样能跑。
 */
class AssistantSkills(context: Context) {
    private val file = File(context.filesDir, "assistant_skills.json")
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true }
    private val _state = MutableStateFlow(load())
    val state: StateFlow<List<Skill>> = _state.asStateFlow()

    /** 存一个技能；同名的覆盖（保留使用次数）。名字 / 步骤不合格返回失败原因 */
    @Synchronized
    fun save(name: String, steps: String): Result<Skill> {
        val n = name.trim().trim('「', '」', '"').take(MAX_NAME)
        val s = steps.trim().take(MAX_STEPS)
        if (n.isEmpty()) return Result.failure(IllegalArgumentException("缺少快捷指令的名字"))
        if (s.length < 4) return Result.failure(IllegalArgumentException("缺少要办的步骤"))
        if (SENSITIVE.containsMatchIn(s)) return Result.failure(IllegalArgumentException("步骤里有密码 / 验证码 / 卡号之类的敏感信息，我不存"))
        val old = _state.value.firstOrNull { it.name.equals(n, ignoreCase = true) }
        val item = Skill(old?.id ?: System.currentTimeMillis().toString(), n, s, old?.createdAt ?: System.currentTimeMillis(), old?.uses ?: 0, old?.lastUsedAt ?: 0L)
        publish((_state.value.filterNot { it.id == item.id } + item).takeLast(MAX_ITEMS))
        return Result.success(item)
    }

    @Synchronized
    fun remove(id: String) = publish(_state.value.filterNot { it.id == id })

    /** 按名字删；返回删掉的 */
    @Synchronized
    fun removeByName(name: String): Skill? {
        val n = name.trim().trim('「', '」')
        val hit = _state.value.firstOrNull { it.name.equals(n, ignoreCase = true) } ?: _state.value.firstOrNull { n.isNotEmpty() && it.name.contains(n, ignoreCase = true) } ?: return null
        publish(_state.value - hit)
        return hit
    }

    /** 助手真的按某个技能办过事之后调用，记使用次数 */
    @Synchronized
    fun recordUse(name: String) {
        val n = name.trim().trim('「', '」')
        val now = System.currentTimeMillis()
        publish(_state.value.map { if (it.name.equals(n, ignoreCase = true)) it.copy(uses = it.uses + 1, lastUsedAt = now) else it })
    }

    /** 整理意图时给大模型看的技能名（让「下班」这类一个词的口令也能认成「执行快捷指令」） */
    fun names(): List<String> = _state.value.map { it.name }

    /** 放进助手提示词的技能名（步骤太长，等助手真要办时用 run_skill 取）；没有就是 null */
    fun promptBlock(): String? {
        val list = _state.value
        if (list.isEmpty()) return null
        return list.joinToString("、") { "「${it.name}」" }
    }

    private fun publish(list: List<Skill>) {
        _state.value = list
        runCatching { file.writeText(json.encodeToString(list)) }
    }

    private fun load(): List<Skill> = runCatching {
        if (!file.isFile) emptyList() else json.decodeFromString<List<Skill>>(file.readText())
    }.getOrDefault(emptyList())

    private companion object {
        const val MAX_ITEMS = 30
        const val MAX_NAME = 12
        const val MAX_STEPS = 400
        val SENSITIVE = Regex("密码|口令|验证码|银行卡|卡号|身份证号|cvv|secret|api[ _-]?key|token|密钥|\\d{15,}", RegexOption.IGNORE_CASE)
    }
}
