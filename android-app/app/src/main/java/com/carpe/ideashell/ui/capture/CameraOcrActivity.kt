package com.carpe.ideashell.ui.capture

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.data.capture.CaptureImages
import com.carpe.ideashell.ui.theme.IdeashellTheme

/** 相机页交回来的结果：[text] 是识别出的文字（没开识别为 null），[images] 是已导入好的图片文件路径 */
data class CameraCaptureResult(val text: String?, val images: List<String>)

/** 启动相机页：输入是还能再加几张图片；用户取消时返回 null */
class CameraCaptureContract : ActivityResultContract<Int, CameraCaptureResult?>() {
    override fun createIntent(context: Context, input: Int): Intent =
        Intent(context, CameraOcrActivity::class.java).putExtra(CameraOcrActivity.EXTRA_REMAINING, input)

    override fun parseResult(resultCode: Int, intent: Intent?): CameraCaptureResult? {
        if (resultCode != android.app.Activity.RESULT_OK || intent == null) return null
        return CameraCaptureResult(
            text = intent.getStringExtra(CameraOcrActivity.EXTRA_TEXT)?.takeIf { it.isNotBlank() },
            images = intent.getStringArrayListExtra(CameraOcrActivity.EXTRA_IMAGES).orEmpty(),
        )
    }
}

/**
 * 全屏相机页：快记面板工具栏上「拍照 / 插入图片」合并后的入口。
 * 左下相册、中间快门、右下「识别文字」开关；开了识别，拍完或选完图就进识别页，挑好文字后交回快记面板。
 */
class CameraOcrActivity : ComponentActivity() {

    private val viewModel: CameraOcrViewModel by viewModels { CameraOcrViewModel.Factory }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        val container = (application as IdeashellApp).container
        val remaining = intent.getIntExtra(EXTRA_REMAINING, CaptureImages.MAX_COUNT)

        setContent {
            val settings by container.settings.state.collectAsStateWithLifecycle()
            IdeashellTheme(settings.themeMode) {
                CameraOcrScreen(
                    viewModel = viewModel,
                    remaining = remaining,
                    onDeliver = ::deliver,
                    onCancel = {
                        viewModel.retake()
                        setResult(RESULT_CANCELED)
                        finish()
                    },
                )
            }
        }
    }

    private fun deliver(text: String?, images: List<String>) {
        viewModel.markHandedOver()
        setResult(
            RESULT_OK,
            Intent()
                .putExtra(EXTRA_TEXT, text)
                .putStringArrayListExtra(EXTRA_IMAGES, ArrayList(images)),
        )
        finish()
    }

    companion object {
        const val EXTRA_REMAINING = "remaining"
        const val EXTRA_TEXT = "text"
        const val EXTRA_IMAGES = "images"
    }
}
