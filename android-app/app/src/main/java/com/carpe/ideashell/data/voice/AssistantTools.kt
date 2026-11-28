package com.carpe.ideashell.data.voice

import com.carpe.ideashell.AppContainer
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.data.assistant.AssistantRunner
import com.carpe.ideashell.data.assistant.AssistantTask
import com.carpe.ideashell.data.assistant.DeviceControl
import com.carpe.ideashell.data.assistant.ScreenContext
import com.carpe.ideashell.data.assistant.SystemActions
import com.carpe.ideashell.data.assistant.TaskTime
import com.carpe.ideashell.system.PhoneControl
import com.carpe.ideashell.system.AssistantScheduler
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId

/**
 * 语音助手除了「查」之外能「做」的事：记忆、助手任务（定时 / 条件）、技能（快捷指令）、读屏幕、记笔记、系统动作（闹钟 / 倒计时 / 拨号 / 导航 / 音乐）、
 * 智能家居（home_list / home_control，经 Home Assistant 控制米家等）、设备控制（勿扰 / 铃声 / 音量 / 亮度 / 手电筒 / 打开应用 / 系统设置页 / 返回回桌面截屏 / 控制中心开关）。
 * 每个工具返回一句给模型看的结果；出错也返回文字，不抛异常。
 */
internal object AssistantTools {
    /** 定时任务里不能用的：要有人在场（读屏幕 / 打开别的应用），或会让任务自己改任务 */
    val NOT_FOR_SCHEDULED = setOf(
        "read_screen", "dial", "navigate", "create_task", "task_control", "set_timer",
        "open_app", "open_settings", "phone_action", "toggle_quick_setting", "save_skill", "delete_skill",
    )

    private fun JsonObject.arg(key: String): String? =
        (this[key] as? JsonPrimitive)?.contentOrNull?.trim()?.takeIf { it.isNotEmpty() && !it.equals("null", true) }

    private fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.let { it.intOrNull ?: it.contentOrNull?.toDoubleOrNull()?.toInt() }

    private fun JsonObject.ints(key: String): List<Int> = (this[key] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.intOrNull }.orEmpty()

    private fun enum(vararg values: String) = buildJsonArray { values.forEach { add(JsonPrimitive(it)) } }

    val defs: List<JsonObject> = listOf(
        VoiceAgent.tool(
            "remember",
            "把一条关于用户的事实 / 偏好记进助手记忆（只在用户明确说「记住……」时用）。一条一句话，写成第三方陈述，如「用户周三不开会」「老张是用户的同事」。密码 / 验证码 / 卡号一律不记。",
            props = { putJsonObject("text") { put("type", "string") } },
            required = listOf("text"),
        ),
        VoiceAgent.tool(
            "forget",
            "删除助手记忆里包含某个关键词的条目（用户说「忘掉……」「别再记……」时用）。",
            props = { putJsonObject("keyword") { put("type", "string") } },
            required = listOf("keyword"),
        ),
        VoiceAgent.tool(
            "create_task",
            "创建助手任务：到点自动让助手办一件事并推一条通知。prompt 写成脱离上下文也能执行的完整指令，日期用「今天 / 本周」这类相对说法，不要写死日期；有触发条件（「有逾期待办超过 3 个才提醒」）就填 condition。普通的「提醒我做某事」不要用它，那是待办。",
            props = {
                putJsonObject("title") { put("type", "string"); put("description", "任务名，10 字以内") }
                putJsonObject("prompt") { put("type", "string"); put("description", "到点交给助手的完整指令") }
                putJsonObject("time") { put("type", "string"); put("description", "HH:mm，24 小时制") }
                putJsonObject("days") { put("type", "array"); put("items", kotlinx.serialization.json.buildJsonObject { put("type", "integer") }); put("description", "每周哪几天（1=周一…7=周日）；不填 = 每天；与 date 二选一") }
                putJsonObject("date") { put("type", "string"); put("description", "只执行一次的日期 yyyy-MM-dd") }
                putJsonObject("condition") { put("type", "string"); put("description", "触发条件，可不填") }
            },
            required = listOf("title", "prompt", "time"),
        ),
        VoiceAgent.tool("list_tasks", "列出所有助手任务（id、什么时候、是否启用、上次结果）。"),
        VoiceAgent.tool(
            "task_control",
            "管理助手任务：pause 暂停、resume 恢复、delete 删除、run_now 立即执行一次。id 来自 list_tasks。",
            props = {
                putJsonObject("id") { put("type", "string") }
                putJsonObject("action") { put("type", "string"); put("enum", enum("pause", "resume", "delete", "run_now")) }
            },
            required = listOf("id", "action"),
        ),
        VoiceAgent.tool(
            "read_screen",
            "读取用户此刻正在看的屏幕内容（文字和选中的文字；页面是图片 / 自绘内容读不到文字时，会自动截屏做文字识别）。用户说「这页 / 这段 / 这篇 / 屏幕上 / 这个」时先用它。读不到会说明原因。",
        ),
        VoiceAgent.tool(
            "save_skill",
            "把用户反复要做的一串事存成一句话快捷指令（技能）。用户说「把这个存成快捷指令」「以后我说『下班』就帮我……」「记成一个技能」时用。name 是以后一句话叫出它的名字（2~8 个字，如「下班」「睡前」「开会模式」）；steps 写成脱离上下文也能照做的完整步骤，按顺序一步一行（可以用你有的任何能力：勿扰、音量、亮度、闹钟、打开应用、查待办……），日期用相对说法。不含密码 / 验证码。同名会覆盖。",
            props = {
                putJsonObject("name") { put("type", "string") }
                putJsonObject("steps") { put("type", "string") }
            },
            required = listOf("name", "steps"),
        ),
        VoiceAgent.tool(
            "run_skill",
            "取出一个快捷指令的步骤。用户一句话叫出了已有的快捷指令（见系统提示里的快捷指令名）时先调用它，拿到步骤后你依次办完，最后用一句话汇报做了什么。",
            props = { putJsonObject("name") { put("type", "string") } },
            required = listOf("name"),
        ),
        VoiceAgent.tool(
            "delete_skill",
            "删除一个快捷指令（用户说「删掉 / 取消 X 快捷指令」时用）。",
            props = { putJsonObject("name") { put("type", "string") } },
            required = listOf("name"),
        ),
        VoiceAgent.tool(
            "set_dnd",
            "开 / 关勿扰模式。mode：off 关闭 / priority 只响重要提醒（默认用它）/ alarms 只响闹钟 / silence 完全静音。minutes 可选：开启后多少分钟自动关闭（「勿扰一小时」= 60）。没有权限时会自动打开授权页并告诉用户。",
            props = {
                putJsonObject("mode") { put("type", "string"); put("enum", enum("off", "priority", "alarms", "silence")) }
                putJsonObject("minutes") { put("type", "integer") }
            },
            required = listOf("mode"),
        ),
        VoiceAgent.tool(
            "set_ringer",
            "切换铃声模式：normal 响铃 / vibrate 震动 / silent 静音。",
            props = { putJsonObject("mode") { put("type", "string"); put("enum", enum("normal", "vibrate", "silent")) } },
            required = listOf("mode"),
        ),
        VoiceAgent.tool(
            "set_volume",
            "调音量。stream：media 媒体（默认）/ ring 铃声 / alarm 闹钟 / call 通话；action：set（要给 percent 0~100）/ up / down / mute。",
            props = {
                putJsonObject("stream") { put("type", "string"); put("enum", enum("media", "ring", "alarm", "call")) }
                putJsonObject("action") { put("type", "string"); put("enum", enum("set", "up", "down", "mute")) }
                putJsonObject("percent") { put("type", "integer") }
            },
            required = listOf("action"),
        ),
        VoiceAgent.tool(
            "set_brightness",
            "调屏幕亮度：percent 1~100；或 auto = true 改回自动亮度。",
            props = {
                putJsonObject("percent") { put("type", "integer") }
                putJsonObject("auto") { put("type", "boolean") }
            },
        ),
        VoiceAgent.tool(
            "flashlight",
            "开 / 关手电筒。",
            props = { putJsonObject("on") { put("type", "boolean") } },
            required = listOf("on"),
        ),
        VoiceAgent.tool(
            "open_app",
            "按名字打开手机上的应用（微信、支付宝、相机、设置……）。",
            props = { putJsonObject("name") { put("type", "string") } },
            required = listOf("name"),
        ),
        VoiceAgent.tool(
            "open_settings",
            "打开系统设置的某一页（要用户自己动手切换时，如连 WLAN / 蓝牙 / 定位）。",
            props = {
                putJsonObject("page") {
                    put("type", "string")
                    put("enum", enum("wifi", "bluetooth", "nfc", "hotspot", "airplane", "display", "sound", "battery", "location", "apps", "accessibility", "date", "storage", "notifications"))
                }
            },
            required = listOf("page"),
        ),
        VoiceAgent.tool(
            "phone_action",
            "做一个系统手势：back 返回 / home 回桌面 / recents 最近任务 / notifications 拉下通知栏 / quick_settings 拉下控制中心 / lock_screen 锁屏 / screenshot 截屏 / power_menu 电源菜单。需要无障碍服务。",
            props = {
                putJsonObject("action") {
                    put("type", "string")
                    put("enum", enum("back", "home", "recents", "notifications", "quick_settings", "lock_screen", "screenshot", "power_menu"))
                }
            },
            required = listOf("action"),
        ),
        VoiceAgent.tool(
            "toggle_quick_setting",
            "点一下控制中心里的开关来切换它（WLAN、蓝牙、飞行模式、移动数据、NFC、自动旋转、热点……；手电筒 / 勿扰 / 亮度 / 音量请用专门的工具）。name 写磁贴上的名字，如「蓝牙」「WLAN」。会返回点完之后的状态；找不到会如实说。需要无障碍服务。",
            props = { putJsonObject("name") { put("type", "string") } },
            required = listOf("name"),
        ),
        VoiceAgent.tool(
            "home_list",
            "列出家里的智能设备（米家等，经 Home Assistant）及当前状态：返回 entity_id | 名称 | 状态。控制设备前先用它找到 entity_id；可带关键词（房间名 / 设备名，如「客厅」「空调」）缩小范围，也能读温湿度这类传感器。",
            props = { putJsonObject("keyword") { put("type", "string"); put("description", "名字或 id 里包含的词，多个词用空格隔开；不填列全部可控设备") } },
        ),
        VoiceAgent.tool(
            "home_control",
            "控制家里的智能设备（灯、开关、空调、窗帘、风扇、扫地机、音箱、场景……）。entity_id 来自 home_list，多个用逗号隔开（「关掉所有灯」= 把所有灯一起传）。action：on / off / toggle / open / close / stop；set 要给 value（灯亮度 0~100、空调温度、窗帘位置 0~100、风扇风速 0~100、音量 0~100）；mode 的 value 是空调模式（cool / heat / auto / dry / fan_only / off）；场景和脚本用 on 触发。不能控制门锁 / 报警 / 摄像头。",
            props = {
                putJsonObject("entity_id") { put("type", "string") }
                putJsonObject("action") { put("type", "string"); put("enum", enum("on", "off", "toggle", "open", "close", "stop", "set", "mode")) }
                putJsonObject("value") { put("type", "string") }
            },
            required = listOf("entity_id", "action"),
        ),
        VoiceAgent.tool(
            "create_note",
            "把一段整理好的文字存成笔记（kind=note）或写进今天的日记（kind=daily）。只在用户明确要「记成笔记 / 记下来 / 存起来」时用；content 是最终要存的完整内容。",
            props = {
                putJsonObject("content") { put("type", "string") }
                putJsonObject("kind") { put("type", "string"); put("enum", enum("note", "daily")) }
            },
            required = listOf("content"),
        ),
        VoiceAgent.tool(
            "set_alarm",
            "设一个系统闹钟（不是待办提醒）。days 为重复的星期（1=周一…7=周日），不填 = 只响一次。",
            props = {
                putJsonObject("hour") { put("type", "integer") }
                putJsonObject("minute") { put("type", "integer") }
                putJsonObject("label") { put("type", "string") }
                putJsonObject("days") { put("type", "array"); put("items", kotlinx.serialization.json.buildJsonObject { put("type", "integer") }) }
            },
            required = listOf("hour", "minute"),
        ),
        VoiceAgent.tool(
            "set_timer",
            "开始一个系统倒计时。",
            props = {
                putJsonObject("seconds") { put("type", "integer"); put("description", "总秒数") }
                putJsonObject("label") { put("type", "string") }
            },
            required = listOf("seconds"),
        ),
        VoiceAgent.tool(
            "dial",
            "打开拨号盘并填好号码（不会直接拨出）。target 是号码，或通讯录里的名字。",
            props = { putJsonObject("target") { put("type", "string") } },
            required = listOf("target"),
        ),
        VoiceAgent.tool(
            "navigate",
            "在地图应用里搜索 / 导航到一个地点。",
            props = { putJsonObject("destination") { put("type", "string") } },
            required = listOf("destination"),
        ),
        VoiceAgent.tool(
            "media_control",
            "控制正在播放的音乐 / 视频。",
            props = { putJsonObject("action") { put("type", "string"); put("enum", enum("play_pause", "play", "pause", "next", "previous")) } },
            required = listOf("action"),
        ),
    )

    val names: Set<String> = defs.mapNotNull { (it["function"] as? JsonObject)?.get("name")?.let { n -> (n as? JsonPrimitive)?.contentOrNull } }.toSet()

    suspend fun run(container: AppContainer, name: String, args: JsonObject): String = when (name) {
        "remember" -> container.assistantMemory.add(args.arg("text").orEmpty()).fold({ "已记住：${it.text}" }, { it.message ?: "没记成" })
        "forget" -> {
            val gone = container.assistantMemory.removeMatching(args.arg("keyword").orEmpty())
            if (gone.isEmpty()) "记忆里没有相关的条目" else "已忘掉 ${gone.size} 条：" + gone.joinToString("；") { it.text }
        }
        "create_task" -> createTask(container, args)
        "list_tasks" -> listTasks(container)
        "task_control" -> taskControl(container, args)
        "read_screen" -> readScreen(container)
        "create_note" -> createNote(container, args)
        "set_alarm" -> SystemActions.setAlarm(container.appContext, args.int("hour") ?: -1, args.int("minute") ?: 0, args.arg("label"), args.ints("days"))
        "set_timer" -> SystemActions.setTimer(container.appContext, args.int("seconds") ?: 0, args.arg("label"))
        "dial" -> SystemActions.dial(container.appContext, args.arg("target").orEmpty())
        "navigate" -> SystemActions.navigate(container.appContext, args.arg("destination").orEmpty())
        "media_control" -> SystemActions.media(container.appContext, args.arg("action").orEmpty())
        "save_skill" -> container.assistantSkills.save(args.arg("name").orEmpty(), args.arg("steps").orEmpty())
            .fold({ "已存成快捷指令「${it.name}」。以后直接说「${it.name}」就会按这些步骤办。可以在 设置 → 语音助手 → 快捷指令 里查看 / 删除。" }, { it.message ?: "没存成" })
        "run_skill" -> runSkill(container, args.arg("name").orEmpty())
        "delete_skill" -> container.assistantSkills.removeByName(args.arg("name").orEmpty())?.let { "已删除快捷指令「${it.name}」" } ?: "没有这个快捷指令"
        "set_dnd" -> DeviceControl.setDnd(container.appContext, args.arg("mode").orEmpty(), args.int("minutes"))
        "set_ringer" -> DeviceControl.setRinger(container.appContext, args.arg("mode").orEmpty())
        "set_volume" -> DeviceControl.setVolume(container.appContext, args.arg("stream") ?: "media", args.arg("action").orEmpty(), args.int("percent"))
        "set_brightness" -> DeviceControl.setBrightness(container.appContext, args.int("percent"), (args["auto"] as? JsonPrimitive)?.contentOrNull == "true")
        "flashlight" -> DeviceControl.flashlight(container.appContext, (args["on"] as? JsonPrimitive)?.contentOrNull != "false")
        "open_app" -> DeviceControl.openApp(container.appContext, args.arg("name").orEmpty())
        "open_settings" -> DeviceControl.openSettings(container.appContext, args.arg("page").orEmpty())
        "phone_action" -> PhoneControl.globalAction(args.arg("action").orEmpty())
        "toggle_quick_setting" -> PhoneControl.toggleQuickSetting(args.arg("name").orEmpty())
        "home_list" -> container.homeAssistant.list(args.arg("keyword"))
        "home_control" -> container.homeAssistant.control(args.arg("entity_id").orEmpty(), args.arg("action").orEmpty(), args.arg("value"))
        else -> "没有这个工具：$name"
    }

    private fun runSkill(container: AppContainer, name: String): String {
        val n = name.trim().trim('「', '」')
        val list = container.assistantSkills.state.value
        val skill = list.firstOrNull { it.name.equals(n, ignoreCase = true) }
            ?: list.firstOrNull { n.isNotEmpty() && (it.name.contains(n, ignoreCase = true) || n.contains(it.name, ignoreCase = true)) }
            ?: return "没有叫「$n」的快捷指令" + if (list.isEmpty()) "" else "；现有：" + list.joinToString("、") { it.name }
        container.assistantSkills.recordUse(skill.name)
        return "快捷指令「${skill.name}」的步骤（请依次办完，办不了的步骤如实说，最后用一句话汇报）：\n${skill.steps}"
    }

    private fun createTask(container: AppContainer, args: JsonObject): String {
        val title = args.arg("title")?.take(20) ?: return "缺少任务名"
        val prompt = args.arg("prompt") ?: return "缺少任务指令"
        val m = Regex("^(\\d{1,2})[:：](\\d{2})").find(args.arg("time").orEmpty()) ?: return "时间要写成 HH:mm"
        val hour = m.groupValues[1].toInt()
        val minute = m.groupValues[2].toInt()
        if (hour !in 0..23 || minute !in 0..59) return "时间不对：${args.arg("time")}"
        val once = args.arg("date")?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() }
        val task = AssistantTask(
            id = System.currentTimeMillis().toString(),
            title = title,
            prompt = prompt,
            hour = hour,
            minute = minute,
            days = AssistantTask.maskOf(args.ints("days")),
            onceDate = once?.toString(),
            condition = args.arg("condition"),
        )
        container.assistantTasks.add(task).onFailure { return it.message ?: "没能创建" }
        val next = TaskTime.next(task, System.currentTimeMillis())
        val nextText = next?.let { LocalDateTime.ofInstant(java.time.Instant.ofEpochMilli(it), ZoneId.systemDefault()) }
            ?.let { "${it.monthValue}月${it.dayOfMonth}日 %02d:%02d".format(it.hour, it.minute) } ?: "没有下一次"
        return "已创建任务「$title」：${task.whenText}" + (task.condition?.let { "，条件：$it" } ?: "") + "；下一次 $nextText。可以在 设置 → 语音助手 里暂停或删除。"
    }

    private fun listTasks(container: AppContainer): String {
        val list = container.assistantTasks.state.value
        if (list.isEmpty()) return "还没有助手任务"
        return list.joinToString("\n") { t ->
            val last = t.runs.firstOrNull()?.let { "；上次：${it.text.take(30)}" }.orEmpty()
            "· [${t.id}] ${t.title}｜${t.whenText}｜" + (if (t.enabled) "启用" else "已暂停") + (t.condition?.let { "｜条件：$it" } ?: "") + last
        }
    }

    private suspend fun taskControl(container: AppContainer, args: JsonObject): String {
        val id = args.arg("id") ?: return "缺少 id"
        val task = container.assistantTasks.get(id) ?: return "没有这个任务，先用 list_tasks 查"
        return when (args.arg("action")) {
            "pause" -> { container.assistantTasks.update(id) { it.copy(enabled = false) }; "已暂停「${task.title}」" }
            "resume" -> { container.assistantTasks.update(id) { it.copy(enabled = true) }; "已恢复「${task.title}」" }
            "delete" -> { container.assistantTasks.remove(id); "已删除「${task.title}」" }
            "run_now" -> {
                val r = AssistantRunner.run(container, task, System.currentTimeMillis(), manual = true)
                "已执行「${task.title}」：" + r.text.take(80)
            }
            else -> "action 只能是 pause / resume / delete / run_now"
        }.also { AssistantScheduler.reschedule(container.appContext) }
    }

    private suspend fun readScreen(container: AppContainer): String {
        val s = ScreenContext.read { jpeg -> container.ocr.recognize(jpeg).joinToString("\n") { it.text } }
            ?: return "读不到屏幕：" + ScreenContext.lastFailure.ifBlank { "原因不明" }
        return buildString {
            append("应用：${s.label}\n")
            if (!s.selection.isNullOrBlank()) append("选中的文字：${s.selection}\n")
            append("屏幕文字：\n${s.text}")
        }
    }

    private suspend fun createNote(container: AppContainer, args: JsonObject): String {
        val content = args.arg("content") ?: return "没有要存的内容"
        val kind = if (args.arg("kind") == "daily") CaptureKind.DAILY else CaptureKind.NOTE
        val ok = container.captures.submitText(content, kind, "voice") != null
        return if (ok) (if (kind == CaptureKind.DAILY) "已写进今天的日记" else "已存成笔记") else "没能保存（稍后会自动重试 / 请检查连接）"
    }
}
