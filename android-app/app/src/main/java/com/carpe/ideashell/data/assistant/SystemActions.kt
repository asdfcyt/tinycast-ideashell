package com.carpe.ideashell.data.assistant

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.provider.AlarmClock
import android.provider.ContactsContract
import android.view.KeyEvent

/**
 * 助手能代你做的系统动作：全部走标准 Intent / 系统接口，不需要额外的特殊权限。
 * 返回给人看的一句话（成功或失败原因），不抛异常。
 * 打电话只是把号码填进拨号盘，要不要拨出去由你按。
 */
object SystemActions {
    fun setAlarm(context: Context, hour: Int, minute: Int, label: String?, days: List<Int>?): String {
        if (hour !in 0..23 || minute !in 0..59) return "时间不对：$hour:$minute"
        val intent = Intent(AlarmClock.ACTION_SET_ALARM)
            .putExtra(AlarmClock.EXTRA_HOUR, hour)
            .putExtra(AlarmClock.EXTRA_MINUTES, minute)
            .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
        if (!label.isNullOrBlank()) intent.putExtra(AlarmClock.EXTRA_MESSAGE, label.trim())
        // 系统的星期：Calendar.SUNDAY=1 … SATURDAY=7；传进来的是 1=周一 … 7=周日
        val weekdays = days?.filter { it in 1..7 }?.map { if (it == 7) 1 else it + 1 }?.distinct()
        if (!weekdays.isNullOrEmpty()) intent.putExtra(AlarmClock.EXTRA_DAYS, ArrayList(weekdays))
        return launch(context, intent, "已设闹钟 %02d:%02d".format(hour, minute) + (label?.takeIf { it.isNotBlank() }?.let { "（$it）" } ?: ""), "没能设闹钟")
    }

    fun setTimer(context: Context, seconds: Int, label: String?): String {
        if (seconds !in 1..86_400) return "倒计时要在 1 秒到 24 小时之间"
        val intent = Intent(AlarmClock.ACTION_SET_TIMER)
            .putExtra(AlarmClock.EXTRA_LENGTH, seconds)
            .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
        if (!label.isNullOrBlank()) intent.putExtra(AlarmClock.EXTRA_MESSAGE, label.trim())
        val text = when {
            seconds % 3600 == 0 -> "${seconds / 3600} 小时"
            seconds % 60 == 0 -> "${seconds / 60} 分钟"
            else -> "$seconds 秒"
        }
        return launch(context, intent, "已开始倒计时 $text", "没能设倒计时")
    }

    /** [target] 是号码或通讯录里的名字；名字要读通讯录权限 */
    fun dial(context: Context, target: String): String {
        val t = target.trim()
        if (t.isEmpty()) return "没有说要打给谁"
        val digits = t.filter { it.isDigit() || it == '+' }
        val number: String
        val shown: String
        if (digits.length >= 3 && digits.length >= t.length - 4) {
            number = digits
            shown = digits
        } else {
            if (context.checkSelfPermission(Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
                return "要按名字找人需要通讯录权限（设置 → 语音助手 → 通讯录），或者直接说号码"
            }
            val found = lookup(context, t) ?: return "通讯录里没找到「$t」"
            number = found.second
            shown = "${found.first} $number"
        }
        return launch(context, Intent(Intent.ACTION_DIAL, Uri.fromParts("tel", number, null)), "已打开拨号盘：$shown（按拨号键才会打出去）", "没能打开拨号盘")
    }

    private fun lookup(context: Context, name: String): Pair<String, String>? = runCatching {
        context.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME, ContactsContract.CommonDataKinds.Phone.NUMBER),
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ?",
            arrayOf("%$name%"),
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC",
        )?.use { c -> if (c.moveToFirst()) c.getString(0) to c.getString(1) else null }
    }.getOrNull()

    fun navigate(context: Context, destination: String): String {
        val d = destination.trim()
        if (d.isEmpty()) return "没有说要去哪"
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=" + Uri.encode(d)))
        return launch(context, intent, "已在地图里搜索：$d", "没有可以导航的地图应用")
    }

    /** [action]：play_pause / play / pause / next / previous */
    fun media(context: Context, action: String): String {
        val key = when (action) {
            "play_pause" -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
            "play" -> KeyEvent.KEYCODE_MEDIA_PLAY
            "pause" -> KeyEvent.KEYCODE_MEDIA_PAUSE
            "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
            "previous" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
            else -> return "action 只能是 play_pause / play / pause / next / previous"
        }
        val am = context.getSystemService(AudioManager::class.java) ?: return "没能控制音乐"
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, key))
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, key))
        return when (action) {
            "play" -> "已发送：播放"
            "pause" -> "已发送：暂停"
            "next" -> "已发送：下一首"
            "previous" -> "已发送：上一首"
            else -> "已发送：播放 / 暂停"
        }
    }

    private fun launch(context: Context, intent: Intent, ok: String, fail: String): String = try {
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        ok
    } catch (_: ActivityNotFoundException) {
        fail
    } catch (e: SecurityException) {
        "$fail（${e.message ?: "没有权限"}）"
    } catch (e: Exception) {
        "$fail（${e.message ?: e.javaClass.simpleName}）"
    }
}
