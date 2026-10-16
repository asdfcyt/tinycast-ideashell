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

    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private var startedAt = 0L

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        startedAt = android.os.SystemClock.uptimeMillis()
        read()
    }

    /**
     * 读剪贴板。替用户点了「复制」时，复制是异步落到剪贴板的：读到的还是点之前的旧内容就每 50ms 再读，
     * 最多等 [WAIT_MS]；不用再固定多等一会儿。
     */
    private fun read() {
        if (done) return
        val since = intent.getLongExtra(EXTRA_SINCE, 0L)
        val clip = (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).primaryClip
        val ts = clip?.description?.timestamp ?: 0L
        if (since > 0 && ts < since && android.os.SystemClock.uptimeMillis() - startedAt < WAIT_MS) {
            handler.postDelayed({ read() }, 50)
            return
        }
        done = true
        // 没点到「复制」时，只认 1 分钟内复制的内容，避免把很久以前的剪贴板当成选中的文字
        val fresh = clip != null && System.currentTimeMillis() - ts < FRESH_MS
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
        const val EXTRA_SINCE = "since"
        private const val WAIT_MS = 700L
        private const val FRESH_MS = 60_000L
    }
}
