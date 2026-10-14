package com.carpe.ideashell

import com.carpe.ideashell.core.notes.NoteSections
import com.carpe.ideashell.core.notes.RevisitTopic
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RevisitTopicTest {
    @Test
    fun titleIsFirstLineTruncated() {
        assertEquals("读完《设计中的设计》", RevisitTopic.title("读完《设计中的设计》\n第二行"))
        assertEquals(30, RevisitTopic.title("字".repeat(60)).length)
        assertEquals("专题", RevisitTopic.title("  "))
    }

    @Test
    fun bodyQuotesTheSourceAndStartsThoughtSection() {
        val body = RevisitTopic.body("Daily Note · 2026-10-08", "第一行\n第二行", "新想法", "2026-10-13 14:30")
        assertEquals(
            "> 摘自 Daily Note · 2026-10-08\n>\n> 第一行\n> 第二行\n\n## 想法\n- **2026-10-13 14:30** 新想法",
            body,
        )
    }

    @Test
    fun appendThoughtAddsToExistingSectionAndKeepsTags() {
        val first = RevisitTopic.body("Daily Note · 2026-10-08", "一句话", "想法一", "2026-10-13 14:30") + "\n\n#专题"
        val next = RevisitTopic.appendThought(first, "想法二", "2026-10-14 09:00")
        assertTrue(next.contains("- **2026-10-13 14:30** 想法一\n- **2026-10-14 09:00** 想法二"))
        assertTrue(next.trimEnd().endsWith("#专题"))
        assertEquals("- **2026-10-13 14:30** 想法一\n- **2026-10-14 09:00** 想法二", NoteSections.sectionBody(next, "想法"))
    }

    @Test
    fun appendThoughtCreatesSectionInPlainNote() {
        val next = RevisitTopic.appendThought("一篇普通笔记\n\n#标签", "新想法", "2026-10-13 14:30")
        assertEquals("一篇普通笔记\n\n## 想法\n- **2026-10-13 14:30** 新想法\n\n#标签", next)
    }
}
