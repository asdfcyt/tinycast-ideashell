package com.carpe.ideashell

import com.carpe.ideashell.data.ideashell.DailyEntry
import com.carpe.ideashell.data.ideashell.DailyFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DailyFormatTest {
    @Test
    fun splitsPlainEntries() {
        val content = "- **2026-10-08 11:37** 第一条\n  接着写\n- **2026-10-08 12:00** 第二条"
        assertEquals(
            listOf(DailyEntry("11:37", "第一条 接着写"), DailyEntry("12:00", "第二条")),
            DailyFormat.entries(content),
        )
    }

    @Test
    fun splitsOldFormatWithSecondsAndNoBullet() {
        val content = "2026-10-08 11:37:40 旧格式一条\n**2026-10-08 12:01:02** 加粗时间"
        assertEquals(
            listOf(DailyEntry("11:37", "旧格式一条"), DailyEntry("12:01", "加粗时间")),
            DailyFormat.entries(content),
        )
    }

    @Test
    fun splitsStruckThroughEntries() {
        val content = listOf(
            "- ~~**2026-10-08 09:00** 整条划掉~~",
            "- **~~2026-10-08 10:00~~** 只划了时间",
            "- ~~**2026-10-08 11:00**~~ ~~时间和正文分开划~~",
            "- **2026-10-08 12:00** ~~正文整句划掉~~",
            "- **2026-10-08 13:00** 没有删除线",
        ).joinToString("\n")
        val entries = DailyFormat.entries(content)
        assertEquals(listOf("09:00", "10:00", "11:00", "12:00", "13:00"), entries.map { it.time })
        assertEquals(listOf(true, true, true, true, false), entries.map { it.struck })
        assertEquals(listOf("整条划掉", "只划了时间", "时间和正文分开划", "正文整句划掉", "没有删除线"), entries.map { it.text })
    }

    @Test
    fun partialStrikeInsideTextIsKept() {
        val entry = DailyFormat.entries("- **2026-10-08 09:00** 买 ~~牛奶~~ 咖啡").single()
        assertEquals("买 ~~牛奶~~ 咖啡", entry.text)
        assertEquals(false, entry.struck)
    }

    @Test
    fun struckEntryContinuesOnNextLines() {
        val entry = DailyFormat.entries("- ~~**2026-10-08 09:00** 第一行\n  第二行~~").single()
        assertEquals("第一行 第二行", entry.text)
        assertTrue(entry.struck)
    }

    @Test
    fun unindentedPlainLineContinuesEntryButHeadingsAndListsDoNot() {
        val content = "- **2026-10-08 09:00** 开头\n没缩进的续行\n## 标题\n- **2026-10-08 10:00** 下一条\n- 普通列表项"
        val sections = DailyFormat.sections(content)
        assertEquals(listOf(DailyEntry("09:00", "开头 没缩进的续行"), DailyEntry("10:00", "下一条")), sections.entries)
        assertEquals("## 标题\n- 普通列表项", sections.other)
    }

    @Test
    fun quoteBlockAndBlankLinesAreNotEntries() {
        val content = "> 今日简报\n> 完成 3 件\n\n- **2026-10-08 09:00** 一条"
        val sections = DailyFormat.sections(content)
        assertEquals(1, sections.entries.size)
        assertEquals("> 今日简报\n> 完成 3 件", sections.other)
    }

    @Test
    fun normalizeLeavesStruckLinesUntouched() {
        val struck = "- ~~**2026-10-08 09:00** 整条划掉~~"
        assertEquals(struck, DailyFormat.normalize(struck))
        assertEquals(
            "- **2026-10-08 11:37** 旧格式",
            DailyFormat.normalize("2026-10-08 11:37:40 旧格式"),
        )
    }
}
