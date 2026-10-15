package com.carpe.ideashell.ui.capture

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.data.capture.ExcerptNotes
import com.carpe.ideashell.ui.theme.ApplyEdgeToEdge
import com.carpe.ideashell.ui.theme.IdeashellTheme
import com.carpe.ideashell.ui.theme.isDark
import kotlinx.coroutines.launch

/**
 * 摘录抽屉：在摘录模式里点胶囊后，从屏幕底部升起，写下对这段摘录的想法，
 * 并确认来源和标签（同一个 App 里自动延续上一次的）。点保存才写进笔记；点遮罩 / 返回键就放弃。
 */
class ExcerptSheetActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val container = (application as IdeashellApp).container
        val pkg = intent.getStringExtra(EXTRA_PKG).orEmpty()
        val appName = intent.getStringExtra(EXTRA_APP).orEmpty()
        val quote = intent.getStringExtra(EXTRA_QUOTE).orEmpty()
        val suggestion = container.excerpts.suggest(pkg, intent.getStringExtra(EXTRA_TITLE), appName)

        setContent {
            val settings by container.settings.state.collectAsStateWithLifecycle()
            IdeashellTheme(settings.themeMode) {
                ApplyEdgeToEdge(isDark(settings.themeMode))
                ExcerptSheetScreen(
                    quote = quote,
                    appName = appName,
                    initialSource = suggestion.source,
                    initialTags = suggestion.tags.joinToString(" ") { "#$it" },
                    onSave = { source, tagsText, thought ->
                        val entry = ExcerptNotes.Entry(pkg, appName, source, ExcerptNotes.parseTags(tagsText), quote, thought)
                        val app = applicationContext
                        container.appScope.launch {
                            val result = container.excerpts.write(entry)
                            // appScope 在后台线程，Toast 要回主线程弹
                            Handler(Looper.getMainLooper()).post { Toast.makeText(app, messageOf(result), Toast.LENGTH_SHORT).show() }
                        }
                        finish()
                    },
                    onClose = { finish() },
                )
            }
        }
    }

    override fun finish() {
        super.finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    companion object {
        private const val EXTRA_PKG = "pkg"
        private const val EXTRA_APP = "app"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_QUOTE = "quote"

        fun intent(context: Context, pkg: String, appName: String, docTitle: String?, quote: String): Intent =
            Intent(context, ExcerptSheetActivity::class.java)
                .putExtra(EXTRA_PKG, pkg)
                .putExtra(EXTRA_APP, appName)
                .putExtra(EXTRA_TITLE, docTitle)
                .putExtra(EXTRA_QUOTE, quote)

        fun messageOf(r: ExcerptNotes.Result): String = when (r) {
            is ExcerptNotes.Result.Created -> "已摘录 · 新笔记「${r.title}」"
            is ExcerptNotes.Result.Appended -> "已追加到「${r.title}」"
            is ExcerptNotes.Result.Queued -> "已摘录 · 稍后同步"
        }
    }
}
