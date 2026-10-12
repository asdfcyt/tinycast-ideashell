package com.carpe.ideashell.ui.capture

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.core.capture.ClipBuilder
import com.carpe.ideashell.core.capture.ClipInput
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.ui.MainActivity
import com.carpe.ideashell.ui.theme.ApplyEdgeToEdge
import com.carpe.ideashell.ui.theme.IdeashellTheme
import com.carpe.ideashell.ui.theme.isDark

/**
 * 轻量输入面板，一个 Activity 服务所有入口：
 * - 快速设置磁贴 / 桌面快捷方式 / 通知上的「＋」：[ACTION_QUICK_CAPTURE]（可带 [EXTRA_KIND] 预设类型）
 * - 系统分享菜单：ACTION_SEND / ACTION_SEND_MULTIPLE（文字 / 链接）
 * - 选中文字菜单：ACTION_PROCESS_TEXT
 * - 荣耀任意门：拖拽文字后系统以「分享」的方式（ACTION_SEND + EXTRA_TEXT）或 deeplink 拉起本页，
 *   所以与分享共用同一条路径；deeplink 形如 `ideashell://capture?text=正文&title=标题&url=链接&source=来源&kind=todo`
 *
 * singleTop：面板已经开着时再来一份内容，走 [onNewIntent] 重新开始，而不是被忽略。
 */
class QuickCaptureActivity : ComponentActivity() {

    private val viewModel: QuickCaptureViewModel by viewModels { QuickCaptureViewModel.Factory }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val container = (application as IdeashellApp).container

        if (savedInstanceState == null) configureFrom(intent, fresh = false)

        setContent {
            val settings by container.settings.state.collectAsStateWithLifecycle()
            IdeashellTheme(settings.themeMode) {
                ApplyEdgeToEdge(isDark(settings.themeMode))
                QuickCaptureScreen(
                    viewModel = viewModel,
                    readClipboard = ::readClipboardText,
                    onClose = { finish() },
                    onOpenApp = {
                        startActivity(Intent(this, MainActivity::class.java))
                        finish()
                    },
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        configureFrom(intent, fresh = true)
    }

    override fun finish() {
        super.finish()
        // 面板自己有退场动画，系统的窗口转场关掉，避免叠加抖动
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    private fun configureFrom(intent: Intent, fresh: Boolean) {
        var clip: ClipInput? = null
        var preset: CaptureKind? = null
        var origin = "quick"

        when (intent.action) {
            Intent.ACTION_SEND -> {
                val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() ?: clipText(intent)
                val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT) ?: intent.getStringExtra(Intent.EXTRA_TITLE)
                clip = ClipBuilder.fromShare(text, subject, sourceAppName())
                origin = "share"
            }

            Intent.ACTION_SEND_MULTIPLE -> {
                // 任意门一次拖多段文字时是 EXTRA_TEXT 数组：合并成一条，每段之间空一行
                val parts = intent.getCharSequenceArrayListExtra(Intent.EXTRA_TEXT)?.map { it.toString() }
                val text = parts?.filter { it.isNotBlank() }?.joinToString("\n\n") ?: clipText(intent)
                clip = ClipBuilder.fromShare(text, intent.getStringExtra(Intent.EXTRA_SUBJECT), sourceAppName())
                origin = "share"
            }

            Intent.ACTION_PROCESS_TEXT -> {
                val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString().orEmpty()
                clip = ClipBuilder.fromSelection(text, sourceAppName())
                origin = "selection"
            }

            Intent.ACTION_VIEW -> {
                val uri = intent.data
                if (uri != null) {
                    val text = (uri.getQueryParameter("text") ?: uri.getQueryParameter("content")).orEmpty()
                    val url = uri.getQueryParameter("url").orEmpty()
                    val joined = listOf(text, url).filter { it.isNotBlank() }.joinToString("\n")
                    clip = ClipBuilder.fromShare(joined, uri.getQueryParameter("title"), uri.getQueryParameter("source") ?: sourceAppName())
                    preset = uri.getQueryParameter("kind")?.let { k -> runCatching { CaptureKind.valueOf(k.uppercase()) }.getOrNull() }
                    origin = "deeplink"
                }
            }

            else -> {
                preset = intent.getStringExtra(EXTRA_KIND)
                    ?.let { runCatching { CaptureKind.valueOf(it.uppercase()) }.getOrNull() }
            }
        }

        if (fresh) viewModel.reconfigure(clip, preset, origin) else viewModel.configure(clip, preset, origin)
    }

    /** 有些来源（含部分系统拖拽）不填 EXTRA_TEXT，文字放在 ClipData 里 */
    private fun clipText(intent: Intent): String? =
        intent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this)?.toString()

    /** 来源应用名：靠 referrer 拿到包名再查应用名（需要 manifest 里的 <queries>） */
    private fun sourceAppName(): String? {
        val pkg = referrer?.takeIf { it.scheme == "android-app" }?.host ?: return null
        if (pkg == packageName || pkg == "android") return null
        return runCatching {
            @Suppress("DEPRECATION")
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
        }.getOrNull()
    }

    private fun readClipboardText(): String? {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        return cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this)?.toString()
    }

    companion object {
        const val ACTION_QUICK_CAPTURE = "com.carpe.ideashell.action.QUICK_CAPTURE"
        const val EXTRA_KIND = "kind"
    }
}
