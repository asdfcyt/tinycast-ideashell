package com.carpe.ideashell.ui.capture

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.Settings
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import com.carpe.ideashell.ui.components.AppMenu
import com.carpe.ideashell.ui.components.AppMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.R
import com.carpe.ideashell.data.ocr.OcrLine
import com.carpe.ideashell.ui.theme.Brand
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * 相机页：拍照页（图 3）与识别页（图 2）两个阶段。
 * [onDeliver] 把结果交回快记面板：文字（可为 null）+ 已导入好的图片路径。
 */
@Composable
fun CameraOcrScreen(
    viewModel: CameraOcrViewModel,
    remaining: Int,
    onDeliver: (String?, List<String>) -> Unit,
    onCancel: () -> Unit,
) {
    val context = LocalContext.current
    val container = (context.applicationContext as IdeashellApp).container
    val settings by container.settings.state.collectAsStateWithLifecycle()
    val ocrConfigured by container.credentials.ocrConfigured.collectAsStateWithLifecycle()
    // 开关记在设置里，但密钥被清掉后一律当作关
    val ocrOn = settings.ocrEnabled && ocrConfigured

    LaunchedEffect(viewModel.notice) {
        viewModel.notice?.let {
            Toast.makeText(context, it, Toast.LENGTH_SHORT).show()
            viewModel.consumeNotice()
        }
    }

    BackHandler {
        if (viewModel.imagePath != null) viewModel.retake() else onCancel()
    }

    val deliverImages: (List<String>) -> Unit = { paths -> onDeliver(null, paths) }

    // 相册：系统自带的照片选择器，不需要权限。识别模式只取一张；否则最多补满剩余张数
    val pickSingle = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri: Uri? ->
        if (uri != null) viewModel.onPicked(context, listOf(uri), ocrOn, deliverImages)
    }
    val pickMulti = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(max(2, remaining)),
    ) { uris -> viewModel.onPicked(context, uris, ocrOn, deliverImages) }

    val noRoom = !ocrOn && remaining <= 0
    // remaining < 0：调用方只要识别出的文字（比如专注记录），不收图片
    val ocrOnly = remaining < 0
    fun warnNoRoom() = Toast.makeText(
        context,
        if (ocrOnly) "这里只收识别出的文字，请先打开右下角「识别文字」" else "最多 9 张图片",
        Toast.LENGTH_SHORT,
    ).show()

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        if (viewModel.imagePath == null) {
            CameraStage(
                ocrOn = ocrOn,
                busy = viewModel.importing,
                onClose = onCancel,
                onToggleOcr = {
                    when {
                        ocrOn -> container.settings.setOcrEnabled(false)
                        !ocrConfigured -> Toast.makeText(context, "请先到「设置 → 文字识别」填入腾讯云密钥", Toast.LENGTH_LONG).show()
                        else -> container.settings.setOcrEnabled(true)
                    }
                },
                onAlbum = {
                    if (noRoom) {
                        warnNoRoom()
                    } else {
                        val request = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                        if (ocrOn || remaining <= 1) pickSingle.launch(request) else pickMulti.launch(request)
                    }
                },
                onPhoto = { file ->
                    if (noRoom) {
                        file.delete()
                        warnNoRoom()
                    } else {
                        viewModel.onPhoto(context, file, ocrOn, deliverImages)
                    }
                },
            )
        } else {
            RecognizeStage(
                viewModel = viewModel,
                onConfirm = {
                    val (text, images) = viewModel.confirm()
                    onDeliver(text, images)
                },
                onClose = onCancel,
            )
        }
    }
}

// ───────────────────────── 拍照页 ─────────────────────────

@Composable
private fun CameraStage(
    ocrOn: Boolean,
    busy: Boolean,
    onClose: () -> Unit,
    onToggleOcr: () -> Unit,
    onAlbum: () -> Unit,
    onPhoto: (File) -> Unit,
) {
    val context = LocalContext.current
    val activity = context as? Activity

    var hasCamera by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    var asked by rememberSaveable { mutableStateOf(false) }
    var denied by rememberSaveable { mutableStateOf(false) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        hasCamera = granted
        if (!granted) denied = true
    }
    LaunchedEffect(Unit) {
        if (!hasCamera && !asked) {
            asked = true
            permission.launch(Manifest.permission.CAMERA)
        }
    }

    var flashOn by rememberSaveable { mutableStateOf(false) }
    var shooting by remember { mutableStateOf(false) }
    val imageCapture = remember {
        ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
            .setResolutionSelector(
                ResolutionSelector.Builder().setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY).build(),
            )
            .build()
    }
    LaunchedEffect(flashOn) {
        imageCapture.flashMode = if (flashOn) ImageCapture.FLASH_MODE_ON else ImageCapture.FLASH_MODE_OFF
    }

    fun shoot() {
        if (shooting || busy || !hasCamera) return
        shooting = true
        val dir = File(context.cacheDir, "camera").apply { mkdirs() }
        val file = File(dir, "shot_${System.currentTimeMillis()}.jpg")
        imageCapture.takePicture(
            ImageCapture.OutputFileOptions.Builder(file).build(),
            ContextCompat.getMainExecutor(context),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    shooting = false
                    onPhoto(file)
                }

                override fun onError(exception: ImageCaptureException) {
                    shooting = false
                    Toast.makeText(context, "拍照失败，请重试", Toast.LENGTH_SHORT).show()
                }
            },
        )
    }

    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
        Row(
            modifier = Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            RoundIconButton(onClick = onClose, description = "关闭") {
                Icon(Icons.Filled.Close, contentDescription = null, tint = Color.White, modifier = Modifier.size(26.dp))
            }
            RoundIconButton(onClick = { flashOn = !flashOn }, description = if (flashOn) "关闭闪光灯" else "打开闪光灯") {
                Icon(
                    painterResource(if (flashOn) R.drawable.ic_flash_on else R.drawable.ic_flash_off),
                    contentDescription = null,
                    tint = if (flashOn) Brand.Orange else Color.White,
                    modifier = Modifier.size(24.dp),
                )
            }
        }

        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            Box(Modifier.fillMaxWidth().aspectRatio(3f / 4f), contentAlignment = Alignment.Center) {
                if (hasCamera) {
                    CameraPreview(imageCapture = imageCapture, modifier = Modifier.fillMaxSize())
                } else {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                        modifier = Modifier.padding(32.dp),
                    ) {
                        Text(
                            "需要相机权限才能拍照\n也可以点左下角从相册选图",
                            color = Color.White.copy(alpha = 0.8f),
                            textAlign = TextAlign.Center,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        OutlinedButton(
                            onClick = {
                                val permanentlyDenied = denied && activity != null &&
                                    !ActivityCompat.shouldShowRequestPermissionRationale(activity, Manifest.permission.CAMERA)
                                if (permanentlyDenied) {
                                    runCatching {
                                        context.startActivity(
                                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")),
                                        )
                                    }
                                } else {
                                    permission.launch(Manifest.permission.CAMERA)
                                }
                            },
                        ) { Text("授权相机", color = Color.White) }
                    }
                }
            }
            if (ocrOn) {
                Text(
                    "识别文字已开启 · 拍完自动识别",
                    color = Color.White,
                    style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .padding(top = 12.dp)
                        .clip(RoundedCornerShape(50))
                        .background(Color.Black.copy(alpha = 0.55f))
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                )
            }
            if (busy) CircularProgressIndicator(color = Color.White, strokeWidth = 3.dp)
        }

        Row(
            modifier = Modifier.fillMaxWidth().height(132.dp).padding(horizontal = 24.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            BottomAction(
                iconRes = R.drawable.ic_image,
                label = "相册",
                active = false,
                onClick = onAlbum,
            )
            Box(
                modifier = Modifier
                    .size(76.dp)
                    .border(4.dp, Color.White, CircleShape)
                    .padding(7.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = if (shooting || busy || !hasCamera) 0.45f else 1f))
                    .clickable(enabled = !shooting && !busy && hasCamera, role = Role.Button, onClick = ::shoot),
            )
            BottomAction(
                iconRes = R.drawable.ic_ocr,
                label = "识别文字",
                active = ocrOn,
                onClick = onToggleOcr,
            )
        }
    }
}

@Composable
private fun RoundIconButton(onClick: () -> Unit, description: String, content: @Composable () -> Unit) {
    Box(
        modifier = Modifier
            .size(48.dp)
            .clip(CircleShape)
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { content() }
}

/** 拍照页底部左右两侧的图标按钮（相册 / 识别文字）：圆形底 + 小字标签；开启时是品牌色 */
@Composable
private fun BottomAction(iconRes: Int, label: String, active: Boolean, onClick: () -> Unit) {
    Column(
        modifier = Modifier
            .width(64.dp)
            .clip(RoundedCornerShape(14.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(CircleShape)
                .background(if (active) Brand.Orange else Color.White.copy(alpha = 0.16f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                painterResource(iconRes),
                contentDescription = label,
                tint = if (active) Brand.Brown else Color.White,
                modifier = Modifier.size(24.dp),
            )
        }
        Spacer(Modifier.height(4.dp))
        Text(label, color = if (active) Brand.Orange else Color.White.copy(alpha = 0.85f), fontSize = 11.sp, maxLines = 1)
    }
}

/** CameraX 预览：绑定到当前生命周期；点一下对焦（拍文字时很有用） */
@Composable
private fun CameraPreview(imageCapture: ImageCapture, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val previewView = remember {
        PreviewView(context).apply { scaleType = PreviewView.ScaleType.FIT_CENTER }
    }
    var camera by remember { mutableStateOf<Camera?>(null) }

    DisposableEffect(lifecycleOwner, imageCapture) {
        val future = ProcessCameraProvider.getInstance(context)
        var provider: ProcessCameraProvider? = null
        future.addListener({
            val p = runCatching { future.get() }.getOrNull() ?: return@addListener
            provider = p
            val preview = Preview.Builder()
                .setResolutionSelector(
                    ResolutionSelector.Builder().setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY).build(),
                )
                .build()
                .also { it.surfaceProvider = previewView.surfaceProvider }
            runCatching {
                p.unbindAll()
                camera = p.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, imageCapture)
            }.onFailure {
                Toast.makeText(context, "相机启动失败", Toast.LENGTH_SHORT).show()
            }
        }, ContextCompat.getMainExecutor(context))
        onDispose {
            camera = null
            provider?.unbindAll()
        }
    }

    Box(
        modifier = modifier.pointerInput(camera) {
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false)
                val up = awaitPointerUp(down.id)
                if (up) {
                    val c = camera ?: return@awaitEachGesture
                    val point = previewView.meteringPointFactory.createPoint(down.position.x, down.position.y)
                    runCatching { c.cameraControl.startFocusAndMetering(FocusMeteringAction.Builder(point).build()) }
                }
            }
        },
    ) {
        AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
    }
}

/** 等这根手指抬起；中途被别的手势消费（比如缩放）返回 false */
private suspend fun androidx.compose.ui.input.pointer.AwaitPointerEventScope.awaitPointerUp(id: androidx.compose.ui.input.pointer.PointerId): Boolean {
    while (true) {
        val event = awaitPointerEvent()
        val change = event.changes.firstOrNull { it.id == id } ?: return false
        if (change.isConsumed) return false
        if (!change.pressed) return true
    }
}

// ───────────────────────── 识别页 ─────────────────────────

@Composable
private fun RecognizeStage(viewModel: CameraOcrViewModel, onConfirm: () -> Unit, onClose: () -> Unit) {
    val path = viewModel.imagePath ?: return
    val version = viewModel.imageVersion
    val bitmap by produceState<ImageBitmap?>(null, path, version) {
        value = withContext(Dispatchers.IO) { runCatching { BitmapFactory.decodeFile(path)?.asImageBitmap() }.getOrNull() }
    }
    val lines = viewModel.lines
    val selected = viewModel.selected
    val cropping = viewModel.cropping
    val busy = viewModel.recognizing || viewModel.importing
    // 选择框（占整张图的比例）：换图 / 旋转后重置
    var crop by remember(path, version) { mutableStateOf(Rect(0.1f, 0.1f, 0.9f, 0.9f)) }

    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
        Row(
            modifier = Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            RoundIconButton(onClick = onClose, description = "关闭") {
                Icon(Icons.Filled.Close, contentDescription = null, tint = Color.White, modifier = Modifier.size(26.dp))
            }
            Text(
                text = when {
                    cropping -> "拖动边框，框住要识别的文字"
                    lines.isEmpty() -> "识别文字"
                    selected.isEmpty() -> "点选或划选要保留的文字"
                    else -> "已选 ${selected.size} / ${lines.size} 行"
                },
                color = Color.White,
                style = MaterialTheme.typography.titleSmall,
                maxLines = 1,
                textAlign = TextAlign.Center,
                modifier = Modifier.weight(1f),
            )
            // 选择方式（对标图 2 右上角的下拉）：划选识别 = 整图识别后划选文字；选择框 = 先框出识别区域，点「识别」只识别框里的
            var modeMenu by remember { mutableStateOf(false) }
            Box {
                Text(
                    "${if (viewModel.frameMode) "选择框" else "划选识别"} ▾",
                    color = Color.White,
                    fontSize = 14.sp,
                    modifier = Modifier
                        .clip(RoundedCornerShape(50))
                        .clickable(role = Role.Button) { modeMenu = true }
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                )
                AppMenu(expanded = modeMenu, onDismissRequest = { modeMenu = false }) {
                    listOf("划选识别" to false, "选择框" to true).forEach { (label, frame) ->
                        AppMenuItem(
                            text = { Text(label) },
                            selected = frame == viewModel.frameMode,
                            onClick = {
                                viewModel.chooseFrameMode(frame)
                                modeMenu = false
                            },
                        )
                    }
                }
            }
        }

        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            bitmap?.let { bmp ->
                if (cropping) {
                    CropFrameView(
                        bitmap = bmp,
                        crop = crop,
                        onCropChange = { crop = it },
                        modifier = Modifier.fillMaxSize().padding(horizontal = 8.dp),
                    )
                } else {
                    PhotoWithBoxes(
                        bitmap = bmp,
                        lines = lines,
                        selected = selected,
                        enabled = !viewModel.recognizing,
                        onTap = viewModel::toggle,
                        onSwipe = viewModel::select,
                        modifier = Modifier.fillMaxSize().padding(horizontal = 8.dp),
                    )
                }
            }
            if (viewModel.recognizing || viewModel.importing) {
                Column(
                    modifier = Modifier
                        .clip(RoundedCornerShape(16.dp))
                        .background(Color.Black.copy(alpha = 0.6f))
                        .padding(horizontal = 24.dp, vertical = 18.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    CircularProgressIndicator(color = Color.White, strokeWidth = 3.dp, modifier = Modifier.size(32.dp))
                    Text(if (viewModel.recognizing) "识别中…" else "处理中…", color = Color.White, style = MaterialTheme.typography.bodyMedium)
                }
            }
            if (!cropping) {
                viewModel.error?.let { message ->
                    Column(
                        modifier = Modifier
                            .padding(24.dp)
                            .clip(RoundedCornerShape(16.dp))
                            .background(Color.Black.copy(alpha = 0.7f))
                            .padding(horizontal = 20.dp, vertical = 16.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Text(message, color = Color.White, textAlign = TextAlign.Center, style = MaterialTheme.typography.bodyMedium)
                        OutlinedButton(onClick = viewModel::recognize) { Text("重试", color = Color.White) }
                    }
                }
            }
        }

        // 右下角的工具：旋转（识别前后都能用，转完会重新识别）；识别后还有保留图片 / 全选 / 重选
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (!cropping && lines.isNotEmpty()) {
                Pill("保留图片", active = viewModel.keepImage) { viewModel.keepImage = !viewModel.keepImage }
                Pill("全选", active = false, onClick = viewModel::selectAll)
                Pill("重选", active = false, onClick = viewModel::clearSelection)
            }
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(Color.White.copy(alpha = if (busy) 0.1f else 0.2f))
                    .clickable(enabled = !busy, role = Role.Button, onClick = viewModel::rotate)
                    .padding(horizontal = 14.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                val tint = Color.White.copy(alpha = if (busy) 0.4f else 1f)
                Icon(painterResource(R.drawable.ic_rotate), contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
                Text("旋转", color = tint, fontSize = 13.sp)
            }
        }

        Row(
            modifier = Modifier.fillMaxWidth().height(84.dp).padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            TextButton(onClick = viewModel::retake, modifier = Modifier.width(88.dp)) {
                Text("重拍", color = Color.White, style = MaterialTheme.typography.titleMedium)
            }
            Button(
                onClick = {
                    if (cropping) viewModel.recognizeCropped(crop.left, crop.top, crop.right, crop.bottom) else onConfirm()
                },
                enabled = if (cropping) !busy else !busy && selected.isNotEmpty(),
                modifier = Modifier.width(140.dp).height(46.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Brand.OrangeDeep,
                    contentColor = Color.White,
                    disabledContainerColor = Color.White.copy(alpha = 0.16f),
                    disabledContentColor = Color.White.copy(alpha = 0.4f),
                ),
            ) { Text(if (cropping) "识别" else "确定", style = MaterialTheme.typography.titleMedium) }
            Spacer(Modifier.width(88.dp))
        }
    }
}

@Composable
private fun Pill(label: String, active: Boolean, onClick: () -> Unit) {
    Text(
        label,
        color = if (active) Brand.Brown else Color.White,
        fontSize = 13.sp,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(if (active) Brand.Orange else Color.White.copy(alpha = 0.2f))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    )
}

/** 从 [from] 到 [to] 的线段上，每隔 [step] 取一点，落在（外扩 [pad] 的）文字框里的行 */
private fun indicesAlong(rects: List<Rect>, from: Offset, to: Offset, step: Float, pad: Float): List<Int> {
    val total = (to - from).getDistance()
    val n = max(1, (total / step).toInt())
    val found = LinkedHashSet<Int>()
    for (k in 0..n) {
        val p = from + (to - from) * (k.toFloat() / n)
        rects.forEachIndexed { i, r -> if (r.inflate(pad).contains(p)) found += i }
    }
    return found.toList()
}

/**
 * 选择框（对标图 2）：图片上叠一个绿色的识别区域，四角和四边中点有把手；
 * 拖把手改变大小，拖框内部整体移动，框外变暗。[crop] 是框占整张图的比例（0..1）。
 */
@Composable
private fun CropFrameView(
    bitmap: ImageBitmap,
    crop: Rect,
    onCropChange: (Rect) -> Unit,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    BoxWithConstraints(modifier, contentAlignment = Alignment.Center) {
        val maxW = with(density) { maxWidth.toPx() }
        val maxH = with(density) { maxHeight.toPx() }
        val scale = min(maxW / bitmap.width, maxH / bitmap.height)
        val w = bitmap.width * scale
        val h = bitmap.height * scale
        val widthDp = with(density) { w.toDp() }
        val heightDp = with(density) { h.toDp() }

        val latestCrop = rememberUpdatedState(crop)
        val latestChange = rememberUpdatedState(onCropChange)
        val frameGreen = Color(0xFF00E676)
        val stroke = with(density) { 2.dp.toPx() }
        val bracket = with(density) { 4.dp.toPx() }
        val bracketLen = with(density) { 20.dp.toPx() }

        Box(
            modifier = Modifier
                .size(widthDp, heightDp)
                .pointerInput(w, h) {
                    val grab = 28.dp.toPx()
                    val minSize = 56.dp.toPx()
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        val c = latestCrop.value
                        var box = Rect(c.left * w, c.top * h, c.right * w, c.bottom * h)
                        val p = down.position
                        val withinX = p.x in (box.left - grab)..(box.right + grab)
                        val withinY = p.y in (box.top - grab)..(box.bottom + grab)
                        val nearL = withinY && abs(p.x - box.left) <= grab
                        val nearR = withinY && abs(p.x - box.right) <= grab
                        val nearT = withinX && abs(p.y - box.top) <= grab
                        val nearB = withinX && abs(p.y - box.bottom) <= grab
                        // 同时靠近左右（框很窄）时取更近的一边
                        val dragLeft = nearL && (!nearR || abs(p.x - box.left) <= abs(p.x - box.right))
                        val dragRight = nearR && !dragLeft
                        val dragTop = nearT && (!nearB || abs(p.y - box.top) <= abs(p.y - box.bottom))
                        val dragBottom = nearB && !dragTop
                        val resizing = dragLeft || dragRight || dragTop || dragBottom
                        if (!resizing && !box.contains(p)) return@awaitEachGesture

                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull { it.id == down.id } ?: break
                            if (!change.pressed) break
                            // 必须先取位移再 consume：已消费的 change，positionChange() 返回 0
                            val d = change.positionChange()
                            change.consume()
                            box = if (resizing) {
                                Rect(
                                    left = if (dragLeft) (box.left + d.x).coerceIn(0f, box.right - minSize) else box.left,
                                    top = if (dragTop) (box.top + d.y).coerceIn(0f, box.bottom - minSize) else box.top,
                                    right = if (dragRight) (box.right + d.x).coerceIn(box.left + minSize, w) else box.right,
                                    bottom = if (dragBottom) (box.bottom + d.y).coerceIn(box.top + minSize, h) else box.bottom,
                                )
                            } else {
                                val nl = (box.left + d.x).coerceIn(0f, w - box.width)
                                val nt = (box.top + d.y).coerceIn(0f, h - box.height)
                                Rect(nl, nt, nl + box.width, nt + box.height)
                            }
                            latestChange.value(Rect(box.left / w, box.top / h, box.right / w, box.bottom / h))
                        }
                    }
                },
        ) {
            Image(bitmap, contentDescription = "待识别的图片", contentScale = ContentScale.FillBounds, modifier = Modifier.fillMaxSize())
            Canvas(Modifier.fillMaxSize()) {
                val l = crop.left * size.width
                val t = crop.top * size.height
                val r = crop.right * size.width
                val b = crop.bottom * size.height
                val dim = Color.Black.copy(alpha = 0.5f)
                // 框外变暗
                drawRect(dim, topLeft = Offset(0f, 0f), size = Size(size.width, t))
                drawRect(dim, topLeft = Offset(0f, b), size = Size(size.width, size.height - b))
                drawRect(dim, topLeft = Offset(0f, t), size = Size(l, b - t))
                drawRect(dim, topLeft = Offset(r, t), size = Size(size.width - r, b - t))
                drawRect(frameGreen, topLeft = Offset(l, t), size = Size(r - l, b - t), style = Stroke(stroke))
                // 四角的粗括号
                fun corner(x: Float, y: Float, dx: Float, dy: Float) {
                    drawLine(frameGreen, Offset(x - dx * bracket / 2, y), Offset(x + dx * bracketLen, y), bracket)
                    drawLine(frameGreen, Offset(x, y - dy * bracket / 2), Offset(x, y + dy * bracketLen), bracket)
                }
                corner(l, t, 1f, 1f)
                corner(r, t, -1f, 1f)
                corner(l, b, 1f, -1f)
                corner(r, b, -1f, -1f)
                // 四边中点的短把手
                val mid = bracketLen
                val cx = (l + r) / 2
                val cy = (t + b) / 2
                drawLine(frameGreen, Offset(cx - mid / 2, t), Offset(cx + mid / 2, t), bracket)
                drawLine(frameGreen, Offset(cx - mid / 2, b), Offset(cx + mid / 2, b), bracket)
                drawLine(frameGreen, Offset(l, cy - mid / 2), Offset(l, cy + mid / 2), bracket)
                drawLine(frameGreen, Offset(r, cy - mid / 2), Offset(r, cy + mid / 2), bracket)
            }
        }
    }
}

/**
 * 图片 + 文字框：框随图片等比缩放；点一下切换某一行，手指划过的文字会被选中并留下一道划痕。
 * 选中的行填橙色，没选的只描一圈绿边（对标图 2）。
 */
@Composable
private fun PhotoWithBoxes(
    bitmap: ImageBitmap,
    lines: List<OcrLine>,
    selected: Set<Int>,
    enabled: Boolean,
    onTap: (Int) -> Unit,
    onSwipe: (List<Int>) -> Unit,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    BoxWithConstraints(modifier, contentAlignment = Alignment.Center) {
        val maxW = with(density) { maxWidth.toPx() }
        val maxH = with(density) { maxHeight.toPx() }
        val scale = min(maxW / bitmap.width, maxH / bitmap.height)
        val widthDp = with(density) { (bitmap.width * scale).toDp() }
        val heightDp = with(density) { (bitmap.height * scale).toDp() }

        val rects = remember(lines, scale) {
            lines.map { Rect(it.left * scale, it.top * scale, it.right * scale, it.bottom * scale) }
        }
        val hitSlop = with(density) { 6.dp.toPx() }
        var trail by remember { mutableStateOf<List<Offset>>(emptyList()) }
        val latestTap = rememberUpdatedState(onTap)
        val latestSwipe = rememberUpdatedState(onSwipe)
        val orange = Brand.Orange
        val green = Color(0xFF4FD6B0)
        val strokeThin = with(density) { 1.5.dp.toPx() }
        val strokeThick = with(density) { 2.dp.toPx() }

        Box(
            modifier = Modifier
                .size(widthDp, heightDp)
                .pointerInput(rects, enabled) {
                    if (!enabled) return@pointerInput
                    val slop = viewConfiguration.touchSlop
                    val step = 6.dp.toPx()
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        val start = down.position
                        var last = start
                        var dragging = false
                        val points = mutableListOf(start)
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull { it.id == down.id } ?: break
                            if (!change.pressed) {
                                if (!dragging) {
                                    val hit = rects.indexOfFirst { it.inflate(hitSlop).contains(start) }
                                    if (hit >= 0) latestTap.value(hit)
                                }
                                break
                            }
                            val pos = change.position
                            if (!dragging && (pos - start).getDistance() > slop) dragging = true
                            if (dragging) {
                                change.consume()
                                points += pos
                                trail = points.toList()
                                val hits = indicesAlong(rects, last, pos, step, hitSlop / 2)
                                if (hits.isNotEmpty()) latestSwipe.value(hits)
                                last = pos
                            }
                        }
                        trail = emptyList()
                    }
                },
        ) {
            Image(bitmap, contentDescription = "待识别的图片", contentScale = ContentScale.FillBounds, modifier = Modifier.fillMaxSize())
            Canvas(Modifier.fillMaxSize()) {
                lines.forEachIndexed { i, line ->
                    val path = Path().apply {
                        line.xs.indices.forEach { k ->
                            val x = line.xs[k] * scale
                            val y = line.ys[k] * scale
                            if (k == 0) moveTo(x, y) else lineTo(x, y)
                        }
                        close()
                    }
                    if (i in selected) {
                        drawPath(path, orange.copy(alpha = 0.38f))
                        drawPath(path, orange, style = Stroke(strokeThick))
                    } else {
                        drawPath(path, green.copy(alpha = 0.9f), style = Stroke(strokeThin))
                    }
                }
                if (trail.size > 1) {
                    val trailPath = Path().apply {
                        moveTo(trail.first().x, trail.first().y)
                        trail.drop(1).forEach { lineTo(it.x, it.y) }
                    }
                    drawPath(
                        trailPath,
                        Color.White.copy(alpha = 0.55f),
                        style = Stroke(strokeThick * 5, cap = StrokeCap.Round, join = StrokeJoin.Round),
                    )
                }
            }
        }
    }
}
