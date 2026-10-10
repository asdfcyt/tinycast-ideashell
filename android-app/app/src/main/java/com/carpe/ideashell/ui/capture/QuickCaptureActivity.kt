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
 * 轻量输入面板，一个 Activity 服务四个入口：
 * - 快速设置磁贴 / 桌面快捷方式：[ACTION_QUICK_CAPTURE]（可带 [EXTRA_KIND] 预设类型）
 * - 系统分享菜单：ACTION_SEND（文字 / 链接）
 * - 选中文字菜单：ACTION_PROCESS_TEXT
 */
class QuickCaptureActivity : ComponentActivity() {

    private val viewModel: QuickCaptureViewModel by viewModels { QuickCaptureViewModel.Factory }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val container = (application as IdeashellApp).container

        if (savedInstanceState == null) configureFrom(intent)

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

    override fun finish() {
        super.finish()
        // 面板自己有退场动画，系统的窗口转场关掉，避免叠加抖动
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    private fun configureFrom(intent: Intent) {
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT) ?: intent.getStringExtra(Intent.EXTRA_TITLE)
                viewModel.configure(ClipBuilder.fromShare(text, subject, sourceAppName()), null, "share")
            }

            Intent.ACTION_PROCESS_TEXT -> {
                val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString().orEmpty()
                viewModel.configure(ClipBuilder.fromSelection(text, sourceAppName()), null, "selection")
            }

            else -> {
                val preset = intent.getStringExtra(EXTRA_KIND)
                    ?.let { runCatching { CaptureKind.valueOf(it.uppercase()) }.getOrNull() }
                viewModel.configure(null as ClipInput?, preset, "quick")
            }
        }
    }

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
