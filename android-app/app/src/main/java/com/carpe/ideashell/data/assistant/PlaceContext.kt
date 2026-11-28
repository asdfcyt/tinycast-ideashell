package com.carpe.ideashell.data.assistant

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Address
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume

/**
 * 助手知道用户在哪：用系统定位拿到大致位置，再反查成「省 市 区（街道）」。
 * 给大模型的只有地址文字（系统提示里只到「区」，用户问「我在哪」时才给到街道），不带经纬度。
 * 反查先用系统的 Geocoder（有些机型没有后端或在国内连不上），不行再用 OpenStreetMap 的 Nominatim。
 * 位置缓存在本机：说话那一刻在后台刷新，回答时直接用缓存，不额外等定位。
 */
class PlaceContext(private val context: Context, http: OkHttpClient) {
    /** [area] 省市区（给提示词用），[detail] 带街道（用户问「我在哪」时用） */
    class Place(val lat: Double, val lon: Double, val accuracy: Float, val at: Long, val area: String, val detail: String)

    private val client = http.newBuilder()
        .connectTimeout(4, TimeUnit.SECONDS)
        .readTimeout(5, TimeUnit.SECONDS)
        .callTimeout(6, TimeUnit.SECONDS)
        .build()
    private val prefs = context.getSharedPreferences("place_cache", Context.MODE_PRIVATE)

    @Volatile
    private var last: Place? = load()

    @Volatile
    private var lastTry = 0L

    /** 上一次定位失败的原因（给工具返回） */
    @Volatile
    var lastFailure: String = ""
        private set

    /** 0 没授权 / 1 仅使用时允许 / 2 始终允许 */
    fun level(): Int {
        val fg = granted(Manifest.permission.ACCESS_FINE_LOCATION) || granted(Manifest.permission.ACCESS_COARSE_LOCATION)
        if (!fg) return 0
        return if (Build.VERSION.SDK_INT < 29 || granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION)) 2 else 1
    }

    private fun granted(p: String) = context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    /**
     * 系统提示里的一句「用户大致在哪」。缓存超过 [REFRESH_MS] 就在 [waitMs] 内试着刷新一次，来不及就用旧的；
     * 缓存超过 12 小时、或没有授权，返回 null。
     */
    suspend fun promptLine(waitMs: Long = 3000L): String? {
        if (level() == 0) return null
        val cached = last
        val now = System.currentTimeMillis()
        // 刚试过（说话时已经在后台刷新了）就不再等，免得定位不到时每次回答都慢三秒
        if ((cached == null || now - cached.at > REFRESH_MS) && now - lastTry > 120_000L) {
            withTimeoutOrNull(waitMs) { refresh() }
        }
        val p = last ?: return null
        val age = System.currentTimeMillis() - p.at
        if (age > 12 * 3_600_000L) return null
        return "${p.area}（大致位置，${ageText(age)}定位）"
    }

    /** 助手工具 get_location 的结果：带街道，必要时先刷新 */
    suspend fun describe(): String {
        if (level() == 0) return "没有定位权限：到 设置 → 语音助手 → 位置 授权后才能知道你在哪。也可以直接告诉我你所在的城市。"
        val p = refresh(maxAgeMs = 120_000L) ?: last
        if (p == null) return "没能定位：${lastFailure.ifBlank { "原因不明" }}。可以直接告诉我你所在的城市。"
        val age = System.currentTimeMillis() - p.at
        val fresh = if (age <= 10 * 60_000L) "" else "（这是${ageText(age)}的位置，现在可能已经变了）"
        return "你现在大致在：${p.detail}，定位精度约 ${p.accuracy.toInt().coerceAtLeast(1)} 米$fresh。"
    }

    private fun ageText(ms: Long): String = when {
        ms < 90_000L -> "刚刚"
        ms < 3_600_000L -> "${ms / 60_000L} 分钟前"
        else -> "${ms / 3_600_000L} 小时前"
    }

    /** 刷新位置（后台调用）。缓存还新（[maxAgeMs] 内）就直接返回；失败返回 null，原因记在 [lastFailure] */
    @SuppressLint("MissingPermission")
    suspend fun refresh(maxAgeMs: Long = REFRESH_MS): Place? {
        val cached = last
        if (cached != null && System.currentTimeMillis() - cached.at <= maxAgeMs) return cached
        lastTry = System.currentTimeMillis()
        if (level() == 0) {
            lastFailure = "没有定位权限"
            return null
        }
        val lm = context.getSystemService(LocationManager::class.java)
        if (lm == null || (Build.VERSION.SDK_INT >= 28 && !lm.isLocationEnabled)) {
            lastFailure = "手机的定位开关没打开"
            return null
        }
        val loc = withContext(Dispatchers.IO) { locate(lm) }
        if (loc == null) {
            lastFailure = "拿不到定位（可能在室内信号差，或系统没有给后台定位）"
            return cached
        }
        val (area, detail) = withContext(Dispatchers.IO) { reverse(loc.latitude, loc.longitude) } ?: ("" to "")
        // 反查不出文字时沿用旧的地址（位置没怎么动的话）；都没有就只能放弃
        val keep = cached?.takeIf { it.area.isNotBlank() && distance(it.lat, it.lon, loc.latitude, loc.longitude) < 3000 }
        val finalArea = area.ifBlank { keep?.area.orEmpty() }
        if (finalArea.isBlank()) {
            lastFailure = "定位到了，但查不出地址（网络不通？）"
            return cached
        }
        val place = Place(loc.latitude, loc.longitude, loc.accuracy, System.currentTimeMillis(), finalArea, detail.ifBlank { finalArea })
        last = place
        save(place)
        lastFailure = ""
        return place
    }

    /** 先试系统融合 / 网络定位（快），再试 GPS；都不行再用各个来源最近一次的位置（1 小时内） */
    @SuppressLint("MissingPermission")
    private suspend fun locate(lm: LocationManager): Location? {
        val providers = buildList {
            if (Build.VERSION.SDK_INT >= 31 && runCatching { lm.hasProvider(LocationManager.FUSED_PROVIDER) }.getOrDefault(false)) add(LocationManager.FUSED_PROVIDER)
            add(LocationManager.NETWORK_PROVIDER)
            if (granted(Manifest.permission.ACCESS_FINE_LOCATION)) add(LocationManager.GPS_PROVIDER)
        }.filter { runCatching { lm.isProviderEnabled(it) }.getOrDefault(false) }
        if (Build.VERSION.SDK_INT >= 30) {
            for (p in providers) {
                val loc = withTimeoutOrNull(if (p == LocationManager.GPS_PROVIDER) 8000L else 4000L) { current(lm, p) }
                if (loc != null) return loc
            }
        }
        return providers.mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }
            .filter { System.currentTimeMillis() - it.time < 3_600_000L }
            .maxByOrNull { it.time }
    }

    @SuppressLint("MissingPermission")
    private suspend fun current(lm: LocationManager, provider: String): Location? = suspendCancellableCoroutine { cont ->
        val signal = CancellationSignal()
        cont.invokeOnCancellation { signal.cancel() }
        runCatching {
            lm.getCurrentLocation(provider, signal, context.mainExecutor) { loc -> if (cont.isActive) cont.resume(loc) }
        }.onFailure { if (cont.isActive) cont.resume(null) }
    }

    /** 经纬度 → （省市区, 带街道的地址） */
    private suspend fun reverse(lat: Double, lon: Double): Pair<String, String>? =
        fromGeocoder(lat, lon) ?: fromNominatim(lat, lon)

    private suspend fun fromGeocoder(lat: Double, lon: Double): Pair<String, String>? {
        if (!Geocoder.isPresent()) return null
        val geocoder = Geocoder(context, Locale.CHINA)
        val list: List<Address>? = withTimeoutOrNull(4000L) {
            runCatching {
                if (Build.VERSION.SDK_INT >= 33) {
                    suspendCancellableCoroutine<List<Address>?> { cont ->
                        geocoder.getFromLocation(lat, lon, 1, object : Geocoder.GeocodeListener {
                            override fun onGeocode(addresses: MutableList<Address>) { if (cont.isActive) cont.resume(addresses) }
                            override fun onError(errorMessage: String?) { if (cont.isActive) cont.resume(null) }
                        })
                    }
                } else {
                    @Suppress("DEPRECATION")
                    geocoder.getFromLocation(lat, lon, 1)
                }
            }.getOrNull()
        }
        val a = list?.firstOrNull() ?: return null
        val area = listOfNotNull(a.adminArea, a.locality ?: a.subAdminArea, a.subLocality).distinct().joinToString("")
        if (area.isBlank()) return null
        val street = listOfNotNull(a.thoroughfare, a.subThoroughfare).joinToString("")
        return area to (area + street)
    }

    private fun fromNominatim(lat: Double, lon: Double): Pair<String, String>? = runCatching {
        val url = "https://nominatim.openstreetmap.org/reverse?format=jsonv2&addressdetails=1&zoom=18&accept-language=zh-CN&lat=$lat&lon=$lon"
        val req = Request.Builder().url(url).header("User-Agent", "Shiyi-Android/personal-assistant").build()
        client.newCall(req).execute().use { r ->
            if (!r.isSuccessful) return@use null
            val a = Json.parseToJsonElement(r.body?.string().orEmpty()).jsonObject["address"] as? JsonObject ?: return@use null
            fun f(vararg keys: String) = keys.firstNotNullOfOrNull { k -> (a[k] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() } }
            val area = listOfNotNull(
                f("state", "province"),
                f("city", "town", "county"),
                f("city_district", "district", "suburb", "county"),
            ).distinct().joinToString("")
            if (area.isBlank()) return@use null
            val street = listOfNotNull(f("road"), f("house_number")).joinToString("")
            val near = f("neighbourhood", "quarter", "amenity", "building")
            area to (area + street + (if (street.isEmpty() && near != null) near else ""))
        }
    }.getOrNull()

    private fun distance(aLat: Double, aLon: Double, bLat: Double, bLon: Double): Float {
        val out = FloatArray(1)
        Location.distanceBetween(aLat, aLon, bLat, bLon, out)
        return out[0]
    }

    private fun load(): Place? {
        val area = prefs.getString("area", null) ?: return null
        return Place(
            prefs.getFloat("lat", 0f).toDouble(), prefs.getFloat("lon", 0f).toDouble(), prefs.getFloat("acc", 0f),
            prefs.getLong("at", 0L), area, prefs.getString("detail", null) ?: area,
        )
    }

    private fun save(p: Place) {
        prefs.edit().putFloat("lat", p.lat.toFloat()).putFloat("lon", p.lon.toFloat()).putFloat("acc", p.accuracy)
            .putLong("at", p.at).putString("area", p.area).putString("detail", p.detail).apply()
    }

    private companion object {
        /** 缓存多久以内不重新定位 */
        const val REFRESH_MS = 10 * 60_000L
    }
}
