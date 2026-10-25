package com.carpe.ideashell.data.llm

import com.carpe.ideashell.core.plan.Series
import com.carpe.ideashell.core.plan.parseDay
import com.carpe.ideashell.data.dida.DidaTask

/** 改期结果里的一项（任务 id → 排到哪天 + 理由）；[AiPlanner.enforceSeriesOrder] 用它兜底系列任务的先后顺序 */
class AiPlanResult(val items: List<Item>, val summary: String, val skipped: Int) {
    class Item(val id: String, val date: String, val reason: String)
}

object AiPlanner {
    /**
     * 同一个系列里编号小的必须不晚于编号大的：
     * 1. 前面的任务没排上，后面的也不排；
     * 2. 已经排好的同系列任务（busy）里，编号更小的在更晚的日子，后面的就不能排在它前面；
     * 3. 其余的，把这批任务拿到的日期按从早到晚重新发给编号从小到大的任务。
     */
    internal fun enforceSeriesOrder(items: List<AiPlanResult.Item>, tasks: List<DidaTask>, busy: List<DidaTask>): List<AiPlanResult.Item> {
        val out = items.toMutableList()
        val groups = HashMap<String, MutableList<Pair<DidaTask, Int>>>()
        for (t in tasks) Series.parse(t)?.let { groups.getOrPut(it.key) { ArrayList() } += t to it.n }
        val busyGroups = HashMap<String, MutableList<Pair<String, Int>>>()
        for (t in busy) {
            if (t.done) continue
            val s = Series.parse(t) ?: continue
            val d = parseDay(t.date)?.toString() ?: continue
            busyGroups.getOrPut(s.key) { ArrayList() } += d to s.n
        }

        for ((key, members) in groups) {
            val sorted = members.sortedBy { it.second }
            // 1. 前面没排上的，后面的也不排
            val firstMissing = sorted.firstOrNull { m -> out.none { it.id == m.first.id } }?.second
            if (firstMissing != null) {
                val drop = sorted.filter { it.second > firstMissing }.map { it.first.id }.toSet()
                out.removeAll { it.id in drop }
            }
            // 2. 编号更小、已经排在某天的同系列任务：后面的不能比它早
            for (m in sorted) {
                val idx = out.indexOfFirst { it.id == m.first.id }
                if (idx < 0) continue
                val floor = busyGroups[key].orEmpty().filter { it.second < m.second }.maxOfOrNull { it.first }
                if (floor != null && out[idx].date < floor) out.removeAt(idx)
            }
            // 3. 日期按编号重新分配
            val planned = sorted.filter { m -> out.any { it.id == m.first.id } }
            if (planned.size <= 1) continue
            val dates = planned.mapNotNull { m -> out.firstOrNull { it.id == m.first.id }?.date }.sorted()
            planned.zip(dates).forEach { (m, d) ->
                val i = out.indexOfFirst { it.id == m.first.id }
                if (i >= 0 && out[i].date != d) out[i] = AiPlanResult.Item(out[i].id, d, out[i].reason + "（按章节顺序调整）")
            }
        }
        return out
    }
}
