package com.carpe.ideashell.system

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.widget.Toast

/**
 * 用对应的 App 打开一条内容（闪念贝壳的笔记、滴答清单的任务）。
 * 两个 App 都认自家的网页链接：Android 11+ 先要求「只交给非浏览器的 App」，装了就直接唤起 App；
 * 没装 / 不接管这个链接时退回浏览器，再不行就提示。
 */
fun openInApp(context: Context, url: String, appName: String) {
    val uri = Uri.parse(url)
    fun view() = Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    if (Build.VERSION.SDK_INT >= 30) {
        try {
            context.startActivity(view().addFlags(Intent.FLAG_ACTIVITY_REQUIRE_NON_BROWSER))
            return
        } catch (_: ActivityNotFoundException) {
            // 没有 App 接管这个链接，往下用浏览器
        }
    }
    try {
        context.startActivity(view())
        if (Build.VERSION.SDK_INT >= 30) Toast.makeText(context, "没有找到${appName} App，已用浏览器打开", Toast.LENGTH_SHORT).show()
    } catch (_: ActivityNotFoundException) {
        Toast.makeText(context, "无法打开：没有可用的应用", Toast.LENGTH_SHORT).show()
    }
}

/** 闪念贝壳的 Android 版：国内版 / Google Play 国际版，各自的包名与自定义链接协议 */
private val IDEASHELL_APPS = listOf(
    "com.roundreddot.ideashell" to "ideashellcn",
    "com.rrd.ideaShell" to "ideashell",
)

/**
 * 在闪念贝壳 App 里打开一条笔记。
 * App 并不认 `ideashell.site/boards/…` 这种网页链接（它只接管 api.ideashell.cn），所以改用它自己的链接协议
 * `ideashellcn://note/detail?id=笔记id`（国内版；推送通知点开笔记用的就是这种格式）。
 * 链接打不开时至少把 App 拉起来；没装 App 才退回网页版。
 */
fun openIdeaShellNote(context: Context, noteId: String) {
    val id = Uri.encode(noteId)
    for ((pkg, scheme) in IDEASHELL_APPS) {
        try {
            context.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse("$scheme://note/detail?id=$id"))
                    .setPackage(pkg)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            return
        } catch (_: ActivityNotFoundException) {
            // 这个版本没装 / 不认这个链接，试下一个
        } catch (_: SecurityException) {
        }
        val launch = context.packageManager.getLaunchIntentForPackage(pkg) ?: continue
        try {
            context.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            Toast.makeText(context, "已打开闪念贝壳，请在里面找这条笔记", Toast.LENGTH_SHORT).show()
            return
        } catch (_: Exception) {
        }
    }
    openInApp(context, com.carpe.ideashell.data.project.noteUrl(noteId), "闪念贝壳")
}
