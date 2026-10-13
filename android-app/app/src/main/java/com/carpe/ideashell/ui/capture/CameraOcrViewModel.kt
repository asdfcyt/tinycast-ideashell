package com.carpe.ideashell.ui.capture

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.Companion.APPLICATION_KEY
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.carpe.ideashell.AppContainer
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.data.capture.CaptureImages
import com.carpe.ideashell.data.ocr.OcrException
import com.carpe.ideashell.data.ocr.OcrLine
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * 相机页（拍照 / 相册选图 / 识别文字）的状态。
 * 没开「识别文字」：拍到的、选到的图片直接交回去当附件；
 * 开了「识别文字」：图片先送腾讯云识别，进入识别页让用户挑要的文字，确定后把文字交回去。
 */
class CameraOcrViewModel(private val container: AppContainer) : ViewModel() {
    /** 非空表示在识别页：待识别的图片（已缩小压缩的本地文件） */
    var imagePath by mutableStateOf<String?>(null)
        private set

    /** 正在把拍到 / 选到的图片缩小压缩 */
    var importing by mutableStateOf(false)
        private set

    var recognizing by mutableStateOf(false)
        private set
    var lines by mutableStateOf<List<OcrLine>>(emptyList())
        private set
    var selected by mutableStateOf<Set<Int>>(emptySet())
        private set
    var error by mutableStateOf<String?>(null)
        private set

    /** 确定时是否把原图也附加到笔记 */
    var keepImage by mutableStateOf(false)

    var notice by mutableStateOf<String?>(null)
        private set

    /**
     * 选择方式（识别页右上角下拉）：
     * false =「划选识别」：整张图直接识别，识别后点选 / 划选文字；
     * true =「选择框」：先在图上拖出一个识别区域，点「识别」只识别框里的内容。上次的选择会记住。
     */
    var frameMode by mutableStateOf(container.settings.current.ocrFrameMode)
        private set

    /** 选择框模式下，图片已就位、等用户调整识别区域并点「识别」 */
    var cropping by mutableStateOf(false)
        private set

    /** 图片文件内容变了（旋转 / 裁剪）：界面据此重新加载 */
    var imageVersion by mutableStateOf(0)
        private set

    private var job: Job? = null
    private var handedOver = false

    /** 框选识别出来的结果默认全选（识别区域本身就是用户的选择） */
    private var autoSelectAll = false

    /** 相机拍出来的原始文件：导入（缩小压缩）后立即删除 */
    fun onPhoto(context: Context, file: File, ocr: Boolean, onImages: (List<String>) -> Unit) {
        val appContext = context.applicationContext
        viewModelScope.launch {
            importing = true
            val path = withContext(Dispatchers.IO) { CaptureImages.import(appContext, file).also { file.delete() } }
            importing = false
            if (path == null) {
                notice = "照片没能读取，请重试"
                return@launch
            }
            if (ocr) startRecognize(path) else onImages(listOf(path))
        }
    }

    /** 相册选的图片：识别模式只取第一张，否则全部作为附件 */
    fun onPicked(context: Context, uris: List<Uri>, ocr: Boolean, onImages: (List<String>) -> Unit) {
        if (uris.isEmpty()) return
        val appContext = context.applicationContext
        viewModelScope.launch {
            importing = true
            val targets = if (ocr) uris.take(1) else uris
            val paths = withContext(Dispatchers.IO) { targets.mapNotNull { CaptureImages.import(appContext, it) } }
            importing = false
            when {
                paths.isEmpty() -> notice = "图片没能读取，请换一张"
                ocr -> startRecognize(paths.first())
                else -> onImages(paths)
            }
        }
    }

    private fun startRecognize(path: String) {
        imagePath = path
        autoSelectAll = false
        if (frameMode) beginCropping() else recognize()
    }

    private fun beginCropping() {
        job?.cancel()
        recognizing = false
        lines = emptyList()
        selected = emptySet()
        error = null
        cropping = true
    }

    /** 切换选择方式：已经有图时立刻按新方式处理（划选 → 整图识别；选择框 → 回到框选区域） */
    fun chooseFrameMode(frame: Boolean) {
        if (frame == frameMode) return
        frameMode = frame
        container.settings.setOcrFrameMode(frame)
        if (imagePath == null) return
        autoSelectAll = false
        if (frame) {
            beginCropping()
        } else {
            cropping = false
            recognize()
        }
    }

    /** 顺时针旋转 90°。选择框阶段只转图；已经识别过的重新识别（文字框的位置变了） */
    fun rotate() {
        val path = imagePath ?: return
        if (importing) return
        viewModelScope.launch {
            importing = true
            val ok = withContext(Dispatchers.IO) {
                runCatching {
                    val source = BitmapFactory.decodeFile(path) ?: throw IllegalStateException("decode")
                    val turned = Bitmap.createBitmap(source, 0, 0, source.width, source.height, Matrix().apply { postRotate(90f) }, true)
                    writeJpeg(turned, path)
                    if (turned !== source) source.recycle()
                    turned.recycle()
                }.isSuccess
            }
            importing = false
            if (!ok) {
                notice = "旋转失败，请重试"
                return@launch
            }
            imageVersion++
            if (!cropping) recognize()
        }
    }

    /** 点「识别」：按选择框（占整张图的比例，0..1）裁出区域，只识别这一块 */
    fun recognizeCropped(left: Float, top: Float, right: Float, bottom: Float) {
        val path = imagePath ?: return
        if (importing) return
        viewModelScope.launch {
            importing = true
            val ok = withContext(Dispatchers.IO) {
                runCatching {
                    val source = BitmapFactory.decodeFile(path) ?: throw IllegalStateException("decode")
                    val x = (left * source.width).toInt().coerceIn(0, source.width - 1)
                    val y = (top * source.height).toInt().coerceIn(0, source.height - 1)
                    val w = ((right - left) * source.width).toInt().coerceIn(1, source.width - x)
                    val h = ((bottom - top) * source.height).toInt().coerceIn(1, source.height - y)
                    val cut = Bitmap.createBitmap(source, x, y, w, h)
                    writeJpeg(cut, path)
                    if (cut !== source) source.recycle()
                    cut.recycle()
                }.isSuccess
            }
            importing = false
            if (!ok) {
                notice = "裁剪失败，请重试"
                return@launch
            }
            imageVersion++
            cropping = false
            autoSelectAll = true
            recognize()
        }
    }

    private fun writeJpeg(bitmap: Bitmap, path: String) {
        File(path).outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 92, it) }
    }

    fun recognize() {
        val path = imagePath ?: return
        job?.cancel()
        job = viewModelScope.launch {
            recognizing = true
            error = null
            lines = emptyList()
            selected = emptySet()
            try {
                val bytes = withContext(Dispatchers.IO) { File(path).readBytes() }
                val result = container.ocr.recognize(bytes)
                lines = result
                // 划选模式不默认全选：由用户点选 / 划选要的文字（需要整页时点「全选」）；框选识别的结果默认全选
                selected = if (autoSelectAll) result.indices.toSet() else emptySet()
                if (result.isEmpty()) error = "没有识别到文字，换个角度或离近一点再拍"
            } catch (e: CancellationException) {
                throw e
            } catch (e: OcrException) {
                error = e.message ?: "识别失败"
            } catch (e: Exception) {
                error = "识别失败：${e.message ?: "未知错误"}"
            } finally {
                recognizing = false
            }
        }
    }

    fun toggle(index: Int) {
        selected = if (index in selected) selected - index else selected + index
    }

    fun select(indices: Collection<Int>) {
        if (indices.isNotEmpty()) selected = selected + indices
    }

    fun selectAll() {
        selected = lines.indices.toSet()
    }

    fun clearSelection() {
        selected = emptySet()
    }

    /** 重拍：丢掉这张图和识别结果，回到相机 */
    fun retake() {
        job?.cancel()
        imagePath?.let { CaptureImages.delete(listOf(it)) }
        imagePath = null
        lines = emptyList()
        selected = emptySet()
        error = null
        recognizing = false
        cropping = false
        autoSelectAll = false
    }

    /** 确定：返回选中的文字（按阅读顺序，一行一行）与要附加的图片（没勾「保留原图」就删掉） */
    fun confirm(): Pair<String, List<String>> {
        val text = lines.filterIndexed { i, _ -> i in selected }.joinToString("\n") { it.text }
        val path = imagePath
        val images = if (keepImage && path != null) listOf(path) else {
            path?.let { CaptureImages.delete(listOf(it)) }
            emptyList()
        }
        imagePath = null
        handedOver = true
        return text to images
    }

    /** 把已经导入好的图片路径交给调用方后，不再由这里清理 */
    fun markHandedOver() {
        handedOver = true
    }

    fun consumeNotice() {
        notice = null
    }

    override fun onCleared() {
        job?.cancel()
        if (!handedOver) imagePath?.let { CaptureImages.delete(listOf(it)) }
    }

    companion object {
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = this[APPLICATION_KEY] as IdeashellApp
                CameraOcrViewModel(app.container)
            }
        }
    }
}
