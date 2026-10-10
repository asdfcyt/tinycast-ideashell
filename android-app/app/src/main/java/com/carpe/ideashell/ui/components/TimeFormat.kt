package com.carpe.ideashell.ui.components

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** 列表里的相对时间：刚刚 / N 分钟前 / 今天 14:20 / 昨天 09:05 / 10月9日 */
fun relativeTime(epochMs: Long, nowMs: Long = System.currentTimeMillis()): String {
    val diff = nowMs - epochMs
    if (diff < 60_000) return "刚刚"
    if (diff < 3_600_000) return "${diff / 60_000} 分钟前"

    val zone = ZoneId.systemDefault()
    val at = Instant.ofEpochMilli(epochMs).atZone(zone)
    val today = LocalDate.now(zone)
    val clock = "%02d:%02d".format(at.hour, at.minute)
    return when (at.toLocalDate()) {
        today -> "今天 $clock"
        today.minusDays(1) -> "昨天 $clock"
        else -> "${at.monthValue}月${at.dayOfMonth}日"
    }
}

/** 首页问候语 */
fun greeting(hour: Int): String = when (hour) {
    in 5..10 -> "早上好"
    in 11..12 -> "中午好"
    in 13..17 -> "下午好"
    in 18..22 -> "晚上好"
    else -> "夜深了"
}
