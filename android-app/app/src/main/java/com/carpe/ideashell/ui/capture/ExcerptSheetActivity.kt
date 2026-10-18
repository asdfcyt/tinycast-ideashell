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
import com.carpe.ideashell.data.capture.ExcerptDrafts
import com.carpe.ideashell.data.capture.ExcerptNotes
import com.carpe.ideashell.data.llm.polishExcerptThought
import com.carpe.ideashell.system.ExcerptService
import com.carpe.ideashell.ui.theme.ApplyEdgeToEdge
import com.carpe.ideashell.ui.theme.IdeashellTheme
import com.carpe.ideashell.ui.theme.isDark
import kotlinx.coroutines.launch

/**
 * 摘录抽屉：在摘录模式里点胶囊后，从屏幕底部升起，写下对这段摘录的想法，
 * 并确认来源和标签（同一个 App 里自动延续上一次的）。点保存（或键盘回车）才写进笔记；点遮罩 / 返回键放弃，但写了的想法会暂存一小会儿（见 [ExcerptDrafts]）。
 */
class ExcerptSheetActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val container = (application as IdeashellApp).container
        val pkg = intent.getStringExtra(EXTRA_PKG).orEmpty()
        val appName = intent.getStringExtra(EXTRA_APP).orEmpty()
        val quote = intent.getStringExtra(EXTRA_QUOTE).orEmpty()
        // 没有摘录内容（比如系统在进程重启后把抽屉恢复出来）：不弹空抽屉
        if (quote.isBlank()) {
            finish()
            return
        }
        val docTitle = intent.getStringExtra(EXTRA_TITLE)
        val suggestion = container.excerpts.suggest(pkg, docTitle, appName)
        // 误触关掉的想法暂存在内存里：同一段摘录再打开（点胶囊 / 重新划线同一段），接着写
        val draft = ExcerptDrafts.alive()?.takeIf { it.quote == quote && it.pkg == pkg }
        if (draft == null) ExcerptDrafts.clear()

        setContent {
            val settings by container.settings.state.collectAsStateWithLifecycle()
            IdeashellTheme(settings.themeMode) {
                ApplyEdgeToEdge(isDark(settings.themeMode))
                ExcerptSheetScreen(
                    quote = quote,
                    appName = appName,
                    initialSource = draft?.source ?: suggestion.source,
                    initialTags = draft?.tags ?: suggestion.tags.joinToString(" ") { "#$it" },
                    initialThought = draft?.thought.orEmpty(),
                    initialAppend = draft?.append ?: true,
                    // AI 整理：用设置里配的大模型整理想法（没填 Key 时会提示去设置里填）
                    onPolish = { thought ->
                        if (!container.llm.configured) throw IllegalStateException("请先到「设置」里填写大模型 API Key")
                        container.llm.polishExcerptThought(quote, thought)
                    },
                    onSave = { source, tagsText, thought, append ->
                        val entry = ExcerptNotes.Entry(pkg, appName, source, ExcerptNotes.parseTags(tagsText), quote, thought, append)
                        val app = applicationContext
                        ExcerptDrafts.clear()
                        ExcerptService.instance?.onDraftChanged()
                        container.appScope.launch {
                            val result = container.excerpts.write(entry)
                            // appScope 在后台线程，Toast 要回主线程弹
                            Handler(Looper.getMainLooper()).post { Toast.makeText(app, messageOf(result), Toast.LENGTH_SHORT).show() }
                        }
                        finish()
                    },
                    onClose = { source, tagsText, thought, append ->
                        // 写了想法才暂存；什么都没写就是单纯放弃
                        if (thought.isNotBlank()) {
                            ExcerptDrafts.put(ExcerptDrafts.Draft(pkg, appName, docTitle, quote, source, tagsText, thought, append))
                        } else {
                            ExcerptDrafts.clear()
                        }
                        ExcerptService.instance?.onDraftChanged()
                        finish()
                    },
                )
            }
        }
    }

    override fun onStart() {
        super.onStart()
        ExcerptService.sheetOpen = true
    }

    override fun onStop() {
        ExcerptService.sheetOpen = false
        super.onStop()
    }

    override fun onDestroy() {
        ExcerptService.sheetOpen = false
        super.onDestroy()
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
