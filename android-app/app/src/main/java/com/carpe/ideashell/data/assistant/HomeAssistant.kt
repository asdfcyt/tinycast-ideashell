package com.carpe.ideashell.data.assistant

import com.carpe.ideashell.data.secure.CredentialStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
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

    private class Entity(val id: String, val name: String, val state: String, val attrs: JsonObject) {
        val domain get() = id.substringBefore('.')
    }

    @Volatile
    private var cache: Pair<Long, List<Entity>>? = null

    private class HaException(message: String) : Exception(message)

    /** 列出能控制的设备（带关键词就按名字 / id 筛，也包含传感器读数）；给模型看的文字 */
    suspend fun list(keyword: String?): String = guard {
        val all = states(fresh = false)
        val tokens = keyword.orEmpty().lowercase().split(' ', '，', ',', '、').filter { it.isNotBlank() }
        val pool = all.filter { e ->
            if (tokens.isEmpty()) e.domain in CONTROL
            else (e.domain in CONTROL || e.domain in READ_ONLY) &&
                tokens.all { t -> e.name.lowercase().contains(t) || e.id.lowercase().contains(t) }
        }
        if (pool.isEmpty()) {
            return@guard if (tokens.isEmpty()) "Home Assistant 里没有可控制的设备" else "没有名字里带「$keyword」的设备。可以不带关键词再列一次看看全部。"
        }
        val shown = pool.take(MAX_LIST)
        buildString {
            append("设备（entity_id | 名称 | 状态）：\n")
            shown.forEach { e -> append(e.id).append(" | ").append(e.name).append(" | ").append(describe(e)).append('\n') }
            if (pool.size > shown.size) append("……还有 ${pool.size - shown.size} 个，请加关键词缩小范围")
        }.trim()
    }

    /**
     * 控制设备。[entityIds] 用逗号分隔可以一次控制多个；[action]：on / off / toggle / open / close / stop / set / mode；
     * set 的 [value]：灯亮度 0~100、空调温度、窗帘位置 0~100、风扇风速 0~100、播放器音量 0~100、加湿器湿度；mode 的 value 是空调模式（cool / heat / auto / off……）。
     */
    suspend fun control(entityIds: String, action: String, value: String?): String = guard {
        val ids = entityIds.split(',', '，', ';', '、').map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        if (ids.isEmpty()) return@guard "没有指定设备"
        if (ids.size > MAX_BATCH) return@guard "一次最多控制 $MAX_BATCH 个设备"
        val known = states(fresh = false).associateBy { it.id }
        val lines = ids.map { id ->
            val domain = id.substringBefore('.')
            if (domain in BLOCKED) return@map "$id：出于安全，不支持用语音控制门锁 / 报警 / 摄像头"
            if (domain !in CONTROL) return@map "$id：这类设备不能控制"
            val entity = known[id] ?: return@map "$id：没有这个设备（先用 home_list 查名字）"
            val call = serviceFor(domain, action.lowercase(), value) ?: return@map "${entity.name}：${domain} 不支持「$action」${if (action == "set" || action == "mode") "（缺少或不合法的 value）" else ""}"
            val changed = callService("/api/services/$domain/${call.service}", JsonObject(call.data + ("entity_id" to JsonPrimitive(id))))
            val after = changed.firstOrNull { it.id == id } ?: states(fresh = true).firstOrNull { it.id == id }
            "${entity.name}：已" + call.label + (after?.let { "，现在 ${describe(it)}" } ?: "")
        }
        cache = null
        lines.joinToString("\n")
    }

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

    private suspend fun states(fresh: Boolean): List<Entity> {
        val c = cache
        if (!fresh && c != null && System.currentTimeMillis() - c.first < CACHE_MS) return c.second
        val body = request("GET", "/api/states", null)
        val list = parse(body)
        cache = System.currentTimeMillis() to list
        return list
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
        const val CACHE_MS = 30_000L
        const val MAX_LIST = 60
        const val MAX_BATCH = 12
        val CONTROL = setOf("light", "switch", "fan", "climate", "cover", "scene", "script", "media_player", "vacuum", "humidifier", "input_boolean", "button", "automation")
        val READ_ONLY = setOf("sensor", "binary_sensor", "weather")
        val BLOCKED = setOf("lock", "alarm_control_panel", "camera", "siren", "garage_door")
    }
}
