package com.carpe.ideashell.system

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle

/**
 * 透明页：读一下剪贴板里的文字，交给快速摘录服务（[ExcerptService.onClipboardText]）。
 * Android 10 起只有拿到焦点的页面才能读剪贴板，所以点胶囊时临时拉起它，读完立刻关掉。
 */
class ExcerptClipActivity : Activity() {
    private var done = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setDimAmount(0f)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        done = true
        val clip = (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).primaryClip
        // 没点到「复制」时，只认 1 分钟内复制的内容，避免把很久以前的剪贴板当成选中的文字
        val fresh = clip != null && System.currentTimeMillis() - clip.description.timestamp < FRESH_MS
        val text = clip
            ?.takeIf { it.itemCount > 0 && (fresh || !intent.getBooleanExtra(EXTRA_FRESH_ONLY, false)) }
            ?.getItemAt(0)?.coerceToText(this)?.toString()
        ExcerptService.instance?.onClipboardText(text, intent.getStringExtra(EXTRA_PKG).orEmpty())
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    companion object {
        const val EXTRA_PKG = "pkg"
        const val EXTRA_FRESH_ONLY = "fresh_only"
        private const val FRESH_MS = 60_000L
    }
}
