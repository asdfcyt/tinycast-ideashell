package com.carpe.ideashell.ui.capture

import android.app.Activity
import android.os.Bundle
import com.carpe.ideashell.system.ExcerptService

/** 透明跳板：桌面快捷方式「快速摘录」，点一下开始 / 结束快速摘录模式 */
class ExcerptToggleActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ExcerptService.toggle(this)
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}
