package com.carpe.ideashell.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.carpe.ideashell.IdeashellApp

/** 读一张笔记里的图片：命中内存缓存直接有；否则后台下载。[reload] 变一下就重试 */
@Composable
private fun rememberNoteBitmap(url: String, reload: Int): Pair<ImageBitmap?, Boolean> {
    val loader = (LocalContext.current.applicationContext as IdeashellApp).container.noteImages
    var bitmap by remember(url) { mutableStateOf(loader.cached(url)?.asImageBitmap()) }
    var failed by remember(url) { mutableStateOf(false) }
    LaunchedEffect(url, reload) {
        if (bitmap != null) return@LaunchedEffect
        failed = false
        val b = loader.load(url)
        if (b != null) bitmap = b.asImageBitmap() else failed = true
    }
    return bitmap to failed
}

/** 笔记正文里的一张图：整宽显示，按图片比例定高；点一下全屏查看（可双指缩放），加载失败点一下重试 */
@Composable
fun NoteImage(url: String, modifier: Modifier = Modifier) {
    var reload by remember { mutableIntStateOf(0) }
    var full by remember { mutableStateOf(false) }
    val (bitmap, failed) = rememberNoteBitmap(url, reload)
    val scheme = MaterialTheme.colorScheme
    if (bitmap != null) {
        Image(
            bitmap = bitmap,
            contentDescription = "笔记图片",
            contentScale = ContentScale.FillWidth,
            modifier = modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .clickable { full = true },
        )
        if (full) ImageViewer(bitmap, onClose = { full = false })
    } else {
        Box(
            modifier = modifier
                .fillMaxWidth()
                .height(120.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(scheme.onSurface.copy(alpha = 0.06f))
                .clickable(enabled = failed) { reload++ },
            contentAlignment = Alignment.Center,
        ) {
            if (failed) {
                Text("图片没能加载，点一下重试", style = MaterialTheme.typography.bodySmall, color = scheme.onSurfaceVariant)
            } else {
                CircularProgressIndicator(modifier = Modifier.height(28.dp))
            }
        }
    }
}

/** 全屏看图：双指缩放 / 拖动，单击关闭 */
@Composable
private fun ImageViewer(bitmap: ImageBitmap, onClose: () -> Unit) {
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        var scale by remember { mutableStateOf(1f) }
        var offsetX by remember { mutableStateOf(0f) }
        var offsetY by remember { mutableStateOf(0f) }
        Box(
            Modifier
                .fillMaxSize()
                .background(Color.Black)
                .pointerInput(Unit) { detectTapGestures(onTap = { onClose() }, onDoubleTap = { scale = 1f; offsetX = 0f; offsetY = 0f }) }
                .pointerInput(Unit) {
                    detectTransformGestures { _, pan, zoom, _ ->
                        scale = (scale * zoom).coerceIn(1f, 5f)
                        if (scale > 1f) {
                            offsetX += pan.x
                            offsetY += pan.y
                        } else {
                            offsetX = 0f
                            offsetY = 0f
                        }
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            Image(
                bitmap = bitmap,
                contentDescription = "查看图片",
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer(scaleX = scale, scaleY = scale, translationX = offsetX, translationY = offsetY),
            )
        }
    }
}
