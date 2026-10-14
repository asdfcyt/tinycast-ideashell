package com.carpe.ideashell

import com.carpe.ideashell.core.parse.RepeatPreset
import com.carpe.ideashell.core.parse.RepeatRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import java.time.DayOfWeek
import java.time.LocalDate
import org.junit.Test

class RepeatRuleTest {
    private val wednesday = LocalDate.of(2026, 10, 14)

    @Test
    fun presetsProduceDidaRRules() {
        assertEquals("RRULE:FREQ=DAILY;INTERVAL=1", RepeatPreset.DAILY.rule(wednesday).toRRule())
        assertEquals("RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR", RepeatPreset.WORKDAY.rule(wednesday).toRRule())
        assertEquals("RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=WE", RepeatPreset.WEEKLY.rule(wednesday).toRRule())
        assertEquals("RRULE:FREQ=MONTHLY;INTERVAL=1;BYMONTHDAY=14", RepeatPreset.MONTHLY.rule(wednesday).toRRule())
        assertEquals("RRULE:FREQ=YEARLY;INTERVAL=1", RepeatPreset.YEARLY.rule(wednesday).toRRule())
    }

    @Test
    fun labels() {
        assertEquals("每天", RepeatPreset.DAILY.rule(wednesday).label())
        assertEquals("每个工作日", RepeatPreset.WORKDAY.rule(wednesday).label())
        assertEquals("每周周三", RepeatPreset.WEEKLY.rule(wednesday).label())
        assertEquals("每月 14 日", RepeatPreset.MONTHLY.rule(wednesday).label())
        assertEquals("每 2 周周一、周五", RepeatRule(RepeatRule.Freq.WEEKLY, 2, setOf(DayOfWeek.FRIDAY, DayOfWeek.MONDAY)).label())
        assertEquals("每 3 天", RepeatRule(RepeatRule.Freq.DAILY, 3).label())
    }

    @Test
    fun parseRoundTrip() {
        val rules = listOf(
            RepeatPreset.DAILY.rule(wednesday),
            RepeatPreset.WORKDAY.rule(wednesday),
            RepeatPreset.MONTHLY.rule(wednesday),
            RepeatRule(RepeatRule.Freq.WEEKLY, 2, setOf(DayOfWeek.MONDAY, DayOfWeek.SUNDAY)),
        )
        rules.forEach { assertEquals(it, RepeatRule.parse(it.toRRule())) }
        assertNull(RepeatRule.parse(""))
        assertNull(RepeatRule.parse(null))
        assertNull(RepeatRule.parse("ERULE:NAME=CUSTOM"))
    }

    @Test
    fun resolvedFillsInDateDependentParts() {
        assertEquals(setOf(DayOfWeek.WEDNESDAY), RepeatRule(RepeatRule.Freq.WEEKLY).resolved(wednesday).weekdays)
        assertEquals(14, RepeatRule(RepeatRule.Freq.MONTHLY).resolved(wednesday).monthDay)
    }

    @Test
    fun presetDetection() {
        assertEquals(RepeatPreset.WEEKLY, RepeatPreset.of(RepeatPreset.WEEKLY.rule(wednesday), wednesday))
        assertNull(RepeatPreset.of(RepeatRule(RepeatRule.Freq.DAILY, 2), wednesday))
    }
}
