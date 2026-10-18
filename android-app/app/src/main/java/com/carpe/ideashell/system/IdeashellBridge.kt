package com.carpe.ideashell.system

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import com.carpe.ideashell.IdeashellApp

/**
 * 调用闪念贝壳 App 自己的功能（语音录音、新建文字笔记、闪念贝壳 AI 对话、打开某条笔记）。
 *
 * 闪念贝壳没有开放这些功能的 API（MCP 只有笔记 / 文件夹 / 待办的数据读写），所以这里用的是它 App 里本来就有的两个入口：
 * 1. `ShortcutActivity`（exported）：桌面长按图标的快捷方式就是它，靠 extra `from_shortcut` 区分：
 *    `new_record` 立刻开始录音、`new_text` 打开空白笔记编辑器、`ask_ai` 打开 AI 对话页；
 * 2. 自定义链接 `ideashellcn://…`（国际版 `ideashell://…`）：`app/askai?query=…` 打开 AI 对话并把 query 填进输入框（不会自动发送）、
 *    `note/detail?id=…&session_id=…` 打开笔记。
 * 这些都是对 App 内部实现的观察（真机验证过，闪念贝壳 2.0.3），App 升级后可能变化，所以每个调用都带回退：
 * 先试专用入口，不行就把 App 拉起来并提示。
 */
object IdeashellBridge {
    enum class Action(val extra: String, val label: String) {
        VOICE("new_record", "语音录音"),
        TEXT("new_text", "新建文字笔记"),
        ASK_AI("ask_ai", "闪念贝壳 AI"),
    }

    /** 国内版 / Google Play 国际版：包名、链接协议、快捷方式入口类 */
    private data class Variant(val pkg: String, val scheme: String, val shortcutClass: String)

    private val VARIANTS = listOf(
        Variant("com.roundreddot.ideashell", "ideashellcn", "com.roundreddot.ideashell.common.ui.launcher.ShortcutActivity"),
        Variant("com.rrd.ideaShell", "ideashell", "com.rrd.ideaShell.common.ui.launcher.ShortcutActivity"),
    )

    /** 装了哪个版本的闪念贝壳（都没装为 null） */
    private fun installed(context: Context): Variant? =
        VARIANTS.firstOrNull { runCatching { context.packageManager.getPackageInfo(it.pkg, 0) }.isSuccess }

    fun isInstalled(context: Context): Boolean = installed(context) != null

    /** 立刻开始录音（闪念贝壳自己的录音页，说完点「结束」会自动整理成笔记） */
    fun startVoiceRecording(context: Context): Boolean = shortcut(context, Action.VOICE)

    /** 打开空白笔记编辑器 */
    fun newTextNote(context: Context): Boolean = shortcut(context, Action.TEXT)

    /**
     * 打开闪念贝壳 AI 对话。[query] 不为空时填进输入框（需要用户点发送：它的链接不支持自动发送；
     * 无障碍服务开着并且开启了「自动发送」或 [preferAutoSend] 时由服务代点）。
     * 链接不认时退回到打开 AI 对话页。
     */
    fun askAi(context: Context, query: String? = null, preferAutoSend: Boolean = false): Boolean {
        val v = installed(context) ?: return notInstalled(context)
        val q = query?.trim().orEmpty()
        // 开启了「自动发送」且无障碍服务在运行：转交后由服务点发送键（见 AiAutoSendService）
        // [preferAutoSend]（语音里说「帮我查一下」）：只要无障碍服务开着就自动发送，不看设置里的开关
        val autoSend = q.isNotEmpty() && AiAutoSendService.isEnabled(context) &&
            (preferAutoSend || (context.applicationContext as? IdeashellApp)?.container?.settings?.state?.value?.aiAutoSend == true)
        if (autoSend) AiAutoSendService.arm(q)
        if (q.isNotEmpty() && start(context, Intent(Intent.ACTION_VIEW, Uri.parse("${v.scheme}://app/askai?query=${Uri.encode(q)}")).setPackage(v.pkg))) {
            return true
        }
        if (autoSend) AiAutoSendService.disarm()
        return shortcut(context, Action.ASK_AI)
    }

    /**
     * 把一条笔记 / 日记发给闪念贝壳 AI 聊：[title] 和 [meta]（日期等）是上下文，[body] 是内容，
     * 末尾带一句默认问题（开了「自动发送」就直接问；没开则留在输入框里，用户可以改成自己的问题）。
     * 链接长度有限，正文超过 [MAX_BODY] 字时截断。
     */
    fun askAboutNote(context: Context, title: String?, meta: String?, body: String): Boolean {
        val text = body.trim()
        val clipped = if (text.length > MAX_BODY) text.take(MAX_BODY) + "……（内容较长，已截取前 $MAX_BODY 字）" else text
        val head = buildString {
            append("这是我记下的一条")
            if (!meta.isNullOrBlank()) append("（$meta）")
            append("：\n")
            if (!title.isNullOrBlank()) append("《${title.trim()}》\n")
        }
        return askAi(context, head + clipped + "\n\n请帮我梳理要点，并指出值得继续追问或深入的地方。")
    }

    private const val MAX_BODY = 1500

    private fun shortcut(context: Context, action: Action): Boolean {
        val v = installed(context) ?: return notInstalled(context)
        val intent = Intent(Intent.ACTION_VIEW).setClassName(v.pkg, v.shortcutClass).putExtra("from_shortcut", action.extra)
        if (start(context, intent)) return true
        // 入口类变了 / 不让调用：至少把 App 拉起来
        val launch = context.packageManager.getLaunchIntentForPackage(v.pkg)
        if (launch != null && start(context, launch)) {
            Toast.makeText(context, "已打开闪念贝壳，请在里面选「${action.label}」", Toast.LENGTH_SHORT).show()
            return true
        }
        return false
    }

    private fun start(context: Context, intent: Intent): Boolean = try {
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (_: ActivityNotFoundException) {
        false
    } catch (_: SecurityException) {
        false
    }

    private fun notInstalled(context: Context): Boolean {
        Toast.makeText(context, "没有找到闪念贝壳 App", Toast.LENGTH_SHORT).show()
        return false
    }
}
