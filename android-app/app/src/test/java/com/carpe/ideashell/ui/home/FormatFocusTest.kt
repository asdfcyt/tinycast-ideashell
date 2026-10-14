package com.carpe.ideashell.ui.home

import org.junit.Assert.assertEquals
import org.junit.Test

class FormatFocusTest {
    @Test
    fun formatsMinutesAndHours() {
        assertEquals("0 分钟", formatFocus(0))
        assertEquals("45 分钟", formatFocus(45))
        assertEquals("1 小时", formatFocus(60))
        assertEquals("1.2 小时", formatFocus(69))
        assertEquals("1.5 小时", formatFocus(90))
        assertEquals("2 小时", formatFocus(120))
    }
}
