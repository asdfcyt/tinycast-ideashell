package com.carpe.ideashell.data.assistant

import com.carpe.ideashell.data.secure.CredentialStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * 智能家居：通过 Home Assistant 的 REST API 控制米家（以及其他）设备。
 * 米家设备由 HA 的官方「Xiaomi Home」集成接入；这里只用 `/api/states` 和 `/api/services/<domain>/<service>`，
 * 令牌是 HA 个人资料页里创建的「长期访问令牌」。门锁、报警面板、摄像头一律不支持（说一句话就开锁太危险）。
 */
class HomeAssistant(http: OkHttpClient, private val credentials: CredentialStore) {
    private val client = http.newBuilder()
        .connectTimeout(4, TimeUnit.SECONDS)
        .readTimeout(8, TimeUnit.SECONDS)
        .callTimeout(10, TimeUnit.SECONDS)
        .build()

    val configured: Boolean
        get() = !credentials.haUrl.isNullOrBlank() && !credentials.haToken.isNullOrBlank()

    private class Entity(val id: String, val rawName: String, val state: String, val attrs: JsonObject, val area: String? = null) {
        val domain get() = id.substringBefore('.')

        /** 带房间的名字：「书房 吸顶灯主灯」（名字里已经有房间名就不重复） */
        val name: String get() = if (area.isNullOrBlank() || rawName.contains(area)) rawName else "$area $rawName"
    }

    @Volatile
    private var cache: Pair<Long, List<Entity>>? = null

    private class HaException(message: String) : Exception(message)

    /** 控制之后设备状态变了，下次列设备要重新取 */
    @Volatile
    private var dirty = false

    /** 列出设备（可按类型、名字 / 房间筛，也能读传感器）；给模型看的文字 */
    suspend fun list(keyword: String?, domain: String? = null): String = guard {
        val all = states(maxAgeMs = if (dirty) 0 else FRESH_MS)
        val tokens = tokensOf(keyword)
        val d = domain?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
        val pool = all.filter { e ->
            (e.domain in CONTROL || (tokens.isNotEmpty() || d != null) && e.domain in READ_ONLY) &&
                (d == null || e.domain == d) && matches(e, tokens)
        }
        if (pool.isEmpty()) return@guard notFound(all, keyword, d)
        val noArea = pool.none { !it.area.isNullOrBlank() }
        val shown = pool.take(MAX_LIST)
        buildString {
            append("设备（entity_id | 名称 | 状态）：\n")
            shown.forEach { e -> append(e.id).append(" | ").append(e.name).append(" | ").append(describe(e)).append('\n') }
            if (pool.size > shown.size) append("……还有 ${pool.size - shown.size} 个，请加类型或关键词缩小范围\n")
            if (noArea && (tokens.isNotEmpty() || d != null)) append("（这些设备在 Home Assistant 里没有标注房间，按房间找不到时请让用户指明设备名，或到 HA「设置 → 区域」里分配房间）")
        }.trim()
    }

    private fun tokensOf(text: String?) = text.orEmpty().lowercase().split(' ', '，', ',', '、', ';').filter { it.isNotBlank() }

    /** 所有词都出现在「房间 + 名字」或 id 里（房间名、设备名都能当关键词） */
    private fun matches(e: Entity, tokens: List<String>): Boolean =
        tokens.all { t -> e.name.lowercase().contains(t) || e.id.lowercase().contains(t) || e.area?.lowercase()?.contains(t) == true }

    private fun notFound(all: List<Entity>, keyword: String?, domain: String?): String {
        val kinds = all.filter { it.domain in CONTROL }.groupingBy { it.domain }.eachCount().entries.joinToString("、") { "${it.key}(${it.value})" }
        val what = listOfNotNull(domain?.let { "类型 $it" }, keyword?.takeIf { it.isNotBlank() }?.let { "关键词「$it」" }).joinToString("、")
        return "没有找到" + (if (what.isEmpty()) "可控制的设备" else "符合 $what 的设备") + "。家里的设备类型有：${kinds.ifEmpty { "无" }}。可以换个关键词或类型再试（比如灯有时是 switch 类型，用关键词「灯」不限类型再找）。"
    }

    /**
     * 控制设备。目标三选一（可组合）：[entityIds]（逗号分隔，精确到设备）；[domain]（类型：light / switch / climate / cover / fan……，
     * 配合 [area] 就是「某个房间的所有灯」，不给 area 就是「全家所有的灯」）；只给 [area]（房间 / 名字关键词，不限类型）。
     * 同一类型的一次发出，快；场景 / 脚本 / 按钮 / 自动化不能按类型批量，只能给 entity_id。
     * [action]：on / off / toggle / open / close / stop / set / mode；set 的 [value]：灯亮度 0~100、空调温度、窗帘位置 0~100、风扇风速 0~100、播放器音量 0~100、加湿器湿度；mode 的 value 是空调模式。
     */
    suspend fun control(entityIds: String?, domain: String?, area: String?, action: String, value: String?): String = guard {
        val act = action.lowercase()
        val all = states(maxAgeMs = CATALOG_MS)
        val byId = all.associateBy { it.id }
        val ids = tokensOf(entityIds).flatMap { it.split(',') }.map { it.trim() }.filter { it.isNotEmpty() }
        val d = domain?.trim()?.lowercase()?.takeIf { it.isNotEmpty() && it != "all" }
        val areaTokens = tokensOf(area)
        if (ids.isEmpty() && d == null && areaTokens.isEmpty()) return@guard "没有指定设备：给 entity_id，或给类型（domain）/ 房间（area）"
        if (d != null && d in BLOCKED) return@guard "出于安全，不支持用语音控制门锁 / 报警 / 摄像头"
        if (d != null && d in SINGLE_ONLY && ids.isEmpty()) return@guard "$d 类不能按类型批量触发，请给具体的 entity_id（先用 home_list 找）"

        val targets: List<Entity>
        val missing = mutableListOf<String>()
        if (ids.isNotEmpty()) {
            targets = ids.mapNotNull { id -> byId[id].also { if (it == null) missing += id } }
        } else {
            targets = all.filter { e ->
                e.domain in CONTROL && e.domain !in SINGLE_ONLY && (d == null || e.domain == d) && matches(e, areaTokens)
            }
            if (targets.isEmpty()) return@guard notFound(all, area, d)
        }
        if (targets.size > MAX_BATCH) return@guard "匹配到 ${targets.size} 个设备，超过一次最多 $MAX_BATCH 个，请缩小范围（指定类型或房间）"

        val problems = missing.map { "$it：没有这个设备（先用 home_list 查名字）" }.toMutableList()
        // 同类型、同动作的设备合成一次请求
        val groups = targets.filter { e ->
            when {
                e.domain in BLOCKED -> { problems += "${e.name}：出于安全，不支持用语音控制"; false }
                e.domain !in CONTROL -> { problems += "${e.name}：这类设备不能控制"; false }
                else -> true
            }
        }.groupBy { it.domain }
        val done = mutableListOf<Pair<Entity, String>>()
        var verb = ""
        for ((dom, members) in groups) {
            val call = serviceFor(dom, act, value)
            if (call == null) {
                problems += members.joinToString("、") { it.name } + "：${dom} 不支持「$action」" + if (act == "set" || act == "mode") "（缺少或不合法的 value）" else ""
                continue
            }
            verb = call.label
            val changed = callService(
                "/api/services/$dom/${call.service}",
                JsonObject(call.data + ("entity_id" to kotlinx.serialization.json.JsonArray(members.map { JsonPrimitive(it.id) }))),
            ).associateBy { it.id }
            members.forEach { m -> done += m to (changed[m.id]?.let { "，现在 ${describe(it)}" } ?: "") }
        }
        dirty = true
        val ok = when {
            done.isEmpty() -> null
            done.size <= 4 -> done.joinToString("\n") { (e, now) -> "${e.name}：已${verbOf(groups, e, act, value, verb)}$now" }
            else -> "共 ${done.size} 个设备：已$verb（" + done.joinToString("、") { it.first.name } + "）"
        }
        listOfNotNull(ok, problems.takeIf { it.isNotEmpty() }?.joinToString("\n")).joinToString("\n")
    }

    private fun verbOf(groups: Map<String, List<Entity>>, e: Entity, act: String, value: String?, fallback: String): String =
        serviceFor(e.domain, act, value)?.label ?: fallback

    private class Call(val service: String, val label: String, val data: Map<String, kotlinx.serialization.json.JsonElement> = emptyMap())

    private fun serviceFor(domain: String, action: String, value: String?): Call? {
        val v = value?.trim()
        val n = v?.toDoubleOrNull()
        return when (action) {
            "on" -> when (domain) {
                "cover" -> Call("open_cover", "打开")
                "vacuum" -> Call("start", "开始工作")
                "button" -> Call("press", "按下")
                "automation" -> Call("trigger", "触发")
                else -> Call("turn_on", "打开")
            }
            "off" -> when (domain) {
                "cover" -> Call("close_cover", "关闭")
                "vacuum" -> Call("return_to_base", "让它回去充电")
                "button", "scene" -> null
                else -> Call("turn_off", "关闭")
            }
            "toggle" -> when (domain) {
                "cover" -> Call("toggle", "切换")
                "light", "switch", "fan", "input_boolean", "humidifier", "media_player", "climate" -> Call("toggle", "切换")
                else -> null
            }
            "open" -> if (domain == "cover") Call("open_cover", "打开") else null
            "close" -> if (domain == "cover") Call("close_cover", "关闭") else null
            "stop" -> when (domain) {
                "cover" -> Call("stop_cover", "停住")
                "vacuum" -> Call("stop", "停下")
                else -> null
            }
            "set" -> when (domain) {
                "light" -> n?.let { Call("turn_on", "调到亮度 ${it.toInt().coerceIn(1, 100)}%", mapOf("brightness_pct" to JsonPrimitive(it.toInt().coerceIn(1, 100)))) }
                "climate" -> n?.let { Call("set_temperature", "调到 ${trim(it)} 度", mapOf("temperature" to JsonPrimitive(it))) }
                "cover" -> n?.let { Call("set_cover_position", "调到 ${it.toInt().coerceIn(0, 100)}%", mapOf("position" to JsonPrimitive(it.toInt().coerceIn(0, 100)))) }
                "fan" -> n?.let { Call("set_percentage", "风速调到 ${it.toInt().coerceIn(0, 100)}%", mapOf("percentage" to JsonPrimitive(it.toInt().coerceIn(0, 100)))) }
                "media_player" -> n?.let { Call("volume_set", "音量调到 ${it.toInt().coerceIn(0, 100)}%", mapOf("volume_level" to JsonPrimitive(it.coerceIn(0.0, 100.0) / 100.0))) }
                "humidifier" -> n?.let { Call("set_humidity", "湿度调到 ${it.toInt().coerceIn(0, 100)}%", mapOf("humidity" to JsonPrimitive(it.toInt().coerceIn(0, 100)))) }
                else -> null
            }
            "mode" -> if (domain == "climate" && !v.isNullOrBlank()) Call("set_hvac_mode", "切到 $v 模式", mapOf("hvac_mode" to JsonPrimitive(v.lowercase()))) else null
            else -> null
        }
    }

    private fun trim(d: Double) = if (d == d.toInt().toDouble()) d.toInt().toString() else d.toString()

    private fun describe(e: Entity): String {
        val attrs = e.attrs
        fun num(key: String) = (attrs[key] as? JsonPrimitive)?.doubleOrNull
        val unit = (attrs["unit_of_measurement"] as? JsonPrimitive)?.contentOrNull.orEmpty()
        return when (e.domain) {
            "sensor" -> e.state + unit
            "light" -> if (e.state == "on") "开" + (num("brightness")?.let { "，亮度 ${(it * 100 / 255).toInt()}%" } ?: "") else zh(e.state)
            "climate" -> zh(e.state) + (num("temperature")?.let { "，设定 ${trim(it)}度" } ?: "") + (num("current_temperature")?.let { "，室温 ${trim(it)}度" } ?: "")
            "cover" -> zh(e.state) + (num("current_position")?.let { "，位置 ${it.toInt()}%" } ?: "")
            "fan" -> zh(e.state) + (num("percentage")?.let { "，风速 ${it.toInt()}%" } ?: "")
            else -> zh(e.state)
        }
    }

    private fun zh(state: String) = when (state) {
        "on" -> "开"
        "off" -> "关"
        "unavailable" -> "离线"
        "unknown" -> "未知"
        "open" -> "已打开"
        "closed" -> "已关闭"
        "opening" -> "正在打开"
        "closing" -> "正在关闭"
        "playing" -> "播放中"
        "paused" -> "已暂停"
        "idle" -> "空闲"
        "docked" -> "已回充"
        "cleaning" -> "清扫中"
        "heat" -> "制热"
        "cool" -> "制冷"
        else -> state
    }

    /**
     * 设备目录（名字 + 房间）：写进助手的系统提示里，模型就不用先调一次 home_list 再控制，少一轮大模型调用。
     * 没配置返回 null；缓存没有时最多等 [WAIT_MS] 毫秒，取不到就不带（模型仍可以调 home_list）。
     */
    suspend fun promptBlock(): String? {
        if (!configured) return null
        val list = cache?.takeIf { System.currentTimeMillis() - it.first < CATALOG_MS }?.second
            ?: runCatching { kotlinx.coroutines.withTimeout(WAIT_MS) { states(maxAgeMs = CATALOG_MS) } }.getOrNull()
            ?: return null
        // 灯 / 空调 / 窗帘这些常用的排前面；开关类（米家会生出很多指示灯、童锁之类的开关）限量，免得把真正的灯挤出去
        val devices = PROMPT_ORDER.flatMap { d -> list.filter { it.domain == d }.sortedWith(compareBy({ it.area ?: "~" }, { it.rawName })).take(if (d == "switch") 30 else 60) }
        if (devices.isEmpty()) return null
        val rooms = list.mapNotNull { it.area }.distinct().take(20)
        return buildString {
            if (rooms.isNotEmpty()) append("房间：").append(rooms.joinToString("、")).append('\n')
            devices.groupBy { it.domain }.forEach { (d, members) ->
                val total = list.count { it.domain == d }
                append("【").append(d).append(" · 共 ").append(total).append(" 个】\n")
                members.forEach { append(it.id).append(" | ").append(it.name).append('\n') }
            }
        }.trim()
    }

    /** 开始说话时在后台刷新一下设备目录（缓存还新就不动） */
    suspend fun warm() {
        if (!configured) return
        val c = cache
        if (c != null && System.currentTimeMillis() - c.first < WARM_MS) return
        runCatching { states(maxAgeMs = 0) }
    }

    private suspend fun states(maxAgeMs: Long): List<Entity> {
        val c = cache
        if (c != null && System.currentTimeMillis() - c.first < maxAgeMs) return c.second
        val (body, areas) = coroutineScope {
            val states = async { request("GET", "/api/states", null) }
            val areaJob = async { runCatching { areaMap() }.getOrDefault(emptyMap()) }
            states.await() to areaJob.await()
        }
        val list = parse(body).map { e -> areas[e.id]?.let { Entity(e.id, e.rawName, e.state, e.attrs, it) } ?: e }
        cache = System.currentTimeMillis() to list
        return list
    }

    /** entity_id → 房间名：HA 的模板接口一次取完（设备所在的房间也算） */
    private suspend fun areaMap(): Map<String, String> {
        val template = "{% set ns = namespace(r=[]) %}{% for s in states %}{% set a = area_name(s.entity_id) %}{% if a %}{% set ns.r = ns.r + [[s.entity_id, a]] %}{% endif %}{% endfor %}{{ ns.r | tojson }}"
        val text = request("POST", "/api/template", buildJsonObject { put("template", template) }.toString())
        return Json.parseToJsonElement(text).jsonArray.mapNotNull { el ->
            val pair = el as? JsonArray ?: return@mapNotNull null
            val id = (pair.getOrNull(0) as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
            val area = (pair.getOrNull(1) as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
            id to area
        }.toMap()
    }

    private suspend fun callService(path: String, data: JsonObject): List<Entity> = parse(request("POST", path, data.toString()))

    private fun parse(body: String): List<Entity> {
        val arr = runCatching { Json.parseToJsonElement(body).jsonArray }.getOrElse { JsonArray(emptyList()) }
        return arr.mapNotNull { el ->
            val o = el as? JsonObject ?: return@mapNotNull null
            val id = (o["entity_id"] as? JsonPrimitive)?.contentOrNull ?: return@mapNotNull null
            val state = (o["state"] as? JsonPrimitive)?.contentOrNull.orEmpty()
            val attrs = (o["attributes"] as? JsonObject) ?: JsonObject(emptyMap())
            val name = (attrs["friendly_name"] as? JsonPrimitive)?.contentOrNull ?: id
            Entity(id, name, state, attrs)
        }
    }

    private suspend fun request(method: String, path: String, json: String?): String {
        val base = credentials.haUrl?.trim()?.trimEnd('/').orEmpty()
        val token = credentials.haToken.orEmpty()
        if (base.isBlank() || token.isBlank()) throw HaException("还没有配置 Home Assistant（设置 → 账号与连接 → 智能家居）")
        val req = try {
            Request.Builder().url(base + path)
                .header("Authorization", "Bearer $token")
                .apply { if (json != null) post(json.toRequestBody("application/json".toMediaType())) }
                .build()
        } catch (_: IllegalArgumentException) {
            throw HaException("Home Assistant 地址不正确，请检查设置（形如 http://192.168.1.10:8123）")
        }
        return withContext(Dispatchers.IO) {
            try {
                client.newCall(req).execute().use { r ->
                    val text = r.body?.string().orEmpty()
                    when {
                        r.isSuccessful -> text
                        r.code == 401 -> throw HaException("Home Assistant 令牌无效或已被删除")
                        r.code == 404 -> throw HaException("Home Assistant 找不到这个接口 / 设备（${r.code}）")
                        else -> throw HaException("Home Assistant 请求失败（${r.code}）" + text.take(80).let { if (it.isBlank()) "" else "：$it" })
                    }
                }
            } catch (e: HaException) {
                throw e
            } catch (e: IOException) {
                throw HaException("连不上 Home Assistant：手机和它要在同一个 WLAN，或改用外网地址（${e.message?.take(60) ?: e.javaClass.simpleName}）")
            }
        }
    }

    private suspend fun guard(block: suspend () -> String): String =
        try {
            block()
        } catch (e: HaException) {
            e.message ?: "Home Assistant 出错"
        }

    private companion object {
        const val FRESH_MS = 30_000L
        const val CATALOG_MS = 600_000L
        const val WARM_MS = 120_000L
        const val WAIT_MS = 2_500L
        const val MAX_LIST = 60
        const val MAX_BATCH = 40
        val CONTROL = setOf("light", "switch", "fan", "climate", "cover", "scene", "script", "media_player", "vacuum", "humidifier", "input_boolean", "button", "automation")
        val READ_ONLY = setOf("sensor", "binary_sensor", "weather")
        val PROMPT_ORDER = listOf("light", "climate", "cover", "fan", "media_player", "vacuum", "humidifier", "scene", "script", "switch")
        /** 只能指名触发、不能「所有」批量的类型 */
        val SINGLE_ONLY = setOf("scene", "script", "button", "automation")
        val BLOCKED = setOf("lock", "alarm_control_panel", "camera", "siren", "garage_door")
    }
}
