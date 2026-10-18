package com.carpe.ideashell.ui.capture

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.core.content.IntentCompat
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.core.capture.CaptureSchedule
import com.carpe.ideashell.core.capture.ClipBuilder
import com.carpe.ideashell.core.capture.ClipInput
import com.carpe.ideashell.core.parse.CaptureKind
import com.carpe.ideashell.system.DirectShare
import com.carpe.ideashell.ui.MainActivity
import com.carpe.ideashell.ui.theme.ApplyEdgeToEdge
import com.carpe.ideashell.ui.theme.IdeashellTheme
import com.carpe.ideashell.ui.theme.isDark
import java.time.LocalDate

/**
 * 轻量输入面板，一个 Activity 服务所有入口：
 * - 快速设置磁贴 / 桌面快捷方式 / 通知上的「＋」：[ACTION_QUICK_CAPTURE]（可带 [EXTRA_KIND] 预设类型）
 * - 系统分享菜单：ACTION_SEND / ACTION_SEND_MULTIPLE（文字 / 链接 / 图片；图片走「拾忆 · 图片」入口，存成带图片的笔记）
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

    override fun onPause() {
        // 点到面板外面、返回键、切走：没提交的文字先存下来，下次打开还在
        viewModel.saveDraft()
        super.onPause()
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
        // 分享进来的图片：不走「摘录」卡，直接进普通输入面板的图片栏，和相册选图是同一条路径
        val sharedImages = sharedImageUris(intent)
        var caption: String? = null
        // 预填到输入框的文字（项目快捷方式：「#项目 」）
        var presetText: String? = null
        // 预选的日期（待办页选了某一天再点「+」）：带上这一天，全天
        var presetDate: LocalDate? = null

        if (sharedImages.isNotEmpty()) {
            caption = (intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() ?: intent.getStringExtra(Intent.EXTRA_SUBJECT))
                ?.trim()?.takeIf { it.isNotEmpty() }
            origin = "share"
        } else when (intent.action) {
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
                presetText = intent.getStringExtra(DirectShare.EXTRA_PRESET_TEXT)
                presetDate = intent.getStringExtra(EXTRA_DATE)?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
            }
        }

        // 从分享菜单第一行的「直接分享」目标进来：按目标决定类型 / 项目
        val target = if (origin == "share") DirectShare.parse(intent.getStringExtra(Intent.EXTRA_SHORTCUT_ID)) else null
        if (target != null) {
            preset = target.kind
            if (target.project != null) presetText = "#${target.project} "
            // 待办 / 日记：文字不走「摘录」卡，直接成为输入框里的内容，再按类型保存
            val shared = clip
            if (shared != null && target.kind != CaptureKind.NOTE) {
                presetText = listOfNotNull(
                    shared.quote.takeIf { it.isNotBlank() },
                    shared.pageTitle?.takeIf { shared.quote.isBlank() },
                    shared.url,
                ).joinToString(" ")
                clip = null
            }
        }

        if (fresh) viewModel.reconfigure(clip, preset, origin) else viewModel.configure(clip, preset, origin)
        // 磁贴「语音记一条」：面板就绪后自动开始录音
        viewModel.voiceStartRequest = intent.getBooleanExtra(EXTRA_START_VOICE, false)
        if (presetText != null) {
            viewModel.text = presetText
            viewModel.baselineText = presetText
        } else if (clip == null && sharedImages.isEmpty()) {
            // 普通的「记一条」：把上次没提交就关掉的文字放回来
            viewModel.restoreDraft()
        }
        if (presetDate != null) viewModel.schedule = CaptureSchedule(presetDate, null)
        if (sharedImages.isNotEmpty()) {
            if (caption != null) viewModel.text = presetText.orEmpty() + caption
            viewModel.addImages(this, sharedImages)
        }
    }

    /** 分享 Intent 里的图片地址：单张在 EXTRA_STREAM，多张是列表；有些来源只把地址放在 ClipData 里 */
    private fun sharedImageUris(intent: Intent): List<Uri> {
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) return emptyList()
        val found = LinkedHashSet<Uri>()
        IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)?.let(found::add)
        IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)?.let(found::addAll)
        intent.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(found::add)
        }
        // 只收图片：类型明确不是图片（比如分享一个文件）就不要硬塞进图片栏
        return found.filter { uri ->
            val type = contentResolver.getType(uri) ?: intent.type
            type == null || type.startsWith("image/")
        }
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

        /** true：面板打开后立刻开始语音录入（快速设置磁贴「语音记一条」） */
        const val EXTRA_START_VOICE = "start_voice"

        /** 预选日期（yyyy-MM-dd）：待办页选了某一天后点「+」，新待办直接排在这一天 */
        const val EXTRA_DATE = "date"

        /** 打开快记面板；[date] 不为空时预设为待办并排在这一天 */
        fun intent(context: Context, date: LocalDate? = null): Intent =
            Intent(context, QuickCaptureActivity::class.java).apply {
                action = ACTION_QUICK_CAPTURE
                if (date != null) {
                    putExtra(EXTRA_KIND, CaptureKind.TODO.name)
                    putExtra(EXTRA_DATE, date.toString())
                }
            }
    }
}
