package com.carpe.ideashell.data.capture

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * 记录里的图片：从相册 / 相机拿到的原图先缩小并压成 JPEG 存进应用私有目录，之后随记录一起上传。
 * 闪念贝壳的限制是单张 ≤ 5MB、最多 9 张，所以这里长边限制在 2048px，质量从 85 往下压到 ≤ 4MB。
 */
object CaptureImages {
    const val MAX_COUNT = 9
    private const val MAX_EDGE = 2048
    private const val MAX_BYTES = 4 * 1024 * 1024

    private fun dir(context: Context): File = File(context.filesDir, "capture_images").apply { mkdirs() }

    /** 导入一张图片，返回存好的文件路径；读取 / 解码失败返回 null */
    fun import(context: Context, uri: Uri): String? = runCatching {
        val source = ImageDecoder.createSource(context.contentResolver, uri)
        val bitmap = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val longest = maxOf(info.size.width, info.size.height)
            if (longest > MAX_EDGE) {
                val scale = MAX_EDGE.toFloat() / longest
                decoder.setTargetSize((info.size.width * scale).toInt().coerceAtLeast(1), (info.size.height * scale).toInt().coerceAtLeast(1))
            }
        }
        var quality = 85
        var bytes: ByteArray
        do {
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
            bytes = out.toByteArray()
            quality -= 10
        } while (bytes.size > MAX_BYTES && quality >= 35)
        bitmap.recycle()
        val file = File(dir(context), "img_${System.currentTimeMillis()}_${(0..9999).random()}.jpg")
        file.writeBytes(bytes)
        file.absolutePath
    }.getOrNull()

    fun delete(paths: List<String>) {
        paths.forEach { runCatching { File(it).delete() } }
    }
}
