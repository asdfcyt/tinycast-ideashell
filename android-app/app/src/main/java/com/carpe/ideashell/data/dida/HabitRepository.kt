package com.carpe.ideashell.data.dida

import com.carpe.ideashell.data.project.HabitDone
import com.carpe.ideashell.data.project.WorkspaceStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.LocalDate
import java.time.ZonedDateTime

/**
 * 滴答习惯：今天需要打卡的习惯 + 一点打卡；在项目里「记一条」后，自动给同名习惯打卡。
 * 习惯接口的返回格式没有公开样例，按「找到有 id + name 的对象」宽松解析；
 * 读不到打卡记录时，用本机记下的「今天已打过卡」兜底。
 */
class HabitRepository(
    private val api: DidaApi,
    private val workspace: WorkspaceStore,
) {
    private val lock = Mutex()
    private var cache: Pair<Long, List<Habit>>? = null

    /** 今天需要打卡的习惯（含已打卡的，[Habit.doneToday] 区分） */
    suspend fun today(force: Boolean = false, day: LocalDate = LocalDate.now()): List<Habit> {
        val habits = loadHabits(force).filter { HabitParser.isDue(it.repeat, day) }
        if (habits.isEmpty()) return emptyList()
        val stamp = HabitParser.stampOf(day)
        val ids = habits.map { it.id }
        val checkins = try {
            HabitParser.parseCheckins(api.habitCheckinsRaw(ids, stamp), ids.toSet(), stamp)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            emptyMap()
        }
        val local = localDone(stamp)
        return habits.map { h ->
            val c = checkins[h.id]
            h.copy(checkinId = c?.id, doneToday = c?.done == true || h.id in local)
        }
    }

    /**
     * [from]..[to]（含）每个习惯的打卡情况：只数「按重复规则当天需要打卡」的日子，今天也算上本机记下的打卡。
     * 读不到打卡记录时抛异常，由调用方决定不显示。
     */
    suspend fun statsIn(from: LocalDate, to: LocalDate): List<HabitStat> {
        val habits = loadHabits(false)
        if (habits.isEmpty()) return emptyList()
        val ids = habits.map { it.id }
        val done = HabitParser.parseCheckinDays(
            api.habitCheckinsRangeRaw(ids, HabitParser.stampOf(from), HabitParser.stampOf(to)),
            ids.toSet(),
        )
        val todayStamp = HabitParser.stampOf(LocalDate.now())
        val local = localDone(todayStamp)
        val days = generateSequence(from) { it.plusDays(1) }.takeWhile { !it.isAfter(to) }.toList()
        return habits.map { h ->
            val due = days.filter { HabitParser.isDue(h.repeat, it) }
            val doneStamps = done[h.id].orEmpty()
            val n = due.count { d ->
                val st = HabitParser.stampOf(d)
                st in doneStamps || (st == todayStamp && h.id in local)
            }
            HabitStat(h.name, due.size, n)
        }
    }

    /** 给习惯打卡（写入目标值，状态为已完成） */
    suspend fun checkin(h: Habit, now: ZonedDateTime = ZonedDateTime.now()) {
        val stamp = HabitParser.stampOf(now.toLocalDate())
        api.upsertHabitCheckin(h.id, h.checkinId, stamp, h.goal, now)
        markDone(stamp, h.id)
    }

    /**
     * 项目「记一条」后：滴答里有和项目同名的习惯（项目「篆刻」、习惯「篆刻」）就自动打卡。
     * 没有同名习惯、今天已打过、或出错，都静默返回 null；成功返回习惯名。
     */
    suspend fun autoCheckinByName(name: String): String? = try {
        val key = name.trim().lowercase()
        val habit = loadHabits(false).firstOrNull { it.name.lowercase() == key }
        if (habit == null) {
            null
        } else {
            val stamp = HabitParser.stampOf(LocalDate.now())
            if (habit.id in localDone(stamp)) {
                null
            } else {
                val pending = today().firstOrNull { it.id == habit.id && !it.doneToday }
                if (pending == null) null else { checkin(pending); habit.name }
            }
        }
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    private suspend fun loadHabits(force: Boolean): List<Habit> = lock.withLock {
        cache?.let { (at, list) ->
            // 空列表只缓存很短时间，避免解析失败 / 刚创建习惯时长时间看不到
            val ttl = if (list.isEmpty()) 5 * 60_000L else 12 * 3_600_000L
            if (!force && System.currentTimeMillis() - at < ttl) return@withLock list
        }
        val list = HabitParser.parseHabits(api.habitsRaw())
        cache = System.currentTimeMillis() to list
        list
    }

    private fun localDone(stamp: Int): Set<String> =
        workspace.current.habitDone.takeIf { it.stamp == stamp }?.ids?.toSet().orEmpty()

    private fun markDone(stamp: Int, id: String) {
        workspace.update { w ->
            val ids = (w.habitDone.takeIf { it.stamp == stamp }?.ids.orEmpty() + id).distinct()
            w.copy(habitDone = HabitDone(stamp, ids))
        }
    }
}
