package com.carpe.ideashell.data.calendar

import com.carpe.ideashell.core.calendar.ChinaHolidays
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.time.LocalDate
import java.util.concurrent.TimeUnit

@Serializable
private data class HolidayYearDto(val year: Int = 0, val days: List<HolidayDayDto> = emptyList())

@Serializable
private data class HolidayDayDto(val name: String = "", val date: String = "", val isOffDay: Boolean = false)

/**
 * 法定节假日 / 调休数据：从开源数据集 holiday-cn（[NateScarlet/holiday-cn](https://github.com/NateScarlet/holiday-cn)，
 * 由 GitHub Actions 按国务院公告自动更新）按年份拉取 JSON，缓存在本机，日历里用。
 * - 当年、上一年、下一年各一份；缓存没过期就不联网；拉不到就用旧缓存，都没有就只显示农历 / 节日（不显示休 / 班）；
 * - 下一年的安排还没公布时数据集里 days 是空的，每隔几天再问一次，公布后自动出现。
 */
class HolidayRepository(
    private val dir: File,
    private val scope: CoroutineScope,
) {
    private val client = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(12, TimeUnit.SECONDS)
        .build()
    private val json = Json { ignoreUnknownKeys = true }
    private val lock = Mutex()

    private val _version = MutableStateFlow(0)

    /** 每次装入新数据加一；日历据此重新取休 / 班标记 */
    val version: StateFlow<Int> = _version.asStateFlow()

    private val loaded = HashMap<Int, HolidayYearDto>()

    init {
        refresh()
    }

    /** 读缓存、必要时联网更新，然后把结果装进 [ChinaHolidays]；在后台跑，不阻塞界面 */
    fun refresh() {
        scope.launch(Dispatchers.IO) {
            lock.withLock {
                val thisYear = LocalDate.now().year
                var changed = false
                for (year in listOf(thisYear - 1, thisYear, thisYear + 1)) {
                    val file = File(dir, "$year.json")
                    val cached = readCache(file)
                    if (cached != null && loaded[year] != cached) {
                        loaded[year] = cached
                        changed = true
                    }
                    if (!isStale(file, cached)) continue
                    val fresh = download(year) ?: continue
                    runCatching {
                        dir.mkdirs()
                        file.writeText(fresh.second)
                    }
                    if (loaded[year] != fresh.first) {
                        loaded[year] = fresh.first
                        changed = true
                    } else {
                        file.setLastModified(System.currentTimeMillis())
                    }
                }
                if (changed) install()
            }
        }
    }

    private fun install() {
        val entries = HashMap<LocalDate, ChinaHolidays.Entry>()
        val years = HashSet<Int>()
        for ((year, dto) in loaded) {
            if (dto.days.isEmpty()) continue
            years += year
            for (day in dto.days) {
                val date = runCatching { LocalDate.parse(day.date) }.getOrNull() ?: continue
                entries[date] = ChinaHolidays.Entry(
                    if (day.isOffDay) ChinaHolidays.Kind.OFF else ChinaHolidays.Kind.WORK,
                    day.name,
                )
            }
        }
        ChinaHolidays.install(entries, years)
        _version.value = _version.value + 1
    }

    /** 缓存没有、或太旧就该更新：已公布的 2 周；还没公布（days 为空）的 2 天 */
    private fun isStale(file: File, cached: HolidayYearDto?): Boolean {
        if (cached == null || !file.exists()) return true
        val age = System.currentTimeMillis() - file.lastModified()
        val limit = if (cached.days.isEmpty()) 2L else 14L
        return age > TimeUnit.DAYS.toMillis(limit)
    }

    private fun readCache(file: File): HolidayYearDto? =
        runCatching { json.decodeFromString(HolidayYearDto.serializer(), file.readText()) }.getOrNull()

    /** 依次试几个镜像；成功返回（解析结果, 原文） */
    private suspend fun download(year: Int): Pair<HolidayYearDto, String>? = withContext(Dispatchers.IO) {
        for (base in MIRRORS) {
            val text = runCatching {
                client.newCall(Request.Builder().url(base.format(year)).build()).execute().use { resp ->
                    if (resp.isSuccessful) resp.body?.string() else null
                }
            }.getOrNull() ?: continue
            val dto = runCatching { json.decodeFromString(HolidayYearDto.serializer(), text) }.getOrNull() ?: continue
            // 年份对不上就当没拿到（镜像返回了别的东西）
            if (dto.year == year) return@withContext dto to text
        }
        null
    }

    private companion object {
        val MIRRORS = listOf(
            "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/%d.json",
            "https://fastly.jsdelivr.net/gh/NateScarlet/holiday-cn@master/%d.json",
            "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/%d.json",
        )
    }
}
