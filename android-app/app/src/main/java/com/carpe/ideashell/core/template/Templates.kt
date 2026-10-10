package com.carpe.ideashell.core.template

import com.carpe.ideashell.domain.NoteText
import kotlinx.serialization.Serializable
import java.time.LocalDate

@Serializable
data class TemplateField(
    val name: String,
    /** 多行输入框；否则为单行 */
    val multiline: Boolean = false,
)

@Serializable
data class Template(
    val name: String,
    val fields: List<TemplateField>,
    val tags: List<String> = emptyList(),
    val folderName: String? = null,
    /** 内置模板不可删除 / 编辑，只能被同名的自定义模板覆盖 */
    val builtin: Boolean = false,
)

/** 模板录入的规则（与桌面 `templates.ts` 一致）：标题固定「模板名 日期」，正文每个字段一段 `**字段**：值` */
object Templates {
    private fun f(name: String, multiline: Boolean = false) = TemplateField(name, multiline)

    val BUILTIN: List<Template> = listOf(
        Template("练习", listOf(f("内容", true), f("自评", true), f("问题", true), f("下次", true)), listOf("练习"), builtin = true),
        Template("阅读", listOf(f("书名 / 来源"), f("摘录", true), f("想法", true)), listOf("阅读", "书摘"), builtin = true),
        Template("决策", listOf(f("决策", true), f("原因", true), f("备选", true), f("预期结果", true), f("复盘日期")), listOf("决策"), builtin = true),
        Template("复盘", listOf(f("发生了什么", true), f("学到了什么", true), f("下次怎么做", true)), listOf("复盘"), builtin = true),
        Template("指标", listOf(f("指标"), f("数值"), f("备注")), listOf("指标"), builtin = true),
    )

    /** 自定义（本地）模板优先于同名内置模板 */
    fun merge(local: List<Template>): List<Template> {
        val seen = HashSet<String>()
        return (local + BUILTIN).filter { seen.add(it.name.lowercase()) }
    }

    /** 模板 → 编辑框里的文本：每行一个字段，多行字段末尾加 + */
    fun fieldsToText(t: Template): String = t.fields.joinToString("\n") { if (it.multiline) "${it.name}+" else it.name }

    /** 编辑框文本（每行一个字段，也接受逗号分隔）→ 模板；名称或字段为空返回 null */
    fun build(name: String, fieldsText: String, tags: String, folderName: String?): Template? {
        val cleanName = name.trim().replace(Regex("[:：;；]"), "")
        val fields = fieldsText.split(Regex("[\\n,，、]"))
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .map { if (it.endsWith("+")) f(it.dropLast(1).trim(), true) else f(it) }
            .filter { it.name.isNotEmpty() }
        if (cleanName.isEmpty() || fields.isEmpty()) return null
        return Template(
            name = cleanName,
            fields = fields,
            tags = splitTags(tags),
            folderName = folderName?.trim()?.trimStart('@')?.ifEmpty { null },
        )
    }

    fun splitTags(text: String): List<String> =
        text.split(Regex("[\\s,，、]+")).map { it.trimStart('#') }.filter { it.isNotEmpty() }.distinct()

    class Built(val title: String, val body: String, val filled: Int)

    fun buildNote(t: Template, values: Map<String, String>, today: LocalDate = LocalDate.now()): Built {
        val blocks = mutableListOf<String>()
        for (field in t.fields) {
            val v = values[field.name].orEmpty().trim()
            if (v.isEmpty()) continue
            blocks += if (v.contains('\n')) "**${field.name}**：\n$v" else "**${field.name}**：$v"
        }
        return Built(NoteText.truncate("${t.name} $today", 30), blocks.joinToString("\n\n"), blocks.size)
    }
}
