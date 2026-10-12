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
